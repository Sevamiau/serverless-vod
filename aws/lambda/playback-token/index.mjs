import { createSign } from 'node:crypto';
import { SSMClient, GetParameterCommand } from '@aws-sdk/client-ssm';

const ssm = new SSMClient({});

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
  const buyer = event.queryStringParameters?.buyer;
  if (!buyer) {
    return { statusCode: 400, body: 'missing buyer' };
  }

  const host = process.env.DISTRIBUTION_DOMAIN;
  const forwardedFor = event.headers['x-forwarded-for'];
  const sourceIp = forwardedFor ? forwardedFor.split(',')[0].trim() : event.requestContext.http.sourceIp;
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
    body: JSON.stringify({ ok: true }),
  };
};