output "environment" {
  value = local.environment
}

output "name_prefix" {
  value = local.name
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "databases" {
  value = module.rds.databases
}

# Read by the Argo CD bootstrap step and passed to the add-ons as cluster annotations
output "vpc_id" {
  value = module.network.vpc_id
}

# Read by the Argo CD bootstrap step and passed to the app as cluster annotations (they change on
# every rebuild, so they can't live in Git)
output "app_secrets" {
  description = "Secrets Manager secrets the app's ExternalSecrets read"
  value = {
    accounts_db = module.rds.databases["accounts"].master_secret_arn
    ledger_db   = module.rds.databases["ledger"].master_secret_arn
    jwt         = aws_secretsmanager_secret.jwt.name
  }
}

output "db_hosts" {
  description = "RDS endpoint per database"
  value       = { for k, db in module.rds.databases : k => db.address }
}
