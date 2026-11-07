# First apply: leave this commented out. The state bucket doesn't exist yet, so state stays local.
# After the first apply: uncomment, then `terraform init -migrate-state` to move state into the
# bucket this stack created. Backend blocks can't use variables, so the values are written out.
# No profile here: credentials come from the environment (AWS_PROFILE locally).

# terraform {
#   backend "s3" {
#     bucket       = "g4-merlion-bootstrap-tfstate-255945442255"
#     key          = "terraform.tfstate"
#     region       = "us-east-1"
#     encrypt      = true
#     kms_key_id   = "alias/g4-merlion-bootstrap-state" # without this the backend uploads with AES256, not our key
#     use_lockfile = true
#   }
# }
