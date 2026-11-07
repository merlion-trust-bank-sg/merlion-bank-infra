output "state_buckets" {
  description = "Backend bucket for each layer"
  value       = { for k, b in aws_s3_bucket.state : k => b.id }
}

output "state_kms_key_aliases" {
  description = "kms_key_id to put in each layer's backend block"
  value       = { for k, a in aws_kms_alias.state : k => a.name }
}

output "state_kms_key_arns" {
  description = "Lets each CI role be given decrypt on its own env's key only"
  value       = { for k, key in aws_kms_key.state : k => key.arn }
}

output "github_oidc_provider_arn" {
  description = "For the CI role trust policies in modules/iam-ci"
  value       = data.aws_iam_openid_connect_provider.github.arn
}
