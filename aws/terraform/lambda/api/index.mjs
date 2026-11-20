import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, GetCommand, PutCommand, UpdateCommand, QueryCommand, DeleteCommand, TransactWriteCommand } from '@aws-sdk/lib-dynamodb';
import { SESClient, SendEmailCommand } from '@aws-sdk/client-ses';
import { SSMClient, GetParameterCommand } from '@aws-sdk/client-ssm';
import { randomBytes, randomUUID, createHash } from 'node:crypto';

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const ses = new SESClient({});
const ssm = new SSMClient({});

function parseViewerIp(headerValue) {
  if (!headerValue) return null;
  const lastColon = headerValue.lastIndexOf(':');
  let ip = headerValue.slice(0, lastColon);
  if (ip.startsWith('[') && ip.endsWith(']')) ip = ip.slice(1, -1);
  return ip;
}

async function checkRateLimit(key, limit, windowSeconds) {
  const windowStart = Math.floor(Date.now() / 1000 / windowSeconds) * windowSeconds;
  try {
    await ddb.send(new UpdateCommand({
      TableName: 'svod-rate-limits',
      Key: { rateLimitKey: `${key}#${windowStart}` },
      UpdateExpression: 'ADD requestCount :one SET expiresAt = if_not_exists(expiresAt, :exp)',
      ConditionExpression: 'attribute_not_exists(requestCount) OR requestCount < :limit',
      ExpressionAttributeValues: { ':one': 1, ':limit': limit, ':exp': windowStart + windowSeconds },
    }));
    return true;
  } catch (err) {
    if (err.name === 'ConditionalCheckFailedException') return false;
    throw err;
  }
}

const CFG = {
  productId: 'film01',
  productTitle: process.env.FILM_TITLE,
  price: { currency: 'ARS', amount: Number(process.env.PRICE_ARS) },
};

let cachedMpAccessToken;
async function getMpAccessToken() {
  if (cachedMpAccessToken) return cachedMpAccessToken;
  const r = await ssm.send(new GetParameterCommand({
    Name: '/serverless-vod/mp-access-token',
    WithDecryption: true,
  }));
  cachedMpAccessToken = r.Parameter.Value;
  return cachedMpAccessToken;
}

async function createMpPreference({ orderId, email }) {
  const accessToken = await getMpAccessToken();
  const res = await fetch('https://api.mercadopago.com/checkout/preferences', {
    method: 'POST',
    headers: { 'content-type': 'application/json', Authorization: `Bearer ${accessToken}` },
    body: JSON.stringify({
      items: [{
        title: CFG.productTitle,
        quantity: 1,
        currency_id: CFG.price.currency,
        unit_price: CFG.price.amount,
      }],
      payer: { email },
      external_reference: orderId,
      notification_url: process.env.MP_WEBHOOK_URL,
      back_urls: {
        success: `https://${process.env.SITE_DOMAIN}/gracias.html?order_id=${orderId}`,
        failure: `https://${process.env.SITE_DOMAIN}/gracias.html?order_id=${orderId}&status=failure`,
      },
      auto_return: 'approved',
    }),
  });
  if (!res.ok) {
    throw new Error(`mp-preference-failed: ${res.status} ${await res.text()}`);
  }
  return res.json();
}

export function traceCode() {
  const A = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  return Array.from(randomBytes(6), (b) => A[b % A.length]).join('');
}

const sha256 = (s) => createHash('sha256').update(s).digest('hex');

