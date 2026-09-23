resource "aws_iam_role" "api_lambda_role" {
  name = "api_lambda"

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

resource "aws_iam_role_policy" "api_lambda_policy" {
  name = "api_lambda_policy"
  role = aws_iam_role.api_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["dynamodb:GetItem"]
        Effect   = "Allow"
        Resource = aws_dynamodb_table.users.arn
      },
      {
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
        Effect   = "Allow"
        Resource = aws_dynamodb_table.magic_links.arn
      },
      {
        Action   = ["dynamodb:PutItem"]
        Effect   = "Allow"
        Resource = aws_dynamodb_table.sessions.arn
      },
      {
        Action   = ["ses:SendEmail"]
        Effect   = "Allow"
        Resource = aws_ses_email_identity.sender.arn
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "api_lambda_logs" {
  role       = aws_iam_role.api_lambda_role.id
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "archive_file" "api_lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/api/index.mjs"
  output_path = "${path.module}/lambda/api/index.zip"
}

resource "aws_lambda_function" "api" {
  function_name = "api"
  role          = aws_iam_role.api_lambda_role.arn
  handler       = "index.handler"
  runtime       = "nodejs24.x"

  filename         = data.archive_file.api_lambda_zip.output_path
  source_code_hash = data.archive_file.api_lambda_zip.output_base64sha256

  lifecycle {
    ignore_changes = [environment]
  }
}

resource "aws_lambda_function_url" "api_url" {
  function_name      = aws_lambda_function.api.function_name
  authorization_type = "AWS_IAM"
}

resource "aws_lambda_permission" "allow_function_url_api" {
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.api.function_name
  principal              = "cloudfront.amazonaws.com"
  source_arn             = aws_cloudfront_distribution.distribution.arn
  function_url_auth_type = "AWS_IAM"
}

resource "aws_lambda_permission" "allon_api" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "cloudfront.amazonaws.com"
  source_arn    = aws_cloudfront_distribution.distribution.arn
}

resource "null_resource" "set_api_lambda_distribution_domain" {
  triggers = {
    lambda_distribution_domain = aws_cloudfront_distribution.distribution.domain_name
  }
  provisioner "local-exec" {
    command = "aws lambda update-function-configuration --function-name ${aws_lambda_function.api.function_name} --environment 'Variables={DISTRIBUTION_DOMAIN=${aws_cloudfront_distribution.distribution.domain_name}}'"
  }
}