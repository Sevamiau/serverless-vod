output "site_bucket_name" {
  value = aws_s3_bucket.site_bucket.bucket
}

output "movie_bucket_name" {
  value = aws_s3_bucket.movie_bucket.bucket
}

output "distribution_domain_name" {
  value = aws_cloudfront_distribution.distribution.domain_name
}

