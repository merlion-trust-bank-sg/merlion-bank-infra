provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "merlion-trust-bank"
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}
