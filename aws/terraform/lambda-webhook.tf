
removed {
  from = aws_ssm_parameter.mp_webhook_secret
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_ssm_parameter.mp_access_token
  lifecycle {
    destroy = false
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
          "${local.ssm_arn}/mp-webhook-secret",
          "${local.ssm_arn}/mp-access-token",
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
        Action   = ["dynamodb:PutItem"]
        Effect   = "Allow"
        Resource = aws_dynamodb_table.users.arn
      },
      {
        Action   = ["ses:SendEmail"]
        Effect   = "Allow"
        Resource = local.ses_identity_arns
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

  reserved_concurrent_executions = try(local.settings.lambda_caps.webhook, -1)

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda["mercadopago_webhook"].name
  }

  filename         = data.archive_file.webhook_lambda_zip.output_path
  source_code_hash = data.archive_file.webhook_lambda_zip.output_base64sha256

  environment {
    variables = {
      SITE_DOMAIN   = local.site_domain
      SENDER_EMAIL  = local.sender_email
      FILM_TITLE    = local.settings.film_title
      CONTACT_EMAIL = local.settings.contact_email
    }
  }
}

resource "aws_lambda_function_url" "webhook_url" {
  function_name      = aws_lambda_function.webhook.function_name
  authorization_type = "NONE"
}

resource "aws_lambda_permission" "webhook_url_public" {
  statement_id           = "FunctionURLAllowPublicAccess"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.webhook.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "webhook_invoke_function" {
  statement_id             = "FunctionURLAllowInvokeAction"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.webhook.function_name
  principal                = "*"
  invoked_via_function_url = true
}

output "mercadopago_webhook_url" {
  value = aws_lambda_function_url.webhook_url.function_url
}
