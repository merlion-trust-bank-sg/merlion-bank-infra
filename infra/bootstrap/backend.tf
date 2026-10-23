# Terraform state for THIS stack lives in your existing state bucket.
# (Backend blocks cannot use variables - edit the bucket name here.)
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
  }

  backend "s3" {
    bucket       = "merlion-tfstate-255945442255-use1"
    key          = "merlion/bootstrap.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
