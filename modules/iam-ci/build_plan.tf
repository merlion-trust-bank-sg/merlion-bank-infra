# --- build: push images, nothing else ---------------------------------------------------------
data "aws_iam_policy_document" "build" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PushAndReadImages"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:ListImages",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [local.ecr_repo_arn]
  }
}

resource "aws_iam_role_policy" "build" {
  name   = "ecr-push"
  role   = aws_iam_role.ci["build"].id
  policy = data.aws_iam_policy_document.build.json
}

# --- plan: read-only terraform plan for staging on infra PRs -----------------------------------
# Only staging state: prod's plan runs in the approval-gated prod job, as ci-prod, just before apply.
resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.ci["plan"].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "plan" {
  statement {
    sid       = "ReadStagingState"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.state_buckets["staging"]}", "arn:aws:s3:::${var.state_buckets["staging"]}/*"]
  }

  # plan takes the state lock, so allow only the lock file; state itself stays read-only
  statement {
    sid       = "StagingLockFileOnly"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.state_buckets["staging"]}/*.tflock"]
  }

  statement {
    sid       = "UseStagingStateKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.state_kms_key_arns["staging"]]
  }

  # ReadOnlyAccess can read every bucket. Keep the plan role out of other state, app logs and the audit trail.
  statement {
    sid     = "DenyOtherStateLogsAndAudit"
    effect  = "Deny"
    actions = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = concat(
      [for l, b in var.state_buckets : "arn:aws:s3:::${b}/*" if l != "staging"],
      ["arn:aws:s3:::${local.p}-*-loki/*", "arn:aws:s3:::${local.audit_bucket}/*"],
    )
  }

  statement {
    sid       = "DenyOtherStateKeys"
    effect    = "Deny"
    actions   = ["kms:Decrypt"]
    resources = [for l, k in var.state_kms_key_arns : k if l != "staging"]
  }
}

resource "aws_iam_role_policy" "plan" {
  name   = "plan-staging"
  role   = aws_iam_role.ci["plan"].id
  policy = data.aws_iam_policy_document.plan.json
}
