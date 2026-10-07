# ---------------------------------------------------------------------------
# Route53 zone (created or looked up) + one DNS-validated ACM certificate
# covering the apex and every service hostname.
#
# Service A/ALIAS records are deliberately NOT managed here: they point at
# ALBs the Load Balancer Controller creates (Terraform never sees them).
# external-dns writes them from the Ingress hosts, using a TXT ownership
# registry so it only ever touches its own records.
# ---------------------------------------------------------------------------
resource "aws_route53_zone" "main" {
  count = var.create_zone ? 1 : 0
  name  = var.root_domain
}

data "aws_route53_zone" "main" {
  count        = var.create_zone ? 0 : 1
  name         = var.root_domain
  private_zone = false
}

locals {
  zone_id = var.create_zone ? aws_route53_zone.main[0].zone_id : data.aws_route53_zone.main[0].zone_id
}

resource "aws_acm_certificate" "main" {
  domain_name               = var.root_domain
  subject_alternative_names = var.cert_sans
  validation_method         = "DNS"
  key_algorithm             = "EC_prime256v1"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${var.name_prefix}-cert" }
}

# Keyed by the STATIC list of names (known at plan time), with the
# apply-time validation values looked up per name. Keying by
# domain_validation_options directly breaks whenever those are unknown.
locals {
  cert_domains = toset(concat([var.root_domain], var.cert_sans))
  dvo          = { for d in aws_acm_certificate.main.domain_validation_options : d.domain_name => d }
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.cert_domains

  zone_id         = local.zone_id
  name            = local.dvo[each.key].resource_record_name
  type            = local.dvo[each.key].resource_record_type
  ttl             = 60
  records         = [local.dvo[each.key].resource_record_value]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# CAA: only the listed CAs may issue certificates for this domain.
# allow_overwrite REPLACES any CAA set already at the apex — if other teams
# issue certificates elsewhere (e.g. letsencrypt.org), list them too, or set
# caa_issuers = [] to leave CAA alone.
resource "aws_route53_record" "caa" {
  count   = length(var.caa_issuers) > 0 ? 1 : 0
  zone_id = local.zone_id
  name    = var.root_domain
  type    = "CAA"
  ttl     = 3600
  records = concat(
    [for ca in var.caa_issuers : "0 issue \"${ca}\""],
    [for ca in var.caa_issuers : "0 issuewild \"${ca}\""],
  )
  allow_overwrite = true
}
