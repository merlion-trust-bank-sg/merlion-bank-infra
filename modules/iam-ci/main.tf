# INF-03 - one GitHub Actions role per environment.
#
#   gha-staging  trusted by jobs in GitHub Environment "staging"    (both repos)
#   gha-prod     trusted by jobs in GitHub Environment "production" (both repos)
#                -> "production" has required reviewers, so nobody gets prod
#                   credentials before a reviewer approves the run.
#   gha-plan     read-only, infra repo PRs + main (terraform plan for the PR comment)
#   gha-build    app repo main branch only, push to merlion/* in ECR
#
# Trust is pinned to OUR two repos (tighter than repo:<org>/*: a new repo in
# the org cannot create its own "production" environment and get prod).

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100, < 6.0"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  repos      = ["${var.github_org}/${var.infra_repo}", "${var.github_org}/${var.app_repo}"]

  # Terraform env name (Environment tag, state path) -> GitHub Environment name
  github_env = { staging = "staging", prod = "production" }
  envs       = { for e in var.environments : e => local.github_env[e] }

  all_envs = ["staging", "prod"]

  # Services with no region; left out of the region lock
  global_actions = [
    "iam:*", "sts:*", "organizations:*", "account:*", "support:*", "budgets:*",
    "ce:*", "cur:*", "route53:*", "route53domains:*", "cloudfront:*", "waf:*",
    "health:*", "trustedadvisor:*", "s3:GetBucketLocation", "s3:ListAllMyBuckets",
  ]
}

# =============================== deploy roles ===============================

data "aws_iam_policy_document" "deploy_trust" {
  for_each = local.envs
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
      values   = [for r in local.repos : "repo:${r}:environment:${each.value}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  for_each             = local.envs
  name                 = "gha-${each.key}"
  description          = "GitHub Actions role for ${each.key} (GitHub Environment ${each.value})"
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust[each.key].json
  max_session_duration = 3600
  tags                 = { Environment = "shared" }
}

# EKS + RDS + VPC + IAM need broad rights. They are bounded by the trust
# policy above and by the fence below (explicit Deny always wins).
# Hardening: replace with a least-privilege policy.
resource "aws_iam_role_policy_attachment" "deploy_admin" {
  #checkov:skip=CKV_AWS_274:Accepted risk (ADR-005) - bounded by OIDC trust, GitHub approval and the fence policy
  for_each   = local.envs
  role       = aws_iam_role.deploy[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# --- the fence ---------------------------------------------------------------
data "aws_iam_policy_document" "fence" {
  for_each = local.envs

  # 1. Resources that carry an Environment tag for ANOTHER environment (or
  #    "shared": bootstrap, ECR, audit) are off limits. Untagged / new
  #    resources are not matched, so creates still work.
  statement {
    sid       = "DenyOtherEnvironmentResources"
    effect    = "Deny"
    actions   = ["*"]
    resources = ["*"]
    condition {
      test     = "Null"
      variable = "aws:ResourceTag/Environment"
      values   = ["false"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [each.key]
    }
  }

  # 2. ...and a role cannot create or re-tag something INTO another environment.
  statement {
    sid       = "DenyTaggingIntoOtherEnvironment"
    effect    = "Deny"
    actions   = ["*"]
    resources = ["*"]
    condition {
      test     = "Null"
      variable = "aws:RequestTag/Environment"
      values   = ["false"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestTag/Environment"
      values   = [each.key]
    }
  }

  # 3. Terraform state of other environments and of the bootstrap.
  statement {
    sid     = "DenyOtherEnvironmentState"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = concat(
      [for e in local.all_envs : "arn:aws:s3:::${var.state_bucket}/merlion/${e}/*" if e != each.key],
      ["arn:aws:s3:::${var.state_bucket}/merlion/bootstrap.tfstate*"],
    )
  }

  # 4. The CI identity itself (cannot remove its own fence or trust).
  statement {
    sid     = "DenyChangingCiIdentity"
    effect  = "Deny"
    actions = ["iam:*"]
    resources = [
      "arn:aws:iam::${local.account_id}:role/gha-*",
      "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com",
    ]
  }

  # 5. INF-11 region guardrail: nothing outside the one approved region.
  statement {
    sid         = "DenyOutsideApprovedRegion"
    effect      = "Deny"
    not_actions = local.global_actions
    resources   = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }
}

resource "aws_iam_role_policy" "fence" {
  for_each = local.envs
  name     = "fence-${each.key}"
  role     = aws_iam_role.deploy[each.key].id
  policy   = data.aws_iam_policy_document.fence[each.key].json
}

# ================================ plan role =================================

resource "aws_iam_role" "plan" {
  count = var.create_plan_role ? 1 : 0
  name  = "gha-plan"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = [
            "repo:${var.github_org}/${var.infra_repo}:pull_request",
            "repo:${var.github_org}/${var.infra_repo}:ref:refs/heads/main",
          ]
        }
      }
    }]
  })
  description          = "Read-only terraform plan for infra PRs and the pre-approval prod plan"
  max_session_duration = 3600
  tags                 = { Environment = "shared" }
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  count      = var.create_plan_role ? 1 : 0
  role       = aws_iam_role.plan[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "plan_extra" {
  count = var.create_plan_role ? 1 : 0
  name  = "terraform-plan-extras"
  role  = aws_iam_role.plan[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadState"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = ["arn:aws:s3:::${var.state_bucket}", "arn:aws:s3:::${var.state_bucket}/merlion/*"]
      },
      {
        # Terraform refresh reads the connection secrets it manages (no passwords in them)
        Sid      = "RefreshConnectionSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:merlion/*/*-db-conn-*"
      },
      {
        Sid      = "DecryptViaSecretsManager"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
        Condition = {
          StringEquals = { "kms:ViaService" = "secretsmanager.${var.region}.amazonaws.com" }
        }
      },
    ]
  })
}

# ================================ build role ================================

resource "aws_iam_role" "build" {
  count = var.create_build_role ? 1 : 0
  name  = "gha-build"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.app_repo}:ref:refs/heads/main"
        }
      }
    }]
  })
  description          = "Push images to merlion/* ECR repos from app repo main only"
  max_session_duration = 3600
  tags                 = { Environment = "shared" }
}

resource "aws_iam_role_policy" "build" {
  count = var.create_build_role ? 1 : 0
  name  = "ecr-push-merlion-only"
  role  = aws_iam_role.build[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload",
          "ecr:DescribeImages", "ecr:DescribeImageScanFindings", "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
        ]
        Resource = "arn:aws:ecr:${var.region}:${local.account_id}:repository/merlion/*"
      },
    ]
  })
}
