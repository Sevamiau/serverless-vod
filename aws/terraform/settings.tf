# then set serve_on_domain and apply again.
locals {
  workspace_settings = {
    default = {
      domain          = ""
      serve_on_domain = false
      protect_data    = false
      alert_email     = "sevakunjadas.bms@gmail.com"
      monthly_budget  = 20
      lambda_caps     = { api = 20, playback_token = 20, webhook = 5 }
      price_ars       = 1
      film_title      = "El florecer de un bombisto"
      contact_email   = ""
    }
    cliente = {
      domain          = "film.ar"
      serve_on_domain = true
      protect_data    = true
      alert_email     = "sevakunjadas.bms@gmail.com"
      monthly_budget  = 20
      lambda_caps     = { api = 20, playback_token = 20, webhook = 5 }
      price_ars       = 4500
      film_title      = "El florecer de un bombisto"
      contact_email   = "hola@film.ar"
    }
  }

  settings        = local.workspace_settings[terraform.workspace]
  domain          = local.settings.domain
  has_domain      = local.domain != ""
  serve_on_domain = local.has_domain && local.settings.serve_on_domain

  ssm_arn = "arn:aws:ssm:${local.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/serverless-vod"

  # validation needs a non-empty name even with count = 0
  zone_name = local.has_domain ? local.domain : "unset.invalid"

  site_domain = local.serve_on_domain ? local.domain : aws_cloudfront_distribution.distribution.domain_name

  dev_sender_email = "sevakunjadas.bms@gmail.com"
  sender_email     = local.serve_on_domain ? "no-reply@${local.domain}" : local.dev_sender_email

  ses_identity_arns = concat(
    [aws_ses_email_identity.sender.arn],
    aws_ses_domain_identity.site[*].arn,
  )
}
