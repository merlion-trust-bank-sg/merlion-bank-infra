output "role_arns" {
  description = "Set as the role to assume in each GitHub workflow"
  value       = { for k, r in aws_iam_role.ci : k => r.arn }
}

output "workload_boundary_arns" {
  description = "Permissions boundary each env must attach to every IAM role it creates"
  value       = { for k, p in aws_iam_policy.workload_boundary : k => p.arn }
}
