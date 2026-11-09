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
  # would need arm64 images. 3 nodes across both AZs.
  node_instance_types = ["t3.medium"]
  node_min_size       = 2
  node_desired_size   = 3
  node_max_size       = 4

  logs_kms_key_arn = module.logs_key.arn

  # Created by bootstrap; every role this pipeline creates must carry it
  permissions_boundary_arn = "arn:aws:iam::${var.account_id}:policy/${local.name}-workload-boundary"

  admin_principal_arns = [
    "arn:aws:iam::${var.account_id}:role/${var.team}-merlion-ci-staging", # the staging pipeline
    "arn:aws:iam::${var.account_id}:user/students/ce13/yqyeoh",           # SRE, kubectl access
  ]
}
