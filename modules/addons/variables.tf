variable "name" {
  description = "Name prefix, e.g. g4-merlion-staging. IAM roles are <name>-*"
  type        = string
}

variable "region" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "permissions_boundary_arn" {
  description = "Boundary required on every IAM role this env creates (bootstrap guardrails)"
  type        = string
}

variable "pod_identity_trust_policy" {
  description = "Trust policy JSON for Pod Identity roles (output of the EKS module)"
  type        = string
}

variable "readable_secret_arns" {
  description = "Secrets Manager secrets External Secrets may read, e.g. the RDS-managed master secrets"
  type        = list(string)
}

variable "secrets_kms_key_arn" {
  description = "KMS key the readable secrets are encrypted with"
  type        = string
}

variable "dns_zone_id" {
  description = "Public hosted zone ExternalDNS writes to (shared with other groups)"
  type        = string
}

variable "dns_name" {
  description = "The only name ExternalDNS may change in that zone, with the names under it and its ownership TXT records"
  type        = string
}
