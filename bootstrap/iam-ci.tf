# GitHub Actions roles: g4-merlion-ci-build, -plan, -staging, -prod
module "iam_ci" {
  source = "../modules/iam-ci"

  region        = var.region
  account_id    = var.account_id
  prefix        = local.prefix
  team          = var.team
  github_org    = var.github_org
  github_org_id = var.github_org_id
  infra_repo    = var.infra_repo
  app_repo      = var.app_repo
  repo_ids = {
    (var.infra_repo) = var.infra_repo_id
    (var.app_repo)   = var.app_repo_id
  }
  oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn

  # Terraform env name => GitHub Environment name
  environments = { for e in var.environments : e => local.github_environments[e] }

  # Only the infra repo changes environments. App deploys go through Argo CD (it pulls from this repo),
  # so the app repo only builds and pushes images (ci-build).
  deploy_repos = [var.infra_repo]

  state_buckets      = { for k, b in aws_s3_bucket.state : k => b.id }
  state_kms_key_arns = { for k, key in aws_kms_key.state : k => key.arn }

  # The app's hostname per env, in the course's shared zone; each env pipeline may only change records
  # under its own. From modules/dns, which the envs read too, so the names always match.
  dns_zone_id = module.dns.zone_id
  dns_names   = module.dns.hostnames
}

module "dns" {
  source = "../modules/dns"
}
