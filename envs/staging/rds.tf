module "rds" {
  source = "../../modules/rds"

  name = local.name

  # Bank of Anthos uses two PostgreSQL databases. RDS database names can't contain hyphens.
  databases = {
    accounts = { db_name = "accountsdb" }
    ledger   = { db_name = "ledgerdb" }
  }

  vpc_id                     = module.network.vpc_id
  db_subnet_group_name       = module.network.database_subnet_group_name
  allowed_security_group_ids = [module.eks.cluster_security_group_id]

  # db.t4g.small (2 GiB) is proven in this account; RDS classes aren't limited like EC2
  engine_version = "18"
  instance_class = "db.t4g.small"
  multi_az       = false

  kms_key_arn        = module.rds_key.arn
  secret_kms_key_arn = module.secretsmanager_key.arn
}
