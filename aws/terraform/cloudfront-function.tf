resource "aws_cloudfront_function" "referer_lock" {
  name    = "referer-lock"
  runtime = "cloudfront-js-2.0"
  comment = "restrict /movie/* to same-origin referer"
  publish = true
  code    = file("${path.module}/cloudfront-function/referer-lock.js")
}