# Audit bucket: CloudTrail logs (AWSLogs/), pipeline deploy records (deploys/<env>/) and the
# Kubernetes audit log of each cluster (eks-audit/<cluster>/, via Firehose from modules/eks).
# Object Lock in governance mode, with deletes and governance bypass denied to everyone by the bucket
# policy (ADR-004). The name must match local.audit_bucket in modules/iam-ci,
# whose guardrails already protect it by name.
locals {
  bucket_name = "${var.name}-audit-${var.account_id}"
  trail_name  = "${var.name}-trail"
  trail_arn   = "arn:aws:cloudtrail:${var.region}:${var.account_id}:trail/${local.trail_name}"
}

resource "aws_s3_bucket" "audit" {
  #checkov:skip=CKV_AWS_18:No access logging bucket: reads, deletes and retention changes on audit objects are CloudTrail data events in this same trail
  #checkov:skip=CKV_AWS_144:No cross-region replication: HC-1 data residency keeps audit logs in us-east-1 only
  #checkov:skip=CKV2_AWS_62:No event notifications needed; delivery errors are watched on the trail (INF-17)
  bucket              = local.bucket_name
  object_lock_enabled = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Default retention for every new object. Governance, not compliance: the instructor's advice, so
# the bucket can still be removed at the end of the project through a recorded policy change.
resource "aws_s3_bucket_object_lock_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = var.retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.audit]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.audit.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# No expiration: logs are kept indefinitely; Object Lock sets the minimum, not the maximum (ADR-004).
# No Glacier transition either: CloudTrail files are mostly under Glacier IR's 128 KB minimum.
resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "audit_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # CloudTrail delivery, for this trail only
  statement {
    sid       = "CloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.audit.arn]
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

  statement {
    sid       = "CloudTrailWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.audit.arn}/AWSLogs/${var.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  # Nobody, including account admins, can delete audit objects, bypass governance retention or change
  # the default retention without first removing this statement (recorded by CloudTrail).
  statement {
    sid    = "DenyDeleteAndBypass"
    effect = "Deny"
    actions = [
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:BypassGovernanceRetention",
      "s3:PutBucketObjectLockConfiguration",
    ]
    resources = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  # Our own roles (CI and workloads) can't remove the statements above. protect_bootstrap in
  # modules/iam-ci already denies this to the CI roles; this holds even if that policy changes.
  statement {
    sid       = "DenyPolicyChangesByOurRoles"
    effect    = "Deny"
    actions   = ["s3:PutBucketPolicy", "s3:DeleteBucketPolicy"]
    resources = [aws_s3_bucket.audit.arn]
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

resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = data.aws_iam_policy_document.audit_bucket.json

  # The policy denies PutBucketObjectLockConfiguration, so the retention rule must exist first
  depends_on = [
    aws_s3_bucket_public_access_block.audit,
    aws_s3_bucket_object_lock_configuration.audit,
  ]
}
