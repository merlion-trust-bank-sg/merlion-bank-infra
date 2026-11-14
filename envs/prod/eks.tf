module "eks" {
  count = local.enabled ? 1 : 0

  source = "../../modules/eks"

  name               = local.name
  kubernetes_version = "1.37"
  private_subnet_ids = module.network[0].private_subnets

  # The API endpoint is public so GitHub-hosted runners can bootstrap Argo CD; they have no fixed IPs.
  # Every call still needs IAM authentication and an access entry below.
  public_access_cidrs = ["0.0.0.0/0"]

  # The training account only allows t2.micro, t3.micro, t3.medium and t4g.large (see envs/staging).
  # 4 nodes across both AZs, as in staging: a t3.medium holds at most 17 pods, and the platform,
  # monitoring and the bank need ~50 of them, so 3 nodes would be nearly full and losing one would
  # leave pods unscheduled. desired_size only applies when the node group is created; min_size is what
  # makes an existing group scale up.
  node_instance_types = ["t3.medium"]
  node_min_size       = 4
  node_desired_size   = 4
  node_max_size       = 5

  logs_kms_key_arn = module.logs_key[0].arn

  # Prod's control-plane logs outlive a teardown, and the pipeline can't delete them. Tearing prod down
  # leaves /aws/eks/g4-merlion-prod/cluster behind; bringing it back needs that group imported first
  # (terraform import 'module.eks[0].aws_cloudwatch_log_group.cluster' /aws/eks/g4-merlion-prod/cluster).
  protect_log_group = true

  # Kubernetes audit log copied to the Object Lock audit bucket, where nobody can delete it (HC-3).
  # Bucket and key are created by bootstrap (modules/audit).
  audit_export = {
    bucket_arn  = "arn:aws:s3:::${var.team}-merlion-audit-${var.account_id}"
    kms_key_arn = data.aws_kms_alias.audit[0].target_key_arn
  }

  # Created by bootstrap; every role this pipeline creates must carry it
  permissions_boundary_arn = "arn:aws:iam::${var.account_id}:policy/${local.name}-workload-boundary"

  # Only the prod pipeline may change the cluster. People get read-only access: prod changes go
  # through a reviewed PR and the approved pipeline, never kubectl (HC-2).
  #
  # TEMPORARY, for testing prod before the presentations: the three of us are cluster admins too.
  # Remove before the demo, so the demo shows the intended access: pipeline admin, people read-only.
  # Every kubectl change is in the EKS audit log (exported to the Object Lock bucket).
  admin_principal_arns = [
    "arn:aws:iam::${var.account_id}:role/${var.team}-merlion-ci-prod",
    "arn:aws:iam::${var.account_id}:user/students/ce13/yqyeoh",    # TEMPORARY
    "arn:aws:iam::${var.account_id}:user/students/ce13/paulyapsl", # TEMPORARY
    "arn:aws:iam::${var.account_id}:user/students/ce13/kealeee",   # TEMPORARY
  ]
  # Admin wins when a principal is in both lists (modules/eks/access.tf), so this stays as the
  # permanent setting once the temporary admins are removed
  viewer_principal_arns = [
    "arn:aws:iam::${var.account_id}:user/students/ce13/yqyeoh", # SRE / DevSecOps
  ]
}

# The audit key, by its alias (bootstrap, modules/audit)
data "aws_kms_alias" "audit" {
  count = local.enabled ? 1 : 0

  name = "alias/${var.team}-merlion-audit"
}
