# -----------------------------------------------------------------------------
# GitHub OIDC -> one IAM role per environment (single AWS account version).
# Same idea as the 3.1 workshop's github-oidc-bootstrap, but:
#   * one deploy role PER ENVIRONMENT, each trusting ONLY its GitHub Environment
#   * a "fence" so a role cannot touch another environment's resources/state
#   * a region lock (data residency) on every pipeline role
#   * a build role (push images from main) and a read-only plan role (PRs)
# Applied ONCE by a human from WSL. The pipeline never changes this stack.
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

# --- GitHub OIDC identity provider (exists already, or create it) -----------
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

locals {
  account_id = data.aws_caller_identity.current.account_id
  oidc_arn   = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
  repo       = "${var.github_owner}/${var.github_repo}"

  # Terraform env name (Environment tag + state path) => GitHub Environment name
  envs = {
    dev     = "development"
    staging = "staging"
    prod    = "production"
  }

  # Global services that have no region (excluded from the region lock)
  global_actions = [
    "iam:*", "sts:*", "organizations:*", "account:*", "support:*",
    "budgets:*", "ce:*", "route53:*", "route53domains:*", "cloudfront:*",
    "health:*", "s3:GetBucketLocation", "s3:ListAllMyBuckets",
  ]
}

# =============================== deploy roles ===============================

data "aws_iam_policy_document" "deploy_trust" {
  for_each = local.envs
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # ONLY a job running in this GitHub Environment of this repo.
    # "production" has required reviewers -> nobody gets prod credentials
    # until a reviewer approves.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.repo}:environment:${each.value}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  for_each             = local.envs
  name                 = "merlion-gha-${each.key}"
  description          = "GitHub Actions deploy role for ${each.key} (GitHub Environment: ${each.value})"
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust[each.key].json
  max_session_duration = 3600
  tags                 = { Environment = each.key }
}

# EKS + RDS + VPC + IAM need broad rights. Bounded by the trust policy,
# the fence and the region lock below. (Ask your lecturer what is allowed.)
resource "aws_iam_role_policy_attachment" "deploy_admin" {
  for_each   = local.envs
  role       = aws_iam_role.deploy[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# --- the fence: explicit denies always beat the Allow above -----------------
data "aws_iam_policy_document" "fence" {
  for_each = local.envs

  statement {
    sid       = "DenyResourcesTaggedForOtherEnv"
    effect    = "Deny"
    actions   = ["*"]
    resources = ["*"]
    condition {
      # every stack tags its resources Environment=<env> via default_tags
      test     = "StringNotEqualsIfExists"
      variable = "aws:ResourceTag/Environment"
      values   = [each.key]
    }
  }

  statement {
    sid       = "DenyOtherEnvState"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [for e in keys(local.envs) : "arn:aws:s3:::${var.state_bucket}/merlion/${e}/*" if e != each.key]
  }

  statement {
    sid       = "DenyBootstrapState"
    effect    = "Deny"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.state_bucket}/merlion/bootstrap.tfstate*"]
  }

  statement {
    sid         = "DenyOutsideSingapore"
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
  name     = "fence-other-environments"
  role     = aws_iam_role.deploy[each.key].id
  policy   = data.aws_iam_policy_document.fence[each.key].json
}

# ================================ build role ================================
# Builds + scans + pushes images ONCE from main. No environment, no approval;
# can ONLY push to the merlion/* ECR repositories.

resource "aws_iam_role" "build" {
  name        = "merlion-gha-build"
  description = "GitHub Actions: push images to merlion/* ECR repos from main only"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${local.repo}:ref:refs/heads/main"
        }
      }
    }]
  })
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "build_ecr" {
  name = "ecr-push-merlion-only"
  role = aws_iam_role.build.id
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
      }
    ]
  })
}

# ============================== PR plan role ================================
# Read-only. Lets CI show a STAGING Terraform plan on every pull request.

resource "aws_iam_role" "plan" {
  name        = "merlion-gha-plan"
  description = "GitHub Actions: read-only terraform plan (staging) on pull requests"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${local.repo}:pull_request"
        }
      }
    }]
  })
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "plan_extra" {
  name = "staging-plan-only"
  role = aws_iam_role.plan.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadStagingState"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${var.state_bucket}/merlion/staging/*"
      },
      {
        Sid      = "ListStateBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.state_bucket}"
      },
      {
        Sid      = "RefreshStagingSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:merlion/staging/*"
      },
      {
        Sid      = "NoProdOrDevState"
        Effect   = "Deny"
        Action   = ["s3:GetObject"]
        Resource = ["arn:aws:s3:::${var.state_bucket}/merlion/prod/*", "arn:aws:s3:::${var.state_bucket}/merlion/dev/*"]
      }
    ]
  })
}

# ==================================== ECR ===================================
# Created here (not per environment) because images are built ONCE and the
# same tag (git SHA) is promoted dev -> staging -> prod.

resource "aws_ecr_repository" "app" {
  for_each             = toset(var.ecr_repositories)
  name                 = "merlion/${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 30 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 30 }
      action       = { type = "expire" }
    }]
  })
}
