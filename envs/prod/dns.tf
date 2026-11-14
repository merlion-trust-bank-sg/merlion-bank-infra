# HTTPS for the bank: an ACM certificate for the app's hostname in the course's shared zone. ExternalDNS
# (deploy/platform/<env>/external-dns.yaml) points the hostname at the ALB; the ALB serves the
# certificate. The zone belongs to the course and other groups have records in it: only names ending in
# our hostname may be changed (CI role and ExternalDNS role, see modules/iam-ci and modules/addons).
# Hostname and zone come from modules/dns, the same values bootstrap gives the CI role.
module "dns" {
  source = "../../modules/dns"
}

locals {
  app_hostname = module.dns.hostnames[local.environment]
}

data "aws_route53_zone" "course" {
  count = local.enabled ? 1 : 0

  zone_id = module.dns.zone_id
}

resource "aws_acm_certificate" "app" {
  count = local.enabled ? 1 : 0

  domain_name       = local.app_hostname
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# ACM checks this record to confirm we control the name, then issues the certificate
resource "aws_route53_record" "app_validation" {
  for_each = {
    for o in flatten(aws_acm_certificate.app[*].domain_validation_options) : o.domain_name => o
  }

  zone_id         = data.aws_route53_zone.course[0].zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 300
  allow_overwrite = true # the same record survives a rebuild if the nightly cleanup leaves it
}

# Waits until the certificate is issued (a few minutes), so the ALB never gets a pending one
resource "aws_acm_certificate_validation" "app" {
  count = local.enabled ? 1 : 0

  certificate_arn         = aws_acm_certificate.app[0].arn
  validation_record_fqdns = [for r in aws_route53_record.app_validation : r.fqdn]
}
