# VPC across 2 AZs:
#   public   /24 x2  ALB, NAT gateway
#   private  /20 x2  EKS nodes and pods
#   database /24 x2  RDS; its route table has no route to the internet or a NAT gateway
#   VPC endpoints: S3 (gateway, free), optional interface endpoints

locals {
  azs = ["${var.region}a", "${var.region}b"]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = var.name
  cidr = var.cidr
  azs  = local.azs

  public_subnets   = [for i in [0, 1] : cidrsubnet(var.cidr, 8, i)]
  private_subnets  = [for i in [1, 2] : cidrsubnet(var.cidr, 4, i)]
  database_subnets = [for i in [100, 101] : cidrsubnet(var.cidr, 8, i)]

  # Isolated database subnets
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

  # Flow logs. The names and the boundary must match what the env's CI role may create:
  # log groups under /aws/vpc/<name>, IAM roles and policies named <name>-*, carrying the boundary.
  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_cloudwatch_log_group_name_prefix       = "/aws/vpc/"
  flow_log_cloudwatch_log_group_name_suffix       = var.name
  flow_log_cloudwatch_log_group_retention_in_days = var.log_retention_days
  flow_log_cloudwatch_log_group_kms_key_id        = var.logs_kms_key_arn
  flow_log_max_aggregation_interval               = 600

  vpc_flow_log_iam_role_name              = "${var.name}-flow-logs"
  vpc_flow_log_iam_role_use_name_prefix   = false
  vpc_flow_log_iam_policy_name            = "${var.name}-flow-logs"
  vpc_flow_log_iam_policy_use_name_prefix = false
  vpc_flow_log_permissions_boundary       = var.permissions_boundary_arn
}
