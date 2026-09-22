import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, GetCommand, PutCommand, UpdateCommand } from '@aws-sdk/lib-dynamodb';
import { SESClient, SendEmailCommand } from '@aws-sdk/client-ses';
import { randomBytes, createHash } from 'node:crypto';

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const ses = new SESClient({});

const sha256 = (s) => createHash('sha256').update(s).digest('hex');

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
