output "loki_bucket_name" {
  description = "Loki's chunk and index bucket; deploy/platform reads it as <cluster name>-loki"
  value       = aws_s3_bucket.loki.id
}

output "loki_role_arn" {
  value = aws_iam_role.loki.arn
}

output "yace_role_arn" {
  value = aws_iam_role.yace.arn
}
