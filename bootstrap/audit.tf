# Audit trail: CloudTrail → S3 Object Lock (governance, 365 days), deletes and bypass denied (ADR-004).
# In bootstrap, not in an environment: the pipeline must never be able to change or remove it.
module "audit" {
  source = "../modules/audit"

  name       = local.prefix
  account_id = var.account_id
  region     = var.region
}
