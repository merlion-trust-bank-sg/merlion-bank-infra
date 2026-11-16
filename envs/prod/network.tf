module "network" {
  count = local.enabled ? 1 : 0

  source = "../../modules/network"

  name   = local.name
  region = var.region
  cidr   = "10.20.0.0/16" # staging is 10.10.0.0/16

  # Survives the loss of one AZ (NFR-3): a NAT gateway in each AZ. Interface endpoints keep ECR,
  # Secrets Manager, Logs and STS traffic inside the VPC.
  single_nat_gateway         = false
  enable_interface_endpoints = true

  logs_kms_key_arn = module.logs_key[0].arn

  # Created by bootstrap; every role this pipeline creates must carry it
  permissions_boundary_arn = "arn:aws:iam::${var.account_id}:policy/${local.name}-workload-boundary"
}
