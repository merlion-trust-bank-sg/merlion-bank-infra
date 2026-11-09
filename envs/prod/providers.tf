provider "aws" {
  region = var.region

  # Refuse to run against any other account
  allowed_account_ids = [var.account_id]

  # Environment is what the CI roles' fence keys on: the other env's role can't touch anything here
  default_tags {
    tags = {
      Project     = var.project
      Team        = var.team
      Environment = local.environment
      ManagedBy   = "terraform"
      Stack       = local.environment
    }
  }
}
