module "eks" {
  source = "../../modules/eks"

  name               = local.name
  kubernetes_version = "1.37"

  # Exact add-on versions for this Kubernetes version (from aws eks describe-addon-versions). A plan
  # never upgrades an add-on by itself: bump these in a PR, staging first, then prod.
  addon_versions = {
    vpc-cni                = "v1.23.3-eksbuild.2"
    kube-proxy             = "v1.37.0-eksbuild.39"
    eks-pod-identity-agent = "v1.5.0-eksbuild.3"
    coredns                = "v1.14.7-eksbuild.35"
    aws-ebs-csi-driver     = "v1.68.1-eksbuild.1"
    metrics-server         = "v0.9.1-eksbuild.2"
  }

  private_subnet_ids = module.network.private_subnets

  # The API endpoint is public so GitHub-hosted runners can deploy Helm releases; they have no fixed
  # IPs. Every call still needs IAM authentication and an access entry below.
  public_access_cidrs = ["0.0.0.0/0"]

  # The training account only allows t2.micro, t3.micro, t3.medium and t4g.large. t3.medium (2 vCPU,
  # 4 GiB, up to 17 pods each with the VPC CNI) is the largest x86 type allowed; t4g.large is ARM and
  # would need arm64 images. Pod slots are the tight limit: a t3.medium holds at most 17 pods, and the
  # system add-ons, Argo CD, monitoring and the bank (every service twice) need about 61. 5 nodes (85
  # slots) leave room for every pod after losing any one node; 4 would leave some unscheduled.
  node_instance_types = ["t3.medium"]
  node_min_size       = 5
  node_desired_size   = 5
  node_max_size       = 6

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
    "arn:aws:iam::${var.account_id}:user/students/ce13/yqyeoh",           # DevSecOps, kubectl access
    "arn:aws:iam::${var.account_id}:user/students/ce13/paulyapsl",        # SRE, kubectl access
  ]
}

# The audit key, by its alias (bootstrap, modules/audit)
data "aws_kms_alias" "audit" {
  name = "alias/${var.team}-merlion-audit"
}
