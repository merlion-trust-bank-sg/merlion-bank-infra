provider "aws" {
  region = var.region

  # Credentials come from the environment (AWS_PROFILE locally). Refuse to run against any other
  # account, so a wrong profile can't touch another account.
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project     = var.project
      Team        = var.team
      Environment = "shared"
      ManagedBy   = "terraform"
      Stack       = "bootstrap"
    }
  }
}
