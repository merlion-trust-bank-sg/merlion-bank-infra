# Terraform state: one bucket per layer
#   g4-merlion-bootstrap-tfstate-<account>   this stack          key alias/g4-merlion-bootstrap-state
#   g4-merlion-staging-tfstate-<account>     envs/staging        key alias/g4-merlion-staging-state
#   g4-merlion-prod-tfstate-<account>        envs/prod           key alias/g4-merlion-prod-state
# Each bucket holds one terraform.tfstate (plus its .tflock while a run is in progress).

resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV_AWS_144:No cross-region replication. A second region would break data residency; versioning gives recovery
  #checkov:skip=CKV_AWS_18:No access logging bucket. Every request is a KMS call recorded by CloudTrail, which is the audit record
  #checkov:skip=CKV2_AWS_62:No event notifications needed for state files
  for_each = local.state_layers

  bucket = "${local.prefix}-${each.key}-tfstate-${var.account_id}"

  tags = {
    Environment = each.value.environment
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  for_each = local.state_layers

  bucket = aws_s3_bucket.state[each.key].id
  versioning_configuration {
    status = "Enabled"
  }
}

# Bucket default only. The S3 backend sends its own encryption setting on every upload, so each
# backend block must also set kms_key_id to the same key (otherwise it uploads with AES256).
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  for_each = local.state_layers

  bucket = aws_s3_bucket.state[each.key].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state[each.key].arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  for_each = local.state_layers

  bucket                  = aws_s3_bucket.state[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  for_each = local.state_layers

  bucket = aws_s3_bucket.state[each.key].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  for_each = local.state_layers

  bucket = aws_s3_bucket.state[each.key].id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = var.state_version_retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "state_bucket" {
  for_each = local.state_layers

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state[each.key].arn, "${aws_s3_bucket.state[each.key].arn}/*"]
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

  # prevent_destroy only stops Terraform. This also stops the console and the CLI. DeleteObject
  # (no version ID) stays allowed: Terraform removes its .tflock file after each run, and on a
  # versioned bucket that only adds a delete marker, so history is kept.
  statement {
    sid       = "DenyStateDeletion"
    effect    = "Deny"
    actions   = ["s3:DeleteBucket", "s3:DeleteObjectVersion"]
    resources = [aws_s3_bucket.state[each.key].arn, "${aws_s3_bucket.state[each.key].arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  for_each = local.state_layers

  bucket = aws_s3_bucket.state[each.key].id
  policy = data.aws_iam_policy_document.state_bucket[each.key].json

  depends_on = [aws_s3_bucket_public_access_block.state]
}
