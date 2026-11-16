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
      {
        Action = [
          "dynamodb:GetItem",
        ]
        Effect = "Allow"
        Resource = [
          aws_dynamodb_table.sessions.arn,
          aws_dynamodb_table.entitlements.arn,
        ]
      },
      {
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query",
        ]
        Effect = "Allow"
        Resource = [
          aws_dynamodb_table.devices.arn,
          aws_dynamodb_table.play_events.arn,
        ]
      },

    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_role.id
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function_url" "playback_token_url" {
  function_name      = aws_lambda_function.playback_token.function_name
  authorization_type = "AWS_IAM"
}

resource "aws_lambda_permission" "allow_function_url" {
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.playback_token.function_name
  principal              = "cloudfront.amazonaws.com"
  source_arn             = aws_cloudfront_distribution.distribution.arn
  function_url_auth_type = "AWS_IAM"
}

resource "aws_lambda_permission" "allow_function_url_invoke_function" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.playback_token.function_name
  principal     = "cloudfront.amazonaws.com"
  source_arn    = aws_cloudfront_distribution.distribution.arn
}

data "aws_kms_alias" "ssm_default" {
  name = "alias/aws/ssm"
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/playback-token/index.mjs"
  output_path = "${path.module}/lambda/playback-token/index.zip"
}

resource "aws_lambda_function" "playback_token" {
  function_name = "playback_token"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.handler"
  runtime       = "nodejs24.x"
  timeout       = 10

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda["playback_token"].name
  }

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      PUBLIC_KEY_ID = aws_cloudfront_public_key.movie_key.id
    }
  }
  lifecycle {
    ignore_changes = [environment]
  }
}

resource "aws_cloudfront_origin_access_control" "lambda_oac" {
  name                              = "lambda_oac"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "null_resource" "set_lambda_distribution_domian" {
  triggers = {
    site_domain   = local.site_domain
    public_key_id = aws_cloudfront_public_key.movie_key.id
  }
  provisioner "local-exec" {
    command = "aws lambda update-function-configuration --function-name ${aws_lambda_function.playback_token.function_name} --environment 'Variables={SITE_DOMAIN=${local.site_domain},PUBLIC_KEY_ID=${aws_cloudfront_public_key.movie_key.id}}'"
    environment = {
      AWS_PROFILE = local.aws_profile
      AWS_REGION  = local.aws_region
    }
  }
}