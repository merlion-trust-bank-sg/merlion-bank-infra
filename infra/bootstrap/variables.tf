variable "github_owner" {
  description = "GitHub organisation/user that owns the repo"
  type        = string
  default     = "merlion-trust-bank"
}

variable "github_repo" {
  description = "Repo that contains .github/workflows (the pipeline)"
  type        = string
  default     = "merlion-bank-app"
}

variable "state_bucket" {
  description = "S3 bucket holding all Terraform state (same as backend.tf)"
  type        = string
  default     = "merlion-tfstate-255945442255-use1"
}

variable "region" {
  type    = string
  default = "us-east-1"
  validation {
    condition     = var.region == "us-east-1"
    error_message = "Data residency: Merlion Trust resources must be in ap-southeast-1."
  }
}

variable "create_oidc_provider" {
  description = "true = create the GitHub OIDC provider; false = it already exists in this account (as in the 3.1 workshop)"
  type        = bool
  default     = false
}

variable "ecr_repositories" {
  type = list(string)
  default = [
    "frontend", "userservice", "contacts",
    "ledgerwriter", "balancereader", "transactionhistory",
    "accounts-db", "ledger-db", "loadgenerator",
  ]
}
