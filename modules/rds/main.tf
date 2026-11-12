# PostgreSQL instances in the isolated database subnets. One security group, parameter group and
# option group are shared by all instances in the environment.

resource "aws_security_group" "db" {
  name        = "${var.name}-rds"
  description = "PostgreSQL from the EKS cluster only"
  vpc_id      = var.vpc_id
}

# No egress rules: the databases only answer connections, they never start them
resource "aws_vpc_security_group_ingress_rule" "postgres" {
  # Keyed by name, not by ID: the IDs don't exist until the groups are created, and for_each keys
  # must be known at plan time (e.g. on a fresh environment)
  for_each = var.allowed_security_groups

  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from ${each.key}"
}

# Encryption in transit: reject any connection that doesn't use TLS
# name_prefix, not name: create_before_destroy builds the replacement before deleting the old group,
# and two groups can't share a name. The prefix keeps g4-merlion-<env>, which the CI role requires.
resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name}-pg${var.engine_version}-"
  family      = "postgres${var.engine_version}"

  # Static in this PostgreSQL version: RDS reports it as pending-reboot. Saying so here keeps plans
  # from showing a change every time; new instances start with it already applied.
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  # Who connected and when, without logging queries (they could contain customer data). Since
  # PostgreSQL 18 this lists which connection stages to log instead of on/off; "all" covers receipt,
  # authentication and authorization (the old "on") plus how long setup took.
  parameter {
    name  = "log_connections"
    value = "all"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Our own (empty) option group: the default one is named default:postgres-NN, which the env CI role
# can't use because its RDS permissions only cover resources named <name>*. name_prefix for the same
# reason as the parameter group.
resource "aws_db_option_group" "this" {
  name_prefix          = "${var.name}-pg${var.engine_version}-"
  engine_name          = "postgres"
  major_engine_version = var.engine_version

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  #checkov:skip=CKV_AWS_293:Deletion protection is a variable; off while environments are rebuilt daily
  #checkov:skip=CKV_AWS_157:Multi-AZ is a variable: off in staging for cost, on in prod
  #checkov:skip=CKV_AWS_118:Enhanced monitoring needs an extra IAM role; CloudWatch metrics are enough here
  #checkov:skip=CKV_AWS_353:Performance Insights not needed on the small classes the training account uses
  #checkov:skip=CKV_AWS_129:Not exported yet: RDS would create /aws/rds log groups with no retention or KMS key; connection logs stay in the RDS console
  for_each = var.databases

  identifier     = "${var.name}-${each.key}-db"
  db_name        = each.value.db_name
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.max_allocated_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  # RDS generates the password and keeps it in Secrets Manager; it never appears in code or state
  username                            = var.master_username
  manage_master_user_password         = true
  master_user_secret_kms_key_id       = var.secret_kms_key_arn
  iam_database_authentication_enabled = true

  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  parameter_group_name   = aws_db_parameter_group.this.name
  option_group_name      = aws_db_option_group.this.name
  multi_az               = var.multi_az

  backup_retention_period    = var.backup_retention_days
  backup_window              = "17:00-18:00" # 01:00-02:00 SGT
  maintenance_window         = "sun:18:00-sun:19:00"
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name}-${each.key}-db-final"

  apply_immediately = true
}
