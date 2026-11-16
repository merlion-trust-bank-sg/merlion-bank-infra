module "eks" {
  source = "../../modules/eks"

  name               = local.name
  kubernetes_version = "1.37"
  private_subnet_ids = module.network.private_subnets

  # The API endpoint is public so GitHub-hosted runners can deploy Helm releases; they have no fixed
  # IPs. Every call still needs IAM authentication and an access entry below.
  public_access_cidrs = ["0.0.0.0/0"]

  # The training account only allows t2.micro, t3.micro, t3.medium and t4g.large. t3.medium (2 vCPU,
  # 4 GiB, up to 17 pods each with the VPC CNI) is the largest x86 type allowed; t4g.large is ARM and
  # would need arm64 images. 4 nodes across both AZs: a t3.medium holds at most 17 pods, and the
  # system add-ons, Argo CD, the add-ons, monitoring and the bank need ~50 of them, so 3 nodes would be
  # nearly full and losing one would leave pods unscheduled. desired_size only applies when the node
  # group is created; min_size is what makes an existing group scale up.
  node_instance_types = ["t3.medium"]
  node_min_size       = 4
  node_desired_size   = 4
  node_max_size       = 5

  logs_kms_key_arn = module.logs_key.arn

  # Kubernetes audit log copied to the Object Lock audit bucket, where nobody can delete it (HC-3).
  # Bucket and key are created by bootstrap (modules/audit).
  audit_export = {
    bucket_arn  = "arn:aws:s3:::${var.team}-merlion-audit-${var.account_id}"
    kms_key_arn = data.aws_kms_alias.audit.target_key_arn
  }

  # Created by bootstrap; every role this pipeline creates must carry it
  permissions_boundary_arn = "arn:aws:iam::${var.account_id}:policy/${local.name}-workload-boundary"

  admin_principal_arns = [
    "arn:aws:iam::${var.account_id}:role/${var.team}-merlion-ci-staging", # the staging pipeline
    "arn:aws:iam::${var.account_id}:user/students/ce13/yqyeoh",           # SRE, kubectl access
  ]
}

# The audit key, by its alias (bootstrap, modules/audit)
data "aws_kms_alias" "audit" {
  name = "alias/${var.team}-merlion-audit"
}