function parseJsonBody(event) {
  if (!event.body) return {};
  try {
    const raw = event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString('utf8') : event.body;
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

const BAD_BODY = { statusCode: 400, body: JSON.stringify({ error: 'bad-body' }) };

function getCookie(event, name) {
  const prefix = `${name}=`;
  const cookie = (event.cookies || []).find((c) => c.startsWith(prefix));
  return cookie ? cookie.slice(prefix.length) : null;
}

const SESSION_MAX_AGE = 30 * 24 * 3600;
const DEVICE_REMOVAL_INTERVAL = 30 * 24 * 3600;

const NO_SESSION = { statusCode: 401, body: JSON.stringify({ error: 'no-session' }) };

async function getSessionEmail(event) {
  const token = getCookie(event, 'poc_session');
  if (!token) return null;
  const result = await ddb.send(new GetCommand({
    TableName: 'svod-sessions',
    Key: { tokenHash: sha256(token) },
  }));
  const session = result.Item;
  if (!session || session.expiresAt < Math.floor(Date.now() / 1000)) return null;
  return session.userEmail;
}

async function handleCheckout(event) {
  const body = parseJsonBody(event);
  if (!body) return BAD_BODY;
  const email = typeof body.email === 'string' ? body.email.trim() : '';
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    return { statusCode: 400, body: JSON.stringify({ error: 'email inválido' }) };
  }

  const sourceIp = parseViewerIp(event.headers['cloudfront-viewer-address']) || event.requestContext.http.sourceIp;
  const emailOk = await checkRateLimit(`email:${email.toLowerCase()}`, 5, 60);
  const ipOk = await checkRateLimit(`ip:${sourceIp}`, 10, 60);
  if (!emailOk || !ipOk) {
    return { statusCode: 429, body: JSON.stringify({ error: 'too-many-requests' }) };
  }

  if (!(CFG.price.amount > 0) || !CFG.productTitle) throw new Error('PRICE_ARS / FILM_TITLE not set');

  const userEmail = email.toLowerCase();
  if (await ownsFilm(userEmail)) {
    if (await checkRateLimit(`authreq:${userEmail}`, 1, 60)) await sendSignInLink(userEmail);
    return { statusCode: 200, body: JSON.stringify({ owned: true }) };
  }

  const orderId = randomUUID();
  const claim = randomBytes(24).toString('base64url');
  const trace = traceCode();

  await ddb.send(new PutCommand({
    TableName: 'svod-orders',
    Item: {
      orderId,
      claim,
      userEmail,
      productId: CFG.productId,
      currency: CFG.price.currency,
      amount: CFG.price.amount,
      status: 'pending',
      traceCode: trace,
      createdAt: Math.floor(Date.now() / 1000),
    },
  }));

  const preference = await createMpPreference({ orderId, email: userEmail });

  return {
    statusCode: 200,
    body: JSON.stringify({ redirect: preference.init_point }),
    cookies: [`poc_claim=${claim}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=3600`],
  };
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

async function orderStatusById(orderId) {
  if (!UUID_RE.test(orderId)) {
    return { statusCode: 200, body: JSON.stringify({ status: 'unknown', reason: 'no-claim-cookie' }) };
  }
  const result = await ddb.send(new GetCommand({
    TableName: 'svod-orders',
    Key: { orderId },
  }));
  if (!result.Item) {
    return { statusCode: 200, body: JSON.stringify({ status: 'unknown', reason: 'no-such-order' }) };
  }
  return { statusCode: 200, body: JSON.stringify({ status: result.Item.status }) };
}

async function handleOrderStatus(event) {
  const claim = getCookie(event, 'poc_claim');
  if (!claim) {
    return orderStatusById(event.queryStringParameters?.order_id ?? '');
  }

  const orderResult = await ddb.send(new QueryCommand({
    TableName: 'svod-orders',
    IndexName: 'claim-index',
    KeyConditionExpression: 'claim = :claim',
    ExpressionAttributeValues: { ':claim': claim },
  }));
  const order = orderResult.Items?.[0];

  if (!order) {
    return { statusCode: 200, body: JSON.stringify({ status: 'unknown', reason: 'no-such-order' }) };
  }
  if (order.status !== 'paid') {
    return { statusCode: 200, body: JSON.stringify({ status: order.status }) };
  }

  return {
    statusCode: 200,
    body: JSON.stringify({ status: 'paid', traceCode: order.traceCode }),
  };
}

async function handleAuthRequest(event) {
  const body = parseJsonBody(event);
  if (!body) return BAD_BODY;
  const email = typeof body.email === 'string' ? body.email.trim().toLowerCase() : '';

  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return { statusCode: 400, body: JSON.stringify({ error: 'bad-email' }) };
  }

  const sourceIp = parseViewerIp(event.headers['cloudfront-viewer-address']) || event.requestContext.http.sourceIp;
  const ipOk = await checkRateLimit(`authreq-ip:${sourceIp}`, 5, 60);
  const emailOk = await checkRateLimit(`authreq:${email}`, 1, 60);
  if (!ipOk || !emailOk) {
    return { statusCode: 429, body: JSON.stringify({ error: 'too-many-requests' }) };
  }

  const userResult = await ddb.send(new GetCommand({
    TableName: 'svod-users',
    Key: { email },
  }));

  if (userResult.Item) await sendSignInLink(email);

  return { statusCode: 200, body: JSON.stringify({ ok: true }) };
}

async function sendSignInLink(email) {
  const token = randomBytes(24).toString('base64url');
  const tokenHash = sha256(token);
  const expiresAt = Math.floor(Date.now() / 1000) + 15 * 60;

  await ddb.send(new PutCommand({
    TableName: 'svod-magic-links',
    Item: { tokenHash, userEmail: email, expiresAt, usedAt: null },
  }));

  const link = `https://${process.env.SITE_DOMAIN}/entrar.html#token=${token}`;
  await ses.send(new SendEmailCommand({
    Source: process.env.SENDER_EMAIL,
    Destination: { ToAddresses: [email] },
    Message: {
      Subject: { Data: 'Tu enlace de acceso' },
      Body: { Text: { Data: link } },
    },
  }));
}

async function ownsFilm(email) {
  const r = await ddb.send(new GetCommand({
    TableName: 'svod-entitlements',
    Key: { userEmail: email, productId: CFG.productId },
  }));
  return Boolean(r.Item && !r.Item.revokedAt);
}

export const handler = async (event) => {
  const method = event.requestContext.http.method;
  const path = event.rawPath;
  const routes = {
    'POST /api/auth/request': handleAuthRequest,
    'GET /api/auth/callback': handleLegacyCallback,
    'POST /api/auth/callback': handleAuthCallback,
    'POST /api/auth/link-info': handleLinkInfo,
    'GET /api/product': handleProduct,
    'POST /api/checkout': handleCheckout,
    'GET /api/order-status': handleOrderStatus,
    'POST /api/auth/logout': handleLogout,
    'GET /api/devices': handleListDevices,
    'POST /api/devices/remove': handleRemoveDevice,
  };

  const fn = routes[`${method} ${path}`];
  if (!fn) return { statusCode: 404, body: JSON.stringify({ error: 'not found' }) };
  return fn(event);
};

const BAD_LINK = { statusCode: 400, body: JSON.stringify({ error: 'link' }) };

async function getLiveLink(token) {
  if (typeof token !== 'string' || !token) return null;
  const tokenHash = sha256(token);
  const result = await ddb.send(new GetCommand({ TableName: 'svod-magic-links', Key: { tokenHash } }));
  const link = result.Item;
  if (!link || link.usedAt || link.expiresAt < Math.floor(Date.now() / 1000)) return null;
  return { ...link, tokenHash };
}

// links in emails sent before the confirmation page existed
async function handleLegacyCallback(event) {
  const token = event.queryStringParameters?.token ?? '';
  return { statusCode: 302, headers: { location: `/entrar.html#token=${encodeURIComponent(token)}` } };
}

// read-only, so mail scanners that open the page don't use up the link
async function handleLinkInfo(event) {
  const body = parseJsonBody(event);
  if (!body) return BAD_BODY;
  const link = await getLiveLink(body.token);
  if (!link) return BAD_LINK;
  return { statusCode: 200, body: JSON.stringify({ email: link.userEmail }) };
}

async function handleAuthCallback(event) {
  const body = parseJsonBody(event);
  if (!body) return BAD_BODY;
  const link = await getLiveLink(body.token);
  if (!link) return BAD_LINK;

  const now = Math.floor(Date.now() / 1000);
  try {
    await ddb.send(new UpdateCommand({
      TableName: 'svod-magic-links',
      Key: { tokenHash: link.tokenHash },
      UpdateExpression: 'SET usedAt = :now',
      ConditionExpression: 'usedAt = :null',
      ExpressionAttributeValues: { ':now': now, ':null': null },
    }));
  } catch (err) {
    if (err.name === 'ConditionalCheckFailedException') return BAD_LINK;
    throw err;
  }

  const sessionToken = randomBytes(32).toString('base64url');
  await ddb.send(new PutCommand({
    TableName: 'svod-sessions',
    Item: { tokenHash: sha256(sessionToken), userEmail: link.userEmail, expiresAt: now + SESSION_MAX_AGE },
  }));

  return {
    statusCode: 200,
    body: JSON.stringify({ ok: true }),
    cookies: [`poc_session=${sessionToken}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${SESSION_MAX_AGE}`],
  };
}

async function handleProduct() {
  return {
    statusCode: 200,
    body: JSON.stringify({ title: CFG.productTitle, amount: CFG.price.amount, currency: CFG.price.currency }),
  };
}
async function handleLogout(event) {
  const sessionToken = getCookie(event, 'poc_session');
  if (sessionToken) {
    await ddb.send(new DeleteCommand({
      TableName: 'svod-sessions',
      Key: { tokenHash: sha256(sessionToken) },
    }));
  }

  const expired = 'Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0';
  return {
    statusCode: 200,
    body: JSON.stringify({ ok: true }),
    cookies: ['poc_session', 'CloudFront-Policy', 'CloudFront-Signature', 'CloudFront-Key-Pair-Id']
      .map((name) => `${name}=; ${expired}`),
  };
}

async function handleListDevices(event) {
  const userEmail = await getSessionEmail(event);
  if (!userEmail) return NO_SESSION;

  const [devices, user] = await Promise.all([
    ddb.send(new QueryCommand({
      TableName: 'svod-devices',
      KeyConditionExpression: 'userEmail = :e',
      ExpressionAttributeValues: { ':e': userEmail },
    })),
    ddb.send(new GetCommand({ TableName: 'svod-users', Key: { email: userEmail } })),
  ]);
  const lastRemoval = user.Item?.lastDeviceRemovalAt;

  return {
    statusCode: 200,
    body: JSON.stringify({
      devices: (devices.Items || []).map(({ deviceHash, label, lastSeen }) => ({ deviceHash, label, lastSeen })),
      nextRemovalAt: lastRemoval ? lastRemoval + DEVICE_REMOVAL_INTERVAL : null,
    }),
  };
}

async function handleRemoveDevice(event) {
  const userEmail = await getSessionEmail(event);
  if (!userEmail) return NO_SESSION;

  const body = parseJsonBody(event);
  if (!body) return BAD_BODY;
  const deviceHash = typeof body.deviceHash === 'string' ? body.deviceHash : '';
  if (!/^[0-9a-f]{64}$/.test(deviceHash)) {
    return { statusCode: 400, body: JSON.stringify({ error: 'bad-device' }) };
  }

  const now = Math.floor(Date.now() / 1000);
  try {
    await ddb.send(new TransactWriteCommand({
      TransactItems: [
        {
          Update: {
            TableName: 'svod-users',
            Key: { email: userEmail },
            UpdateExpression: 'SET lastDeviceRemovalAt = :now',
            ConditionExpression: 'attribute_not_exists(lastDeviceRemovalAt) OR lastDeviceRemovalAt <= :cutoff',
            ExpressionAttributeValues: { ':now': now, ':cutoff': now - DEVICE_REMOVAL_INTERVAL },
          },
        },
        {
          Delete: {
            TableName: 'svod-devices',
            Key: { userEmail, deviceHash },
            ConditionExpression: 'attribute_exists(deviceHash)',
          },
        },
      ],
    }));
  } catch (err) {
    if (err.name !== 'TransactionCanceledException') throw err;
    const [userReason, deviceReason] = (err.CancellationReasons || []).map((r) => r.Code);
    if (deviceReason === 'ConditionalCheckFailed') {
      return { statusCode: 404, body: JSON.stringify({ error: 'no-such-device' }) };
    }
    if (userReason === 'ConditionalCheckFailed') {
      return { statusCode: 429, body: JSON.stringify({ error: 'removal-limit' }) };
    }
    throw err;
  }

  return { statusCode: 200, body: JSON.stringify({ ok: true }) };
}
