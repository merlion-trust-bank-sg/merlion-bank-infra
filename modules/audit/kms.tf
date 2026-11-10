# Dedicated key for the audit logs (ADR-004). A disabled or deleted key stops CloudTrail delivering
# logs, so the key policy itself refuses to be disabled or scheduled for deletion, by anyone.
data "aws_iam_policy_document" "audit_key" {
  #checkov:skip=CKV_AWS_356:Key policy, not an identity policy: Resource "*" means this key only
  #checkov:skip=CKV_AWS_109:Key policy: AWS's default root-account statement, so IAM decides who can use the key and it can't be locked out
  #checkov:skip=CKV_AWS_111:Key policy: same default statement; the Deny statements below limit it

  # Account admins manage the key through IAM, so the key can't be locked out
  statement {
    sid       = "AccountAdminsViaIAM"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
  }

  # CloudTrail encrypts log files for this trail only
  statement {
    sid       = "CloudTrailEncryptLogs"
    actions   = ["kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:aws:cloudtrail:*:${var.account_id}:trail/*"]
    }
  }

  statement {
    sid       = "CloudTrailDescribeKey"
    actions   = ["kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  # Nobody can disable or delete the key. Removing the key at the end of the project means first
  # removing this statement, which is itself recorded by CloudTrail (ADR-004, clean-up).
  statement {
    sid       = "DenyDisableOrDelete"
    effect    = "Deny"
    actions   = ["kms:DisableKey", "kms:ScheduleKeyDeletion"]
    resources = ["*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  # Our own roles (CI and workloads) can't weaken the key, even though the deploy roles have kms:*
  statement {
    sid    = "DenyKeyChangesByOurRoles"
    effect = "Deny"
    actions = [
      "kms:PutKeyPolicy",
      "kms:DisableKeyRotation",
      "kms:CreateGrant",
      "kms:UpdateAlias",
      "kms:DeleteAlias",
    ]
    resources = ["*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values   = ["arn:aws:iam::${var.account_id}:role/${var.name}-*"]
    }
  }
}

resource "aws_kms_key" "audit" {
  description             = "${var.name} audit trail (CloudTrail logs, deploy records)"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.audit_key.json
}

resource "aws_kms_alias" "audit" {
  name          = "alias/${var.name}-audit"
  target_key_id = aws_kms_key.audit.key_id
}
