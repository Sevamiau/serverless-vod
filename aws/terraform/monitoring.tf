

locals {
  lambda_names = {
    api            = aws_lambda_function.api.function_name
    playback_token = aws_lambda_function.playback_token.function_name
    webhook        = aws_lambda_function.webhook.function_name
  }
}

resource "aws_cloudwatch_log_group" "lambda" {
  for_each          = toset(["api", "playback_token", "mercadopago_webhook"])
  name              = "/serverless-vod/lambda/${each.key}"
  retention_in_days = 90
}

resource "aws_sns_topic" "alerts" {
  name = "svod-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = local.settings.alert_email
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each            = local.lambda_names
  alarm_name          = "svod-${each.key}-errors"
  alarm_description   = "The ${each.value} Lambda threw an error or timed out."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_log_metric_filter" "webhook_problems" {
  for_each = {
    bad_signature   = "\"MP webhook REJECTED\" \"bad-signature\""
    lookup_failed   = "\"MP payment lookup failed\""
    amount_mismatch = "\"MP payment does not match order\""
  }
  name           = "svod-webhook-${each.key}"
  log_group_name = aws_cloudwatch_log_group.lambda["mercadopago_webhook"].name
  pattern        = each.value

  metric_transformation {
    name          = "WebhookProblems"
    namespace     = "ServerlessVod"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "webhook_problems" {
  alarm_name          = "svod-webhook-problems"
  alarm_description   = "The webhook rejected a signed notification, couldn't look up a payment, or saw a payment that doesn't match its order. Check the mercadopago_webhook logs."
  namespace           = "ServerlessVod"
  metric_name         = "WebhookProblems"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "ses_reputation" {
  for_each = {
    bounce    = { metric = "Reputation.BounceRate", threshold = 0.05 }
    complaint = { metric = "Reputation.ComplaintRate", threshold = 0.001 }
  }
  alarm_name          = "svod-ses-${each.key}-rate"
  alarm_description   = "SES ${each.key} rate reached the level where AWS reviews the account."
  namespace           = "AWS/SES"
  metric_name         = each.value.metric
  statistic           = "Maximum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_budgets_budget" "monthly" {
  name         = "svod-monthly"
  budget_type  = "COST"
  limit_amount = tostring(local.settings.monthly_budget)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [local.settings.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [local.settings.alert_email]
  }
}
