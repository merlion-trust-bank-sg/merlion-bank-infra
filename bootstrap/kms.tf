# One customer-managed key per state bucket. Reading a state file needs both s3:GetObject on the
# bucket and kms:Decrypt on its key, so each CI role can be given decrypt on its own env's key only.
data "aws_iam_policy_document" "state_key" {
  #checkov:skip=CKV_AWS_356:Key policy, not an identity policy: Resource "*" means this key only
  #checkov:skip=CKV_AWS_109:Key policy: AWS's default root-account statement, so IAM decides who can use the key and it can't be locked out
  #checkov:skip=CKV_AWS_111:Key policy: same default statement; access is granted per role in IAM (state key decrypt for own env only)
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
}

resource "aws_kms_key" "state" {
  for_each = local.state_layers

  description             = "${local.prefix} ${each.key} Terraform state"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.state_key.json

  tags = {
    Environment = each.value.environment
  }
}

resource "aws_kms_alias" "state" {
  for_each = local.state_layers

  name          = "alias/${local.prefix}-${each.key}-state"
  target_key_id = aws_kms_key.state[each.key].key_id
}
