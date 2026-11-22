# AWS side of the monitoring stack (ADR-003): Loki's bucket and key, Pod Identity roles for Loki and
# YACE. The stack itself is installed by Argo CD from deploy/platform/prod/ (SCRUM-52, INF-15b).
module "observability" {
  count = local.enabled ? 1 : 0

  source = "../../modules/observability"

  name                      = local.name
  region                    = var.region
  cluster_name              = module.eks[0].cluster_name
  permissions_boundary_arn  = "arn:aws:iam::${var.account_id}:policy/${local.name}-workload-boundary"
  pod_identity_trust_policy = module.eks[0].pod_identity_trust_policy

  # force_destroy stays at the module default (false): Terraform can't delete the Loki bucket while
  # it holds logs, so 365 days of prod logs aren't lost to a teardown or a bad change. Tearing prod
  # down therefore needs the bucket emptied first (README, "Prod teardown").
}
