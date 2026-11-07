# State bucket and key created by bootstrap. Backend blocks can't use variables, so the values are
# written out; they must match bootstrap (account 255945442255, us-east-1).
# No profile here: credentials come from the environment (OIDC in CI, AWS_PROFILE locally).
terraform {
  backend "s3" {
    bucket       = "g4-merlion-prod-tfstate-255945442255"
    key          = "terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    kms_key_id   = "alias/g4-merlion-prod-state" # without this the backend uploads with AES256, not our key
    use_lockfile = true
  }
}
