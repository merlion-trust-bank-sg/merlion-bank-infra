terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
  }

  # Bucket created by scripts/create-state-bucket.sh. Change the account id
  # if you are not in 255945442255.
  backend "s3" {
    bucket       = "g4-merlion-tfstate-255945442255-use1"
    key          = "merlion/bootstrap.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region              = var.region
  allowed_account_ids = ["255945442255"] # hard stop if logged in to another account
  # No Environment tag here: CI roles and ECR repos are tagged
  # Environment = "shared" in their modules (the fence then blocks every
  # gha-<env> role from changing them). Buckets are protected by bucket policy.
  default_tags {
    tags = {
      Project   = "merlion-trust-bank"
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}
