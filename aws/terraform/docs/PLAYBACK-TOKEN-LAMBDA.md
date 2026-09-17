# Deep dive: `playback-token/index.mjs`

This walks through the signing Lambda function by function. It assumes you know
JavaScript already but haven't worked with CloudFront's signed-cookie format or
Node's `crypto` module before — which is exactly the gap this file lives in.

## What this file is for

One job: given a request for a playback token, produce three cookies that
CloudFront's trusted key group (Step 3) will accept as proof the viewer is allowed to
watch `/movie/*`. It does this once, when a buyer starts a session — not on every
segment request. See `SIGNED-COOKIES.md` for how CloudFront verifies what this file
produces; this doc is about the producing side.

## The shape of the policy

CloudFront's *custom* policy format (as opposed to the simpler canned policy) is a
JSON document describing exactly what's being permitted:

```js
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
```

Three real constraints get embedded here: **which resource** the cookie is good for,
**until when** (a Unix timestamp, not a duration — CloudFront checks "is now before
this instant?"), and **from which IP**. The `/32` suffix on the IP is CIDR notation
for "exactly this one address, no range." This step used the custom format
specifically because a canned policy can't express the `IpAddress` condition at all
— only `Resource` and `DateLessThan`.

One easy mistake to internalize: `JSON.stringify` here produces a single-line,
whitespace-free string on its own — good, because the signature has to be computed
over the *exact* bytes CloudFront will later reconstruct. If you ever refactor this
to build the object differently, keep it minified; a pretty-printed version with
extra whitespace would produce a signature that doesn't match.

## Why RSA-SHA1, specifically

CloudFront has required RSA with SHA1 for signed cookies/URLs since the feature
launched in 2013, and that hasn't changed since — even though SHA1 is now considered
too weak for most other signature use. This is a case where the platform's contract
is just fixed; you sign with what CloudFront expects to verify with, not with
whatever's currently considered best practice. Worth knowing if you ever hit local
tooling that refuses SHA1-based signing (see `STEP5-SESSION-NOTES.md`) — that's your
environment being stricter than the API you're calling actually requires.

## Signing

```js
function signPolicy(policyJson, privateKeyPem) {
  const sign = createSign('RSA-SHA1');
  sign.update(policyJson);
  sign.end();
  return sign.sign(privateKeyPem);
}
```

`createSign` returns a `Sign` object you feed data into via `.update()` (you could
call this multiple times for streamed data; here it's one shot), then finalize with
`.end()`. `.sign(privateKeyPem)` does the actual RSA math and returns a `Buffer` of
raw signature bytes — not a string, not already encoded. That distinction matters for
the next step.

## CloudFront's base64 variant

Cookie values can't safely contain `+`, `/`, or `=` — they have special meaning in
cookie syntax. So both the policy JSON and the raw signature bytes get standard
base64-encoded first, then run through a character substitution that is specific to
CloudFront (not the more common "base64url" variant used elsewhere on the web):

```js
function cloudfrontSafeBase64(str) {
  return str
    .replace(/\+/g, "-")
    .replace(/=/g, "_")
    .replace(/\//g, "~");
}
```

The pipeline is always **encode, then substitute** — never substitute the raw text
directly. That exact mistake happened while building this: calling
`cloudfrontSafeBase64` on the un-encoded JSON string instead of its base64 form. Since
the function just looks for literal `/` characters to replace, it found the ones
inside `https://` and `/movie/*` and mangled them — while still "succeeding" in the
sense of returning a string with no error. That's the danger with this kind of
code: a wrong order of operations doesn't crash, it just quietly produces the wrong
value.

## Fetching the private key

```js
async function getPrivateKey() {
  const result = await ssm.send(new GetParameterCommand({
    Name: '/serverless-vod/movie-signing-key',
    WithDecryption: true,
  }));
  return result.Parameter.Value;
}
```

`WithDecryption: true` is what turns the `SecureString` back into plaintext PEM —
without it, SSM would hand back the encrypted ciphertext. This call needs the
Lambda's execution role to have both `ssm:GetParameter` on this specific parameter
*and* `kms:Decrypt` permission, since SSM delegates the actual decryption to KMS
under the hood. That IAM policy is part of `lambda.tf`, still to be written.

## The handler, request to response

```js
export const handler = async (event) => {
  const buyer = event.queryStringParameters?.buyer;
  if (!buyer) {
    return { statusCode: 400, body: 'missing buyer' };
  }
  ...
```

The `?buyer=` requirement is a deliberate placeholder, not real entitlement checking
— it exists so the endpoint isn't a wide-open cookie mint, and it marks the exact spot
where real session/purchase verification attaches in a later milestone.

```js
  const host = process.env.DISTRIBUTION_DOMAIN;
  const forwardedFor = event.headers['x-forwarded-for'];
  const sourceIp = forwardedFor ? forwardedFor.split(',')[0].trim() : event.requestContext.http.sourceIp;
```

Neither `host` nor `sourceIp` are trusted from the "obvious" place. `host` comes from
an environment variable set by Terraform, not `event.headers.host`, because
CloudFront rewrites the `Host` header to the origin's own domain before forwarding to
a custom origin like this Lambda — using the request's own `Host` would have signed
a policy for the wrong domain entirely. `sourceIp` comes from `X-Forwarded-For`
rather than `event.requestContext.http.sourceIp`, because that field reflects
CloudFront's own edge server (the actual TCP peer of this specific request), not the
browser sitting on the other side of CloudFront.

```js
  const policy = buildPolicy(host, 300, sourceIp);
  const privateKeyPem = await getPrivateKey();
  const signature = signPolicy(policy, privateKeyPem);

  const policyEncoded = cloudfrontSafeBase64(Buffer.from(policy).toString('base64'));
  const signatureEncoded = cloudfrontSafeBase64(Buffer.from(signature).toString('base64'));
```

Five-minute TTL, build the policy, fetch the key, sign, encode both the policy and
the signature the same way (each independently goes through encode-then-substitute).

```js
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
```

Lambda Function URLs use the same response shape as API Gateway's HTTP API (payload
format 2.0) — a dedicated `cookies` array, rather than trying to cram three
`Set-Cookie` values into one `headers` object (HTTP allows repeated `Set-Cookie`
headers, but a plain JS object can only hold one value per key, so this response
format gives cookies their own field specifically to sidestep that).

`Path=/` matters more than it looks: without it, a cookie set by a response to
`/api/playback-token` defaults to being scoped to `/api/` only, per the cookie spec's
default-path rule — meaning it would never be attached to a later `/movie/*` request
at all. `Secure` makes explicit what's already true here (everything runs over HTTPS
via `redirect-to-https`), so a browser will refuse to send these cookies over a plain
HTTP connection even by mistake.

`Key-Pair-Id` isn't encoded at all — it's just the ID of the public key CloudFront
should check the signature against, plain text, since it's not sensitive.

## Why this can only be fully verified after deployment

Every function here (`buildPolicy`, `cloudfrontSafeBase64`, `signPolicy`) was tested
in isolation locally before being assembled — but the handler as a whole needs a real
SSM parameter, a real distribution domain, and a real CloudFront edge to check the
result against. That's `lambda.tf`'s job to make possible, and the real verification
step, once it exists: a `curl -X POST` for the cookies, then replaying them against
`/movie/*` and watching a `403` finally turn into a `200`.
