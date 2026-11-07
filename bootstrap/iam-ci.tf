# GitHub Actions roles: g4-merlion-ci-build, -plan, -staging, -prod
module "iam_ci" {
  source = "../modules/iam-ci"

  region            = var.region
  account_id        = var.account_id
  prefix            = local.prefix
  team              = var.team
  github_org        = var.github_org
  infra_repo        = var.infra_repo
  app_repo          = var.app_repo
  oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn

  # Terraform env name => GitHub Environment name
  environments = { for e in var.environments : e => local.github_environments[e] }

  # Only the infra repo changes environments. App deploys go through Argo CD (it pulls from this repo),
  # so the app repo only builds and pushes images (ci-build).
  deploy_repos = [var.infra_repo]

  state_buckets      = { for k, b in aws_s3_bucket.state : k => b.id }
  state_kms_key_arns = { for k, key in aws_kms_key.state : k => key.arn }
}
