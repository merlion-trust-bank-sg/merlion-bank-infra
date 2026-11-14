terraform {
  # 1.11: write-only arguments, so the JWT private key never reaches the plan or state
  required_version = ">= 1.11, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.1" # ephemeral tls_private_key
    }
  }
}
