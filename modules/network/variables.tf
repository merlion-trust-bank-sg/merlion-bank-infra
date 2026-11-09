variable "name" {
  description = "Name prefix for every network resource, e.g. g4-merlion-staging. The CI role can only create IAM roles and log groups under its own env's prefix."
  type        = string
}

variable "region" {
  description = "AWS region; the two AZs are <region>a and <region>b"
  type        = string
}

variable "cidr" {
  description = "VPC CIDR, at least a /16 so the subnet maths below fits"
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr, 0)) && tonumber(split("/", var.cidr)[1]) <= 16
    error_message = "cidr must be a valid IPv4 CIDR of /16 or larger."
  }
}

variable "single_nat_gateway" {
  description = "true = one NAT gateway (staging, cheaper). false = one per AZ (prod, survives an AZ outage)."
  type        = bool
  default     = true
}

variable "enable_interface_endpoints" {
  description = "ECR, Secrets Manager, Logs and STS interface endpoints. About USD 15/month each across 2 AZs."
  type        = bool
  default     = false
}

variable "logs_kms_key_arn" {
  description = "KMS key for the flow log group. Its key policy must allow the CloudWatch Logs service."
  type        = string
}

variable "log_retention_days" {
  description = "Flow log retention in days"
  type        = number
  default     = 365
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for the flow log IAM role. The env pipeline can only create roles that carry its env's workload boundary."
  type        = string
}
