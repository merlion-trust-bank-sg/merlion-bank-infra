# Whether prod exists (var.enabled). bootstrap.sh skips prod when it doesn't.
output "enabled" {
  value = local.enabled
}

output "environment" {
  value = local.environment
}

output "name_prefix" {
  value = local.name
}

output "eks_cluster_name" {
  value = local.enabled ? module.eks[0].cluster_name : null
}

output "eks_cluster_endpoint" {
  value = local.enabled ? module.eks[0].cluster_endpoint : null
}

output "databases" {
  value = local.enabled ? module.rds[0].databases : null
}

# Read by the Argo CD bootstrap step and passed to the add-ons as cluster annotations
output "vpc_id" {
  value = local.enabled ? module.network[0].vpc_id : null
}

# Read by the Argo CD bootstrap step and passed to the app as cluster annotations (they change on
# every rebuild, so they can't live in Git)
output "app_secrets" {
  description = "Secrets Manager secrets the app's ExternalSecrets read"
  value = local.enabled ? {
    accounts_db = module.rds[0].databases["accounts"].master_secret_arn
    ledger_db   = module.rds[0].databases["ledger"].master_secret_arn
    jwt         = aws_secretsmanager_secret.jwt[0].name
  } : null
}

output "db_hosts" {
  description = "RDS endpoint per database"
  value       = local.enabled ? { for k, db in module.rds[0].databases : k => db.address } : null
}

# Read by the Argo CD bootstrap step and passed to the app and ExternalDNS as cluster annotations
output "app_hostname" {
  value = local.app_hostname
}

output "certificate_arn" {
  description = "Issued ACM certificate for app_hostname (the ALB's HTTPS listener)"
  value       = local.enabled ? aws_acm_certificate_validation.app[0].certificate_arn : null
}

output "dns_zone_id" {
  value = module.dns.zone_id
}
