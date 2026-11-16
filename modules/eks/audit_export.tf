# Kubernetes API audit log → Firehose → the Object Lock audit bucket (HC-3). CloudWatch keeps its own
# copy for searching; the bucket copy is the one nobody can delete for a year, admins included.
#
#   log group /aws/eks/<name>/cluster
#     └ subscription filter (audit records only)
#         └ Firehose <name>-eks-audit  (buffers ≤ 5 min, GZIP)
#             └ s3://<audit bucket>/eks-audit/<name>/events/YYYY/MM/DD/HH/…, encrypted with the audit key
locals {
  export_audit = var.audit_export != null
  audit_prefix = "eks-audit/${var.name}/"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# Firehose writes into the audit bucket: new objects under this cluster's prefix only, never read,
# list or delete; encrypt with the audit key, never decrypt
data "aws_iam_policy_document" "audit_firehose" {
  count = local.export_audit ? 1 : 0

  statement {
    sid       = "WriteAuditObjects"
    actions   = ["s3:PutObject", "s3:AbortMultipartUpload"]
    resources = ["${var.audit_export.bucket_arn}/${local.audit_prefix}*"]
  }

  statement {
    sid       = "FindTheBucket"
    actions   = ["s3:GetBucketLocation"]
    resources = [var.audit_export.bucket_arn]
  }

  statement {
    sid       = "EncryptWithAuditKey"
    actions   = ["kms:GenerateDataKey"]
    resources = [var.audit_export.kms_key_arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${data.aws_region.current.region}.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "audit_firehose_trust" {
  count = local.export_audit ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "audit_firehose" {
  count = local.export_audit ? 1 : 0

  name                 = "${var.name}-eks-audit-firehose"
  assume_role_policy   = data.aws_iam_policy_document.audit_firehose_trust[0].json
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_role_policy" "audit_firehose" {
  count = local.export_audit ? 1 : 0

  name   = "${var.name}-eks-audit-firehose"
  role   = aws_iam_role.audit_firehose[0].id
  policy = data.aws_iam_policy_document.audit_firehose[0].json
}

resource "aws_kinesis_firehose_delivery_stream" "audit" {
  #checkov:skip=CKV_AWS_240:Records are encrypted at rest in S3 with the audit key; Firehose holds them for at most 5 minutes in transit
  #checkov:skip=CKV_AWS_241:Same: the destination, the Object Lock bucket, is encrypted with our KMS key
  count = local.export_audit ? 1 : 0

  name        = "${var.name}-eks-audit"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn   = aws_iam_role.audit_firehose[0].arn
    bucket_arn = var.audit_export.bucket_arn
    prefix     = "${local.audit_prefix}events/"
    # Records Firehose couldn't deliver, still inside this cluster's prefix (its role can't write elsewhere)
    error_output_prefix = "${local.audit_prefix}errors/!{firehose:error-output-type}/"
    kms_key_arn         = var.audit_export.kms_key_arn
    compression_format  = "GZIP"
    # Deliver at least every 5 minutes, so at most 5 minutes of audit events exist only in transit
    buffering_interval = 300
    buffering_size     = 5
  }

  depends_on = [aws_iam_role_policy.audit_firehose]
}

# CloudWatch Logs puts the matching log events into the stream
data "aws_iam_policy_document" "audit_logs_to_firehose_trust" {
  count = local.export_audit ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["logs.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:SourceArn"
      values   = ["${aws_cloudwatch_log_group.cluster.arn}*"]
    }
  }
}

resource "aws_iam_role" "audit_logs_to_firehose" {
  count = local.export_audit ? 1 : 0

  name                 = "${var.name}-eks-audit-logs"
  assume_role_policy   = data.aws_iam_policy_document.audit_logs_to_firehose_trust[0].json
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_role_policy" "audit_logs_to_firehose" {
  count = local.export_audit ? 1 : 0

  name = "${var.name}-eks-audit-logs"
  role = aws_iam_role.audit_logs_to_firehose[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "PutIntoAuditStream"
      Effect   = "Allow"
      Action   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
      Resource = aws_kinesis_firehose_delivery_stream.audit[0].arn
    }]
  })
}

# Only Kubernetes audit records: every one is JSON with kind "Event" and an auditID. The other
# control-plane logs in the group (api, authenticator, scheduler…) aren't audit records and stay in
# CloudWatch only. (A filter matches log content, not the stream name.)
resource "aws_cloudwatch_log_subscription_filter" "audit" {
  count = local.export_audit ? 1 : 0

  name            = "${var.name}-eks-audit"
  log_group_name  = aws_cloudwatch_log_group.cluster.name
  filter_pattern  = "{ ($.kind = \"Event\") && ($.auditID = *) }"
  destination_arn = aws_kinesis_firehose_delivery_stream.audit[0].arn
  role_arn        = aws_iam_role.audit_logs_to_firehose[0].arn
  distribution    = "ByLogStream"

  depends_on = [aws_iam_role_policy.audit_logs_to_firehose]
}
