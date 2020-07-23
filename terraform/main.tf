provider "aws" {
    region = var.region
}

terraform {
  backend "s3" {
    bucket = "#{/Common/Terraform/BackEnd/Bucket}#"
    key    = "#{Project}#.tfstate"
    region = "#{/Common/Terraform/BackEnd/Region}#"
  }
}

data "aws_caller_identity" "current" {}

# Setup Static Website (S3)
resource "aws_s3_bucket" "logs" {
  bucket = "${var.site_name}-site-logs"
  acl = "log-delivery-write"

  tags = {
    project = var.project
  }
}

# S3 Static Hosting
resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
  comment = "cloudfront origin access identity"
}

resource "aws_s3_bucket" "www_site" {
  bucket = var.site_name
  
  logging {
    target_bucket = aws_s3_bucket.logs.bucket
    target_prefix = "www.${var.site_name}/"
  }

  website {
    index_document = "index.html"
    error_document = "error.html"
  }

  tags = {
    project = var.project
  }
}

data "aws_iam_policy_document" "s3_policy" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.www_site.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [aws_cloudfront_origin_access_identity.origin_access_identity.iam_arn]
    }
  }

  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.www_site.arn]

    principals {
      type        = "AWS"
      identifiers = [aws_cloudfront_origin_access_identity.origin_access_identity.iam_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "www_site_policy" {
  bucket = aws_s3_bucket.www_site.id
  policy = data.aws_iam_policy_document.s3_policy.json
}


resource "aws_cloudfront_distribution" "website_cdn" {
  enabled      = true
  price_class  = "PriceClass_200"
  http_version = "http1.1"
  aliases = ["www.${var.site_name}"]

  origin {
    origin_id   = "origin-bucket-${aws_s3_bucket.www_site.id}"
    domain_name = "${var.site_name}.s3.${var.region}.amazonaws.com"

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
    minimum_protocol_version = "TLSv1.2_2018"
  }

  tags = {
    project = var.project
  }
}

# Cognito
resource "aws_cognito_user_pool" "userpool" {
  # This is choosen when creating a user pool in the console
  name = var.project

  # ATTRIBUTES
  alias_attributes = ["email", "preferred_username"]

  schema {
    attribute_data_type = "String"
    mutable             = true
    name                = "nickname"
    required            = true
  }

  # POLICY
  password_policy {
    minimum_length    = "8"
    require_lowercase = true
    require_numbers   = true
    require_symbols   = true
    require_uppercase = true
  }

  # MFA & VERIFICATIONS
  mfa_configuration        = "ON"
  auto_verified_attributes = ["email"]

  # MESSAGE CUSTOMIZATIONS
  verification_message_template {
    default_email_option  = "CONFIRM_WITH_LINK"
    email_message_by_link = "You're close te prepare your next review! {##Click Here##}"
    email_subject_by_link = "Welcome on PrepareYourReview"
  }
  email_configuration {
    reply_to_email_address = "signin@prepareyourreview.com"
  }

  # TAGS
  tags = {
    project = var.project
  }

  # DEVICES
  device_configuration {
    challenge_required_on_new_device      = true
    device_only_remembered_on_user_prompt = true
  }
}

# DOMAIN NAME
resource "aws_cognito_user_pool_domain" "userpool" {
  user_pool_id = aws_cognito_user_pool.userpool.id
  # DOMAIN PREFIX
  domain = "${var.project}-91240"
}

resource "aws_cognito_user_pool_client" "userpool" {
  user_pool_id = aws_cognito_user_pool.userpool.id

  # APP CLIENTS
  name                   = "${var.project}-client"
  refresh_token_validity = 30
  read_attributes  = ["nickname"]
  write_attributes = ["nickname"]

  # APP INTEGRATION -
  # APP CLIENT SETTINGS
  supported_identity_providers = ["COGNITO"]
  callback_urls                = ["http://localhost:3000"]
  logout_urls                  = ["http://localhost:3000"]
}

resource "aws_cognito_identity_pool" "identitypool" {
  identity_pool_name               = var.project
  allow_unauthenticated_identities = false
  cognito_identity_providers {
    client_id               = aws_cognito_user_pool_client.userpool.id
    provider_name           = aws_cognito_user_pool.userpool.endpoint
    server_side_token_check = false
  }
}

resource "aws_cognito_identity_pool_roles_attachment" "idroles" {
  identity_pool_id = aws_cognito_identity_pool.identitypool.id

  roles = {
    "authenticated"   = aws_iam_role.api_gateway_access.arn
    "unauthenticated" = aws_iam_role.deny_everything.arn
  }
}

resource "aws_iam_role_policy" "api_gateway_access" {
  name   = "api-gateway-access"
  role   = aws_iam_role.api_gateway_access.id
  policy = data.aws_iam_policy_document.api_gateway_access.json
}

resource "aws_iam_role" "api_gateway_access" {
  name = "ap-gateway-access"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "cognito-identity.amazonaws.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "cognito-identity.amazonaws.com:aud": "${aws_cognito_identity_pool.identitypool.id}"
        },
        "ForAnyValue:StringLike": {
          "cognito-identity.amazonaws.com:amr": "authenticated"
        }
      }
    }
  ]
}
EOF
}

