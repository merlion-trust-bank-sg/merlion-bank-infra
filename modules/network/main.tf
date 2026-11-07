# INF-05 - VPC across 2 AZs:
#   public   /24 x2  ALB, NAT gateway
#   private  /20 x2  EKS nodes and pods
#   database /24 x2  RDS - route table has NO route to the internet or NAT
#   VPC endpoints: S3 (gateway, free) + optional interface endpoints

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100, < 6.0"
    }
  }
}

variable "name" {
  type = string
}
variable "region" {
  type = string
}
variable "cidr" {
  type = string
}
variable "single_nat_gateway" {
  description = "true = 1 NAT (dev/staging, cheaper). false = 1 NAT per AZ (prod)."
  type        = bool
  default     = true
}
variable "enable_interface_endpoints" {
  description = "ECR, Secrets Manager, Logs, STS endpoints. About USD 15/month each across 2 AZs."
  type        = bool
  default     = false
}
variable "logs_kms_key_arn" {
  type = string
}
variable "log_retention_days" {
  type    = number
  default = 365
}

locals {
  azs = ["${var.region}a", "${var.region}b"]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.21"

  name = var.name
  cidr = var.cidr
  azs  = local.azs

  public_subnets   = [for i in [0, 1] : cidrsubnet(var.cidr, 8, i)]
  private_subnets  = [for i in [1, 2] : cidrsubnet(var.cidr, 4, i)]
  database_subnets = [for i in [100, 101] : cidrsubnet(var.cidr, 8, i)]

  # isolated DB subnets
  create_database_subnet_group           = true
  create_database_subnet_route_table     = true
  create_database_internet_gateway_route = false
  create_database_nat_gateway_route      = false

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway
  enable_dns_hostnames   = true
  enable_dns_support     = true

  # The default security group allows nothing
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }

  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_cloudwatch_log_group_retention_in_days = var.log_retention_days
  flow_log_cloudwatch_log_group_kms_key_id        = var.logs_kms_key_arn
  flow_log_max_aggregation_interval               = 600
}

# ------------------------------ VPC endpoints -------------------------------
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
  tags              = { Name = "${var.name}-s3" }
}

resource "aws_security_group" "endpoints" {
  count       = var.enable_interface_endpoints ? 1 : 0
  name        = "${var.name}-vpc-endpoints"
  description = "HTTPS from inside the VPC to interface endpoints"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "endpoints" {
  count             = var.enable_interface_endpoints ? 1 : 0
  security_group_id = aws_security_group.endpoints[0].id
  cidr_ipv4         = var.cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "VPC to endpoints"
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = var.enable_interface_endpoints ? toset(["ecr.api", "ecr.dkr", "secretsmanager", "logs", "sts"]) : toset([])
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true
  tags                = { Name = "${var.name}-${each.key}" }
}

output "vpc_id" {
  value = module.vpc.vpc_id
}
output "vpc_cidr" {
  value = var.cidr
}
output "private_subnets" {
  value = module.vpc.private_subnets
}
output "public_subnets" {
  value = module.vpc.public_subnets
}
output "database_subnets" {
  value = module.vpc.database_subnets
}
output "database_subnet_group_name" {
  value = module.vpc.database_subnet_group_name
}
