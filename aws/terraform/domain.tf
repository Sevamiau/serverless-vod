# Everything the custom domain needs. All of it is created as soon as
# `domain` is set in settings.tf, but stays inert until `serve_on_domain`.

resource "aws_route53_zone" "site" {
  count = local.has_domain ? 1 : 0
  name  = local.zone_name

  # Recreating the zone assigns new nameservers, which would take the site and
  # its email offline until the registrar is updated again.
  lifecycle {
    prevent_destroy = true
  }
}

# CloudFront only accepts certificates from us-east-1.
resource "aws_acm_certificate" "site" {
  count                     = local.has_domain ? 1 : 0
  provider                  = aws.us_east_1
  domain_name               = local.zone_name
  subject_alternative_names = ["www.${local.zone_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in flatten(aws_acm_certificate.site[*].domain_validation_options) : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = aws_route53_zone.site[0].zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 300
  allow_overwrite = true
}

# Waits until ACM sees the records above, which only happens once the
# registrar delegates to the zone's nameservers. That's why it's gated on
# serve_on_domain and not on has_domain.
resource "aws_acm_certificate_validation" "site" {
  count                   = local.serve_on_domain ? 1 : 0
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.site[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# A records only: the distribution has IPv6 disabled because the signed
# cookie's IP condition assumes IPv4, so there's no AAAA on purpose.
resource "aws_route53_record" "site" {
  for_each = local.serve_on_domain ? toset([local.zone_name, "www.${local.zone_name}"]) : toset([])

  zone_id = aws_route53_zone.site[0].zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.distribution.domain_name
    zone_id                = aws_cloudfront_distribution.distribution.hosted_zone_id
    evaluate_target_health = false
  }
}

# --- Email: SES domain identity, DKIM, custom MAIL FROM, SPF, DMARC ---------
# With these in place, mail from no-reply@<domain> passes DMARC, which mail
# sent from a @gmail.com address through SES never can.

resource "aws_ses_domain_identity" "site" {
  count  = local.has_domain ? 1 : 0
  domain = local.zone_name
}

resource "aws_route53_record" "ses_verification" {
  count   = local.has_domain ? 1 : 0
  zone_id = aws_route53_zone.site[0].zone_id
  name    = "_amazonses.${local.zone_name}"
  type    = "TXT"
  ttl     = 600
  records = [aws_ses_domain_identity.site[0].verification_token]
}

resource "aws_ses_domain_dkim" "site" {
  count  = local.has_domain ? 1 : 0
  domain = aws_ses_domain_identity.site[0].domain
}

resource "aws_route53_record" "ses_dkim" {
  count   = local.has_domain ? 3 : 0
  zone_id = aws_route53_zone.site[0].zone_id
  name    = "${aws_ses_domain_dkim.site[0].dkim_tokens[count.index]}._domainkey.${local.zone_name}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_ses_domain_dkim.site[0].dkim_tokens[count.index]}.dkim.amazonses.com"]
}

resource "aws_ses_domain_mail_from" "site" {
  count            = local.has_domain ? 1 : 0
  domain           = aws_ses_domain_identity.site[0].domain
  mail_from_domain = "mail.${local.zone_name}"
}

resource "aws_route53_record" "ses_mail_from_mx" {
  count   = local.has_domain ? 1 : 0
  zone_id = aws_route53_zone.site[0].zone_id
  name    = aws_ses_domain_mail_from.site[0].mail_from_domain
  type    = "MX"
  ttl     = 600
  records = ["10 feedback-smtp.${local.aws_region}.amazonses.com"]
}

resource "aws_route53_record" "ses_mail_from_spf" {
  count   = local.has_domain ? 1 : 0
  zone_id = aws_route53_zone.site[0].zone_id
  name    = aws_ses_domain_mail_from.site[0].mail_from_domain
  type    = "TXT"
  ttl     = 600
  records = ["v=spf1 include:amazonses.com ~all"]
}

# p=none only reports; tighten to quarantine once a few weeks of mail have
# gone out cleanly.
resource "aws_route53_record" "dmarc" {
  count   = local.has_domain ? 1 : 0
  zone_id = aws_route53_zone.site[0].zone_id
  name    = "_dmarc.${local.zone_name}"
  type    = "TXT"
  ttl     = 600
  records = ["v=DMARC1; p=none"]
}
