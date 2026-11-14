# Loki stores log chunks and its index in this bucket (ADR-003): us-east-1 only, our own KMS key,
# reached by the Loki pods through Pod Identity. Loki's compactor deletes logs after
# log_retention_days; the lifecycle rule below is only a safety net.
module "loki_key" {
  source = "../kms"

  name        = "${var.name}-loki"
  description = "${var.name} Loki log storage"
}

resource "aws_s3_bucket" "loki" {
  #checkov:skip=CKV_AWS_18:No access logging bucket: CloudTrail records bucket changes, and only the Loki role reads and writes objects
  #checkov:skip=CKV_AWS_144:No cross-region replication: HC-1 keeps application logs in us-east-1 only
  #checkov:skip=CKV2_AWS_62:No event notifications needed for log chunks
  bucket        = "${var.name}-loki"
  force_destroy = var.force_destroy
}

# Versioning protects against accidental overwrites; old versions expire quickly so the compactor's
# deletes really remove logs after the retention period
resource "aws_s3_bucket_versioning" "loki" {
  bucket = aws_s3_bucket.loki.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = module.loki_key.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "loki" {
  bucket                  = aws_s3_bucket.loki.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "loki" {
  bucket = aws_s3_bucket.loki.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id

  rule {
    id     = "safety-net-and-cleanup"
    status = "Enabled"
    filter {}

    # Loki deletes at log_retention_days; anything it misses goes 35 days later
    expiration {
      days = var.log_retention_days + 35
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.loki]
}

data "aws_iam_policy_document" "loki_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.loki.arn, "${aws_s3_bucket.loki.arn}/*"]
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
}

resource "aws_s3_bucket_policy" "loki" {
  bucket = aws_s3_bucket.loki.id
  policy = data.aws_iam_policy_document.loki_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.loki]
}

# --- Loki's Pod Identity role: this bucket and its key only --------------------------------------
data "aws_iam_policy_document" "loki" {
  statement {
    sid       = "ListLokiBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.loki.arn]
  }

  statement {
    sid       = "ReadWriteLogChunks"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.loki.arn}/*"]
  }

  statement {
    sid       = "UseLokiKeyThroughS3"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [module.loki_key.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "loki" {
  name                 = "${var.name}-loki"
  assume_role_policy   = var.pod_identity_trust_policy
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_role_policy" "loki" {
  name   = "${var.name}-loki"
  role   = aws_iam_role.loki.id
  policy = data.aws_iam_policy_document.loki.json
}

resource "aws_eks_pod_identity_association" "loki" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = "loki"
  role_arn        = aws_iam_role.loki.arn
}
