output "role_arns" {
  value = merge(
    { for k, r in aws_iam_role.deploy : k => r.arn },
    { build = aws_iam_role.build.arn, plan = aws_iam_role.plan.arn }
  )
}

output "ecr_registry" {
  value = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "github_environment_for" {
  description = "Which GitHub Environment each deploy role trusts"
  value       = local.envs
}
