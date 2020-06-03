provider "aws" {
    region = var.region
}

terraform {
  backend "s3" {
    bucket = var.backendbucket
    key    = var.backendkey
    region = var.backendregion
  }
}

# Setup Static Website (S3)
resource "aws_s3_bucket" "logs" {
  bucket = "${var.site_name}-site-logs"
  acl = "log-delivery-write"
}

resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
  comment = "cloudfront origin access identity"
}

resource "aws_s3_bucket" "www_site" {
  bucket = var.site_name
  
  logging {
    target_bucket = aws_s3_bucket.logs.bucket
    target_prefix = "www.${var.site_name}/"
  }

  policy = templatefile("bucket_policy.json", {
    origin_access_identity_arn = aws_cloudfront_origin_access_identity.origin_access_identity.cloudfront_access_identity_path
    bucket = aws_s3_bucket.www_site.arn
  })

  website {
    index_document = "index.html"
    error_document = "error.html"
  }
}

resource "aws_cloudfront_distribution" "website_cdn" {
  enabled      = true
  price_class  = "PriceClass_200"
  http_version = "http1.1"
  aliases = ["www.${var.site_name}"]

  origin {
    origin_id   = "origin-bucket-${aws_s3_bucket.www_site.id}"
    domain_name = "www.${var.site_name}.s3.${var.region}.amazonaws.com"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.origin_access_identity.cloudfront_access_identity_path
    }
  }

  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]
    target_origin_id = "origin-bucket-${aws_s3_bucket.www_site.id}"

    min_ttl          = "0"
    default_ttl      = "300"                                              //3600
    max_ttl          = "1200"                                             //86400

    // This redirects any HTTP request to HTTPS. Security first!
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = var.certificate_arn
    ssl_support_method       = "sni-only"
  }
}