terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.28" # the VPC module v6 needs at least 6.28
    }
  }
}
