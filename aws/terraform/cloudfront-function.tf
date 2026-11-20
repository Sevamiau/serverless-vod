resource "aws_cloudfront_function" "referer_lock" {
  name    = "referer-lock"
  runtime = "cloudfront-js-2.0"
  comment = "restrict /movie/* to same-origin referer"
  publish = true
  code    = file("${path.module}/cloudfront-function/referer-lock.js")
}

resource "aws_cloudfront_function" "redirect_to_domain" {
  count   = local.serve_on_domain ? 1 : 0
  name    = "redirect-to-domain"
  runtime = "cloudfront-js-2.0"
  comment = "*.cloudfront.net and www -> custom domain"
  publish = true
  code    = templatefile("${path.module}/cloudfront-function/redirect-to-domain.js", { domain = local.domain })
}
