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

# --- plan roles: read-only terraform plan, one environment each ----------------------------------
#   g4-merlion-ci-plan       staging, on infra PRs
#   g4-merlion-ci-prod-plan  prod, on main after merge (before the production approval)
# ReadOnlyAccess for the plan itself; state, lock file and key access only for the role's own env.
locals {
  plan_roles = {
    plan      = { env = "staging", sid = "Staging", policy_name = "plan-staging" }
    prod_plan = { env = "prod", sid = "Prod", policy_name = "plan-prod" }
  }
}

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  for_each = local.plan_roles

  role       = aws_iam_role.ci[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "plan" {
  for_each = local.plan_roles

  statement {
    sid       = "Read${each.value.sid}State"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.state_buckets[each.value.env]}", "arn:aws:s3:::${var.state_buckets[each.value.env]}/*"]
  }

  # plan takes the state lock, so allow only the lock file; state itself stays read-only
  statement {
    sid       = "${each.value.sid}LockFileOnly"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.state_buckets[each.value.env]}/*.tflock"]
  }

  statement {
    sid       = "Use${each.value.sid}StateKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.state_kms_key_arns[each.value.env]]
  }

  # ReadOnlyAccess can read every bucket. Keep the plan role out of other state, app logs and the audit trail.
  statement {
    sid     = "DenyOtherStateLogsAndAudit"
    effect  = "Deny"
    actions = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = concat(
      [for l, b in var.state_buckets : "arn:aws:s3:::${b}/*" if l != each.value.env],
      ["arn:aws:s3:::${local.p}-*-loki/*", "arn:aws:s3:::${local.audit_bucket}/*"],
    )
  }

  statement {
    sid       = "DenyOtherStateKeys"
    effect    = "Deny"
    actions   = ["kms:Decrypt"]
    resources = [for l, k in var.state_kms_key_arns : k if l != each.value.env]
  }
}

resource "aws_iam_role_policy" "plan" {
  for_each = local.plan_roles

  name   = each.value.policy_name
  role   = aws_iam_role.ci[each.key].id
  policy = data.aws_iam_policy_document.plan[each.key].json
}

# These resources were written out once per role; the moves keep them in place (no AWS change)
moved {
  from = aws_iam_role_policy_attachment.plan_read_only
  to   = aws_iam_role_policy_attachment.plan_read_only["plan"]
}

moved {
  from = aws_iam_role_policy_attachment.prod_plan_read_only
  to   = aws_iam_role_policy_attachment.plan_read_only["prod_plan"]
}

moved {
  from = aws_iam_role_policy.plan
  to   = aws_iam_role_policy.plan["plan"]
}

moved {
  from = aws_iam_role_policy.prod_plan
  to   = aws_iam_role_policy.plan["prod_plan"]
}
