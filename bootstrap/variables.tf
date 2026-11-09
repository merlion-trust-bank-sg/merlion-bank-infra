variable "region" {
  description = "The one approved region for data residency. Changing it means a variable change and a redeploy."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = var.region == "us-east-1"
    error_message = "Data residency: only us-east-1 is approved."
  }
}

variable "account_id" {
  description = "Shared training account. Terraform refuses to run against any other account."
  type        = string
  default     = "255945442255"
}

variable "project" {
  type    = string
  default = "merlion-trust-bank"
}

variable "team" {
  description = "Group id. Prefix for every resource name, because the account is shared with other groups."
  type        = string
  default     = "g4"
}

variable "github_org" {
  type    = string
  default = "merlion-trust-bank-sg"
}

# Numeric IDs are part of GitHub's OIDC sub claim. Look up with: gh api orgs/<org> --jq .id
variable "github_org_id" {
  type    = string
  default = "346416510"
}

variable "infra_repo" {
  type    = string
  default = "merlion-bank-infra"
}

variable "infra_repo_id" {
  type    = string
  default = "1431038820"
}

variable "app_repo" {
  type    = string
  default = "merlion-bank-app"
}

variable "app_repo_id" {
  type    = string
  default = "1431037109"
}

variable "environments" {
  description = "Environments that get their own state bucket and key"
  type        = list(string)
  default     = ["staging", "prod"]

  validation {
    condition     = alltrue([for e in var.environments : contains(["staging", "prod"], e)])
    error_message = "Only staging and prod are supported."
  }
}

variable "state_version_retention_days" {
  description = "How long old state versions are kept after being replaced"
  type        = number
  default     = 90
}
