import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, GetCommand, PutCommand, UpdateCommand } from '@aws-sdk/lib-dynamodb';
import { SSMClient, GetParameterCommand } from '@aws-sdk/client-ssm';
import { SESClient, SendEmailCommand } from '@aws-sdk/client-ses';
import { randomBytes, createHash, createHmac, timingSafeEqual } from 'node:crypto';

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const ssm = new SSMClient({});
const ses = new SESClient({});

const sha256 = (s) => createHash('sha256').update(s).digest('hex');

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

function mpManifest({ id, requestId, ts }) {
  return `id:${id};request-id:${requestId};ts:${ts};`;
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
  const body = JSON.parse(event.body || '{}');
  const headers = event.headers || {};
  const paymentId = event.queryStringParameters?.['data.id'] ?? body?.data?.id;

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
    return { statusCode: 400, body: JSON.stringify({ error: 'payment-not-found-upstream' }) };
  }
  const payment = await paymentRes.json();

  if (payment.status !== 'approved') {
    return { statusCode: 200, body: JSON.stringify({ ignored: payment.status }) };
  }

  const orderId = payment.external_reference;
  const orderResult = await ddb.send(new GetCommand({
    TableName: 'svod-orders',
    Key: { orderId },
  }));
  const order = orderResult.Item;
  if (!order) {
    return { statusCode: 200, body: JSON.stringify({ error: 'unknown-order' }) };
  }

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
    if (err.name === 'ConditionalCheckFailedException') {
      return { statusCode: 200, body: JSON.stringify({ ok: true, idempotent: true }) };
    }
    throw err;
  }

  const now = Math.floor(Date.now() / 1000);
  await ddb.send(new UpdateCommand({
    TableName: 'svod-entitlements',
    Key: { userEmail: order.userEmail, productId: order.productId },
    UpdateExpression: 'SET grantedAt = :now REMOVE revokedAt',
    ExpressionAttributeValues: { ':now': now },
  }));


  const token = randomBytes(24).toString('base64url');
  const tokenHash = sha256(token);
  await ddb.send(new PutCommand({
    TableName: 'svod-magic-links',
    Item: { tokenHash, userEmail: order.userEmail, expiresAt: now + 15 * 60, usedAt: null },
  }));

  const link = `https://${process.env.DISTRIBUTION_DOMAIN}/api/auth/callback?token=${token}`;
  await ses.send(new SendEmailCommand({
    Source: 'sevakunjadas.bms@gmail.com',
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

  return { statusCode: 200, body: JSON.stringify({ ok: true }) };
};
