# Bootstrap stores its state in the bucket it created. The very first apply in a new account ran with
# this block commented out (the bucket didn't exist yet) and then moved state here with
# `terraform init -migrate-state`. Backend blocks can't use variables, so the values are written out.
# They must match the defaults in variables.tf: account 255945442255 (the shared training account) and
# us-east-1 (the one approved region). Changing either means editing both places.
# No profile here: credentials come from the environment (AWS_PROFILE locally).

terraform {
  backend "s3" {
    bucket       = "g4-merlion-bootstrap-tfstate-255945442255"
    key          = "terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    kms_key_id   = "alias/g4-merlion-bootstrap-state" # without this the backend uploads with AES256, not our key
    use_lockfile = true
  }
}
