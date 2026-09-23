import { createSign, createHash } from 'node:crypto';
import { SSMClient, GetParameterCommand } from '@aws-sdk/client-ssm';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, GetCommand, PutCommand, UpdateCommand, QueryCommand } from '@aws-sdk/lib-dynamodb';

const ssm = new SSMClient({});

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const sha256 = (s) => createHash('sha256').update(s).digest('hex');

const CFG = {
  productId: 'film-01',
  deviceCap: 3,
  concurrencyWindowSec: 60,
};

function getSessionToken(event) {
  const cookies = event.cookies || [];
  for (const c of cookies) {
    const [name, value] = c.split('=');
    if (name === 'poc_session') return value;
  }
  return null;
}

async function getUserEmail(event) {
  const token = getSessionToken(event);
  if (!token) return null;
  const result = await ddb.send(new GetCommand({
    TableName: 'svod-sessions',
    Key: { tokenHash: sha256(token) },
  }));
  const session = result.Item;
  if (!session) return null;
  const now = Math.floor(Date.now() / 1000);
  if (session.expiresAt < now) return null;
  return session.userEmail;
}

async function getEntitlement(userEmail) {
  const result = await ddb.send(new GetCommand({
    TableName: 'svod-entitlements',
    Key: { userEmail, productId: CFG.productId },
  }));
  const item = result.Item;
  if (!item || item.revokedAt) return null;
  return item;
}

async function getDevices(userEmail) {
  const result = await ddb.send(new QueryCommand({
    TableName: 'svod-devices',
    KeyConditionExpression: 'userEmail = :e',
    ExpressionAttributeValues: { ':e': userEmail },
  }));
  return result.Items || [];
}

async function hasOtherActiveDevice(userEmail, deviceHash) {
  const cutoff = Math.floor(Date.now() / 1000) - CFG.concurrencyWindowSec;
  const result = await ddb.send(new QueryCommand({
    TableName: 'svod-play-events',
    KeyConditionExpression: 'userEmail = :e AND createdAt > :cutoff',
    FilterExpression: 'deviceHash <> :d',
    ExpressionAttributeValues: { ':e': userEmail, ':cutoff': cutoff, ':d': deviceHash },
  }));
  return (result.Items || []).length > 0;
}

async function registerDevice(userEmail, deviceHash, label, existing) {
  const now = Math.floor(Date.now() / 1000);
  if (existing) {
    await ddb.send(new UpdateCommand({
      TableName: 'svod-devices',
      Key: { userEmail, deviceHash },
      UpdateExpression: 'SET lastSeen = :now',
      ExpressionAttributeValues: { ':now': now },
    }));
  } else {
    await ddb.send(new PutCommand({
      TableName: 'svod-devices',
      Item: { userEmail, deviceHash, label: (label || 'dispositivo').slice(0, 40), firstSeen: now, lastSeen: now },
    }));
  }
}

async function logPlayEvent(userEmail, deviceHash, ip) {
  const now = Math.floor(Date.now() / 1000);
  await ddb.send(new PutCommand({
    TableName: 'svod-play-events',
    Item: { userEmail, createdAt: now, deviceHash, ip, expiresAt: now + 24 * 3600 },
  }));
}


function buildPolicy(host, ttlSeconds, sourceIp) {
  const expires = Math.floor(Date.now() / 1000) + ttlSeconds;
  const policy = {
    Statement: [{
      Resource: `https://${host}/movie/*`,
      Condition: {
        DateLessThan: { "AWS:EpochTime": expires },
        IpAddress: { "AWS:SourceIp": `${sourceIp}/32` }
      }
    }]
  };
  return JSON.stringify(policy);
}

function cloudfrontSafeBase64(str) {
  return str
    .replace(/\+/g, "-")
    .replace(/=/g, "_")
    .replace(/\//g, "~");
}

function signPolicy(policyJson, privateKeyPem) {
  const sign = createSign('RSA-SHA1');
  sign.update(policyJson);
  sign.end();
  return sign.sign(privateKeyPem);
}

async function getPrivateKey() {
  const result = await ssm.send(new GetParameterCommand({
    Name: '/serverless-vod/movie-signing-key',
    WithDecryption: true,
  }));
  return result.Parameter.Value;
}

export const handler = async (event) => {
  const body = JSON.parse(event.body || '{}');

  const userEmail = await getUserEmail(event);
  if (!userEmail) return { statusCode: 401, body: JSON.stringify({ error: 'no-session' }) };

  const entitlement = await getEntitlement(userEmail);
  if (!entitlement) return { statusCode: 403, body: JSON.stringify({ error: 'no-entitlement' }) };

  const deviceId = String(body.deviceId || '');
  if (deviceId.length < 8) return { statusCode: 400, body: JSON.stringify({ error: 'bad-device-id' }) };
  const deviceHash = sha256(deviceId);

  const devices = await getDevices(userEmail);
  const existingDevice = devices.find((d) => d.deviceHash === deviceHash);
  if (!existingDevice && devices.length >= CFG.deviceCap) {
    return { statusCode: 403, body: JSON.stringify({ error: 'device-cap', devices: devices.length, cap: CFG.deviceCap }) };
  }

  const blocked = await hasOtherActiveDevice(userEmail, deviceHash);
  if (blocked) return { statusCode: 403, body: JSON.stringify({ error: 'concurrency' }) };

  await registerDevice(userEmail, deviceHash, body.label, existingDevice);

  const host = process.env.DISTRIBUTION_DOMAIN;
  const forwardedFor = event.headers['x-forwarded-for'];
  const sourceIp = forwardedFor ? forwardedFor.split(',')[0].trim() : event.requestContext.http.sourceIp;
  await logPlayEvent(userEmail, deviceHash, sourceIp);

  const policy = buildPolicy(host, 300, sourceIp);
  const privateKeyPem = await getPrivateKey();
  const signature = signPolicy(policy, privateKeyPem);
  const policyEncoded = cloudfrontSafeBase64(Buffer.from(policy).toString('base64'));
  const signatureEncoded = cloudfrontSafeBase64(Buffer.from(signature).toString('base64'));

  return {
    statusCode: 200,
    cookies: [
      `CloudFront-Policy=${policyEncoded}; Path=/; Secure`,
      `CloudFront-Signature=${signatureEncoded}; Path=/; Secure`,
      `CloudFront-Key-Pair-Id=${process.env.PUBLIC_KEY_ID}; Path=/; Secure`,
    ],
    body: JSON.stringify({
      ok: true,
      watermark: entitlement.traceCode ?? '??????',
      devices: existingDevice ? devices.length : devices.length + 1,
      cap: CFG.deviceCap,
    }),
  };
};