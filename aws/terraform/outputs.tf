output "site_bucket_name" {
  value = aws_s3_bucket.site_bucket.bucket
}

output "movie_bucket_name" {
  value = aws_s3_bucket.movie_bucket.bucket
}

output "distribution_domain_name" {
  value = aws_cloudfront_distribution.distribution.domain_name
}

output "site_domain" {
  description = "The domain buyers use: the custom domain once serve_on_domain is on, else the CloudFront one"
  value       = local.site_domain
}

output "name_servers" {
  description = "Set these at the domain's registrar after the first apply with a domain"
  value       = aws_route53_zone.site[*].name_servers
}

output "distribution_id" {
  value = aws_cloudfront_distribution.distribution.id
}
