# Per-workspace settings. Kept in code rather than in a .tfvars file so an
# apply can never silently fall back to the defaults (no domain, no
# protection) because someone forgot a -var-file.
#
# Switching to the real domain is two steps, because delegating the domain's
# nameservers to Route 53 happens at the registrar, outside Terraform:
#
#   1. Set `domain` and apply. Creates the Route 53 zone, the certificate,
#      and the SES/DKIM/SPF/DMARC records. Nothing user-facing changes yet.
#      Copy the `name_servers` output into the registrar.
#   2. Once `dig NS <domain>` returns those nameservers, set
#      `serve_on_domain = true` and apply. This waits for the certificate,
#      attaches the domain to CloudFront, and switches email links,
#      Mercado Pago back_urls, the signed-cookie policy and the email sender.
locals {
  workspace_settings = {
    default = {
      domain          = ""
      serve_on_domain = false
      protect_data    = false
    }
    cliente = {
      domain          = ""
      serve_on_domain = false
      protect_data    = true
    }
  }

  settings        = local.workspace_settings[terraform.workspace]
  domain          = local.settings.domain
  has_domain      = local.domain != ""
  serve_on_domain = local.has_domain && local.settings.serve_on_domain

  # domain.tf's resources all have count 0 without a domain, but the provider
  # still validates their arguments, and an empty name fails that.
  zone_name = local.has_domain ? local.domain : "unset.invalid"

  # The domain buyers see in links, back_urls and the signed-cookie policy.
  site_domain = local.serve_on_domain ? local.domain : aws_cloudfront_distribution.distribution.domain_name

  # Until the domain's DKIM is live, mail goes out from the verified address
  # below (and, in SES sandbox mode, can only go to verified addresses).
  dev_sender_email = "sevakunjadas.bms@gmail.com"
  sender_email     = local.serve_on_domain ? "no-reply@${local.domain}" : local.dev_sender_email

  # In sandbox mode SES also checks ses:SendEmail against the recipient's
  # identity, so the verified dev address stays in the list after the switch.
  ses_identity_arns = concat(
    [aws_ses_email_identity.sender.arn],
    aws_ses_domain_identity.site[*].arn,
  )
}
