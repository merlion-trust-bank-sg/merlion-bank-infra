# Each role can only be assumed by one exact kind of GitHub Actions job (OIDC sub claim, no wildcards)
#   ci-build    app repo, push to main             push images to ECR
#   ci-plan     infra repo, pull requests          read-only terraform plan (staging)
#   ci-prod-plan  infra repo, push/dispatch on main, no environment   read-only terraform plan (prod)
#   ci-staging  infra repo, environment staging    change staging only
#   ci-prod     infra repo, environment production, after a reviewer approves   change prod only

locals {
  trust_subjects = merge(
    { for e, gh_env in var.environments :
      e => [for repo in var.deploy_repos : "repo:${var.github_org}/${repo}:environment:${gh_env}"]
    },
    {
      build = ["repo:${var.github_org}/${var.app_repo}:ref:refs/heads/main"]
      plan  = ["repo:${var.github_org}/${var.infra_repo}:pull_request"]
      # A job on main WITHOUT an environment gets this sub. Only merged code can plan prod, and the
      # plan can't change anything; applying it needs ci-prod, behind the production approval.
      prod_plan = ["repo:${var.github_org}/${var.infra_repo}:ref:refs/heads/main"]
    },
  )
}

data "aws_iam_policy_document" "trust" {
  for_each = local.trust_subjects

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value
    }
  }
}

resource "aws_iam_role" "ci" {
  for_each = local.role_names

  name                 = each.value
  description          = "GitHub Actions role (${each.key})"
  assume_role_policy   = data.aws_iam_policy_document.trust[each.key].json
  max_session_duration = 3600
}
