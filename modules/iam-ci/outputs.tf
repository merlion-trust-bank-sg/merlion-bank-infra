output "deploy_role_arns" {
  value = { for k, r in aws_iam_role.deploy : k => r.arn }
}
output "plan_role_arn" {
  value = var.create_plan_role ? aws_iam_role.plan[0].arn : null
}
output "build_role_arn" {
  value = var.create_build_role ? aws_iam_role.build[0].arn : null
}
