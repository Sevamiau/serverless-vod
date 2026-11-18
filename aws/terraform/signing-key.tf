# key pair comes from rotate-signing-key.sh and lives only in SSM
data "aws_ssm_parameter" "movie_signing_public_key" {
  name = "/serverless-vod/movie-signing-key-public"
}

locals {
  movie_public_key = data.aws_ssm_parameter.movie_signing_public_key.insecure_value
}

# keyed by fingerprint: a rotated key is a new instance, created before the
# old one is deleted, without create_before_destroy
resource "aws_cloudfront_public_key" "movie_key" {
  for_each    = toset([substr(sha256(local.movie_public_key), 0, 16)])
  name        = "movie-signing-key-${each.key}"
  encoded_key = local.movie_public_key
}

resource "aws_cloudfront_key_group" "movie_key_group" {
  name = "movie-key-group"

  items = [for k in aws_cloudfront_public_key.movie_key : k.id]
}


removed {
  from = aws_ssm_parameter.movie_signing_key_private
  lifecycle {
    destroy = false
  }
}
