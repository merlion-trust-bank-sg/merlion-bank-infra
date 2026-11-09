# Key for this environment's CloudWatch log groups (VPC flow logs, EKS control-plane logs).
# CloudWatch Logs may use it only for log groups whose ARN contains this env's name.
module "logs_key" {
  source = "../../modules/kms"

  name        = "${local.name}-logs"
  description = "${local.name} CloudWatch log groups"

  service_statements = [{
    sid     = "CloudWatchLogsForThisEnv"
    service = "logs.${var.region}.amazonaws.com"
    actions = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    conditions = [{
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${var.region}:${var.account_id}:log-group:*${local.name}*"]
    }]
  }]
}

# RDS storage, snapshots and backups. RDS uses it through grants made by the caller, so the key
# policy only needs the default account statement.
module "rds_key" {
  source = "../../modules/kms"

  name        = "${local.name}-rds"
  description = "${local.name} RDS storage and snapshots"
}

# Secrets Manager secrets (RDS master passwords now, the app's JWT key pair later). Kept apart from
# the RDS key, so reading a password and reading database storage need different permissions.
module "secretsmanager_key" {
  source = "../../modules/kms"

  name        = "${local.name}-secretsmanager"
  description = "${local.name} Secrets Manager secrets"
}
