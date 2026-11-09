# prod environment. Modules (network, EKS, RDS, ...) are added here in their own PRs and applied by
# the pipeline only.
locals {
  environment = "prod"
  name        = "${var.team}-merlion-${local.environment}" # g4-merlion-prod
}
