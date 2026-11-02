output "oidc_provider_arn" {
  value = local.oidc_provider_arn
}

output "deploy_role_arns" {
  description = "Put each one in the matching GitHub Environment as variable OIDC_ROLE"
  value       = module.iam_ci.deploy_role_arns
}

output "plan_role_arn" {
  description = "infra repo variable PLAN_ROLE"
  value       = module.iam_ci.plan_role_arn
}

output "build_role_arn" {
  description = "app repo variable BUILD_ROLE"
  value       = module.iam_ci.build_role_arn
}
