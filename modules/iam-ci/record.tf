# --- record: deploy records, add-only (APP-11) ---------------------------------------------------
#   g4-merlion-ci-record  infra repo, main, job without an environment (.github/workflows/deploy-record.yml)
#
# Writes one JSON record per deploy to the Object Lock audit bucket (ADR-004). A prod app deploy is a
# merged promotion PR: Terraform has nothing to change, so apply prod (the only job with the prod
# role) doesn't run. A separate role with nothing but "add a record" avoids a production approval
# just to write one, and keeps the deploy roles out of it.
#
# It can't read anything back, overwrite (Object Lock keeps every version), delete (bucket policy),
# or touch anything else in the account.
data "aws_iam_policy_document" "record" {
  statement {
    sid       = "AddDeployRecords"
    actions   = ["s3:PutObject"]
    resources = [for e in keys(var.environments) : "arn:aws:s3:::${local.audit_bucket}/deploys/${e}/*"]
  }

  # The bucket's default encryption is the audit key: a new object needs a data key, nothing else
  statement {
    sid       = "EncryptWithAuditKey"
    actions   = ["kms:GenerateDataKey"]
    resources = [var.audit_kms_key_arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${local.r}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "record" {
  name   = "deploy-records"
  role   = aws_iam_role.ci["record"].id
  policy = data.aws_iam_policy_document.record.json
}
