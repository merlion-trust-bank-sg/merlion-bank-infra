variable "name" {
  description = "Name prefix, e.g. g4-merlion-staging. Bucket <name>-loki, roles <name>-loki and <name>-yace"
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

variable "namespace" {
  description = "Kubernetes namespace of the monitoring stack"
  type        = string
  default     = "monitoring"
}

variable "log_retention_days" {
  description = "Loki keeps logs this long (compactor). The bucket expires objects a little later as a safety net"
  type        = number
  default     = 365

  validation {
    condition     = var.log_retention_days >= 365
    error_message = "Application logs are kept at least 365 days."
  }
}

variable "force_destroy" {
  description = "Allow Terraform to delete the Loki bucket with logs in it. true only where logs are disposable (staging)"
  type        = bool
  default     = false
}
