# Gateway endpoint: S3 traffic (ECR image layers, Loki chunks) stays off the NAT gateway
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
