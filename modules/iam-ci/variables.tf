variable "region" {
  type = string
}
variable "github_org" {
  type = string
}
variable "infra_repo" {
  type = string
}
variable "app_repo" {
  type = string
}
variable "oidc_provider_arn" {
  type = string
}
variable "state_bucket" {
  type = string
}
variable "environments" {
  type = list(string)
  validation {
    condition     = alltrue([for e in var.environments : contains(["dev", "staging", "prod"], e)])
    error_message = "environments may contain only dev, staging, prod."
  }
}
variable "create_plan_role" {
  type    = bool
  default = true
}
variable "create_build_role" {
  type    = bool
  default = true
}
