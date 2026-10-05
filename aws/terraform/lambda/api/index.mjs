import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, GetCommand, PutCommand, UpdateCommand, QueryCommand } from '@aws-sdk/lib-dynamodb';
import { SESClient, SendEmailCommand } from '@aws-sdk/client-ses';
import { SSMClient, GetParameterCommand } from '@aws-sdk/client-ssm';
import { randomBytes, randomUUID, createHash } from 'node:crypto';

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const ses = new SESClient({});
const ssm = new SSMClient({});

const CFG = {
  productId: 'film01',
  productTitle: 'La película',
  price: { currency: 'ARS', amount: 5000 },
}

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
        success: `https://${process.env.DISTRIBUTION_DOMAIN}/gracias?order_id=${orderId}`,
        failure: `https://${process.env.DISTRIBUTION_DOMAIN}/gracias?order_id=${orderId}&status=failure`,
      },
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

async function upsertUser(email) {
  const normalized = email.trim().toLowerCase();

  const existing = await ddb.send(new GetCommand({
    TableName: 'svod-users',
    Key: { email: normalized },
  }));

  if (existing.Item) return existing.Item;

  const newUser = { email: normalized, createdAt: Math.floor(Date.now() / 1000) };
  await ddb.send(new PutCommand({
    TableName: 'svod-users',
    Item: newUser,
  }));

  return newUser;
}

async function handleCheckout(event) {
  const body = JSON.parse(event.body || '{}');
  const email = body.email ?? '';
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    return { statusCode: 400, body: JSON.stringify({ error: 'email inválido' }) };
  }

  const user = await upsertUser(email);
  const orderId = randomUUID();
  const claim = randomBytes(24).toString('base64url');
  const trace = traceCode();

  await ddb.send(new PutCommand({
    TableName: 'svod-orders',
    Item: {
      orderId,
      claim,
      userEmail: user.email,
      productId: CFG.productId,
      currency: CFG.price.currency,
      amount: CFG.price.amount,
      status: 'pending',
      traceCode: trace,
      createdAt: Math.floor(Date.now() / 1000),
    },
  }));

  const preference = await createMpPreference({ orderId, email: user.email });

  return {
    statusCode: 200,
    body: JSON.stringify({ redirect: preference.init_point }),
    cookies: [`poc_claim=${claim}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=3600`],
  };
}

async function handleOrderStatus(event) {
  const claimCookie = (event.cookies || []).find((c) => c.startsWith('poc_claim='));
  if (!claimCookie) {
    return { statusCode: 200, body: JSON.stringify({ status: 'unknown', reason: 'no-claim-cookie' }) };
  }
  const claim = claimCookie.slice('poc_claim='.length);

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

  const sessionToken = randomBytes(32).toString('base64url');
  const sessionHash = sha256(sessionToken);
  await ddb.send(new PutCommand({
    TableName: 'svod-sessions',
    Item: { tokenHash: sessionHash, userEmail: order.userEmail, expiresAt: Math.floor(Date.now() / 1000) + 30 * 24 * 3600 },
  }));

  return {
    statusCode: 200,
    body: JSON.stringify({ status: 'paid', traceCode: order.traceCode }),
    cookies: [`poc_session=${sessionToken}; Path=/; HttpOnly; Secure; SameSite=Lax`],
  };
}

async function handleAuthRequest(event) {
  const body = JSON.parse(event.body || '{}');
  const email = body.email;

  const userResult = await ddb.send(new GetCommand({
    TableName: 'svod-users',
    Key: { email },
  }));

  if (userResult.Item) {
    const token = randomBytes(24).toString('base64url');
    const tokenHash = sha256(token);
    const expiresAt = Math.floor(Date.now() / 1000) + 15 * 60;

    await ddb.send(new PutCommand({
      TableName: 'svod-magic-links',
      Item: { tokenHash, userEmail: email, expiresAt, usedAt: null },
    }));

    const link = `https://${process.env.DISTRIBUTION_DOMAIN}/api/auth/callback?token=${token}`;
    await ses.send(new SendEmailCommand({
      Source: 'sevakunjadas.bms@gmail.com',
      Destination: { ToAddresses: [email] },
      Message: {
        Subject: { Data: 'Tu enlace de acceso' },
        Body: { Text: { Data: link } },
      },
    }));
  }

  return { statusCode: 200, body: JSON.stringify({ ok: true }) };
}

export const handler = async (event) => {
  const method = event.requestContext.http.method;
  const path = event.rawPath;
  const routes = {
    'POST /api/auth/request': handleAuthRequest,
    'GET /api/auth/callback': handleAuthCallback,
    'POST /api/checkout': handleCheckout,
    'GET /api/order-status': handleOrderStatus,
  };

  const fn = routes[`${method} ${path}`];
  if (!fn) return { statusCode: 404, body: JSON.stringify({ error: 'not found' }) };
  return fn(event);
};



async function handleAuthCallback(event) {
  const token = event.queryStringParameters?.token ?? '';
  const tokenHash = sha256(token);
  const now = Math.floor(Date.now() / 1000);

  const linkResult = await ddb.send(new GetCommand({
    TableName: 'svod-magic-links',
    Key: { tokenHash },
  }));
  const link = linkResult.Item;

  if (!link || link.usedAt || link.expiresAt < now) {
    return { statusCode: 302, headers: { location: '/entrar?error=link' } };
  }

  await ddb.send(new UpdateCommand({
    TableName: 'svod-magic-links',
    Key: { tokenHash },
    UpdateExpression: 'SET usedAt = :now',
    ExpressionAttributeValues: { ':now': now },
  }));

  const sessionToken = randomBytes(32).toString('base64url');
  const sessionHash = sha256(sessionToken);
  await ddb.send(new PutCommand({
    TableName: 'svod-sessions',
    Item: { tokenHash: sessionHash, userEmail: link.userEmail, expiresAt: now + 30 * 24 * 3600 },
  }));

  return {
    statusCode: 302,
    headers: { location: '/ver' },
    cookies: [`poc_session=${sessionToken}; Path=/; HttpOnly; Secure; SameSite=Lax`],
  };
}
