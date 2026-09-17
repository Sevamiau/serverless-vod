# Step 5, session 1 — building the signing Lambda

Where things stand at the end of this session: `aws/lambda/playback-token/index.mjs`
is written and reviewed. Nothing was applied to AWS — no `lambda.tf` yet, no new
CloudFront behavior, no `terraform apply`. There's genuinely nothing to
`terraform destroy`; the only artifact from today is that one file.

This is worth its own note, separate from the usual per-step "Gotchas" section in
`README.md`, because this step was harder than Steps 1–4 combined, for a reason worth
naming plainly: every previous step's mistakes got caught by `terraform plan` before
they could do anything. A broken cache policy, an undeclared resource, a wrong
attribute name — Terraform refuses to apply any of it. JavaScript has no such
gatekeeper. A logic bug in `index.mjs` doesn't fail loudly; it produces a cookie that
looks completely normal and gets silently rejected by CloudFront later, with no error
message pointing back at the cause. That shift — from "the tool stops me" to "I have
to reason about correctness myself" — is what made this session feel so different.

## What got built

`aws/lambda/playback-token/index.mjs` — given a buyer, builds a CloudFront custom
signed-cookie policy (which path, until when, from which IP), signs it with the
private RSA key stored in SSM (from Step 3), and returns three cookies encoded the
way CloudFront specifically requires.

## Five real bugs, caught before this ever touches AWS

1. **Base64 substitution run on the wrong string.** `cloudfrontSafeBase64` only
   swaps characters — it assumes its input is already base64. Calling it directly on
   the raw JSON policy (skipping the base64-encoding step) silently corrupted the
   actual URL and IP text inside the policy, turning `//` into `~~`.
2. **Fedora's OpenSSL blocked RSA-SHA1 signing locally**, and so did Node (since
   Node on this system dynamically links the same system OpenSSL) — a real,
   environment-specific restriction on using SHA1 for signature operations,
   confirmed unrelated to the actual code by reproducing the identical
   `ERR_OSSL_EVP_INVALID_DIGEST` error from both the `openssl` CLI and a bare Node
   script. Time-boxed rather than chased to a full fix, since it has no bearing on
   the real Lambda — AWS's own Node runtime uses a completely separate OpenSSL build.
3. **CloudFront rewrites the `Host` header when forwarding to a custom origin.**
   Building the policy's `Resource` field from `event.headers.host` would have signed
   the wrong domain (the Lambda Function URL's own domain, not the CloudFront
   distribution's). Fixed by passing the distribution domain in as a Terraform-set
   environment variable instead of trusting the incoming request.
4. **`event.requestContext.http.sourceIp` is CloudFront's edge IP, not the
   viewer's.** CloudFront terminates the browser's connection and opens its own
   separate connection to the Lambda, so the "source" of that second connection is
   CloudFront itself. Fixed by reading the real client IP from the
   `X-Forwarded-For` header, which CloudFront always adds for custom origins.
5. **Cookies default to the path of the URL that set them.** Without an explicit
   `Path=/` attribute, cookies set by a response to `/api/playback-token` would
   default to `Path=/api/` and never be sent on `/movie/*` requests at all — a
   failure that would look exactly like Step 3's original "no cookies" state, with
   no obvious link back to the real cause.

## What's left for Step 5

- `lambda.tf`: an execution role (`ssm:GetParameter` + `kms:Decrypt`, scoped to the
  one signing-key parameter), the function itself (code zipped via Terraform's
  `archive_file` data source), a Function URL, and the two environment variables
  (`DISTRIBUTION_DOMAIN`, `PUBLIC_KEY_ID`) that let the handler avoid trusting
  request headers for either value.
- `cloudfront.tf`: a Lambda-flavored Origin Access Control
  (`origin_access_control_origin_type = "lambda"`), a third origin pointed at the
  Function URL, and a new `ordered_cache_behavior` for `/api/*` — the first behavior
  in this project that needs caching turned off and the POST body, query string, and
  headers actually forwarded through, unlike every GET-only, cache-friendly behavior
  built so far.
- `terraform apply`, then a real `curl -X POST .../api/playback-token?buyer=demo -c
  cookies.txt`, followed by replaying those cookies against `/movie/*` to see the
  whole chain — mint and verify — close for the first time.
