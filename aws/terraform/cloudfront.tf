resource "aws_cloudfront_distribution" "distribution" {
  origin {
    domain_name              = aws_s3_bucket.site_bucket.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.site_oac.id
    origin_id                = "s3-site-bucket"
  }

  origin {
    domain_name              = aws_s3_bucket.movie_bucket.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.movie_oac.id
    origin_id                = "s3-movie-bucket"
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "CloudFront distribution for site and movie buckets"
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "s3-site-bucket"

    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6" #instead of forwaded rules

    viewer_protocol_policy = "redirect-to-https"
  }

  ordered_cache_behavior {
    path_pattern     = "/movie/*"
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "s3-movie-bucket"
    cache_policy_id  = "658327ea-f89d-4fab-a63d-7e88639e58f6"

    viewer_protocol_policy = "redirect-to-https"
    trusted_key_groups     = [aws_cloudfront_key_group.movie_key_group.id]

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.referer_lock.arn
    }
  }


  price_class = "PriceClass_100"

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.site_bucket.arn}/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.distribution.arn }
      }
    }]
  })
}

resource "aws_s3_bucket_policy" "movie" {
  bucket = aws_s3_bucket.movie_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.movie_bucket.arn}/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.distribution.arn }
      }
    }]
  })
}

