# --- restore: put back the CI roles' policies after the nightly cleanup ---------------------------
#   g4-merlion-ci-restore  infra repo, main, job without an environment (.github/workflows/restore.yml)
#
# The training account's nightly cleanup keeps our roles and managed policies but detaches every
# policy from every role, this one's included. Each morning a person re-attaches this role's one
# policy (README "Restoring after the training account's nightly cleanup"); the workflow then puts
# back every other CI role's policies, and the env pipelines repair their own environments.
#
# Attach only, from a fixed list: one statement per CI role, naming exactly the policies Terraform
# attaches to it. It can't write a policy, attach anything else, or change its own permissions. The
# workflow reads the list from this policy, so what it restores can't drift from what's allowed.
locals {
  # Every policy attachment on the CI roles, except this role's own. A new attachment on a CI role
  # must be added here, or the restore workflow won't put it back.
  ci_attachments = concat(
    values(aws_iam_role_policy_attachment.env_read_only),
    values(aws_iam_role_policy_attachment.env_policies),
    values(aws_iam_role_policy_attachment.plan_read_only),
    values(aws_iam_role_policy_attachment.plan),
    [aws_iam_role_policy_attachment.build, aws_iam_role_policy_attachment.record],
  )

  # Role key => policy ARNs, e.g. prod_plan => [ReadOnlyAccess, g4-merlion-ci-plan-prod]
  restore_policy_arns = { for k, name in local.role_names :
    k => sort([for a in local.ci_attachments : a.policy_arn if a.role == name])
    if k != "restore"
  }

  restore_policy_name = "${local.p}-ci-restore"
}

data "aws_iam_policy_document" "restore" {
  dynamic "statement" {
    for_each = local.restore_policy_arns
    content {
      # Restore<Role>, e.g. RestoreProdPlan. The workflow finds the list by this prefix.
      sid       = "Restore${join("", [for w in split("_", statement.key) : title(w)])}"
      actions   = ["iam:AttachRolePolicy"]
      resources = ["arn:aws:iam::${local.a}:role/${local.role_names[statement.key]}"]
      condition {
        test     = "ArnEquals"
        variable = "iam:PolicyARN"
        values   = statement.value
      }
    }
  }

  statement {
    sid       = "ReadOwnPolicy"
    actions   = ["iam:GetPolicy", "iam:GetPolicyVersion"]
    resources = ["arn:aws:iam::${local.a}:policy/${local.restore_policy_name}"]
  }

  statement {
    sid       = "ListCiRolePolicies"
    actions   = ["iam:ListAttachedRolePolicies"]
    resources = ["arn:aws:iam::${local.a}:role/${local.p}-ci-*"]
  }
}

resource "aws_iam_policy" "restore" {
  name        = local.restore_policy_name
  description = "Re-attach the CI roles' own policies after the nightly cleanup, nothing else"
  policy      = data.aws_iam_policy_document.restore.json
}

resource "aws_iam_role_policy_attachment" "restore" {
  role       = aws_iam_role.ci["restore"].name
  policy_arn = aws_iam_policy.restore.arn
}
