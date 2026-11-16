# prod environment: the same modules as staging (envs/staging), sized for production. Applied by the
# pipeline only, after a reviewer approves the plan (tf-apply.yml, production Environment).
locals {
  environment = "prod"
  name        = "${var.team}-merlion-${local.environment}" # g4-merlion-prod

  # Everything below is created only when prod is on (count = local.enabled ? 1 : 0)
  enabled = var.enabled
}
