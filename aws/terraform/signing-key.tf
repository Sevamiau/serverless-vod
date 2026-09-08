resource "tls_private_key" "movie_signing_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_cloudfront_public_key" "movie_key" {
  name        = "movie-signing-key"
  encoded_key = tls_private_key.movie_signing_key.public_key_pem
}

resource "aws_cloudfront_key_group" "movie_key_group" {
  name = "movie-key-group"

  items = [aws_cloudfront_public_key.movie_key.id]
}

resource "aws_ssm_parameter" "movie_signing_key_private" {
  name  = "/serverless-vod/movie-signing-key"
  type  = "SecureString"
  value = tls_private_key.movie_signing_key.private_key_pem
}

