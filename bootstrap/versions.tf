terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
  }

  backend "s3" {
    bucket       = "g4-merlion-tfstate-255945442255-use1"
    key          = "merlion/bootstrap.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "merlion-trust-bank"
      Team      = "g4"
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}
