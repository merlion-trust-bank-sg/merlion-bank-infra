variable "region" {
  description = "The ONE approved region (ADR-006)"
  type        = string
  default     = "us-east-1"
}

variable "github_org" {
  type    = string
  default = "merlion-trust-bank-sg"
}

variable "infra_repo" {
  type    = string
  default = "merlion-bank-infra"
}

variable "app_repo" {
  type    = string
  default = "merlion-bank-app"
}

variable "state_bucket" {
  description = "Created by scripts/create-state-bucket.sh"
  type        = string
}

variable "environments" {
  description = "Environments in this account (shared training account: staging + prod)"
  type        = list(string)
  default     = ["staging", "prod"]
}

variable "create_oidc_provider" {
  description = "false if token.actions.githubusercontent.com already exists in the account"
  type        = bool
  default     = false
}
