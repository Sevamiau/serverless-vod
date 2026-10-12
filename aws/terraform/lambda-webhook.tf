
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
        Action = ["ssm:GetParameter"]
        Effect = "Allow"
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
  timeout       = 10

  filename         = data.archive_file.webhook_lambda_zip.output_path
  source_code_hash = data.archive_file.webhook_lambda_zip.output_base64sha256

  environment {
    variables = {
      DISTRIBUTION_DOMAIN = aws_cloudfront_distribution.distribution.domain_name
    }
  }
}


resource "aws_lambda_function_url" "webhook_url" {
  function_name      = aws_lambda_function.webhook.function_name
  authorization_type = "NONE"
}

output "mercadopago_webhook_url" {
  value = aws_lambda_function_url.webhook_url.function_url
}
