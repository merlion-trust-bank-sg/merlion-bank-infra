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
  # 3 nodes across both AZs; at least 2 so losing a node or an AZ keeps the bank up.
  node_instance_types = ["t3.medium"]
  node_min_size       = 2
  node_desired_size   = 3
  node_max_size       = 4

  logs_kms_key_arn = module.logs_key[0].arn

  # Created by bootstrap; every role this pipeline creates must carry it
  permissions_boundary_arn = "arn:aws:iam::${var.account_id}:policy/${local.name}-workload-boundary"

  # Only the prod pipeline may change the cluster. People get read-only access: prod changes go
  # through a reviewed PR and the approved pipeline, never kubectl (HC-2).
  admin_principal_arns = [
    "arn:aws:iam::${var.account_id}:role/${var.team}-merlion-ci-prod",
  ]
  viewer_principal_arns = [
    "arn:aws:iam::${var.account_id}:user/students/ce13/yqyeoh", # SRE / DevSecOps
  ]
}
