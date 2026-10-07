output "zone_id" {
  value = local.zone_id
}

output "name_servers" {
  value = var.create_zone ? aws_route53_zone.main[0].name_servers : data.aws_route53_zone.main[0].name_servers
}

output "certificate_arn" {
  description = "The VALIDATED certificate — referencing the validation resource makes Ingresses wait for issuance."
  value       = aws_acm_certificate_validation.main.certificate_arn
}
