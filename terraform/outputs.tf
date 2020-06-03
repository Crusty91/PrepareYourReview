output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.website_cdn.domain_name
}
