import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, GetCommand, PutCommand, UpdateCommand } from '@aws-sdk/lib-dynamodb';
import { SSMClient, GetParameterCommand } from '@aws-sdk/client-ssm';
import { SESClient, SendEmailCommand } from '@aws-sdk/client-ses';
import { randomBytes, createHash, createHmac, timingSafeEqual } from 'node:crypto';

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const ssm = new SSMClient({});
const ses = new SESClient({});

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

let cachedSecret;
let cachedAccessToken;

async function getWebhookSecret() {
  if (cachedSecret) return cachedSecret;
  const r = await ssm.send(new GetParameterCommand({
    Name: '/serverless-vod/mp-webhook-secret',
    WithDecryption: true,
  }));
  cachedSecret = r.Parameter.Value;
  return cachedSecret;
}

async function getAccessToken() {
  if (cachedAccessToken) return cachedAccessToken;
  const r = await ssm.send(new GetParameterCommand({
    Name: '/serverless-vod/mp-access-token',
    WithDecryption: true,
  }));
  cachedAccessToken = r.Parameter.Value;
  return cachedAccessToken;
}

// per MP docs: omit missing parts, lowercase data.id
function mpManifest({ id, requestId, ts }) {
  let manifest = '';
  if (id) manifest += `id:${String(id).toLowerCase()};`;
  if (requestId) manifest += `request-id:${requestId};`;
  manifest += `ts:${ts};`;
  return manifest;
}

async function mpVerify({ header, id, requestId }) {
  if (!header) return { ok: false, reason: 'missing-signature' };
  const parts = Object.fromEntries(
    header.split(',').map((p) => p.split('=').map((s) => s.trim())));
  const { ts, v1 } = parts;
  if (!ts || !v1) return { ok: false, reason: 'malformed-signature' };

  if (Math.abs(Math.floor(Date.now() / 1000) - Number(ts)) > 600) {
    return { ok: false, reason: 'stale-timestamp' };
  }

  const secret = await getWebhookSecret();
  const expected = createHmac('sha256', secret)
    .update(mpManifest({ id, requestId, ts })).digest('hex');
  const a = Buffer.from(v1);
  const b = Buffer.from(expected);
  if (a.length !== b.length || !timingSafeEqual(a, b)) {
    return { ok: false, reason: 'bad-signature' };
  }
  return { ok: true };
}

