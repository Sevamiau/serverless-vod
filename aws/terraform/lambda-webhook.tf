# Mercado Pago can never supply x-amz-content-sha256, so it cannot go through
# the OAC-gated Function URLs the rest of /api/* uses (see
# CLOUDFRONT-OAC-LAMBDA-BODY-BUG.md). This Lambda gets its own public
# Function URL instead, isolated from checkout/order-status/auth: its only
# job is to verify Mercado Pago's own signature, re-fetch the payment from
# Mercado Pago's API, and grant the entitlement. It has no access to
# svod-users, svod-sessions, or anything playback-token touches.

resource "aws_ssm_parameter" "mp_webhook_secret" {
  name  = "/serverless-vod/mp-webhook-secret"
  type  = "SecureString"
  value = "REPLACE_ME"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "mp_access_token" {
  name  = "/serverless-vod/mp-access-token"
  type  = "SecureString"
  value = "REPLACE_ME"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_iam_role" "webhook_lambda_role" {
  name = "mercadopago_webhook_lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "webhook_lambda_policy" {
  name = "mercadopago_webhook_lambda_policy"
  role = aws_iam_role.webhook_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["ssm:GetParameter"]
        Effect   = "Allow"
        Resource = [
          aws_ssm_parameter.mp_webhook_secret.arn,
          aws_ssm_parameter.mp_access_token.arn,
        ]
      },
      {
        Action   = ["kms:Decrypt"]
        Effect   = "Allow"
        Resource = data.aws_kms_alias.ssm_default.target_key_arn
      },
      {
        Action   = ["dynamodb:GetItem"]
        Effect   = "Allow"
        Resource = aws_dynamodb_table.orders.arn
      },
      {
        Action   = ["dynamodb:UpdateItem"]
        Effect   = "Allow"
        Resource = aws_dynamodb_table.orders.arn
      },
      {
        Action   = ["dynamodb:UpdateItem"]
        Effect   = "Allow"
        Resource = aws_dynamodb_table.entitlements.arn
      },
      {
        Action   = ["dynamodb:PutItem"]
        Effect   = "Allow"
        Resource = aws_dynamodb_table.magic_links.arn
      },
      {
        Action   = ["ses:SendEmail"]
        Effect   = "Allow"
        Resource = aws_ses_email_identity.sender.arn
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "webhook_lambda_logs" {
  role       = aws_iam_role.webhook_lambda_role.id
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "archive_file" "webhook_lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/webhook/index.mjs"
  output_path = "${path.module}/lambda/webhook/index.zip"
}

resource "aws_lambda_function" "webhook" {
  function_name = "mercadopago_webhook"
  role          = aws_iam_role.webhook_lambda_role.arn
  handler       = "index.handler"
  runtime       = "nodejs24.x"

  filename         = data.archive_file.webhook_lambda_zip.output_path
  source_code_hash = data.archive_file.webhook_lambda_zip.output_base64sha256

  environment {
    variables = {
      DISTRIBUTION_DOMAIN = aws_cloudfront_distribution.distribution.domain_name
    }
  }
}

# Deliberately public: Mercado Pago cannot sign requests the way CloudFront's
# OAC requires, so this Function URL skips CloudFront entirely. Security here
# comes from mpVerify() inside the handler, not from AWS_IAM.
resource "aws_lambda_function_url" "webhook_url" {
  function_name      = aws_lambda_function.webhook.function_name
  authorization_type = "NONE"
}

output "mercadopago_webhook_url" {
  value = aws_lambda_function_url.webhook_url.function_url
}
