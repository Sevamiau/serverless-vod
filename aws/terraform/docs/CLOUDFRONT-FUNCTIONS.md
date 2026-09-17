# CloudFront Functions, in depth

Step 4 added `referer-lock.js`, but the *mechanism* it runs on — CloudFront
Functions — is a genuinely different thing from "a Lambda that runs when a request
comes in," even though it's easy to conflate the two. Worth understanding on its own.

## Not Lambda@Edge, a different (older-purpose, newer) product

AWS has two distinct ways to run code at the CloudFront edge:

- **Lambda@Edge** — real Lambda functions (Node/Python/etc., full runtime, can call
  other AWS services, can run on all four event types: viewer-request,
  origin-request, origin-response, viewer-response), but with real cold-start
  latency and per-invocation cost, and it must be authored in `us-east-1` and
  replicated globally by AWS.
- **CloudFront Functions** — a much smaller, purpose-built JS runtime. Sub-millisecond
  execution, no cold starts worth mentioning, effectively free at low-to-moderate
  volume, but deliberately limited: **only** `viewer-request` and `viewer-response`
  events, no network calls, no filesystem, no npm packages, a restricted subset of
  JavaScript, and a hard size/complexity ceiling (10 KB of code).

`referer-lock.js` only needs to read two headers and do string comparison — nothing
that needs Lambda@Edge's extra power — so a CloudFront Function is the right-sized
tool, not a scaled-down compromise.

## The event object shape

A CloudFront Function receives a single `event` argument shaped like this (trimmed to
the parts this project uses):

```json
{
  "version": "1.0",
  "context": { "eventType": "viewer-request" },
  "viewer": { "ip": "1.2.3.4" },
  "request": {
    "method": "GET",
    "uri": "/movie/test.txt",
    "querystring": {},
    "headers": {
      "host": { "value": "d2on72j9tqcbnv.cloudfront.net" },
      "referer": { "value": "https://d2on72j9tqcbnv.cloudfront.net/index.html" }
    },
    "cookies": {}
  }
}
```

Two things worth noticing: header names are lowercased keys, and each header's value
sits one level deeper (`headers.host.value`, not `headers.host`) because CloudFront
also supports multi-value headers under a parallel `multiValue` key — the shape
reserves room for that even when, like here, you only care about a single value.

## What the handler can return

A `viewer-request` function has exactly two valid moves:

- **Return the `request` object** (unchanged, or with fields you deliberately
  modified — not used here, but this is how you'd rewrite a URI or add a header) —
  CloudFront continues normal processing: cache lookup, then the `/movie/*`
  behavior's other viewer-access checks (Step 3's trusted key group), then the
  origin fetch if everything else also passes.
- **Return a response object** (`{ statusCode, statusDescription, ... }`) — this
  short-circuits immediately. CloudFront never checks the cache, never evaluates
  signed cookies, never asks the origin. The viewer gets exactly what the function
  returned and nothing else runs.

`referer-lock.js` uses the second form to reject a bad referer immediately, and the
first form (implicitly, by returning `request` unmodified) to let a good one continue
on to Step 3's signed-cookie check.

## Why compare against `Host`, not a hardcoded domain

The obvious-looking alternative — hardcode the distribution's own domain and check
`referer === "https://d2on72j9tqcbnv.cloudfront.net/..."` — has a real
chicken-and-egg problem: that domain doesn't exist until *after* the first
`terraform apply`, and it changes on every destroy/recreate cycle (see
`CHECKLIST.md`). Comparing against the request's own `Host` header instead means the
function is correct regardless of which distribution it happens to be running on,
with zero hardcoded values to keep in sync.

## Testing it without curl

`curl` can't isolate this function's behavior on its own, because the movie behavior
also has Step 3's `trusted_key_groups` check active — any request without a valid
signed cookie gets `403` regardless of what the referer check would have decided.
That's why this step is verified with `aws cloudfront test-function` and hand-built
event JSON instead: it calls the function directly, bypassing the cache-behavior
pipeline entirely, so the only thing under test is the function's own logic. See the
README's Step 4 gotchas for the exact CLI quirks that came up doing this
(`fileb://` vs `file://`, `DEVELOPMENT` vs `LIVE` stage).
