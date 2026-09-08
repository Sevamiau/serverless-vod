resource "aws_s3_bucket" "site_bucket" {
  bucket_prefix = "site-bucket-"
  force_destroy = true
}

resource "aws_s3_bucket" "movie_bucket" {
  bucket_prefix = "movie-bucket-"
  force_destroy = true
}


resource "aws_s3_bucket_public_access_block" "site" {
  bucket = aws_s3_bucket.site_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "movie" {
  bucket = aws_s3_bucket.movie_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}


resource "aws_cloudfront_origin_access_control" "site_oac" {
  name                              = "site_oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_origin_access_control" "movie_oac" {
  name                              = "movie_oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}