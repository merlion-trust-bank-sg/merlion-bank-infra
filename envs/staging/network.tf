module "network" {
  source = "../../modules/network"

  name   = local.name
  region = var.region
  cidr   = "10.10.0.0/16"

  # Staging: one NAT gateway and no interface endpoints, to keep cost down
  single_nat_gateway         = true
  enable_interface_endpoints = false

  logs_kms_key_arn = module.logs_key.arn

  # Created by bootstrap; every role this pipeline creates must carry it
  permissions_boundary_arn = "arn:aws:iam::${var.account_id}:policy/${local.name}-workload-boundary"
}
