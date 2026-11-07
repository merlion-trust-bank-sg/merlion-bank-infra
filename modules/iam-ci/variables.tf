variable "region" {
  description = "The one approved region. Every non-global action outside it is denied."
  type        = string
}

variable "account_id" {
  type = string
}

variable "prefix" {
  description = "Name prefix for every resource of this project, e.g. g4-merlion"
  type        = string
}

variable "team" {
  description = "Value of the Team tag on everything this project creates, e.g. g4"
  type        = string
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
  description = "Existing GitHub Actions OIDC provider"
  type        = string
}

variable "environments" {
  description = "Environment name => GitHub Environment name, e.g. { staging = \"staging\", prod = \"production\" }"
  type        = map(string)

  validation {
    condition     = alltrue([for e in keys(var.environments) : contains(["staging", "prod"], e)])
    error_message = "Only staging and prod are supported."
  }
}

variable "deploy_repos" {
  description = "Repos whose staging/production jobs may assume the deploy roles"
  type        = list(string)
}

variable "state_buckets" {
  description = "Layer => state bucket name (bootstrap, staging, prod)"
  type        = map(string)
}

variable "state_kms_key_arns" {
  description = "Layer => state KMS key ARN (bootstrap, staging, prod)"
  type        = map(string)
}
