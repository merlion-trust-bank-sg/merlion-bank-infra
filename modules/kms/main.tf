# A customer managed key with rotation and an alias. Account admins manage it through IAM, so roles
# get access through their own IAM policies; services that can't use IAM are listed in the key policy.
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "this" {
  #checkov:skip=CKV_AWS_109:Key policy: Resource * means this key only; account admins manage it through IAM
  #checkov:skip=CKV_AWS_111:Key policy: Resource * means this key only
  #checkov:skip=CKV_AWS_356:Key policy: Resource * is the only valid value and refers to this key
  statement {
    sid       = "AccountAdminsViaIAM"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  dynamic "statement" {
    for_each = var.service_statements
    content {
      sid       = statement.value.sid
      actions   = statement.value.actions
      resources = ["*"]
      principals {
        type        = "Service"
        identifiers = [statement.value.service]
      }
      dynamic "condition" {
        for_each = statement.value.conditions
        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_kms_key" "this" {
  description             = var.description
  enable_key_rotation     = true
  deletion_window_in_days = var.deletion_window_in_days
  policy                  = data.aws_iam_policy_document.this.json
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}"
  target_key_id = aws_kms_key.this.key_id
}