export const handler = async (event) => {
  const body = parseJsonBody(event);
  if (!body) return BAD_BODY;
  const headers = event.headers || {};
  const query = event.queryStringParameters || {};

  // ack IPN and non-payment topics so MP stops retrying
  const type = query.type ?? body.type;
  if (query.topic || type !== 'payment') {
    console.log('MP webhook ignored:', query.topic ?? type ?? 'no-type');
    return { statusCode: 200, body: JSON.stringify({ ignored: query.topic ?? type ?? 'no-type' }) };
  }

  const paymentId = query['data.id'] ?? body.data?.id;
  if (!paymentId) {
    return { statusCode: 400, body: JSON.stringify({ error: 'missing-payment-id' }) };
  }

  const v = await mpVerify({
    header: headers['x-signature'],
    id: paymentId,
    requestId: headers['x-request-id'],
  });
  if (!v.ok) {
    console.log('MP webhook REJECTED:', v.reason);
    return { statusCode: 401, body: JSON.stringify({ error: v.reason }) };
  }

  const accessToken = await getAccessToken();
  const paymentRes = await fetch(`https://api.mercadopago.com/v1/payments/${encodeURIComponent(paymentId)}`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!paymentRes.ok) {
    console.error('MP payment lookup failed:', paymentRes.status, paymentId);
    return { statusCode: 400, body: JSON.stringify({ error: 'payment-not-found-upstream' }) };
  }
  const payment = await paymentRes.json();

  const orderId = payment.external_reference;
  if (!orderId) {
    return { statusCode: 200, body: JSON.stringify({ error: 'no-external-reference' }) };
  }
  const orderResult = await ddb.send(new GetCommand({
    TableName: 'svod-orders',
    Key: { orderId },
  }));
  const order = orderResult.Item;
  if (!order) {
    return { statusCode: 200, body: JSON.stringify({ error: 'unknown-order' }) };
  }

  const REVOKING_STATUSES = new Set(['refunded', 'cancelled', 'charged_back']);
  if (payment.status !== 'approved') {
    if (!REVOKING_STATUSES.has(payment.status)) {
      return { statusCode: 200, body: JSON.stringify({ ignored: payment.status }) };
    }

    await ddb.send(new UpdateCommand({
      TableName: 'svod-entitlements',
      Key: { userEmail: order.userEmail, productId: order.productId },
      UpdateExpression: 'SET revokedAt = :now',
      ExpressionAttributeValues: { ':now': Math.floor(Date.now() / 1000) },
    }));
    await ddb.send(new UpdateCommand({
      TableName: 'svod-orders',
      Key: { orderId },
      UpdateExpression: 'SET #s = :status',
      ExpressionAttributeNames: { '#s': 'status' },
      ExpressionAttributeValues: { ':status': payment.status },
    }));

    return { statusCode: 200, body: JSON.stringify({ ok: true, revoked: payment.status }) };
  }

  if (Number(payment.transaction_amount) !== Number(order.amount) || payment.currency_id !== order.currency) {
    console.error('MP payment does not match order', {
      orderId,
      paymentId: payment.id,
      paid: `${payment.transaction_amount} ${payment.currency_id}`,
      expected: `${order.amount} ${order.currency}`,
    });
    await ddb.send(new UpdateCommand({
      TableName: 'svod-orders',
      Key: { orderId },
      UpdateExpression: 'SET #s = :status, providerRef = :ref',
      ExpressionAttributeNames: { '#s': 'status' },
      ExpressionAttributeValues: { ':status': 'amount-mismatch', ':ref': `mp:${payment.id}` },
    }));
    return { statusCode: 200, body: JSON.stringify({ error: 'amount-mismatch' }) };
  }

  if (order.emailedAt) {
    return { statusCode: 200, body: JSON.stringify({ ok: true, idempotent: true }) };
  }

  const now = Math.floor(Date.now() / 1000);
  await ddb.send(new UpdateCommand({
    TableName: 'svod-entitlements',
    Key: { userEmail: order.userEmail, productId: order.productId },
    UpdateExpression: 'SET grantedAt = :now, traceCode = if_not_exists(traceCode, :tc) REMOVE revokedAt',
    ExpressionAttributeValues: { ':now': now, ':tc': order.traceCode },
  }));

  try {
    await ddb.send(new UpdateCommand({
      TableName: 'svod-orders',
      Key: { orderId },
      UpdateExpression: 'SET #s = :paid, providerRef = :ref',
      ConditionExpression: '#s <> :paid',
      ExpressionAttributeNames: { '#s': 'status' },
      ExpressionAttributeValues: { ':paid': 'paid', ':ref': `mp:${payment.id}` },
    }));
  } catch (err) {
    if (err.name !== 'ConditionalCheckFailedException') throw err;
  }

  const token = randomBytes(24).toString('base64url');
  const tokenHash = sha256(token);
  await ddb.send(new PutCommand({
    TableName: 'svod-magic-links',
    Item: { tokenHash, userEmail: order.userEmail, expiresAt: now + 72 * 3600, usedAt: null },
  }));

  const link = `https://${process.env.SITE_DOMAIN}/api/auth/callback?token=${token}`;
  await ses.send(new SendEmailCommand({
    Source: process.env.SENDER_EMAIL,
    Destination: { ToAddresses: [order.userEmail] },
    Message: {
      Subject: { Data: 'Tu acceso a la película' },
      Body: {
        Text: {
          Data: `Gracias por tu compra.\nVer la película: ${link}\nCódigo de tu copia: ${order.traceCode}`,
        },
      },
    },
  }));

  await ddb.send(new UpdateCommand({
    TableName: 'svod-orders',
    Key: { orderId },
    UpdateExpression: 'SET emailedAt = :now',
    ExpressionAttributeValues: { ':now': now },
  }));

  return { statusCode: 200, body: JSON.stringify({ ok: true }) };
};
