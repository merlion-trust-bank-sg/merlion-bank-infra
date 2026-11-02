# Find the GitHub OIDC provider (or create it if create_oidc_provider = true)
data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count           = var.create_oidc_provider ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# The provider's ARN, whichever way it was found
locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

# INF-03: gha-staging, gha-prod, gha-plan, gha-build
module "iam_ci" {
  source            = "../modules/iam-ci"
  region            = var.region
  github_org        = var.github_org
  infra_repo        = var.infra_repo
  app_repo          = var.app_repo
  oidc_provider_arn = local.oidc_provider_arn
  state_bucket      = var.state_bucket
  environments      = var.environments
}
