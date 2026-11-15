module "rds" {
  count = local.enabled ? 1 : 0

  source = "../../modules/rds"

  name = local.name

  # Bank of Anthos uses two PostgreSQL databases. RDS database names can't contain hyphens.
  databases = {
    accounts = { db_name = "accountsdb" }
    ledger   = { db_name = "ledgerdb" }
  }

  vpc_id               = module.network[0].vpc_id
  db_subnet_group_name = module.network[0].database_subnet_group_name
  allowed_security_groups = {
    eks_cluster = module.eks[0].cluster_security_group_id
  }

  engine_version = "18"
  instance_class = "db.t4g.small"

  # Standby in the second AZ (NFR-3); 7 days of automated backups in this region (NFR-4, HC-1)
  multi_az              = true
  backup_retention_days = 7

  # A delete must be deliberate. To tear prod down, first set this to false in its own PR and apply it;
  # only then set enabled = false. In one PR the destroy fails: the databases are removed from the
  # config, so it sees deletion_protection = true from state. Each database keeps a final snapshot.
  deletion_protection = true
  skip_final_snapshot = false

  kms_key_arn        = module.rds_key[0].arn
  secret_kms_key_arn = module.secretsmanager_key[0].arn
}
