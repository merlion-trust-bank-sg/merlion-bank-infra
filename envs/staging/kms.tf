# Key for this environment's CloudWatch log groups (VPC flow logs now; EKS control-plane logs later).
# Moves to the shared KMS module once that exists.
data "aws_iam_policy_document" "logs_key" {
  #checkov:skip=CKV_AWS_109:Key policy: Resource * means this key only; account admins manage it through IAM
  #checkov:skip=CKV_AWS_111:Key policy: Resource * means this key only; writes are limited to this key
  #checkov:skip=CKV_AWS_356:Key policy: Resource * is the only valid value and refers to this key
  statement {
    sid       = "AccountAdminsViaIAM"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
  }

  # CloudWatch Logs encrypts with the key itself, but only for this environment's log groups
  statement {
    sid = "CloudWatchLogsForThisEnv"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${var.region}:${var.account_id}:log-group:*${local.name}*"]
    }
  }
}

resource "aws_kms_key" "logs" {
  description             = "${local.name} CloudWatch log groups"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.logs_key.json
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${local.name}-logs"
  target_key_id = aws_kms_key.logs.key_id
}
