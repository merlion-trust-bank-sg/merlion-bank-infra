# AWS side of the monitoring stack (ADR-003): Loki's bucket and key, Pod Identity roles for Loki and
# YACE. The stack itself is installed by Argo CD from deploy/platform/staging/.
module "observability" {
  source = "../../modules/observability"

  name                      = local.name
  region                    = var.region
  cluster_name              = module.eks.cluster_name
  permissions_boundary_arn  = "arn:aws:iam::${var.account_id}:policy/${local.name}-workload-boundary"
  pod_identity_trust_policy = module.eks.pod_identity_trust_policy

  # Staging is rebuilt every day and its logs are synthetic, so the bucket may be deleted with them
  force_destroy = true
}
