
resource "aws_route53_zone" "site" {
  count = local.has_domain ? 1 : 0
  name  = local.zone_name

  lifecycle {
    prevent_destroy = true
  }
}

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

locals {
  cert_dvo = { for dvo in flatten(aws_acm_certificate.site[*].domain_validation_options) : dvo.domain_name => dvo }
}

# keys known at plan time; values come from the certificate
resource "aws_route53_record" "cert_validation" {
  for_each = local.has_domain ? toset([local.zone_name, "www.${local.zone_name}"]) : toset([])

  zone_id         = aws_route53_zone.site[0].zone_id
  name            = local.cert_dvo[each.key].resource_record_name
  type            = local.cert_dvo[each.key].resource_record_type
  records         = [local.cert_dvo[each.key].resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

# waits until the registrar points at the zone
resource "aws_acm_certificate_validation" "site" {
  count                   = local.serve_on_domain ? 1 : 0
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.site[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# no AAAA: IPv6 is off on the distribution
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

resource "aws_route53_record" "dmarc" {
  count   = local.has_domain ? 1 : 0
  zone_id = aws_route53_zone.site[0].zone_id
  name    = "_dmarc.${local.zone_name}"
  type    = "TXT"
  ttl     = 600
  records = ["v=DMARC1; p=none"]
}

# receiving: ImprovMX forwards hola@ to a mailbox set in its dashboard
resource "aws_route53_record" "mx" {
  count   = local.has_domain ? 1 : 0
  zone_id = aws_route53_zone.site[0].zone_id
  name    = local.zone_name
  type    = "MX"
  ttl     = 3600
  records = ["10 mx1.improvmx.com", "20 mx2.improvmx.com"]
}

resource "aws_route53_record" "spf" {
  count   = local.has_domain ? 1 : 0
  zone_id = aws_route53_zone.site[0].zone_id
  name    = local.zone_name
  type    = "TXT"
  ttl     = 3600
  records = ["v=spf1 include:spf.improvmx.com include:amazonses.com ~all"]
}
