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

variable "github_org_id" {
  description = "Numeric ID of the GitHub org. GitHub puts it in the OIDC sub claim."
  type        = string
}

variable "infra_repo" {
  type = string
}

variable "app_repo" {
  type = string
}

variable "repo_ids" {
  description = "Repo name => numeric GitHub repo ID, for every repo that assumes a role"
  type        = map(string)
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

  validation {
    condition     = alltrue([for r in var.deploy_repos : contains(keys(var.repo_ids), r)])
    error_message = "Every deploy repo needs an entry in repo_ids."
  }
}

variable "state_buckets" {
  description = "Layer => state bucket name (bootstrap, staging, prod)"
  type        = map(string)
}

variable "state_kms_key_arns" {
  description = "Layer => state KMS key ARN (bootstrap, staging, prod)"
  type        = map(string)
}

variable "dns_zone_id" {
  description = "The course's shared public hosted zone (sctp-sandbox.com). Each env pipeline may change only records under its own name in dns_names."
  type        = string
}

variable "dns_names" {
  description = "Env => the app's hostname in dns_zone_id, e.g. { staging = \"merlion-staging.sctp-sandbox.com\" }"
  type        = map(string)

  validation {
    condition     = alltrue([for e in keys(var.dns_names) : contains(["staging", "prod"], e)])
    error_message = "Only staging and prod are supported."
  }
}