data "aws_iam_policy_document" "api_gateway_access" {
  version = "2012-10-17"
  statement {
    actions = [
      "execute-api:Invoke"
    ]

    effect = "Allow"

    resources = ["arn:aws:execute-api:*:*:*"]
  }
}

resource "aws_iam_role_policy" "deny_everything" {
  name   = "deny_everything"
  role   = aws_iam_role.deny_everything.id
  policy = data.aws_iam_policy_document.deny_everything.json
}

resource "aws_iam_role" "deny_everything" {
  name = "deny_everything"
  # This will grant the role the ability for cognito identity to assume it
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "cognito-identity.amazonaws.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "cognito-identity.amazonaws.com:aud": "${aws_cognito_identity_pool.identitypool.id}"
        },
        "ForAnyValue:StringLike": {
          "cognito-identity.amazonaws.com:amr": "unauthenticated"
        }
      }
    }
  ]
}
EOF
}

data "aws_iam_policy_document" "deny_everything" {
  version = "2012-10-17"

  statement {
    actions = ["*"]
    effect    = "Deny"
    resources = ["*"]
  }
}

# API Gateway
resource "aws_api_gateway_rest_api" "apig" {
  name        = "Secure API Gateway"
  description = "Example Rest Api"
}

resource "aws_api_gateway_resource" "apig_resource" {
  rest_api_id = aws_api_gateway_rest_api.apig.id
  parent_id   = aws_api_gateway_rest_api.apig.root_resource_id
  path_part   = "prepareyourreview"
}

resource "aws_api_gateway_method" "apig_method" {
  rest_api_id   = aws_api_gateway_rest_api.apig.id
  resource_id   = aws_api_gateway_resource.apig_resource.id
  http_method   = "POST"
  authorization = "AWS_IAM"

  request_parameters = {
    "method.request.path.proxy" = true
  }
}

resource "aws_api_gateway_integration" "apig_method-integration" {
  rest_api_id             = aws_api_gateway_rest_api.apig.id
  resource_id             = aws_api_gateway_resource.apig_resource.id
  http_method             = aws_api_gateway_method.apig_method.http_method
  type                    = "AWS_PROXY"
  uri                     = "arn:aws:apigateway:${var.region}:lambda:path/2015-03-31/functions/arn:aws:lambda:${var.region}:${data.aws_caller_identity.current.account_id}:function:${aws_lambda_function.example_test_function.function_name}/invocations"
  integration_http_method = "POST"
}

resource "aws_api_gateway_deployment" "example_deployment_dev" {
  depends_on = [
    aws_api_gateway_method.apig_method,
    aws_api_gateway_integration.apig_method-integration
  ]
  rest_api_id = aws_api_gateway_rest_api.apig.id
  stage_name  = "dev"
}

# Lambda
data "archive_file" "lambda" {
  type        = "zip"
  output_path = "lambda.zip"
  source {
    content = "hello"
    filename = "dummy.txt"
  }
}

resource "aws_lambda_function" "example_test_function" {
  filename         = data.archive_file.lambda.output_path
  function_name    = "${var.project}-lambda-test"
  role             = aws_iam_role.example_api_role.arn
  handler          = "index.handler"
  runtime          = "nodejs10.x"
  source_code_hash = filebase64sha256(data.archive_file.lambda.output_path)
  publish          = true
}

resource "aws_iam_role" "example_api_role" {
  name               = "example_api_role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role_policy.json
}

data "aws_iam_policy_document" "lambda_assume_role_policy" {
  version = "2012-10-17"
  # ASSUME ROLE
  statement {
    actions = [
      "sts:AssumeRole",
    ]

    effect = "Allow"

    principals {
      type = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_lambda_permission" "apigw_lambda" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.example_test_function.function_name
  principal     = "apigateway.amazonaws.com"

   source_arn = "arn:aws:execute-api:${var.region}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.example_api.id}/*/${aws_api_gateway_method.example_api_method.http_method}${aws_api_gateway_resource.example_api_resource.path}"
}