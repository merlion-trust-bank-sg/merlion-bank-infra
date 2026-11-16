output "bucket_name" {
  value = aws_s3_bucket.audit.id
}

output "bucket_arn" {
  value = aws_s3_bucket.audit.arn
}

output "trail_arn" {
  value = aws_cloudtrail.this.arn
}

output "kms_key_arn" {
  description = "Writers of deploy records need kms:GenerateDataKey on this key"
  value       = aws_kms_key.audit.arn
}
