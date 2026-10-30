variable "region" {
  description = "The ONE approved region (ADR-006). Change here + redeploy to move."
  type        = string
  default     = "us-east-1"
}

# tflint-ignore: terraform_unused_declarations
variable "state_bucket" {
  description = "Created by scripts/create-state-bucket.sh (used by the roles from INF-03)"
  type        = string
}

variable "create_oidc_provider" {
  description = "false if token.actions.githubusercontent.com already exists in the account"
  type        = bool
  default     = false
}
