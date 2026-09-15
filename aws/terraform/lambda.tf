resource "aws_iam_role" "lambda_role" {
  name = "playback_token_lambda"

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

resource "aws_iam_role_policy" "lambda_policy" {
  name = "playback_token_lambda_policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ssm:GetParameter",
        ]
        Effect   = "Allow"
        Resource = aws_ssm_parameter.movie_signing_key_private.arn
      },
      {
        Action = [
          "kms:Decrypt"
        ]
        Effect   = "Allow"
        Resource = data.aws_kms_alias.ssm_default.target_key_arn
      },
    ]
  })
}

data "aws_kms_alias" "ssm_default" {
  name = "alias/aws/ssm"
}


data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file  = "${path.module}/lambda/playback-token/index.mjs"
  output_path = "${path.module}/lambda/playback-token/index.zip"
}

resource "aws_lambda_function" "playback_token" {
  function_name = "playback_token"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.handler"
  runtime       = "nodejs24.x"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      DISTRIBUTION_DOMAIN = aws_cloudfront_distribution.distribution.domain_name
      PUBLIC_KEY_ID = aws_cloudfront_public_key.movie_key.id
    }
  }
}