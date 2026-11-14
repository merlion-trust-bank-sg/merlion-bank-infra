variable "name" {
  description = "Cluster name, e.g. g4-merlion-staging. IAM roles, keys and log groups are named after it"
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version, e.g. 1.33. Upgrade one minor version at a time."
  type        = string
}

variable "private_subnet_ids" {
  description = "Subnets for the control plane ENIs and the worker nodes"
  type        = list(string)
}

variable "permissions_boundary_arn" {
  description = "Boundary required on every IAM role this env creates (bootstrap guardrails)"
  type        = string
}

variable "public_access_cidrs" {
  description = "Who can reach the public Kubernetes API endpoint. Access still needs IAM + an access entry."
  type        = list(string)
}

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group"
  type        = list(string)
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT"
  type        = string
  default     = "ON_DEMAND"
}

variable "node_min_size" {
  description = "Minimum number of nodes"
  type        = number
}

variable "node_desired_size" {
  description = "Nodes at creation. Ignored afterwards so an autoscaler can change it."
  type        = number
}

variable "node_max_size" {
  description = "Maximum number of nodes"
  type        = number
}

variable "node_disk_size_gb" {
  description = "Root volume size per node (gp3, encrypted)"
  type        = number
  default     = 30
}

variable "cluster_log_retention_days" {
  description = "Retention of the control-plane logs, including the Kubernetes audit log"
  type        = number
  default     = 365

  validation {
    condition     = var.cluster_log_retention_days >= 365
    error_message = "HC-3: the control-plane log group holds the Kubernetes audit log and must keep it at least 365 days."
  }
}

variable "logs_kms_key_arn" {
  description = "KMS key for the control-plane log group (the env's logs key)"
  type        = string
}

variable "admin_principal_arns" {
  description = "IAM principals with cluster-admin (e.g. the env's CI role)"
  type        = list(string)
  default     = []
}

variable "viewer_principal_arns" {
  description = "IAM principals with read-only access to the cluster"
  type        = list(string)
  default     = []
}

variable "audit_export" {
  description = <<-EOT
    Copy the Kubernetes API audit log to the Object Lock audit bucket (bootstrap, modules/audit) under
    eks-audit/<cluster>/, where nobody can delete it for a year (HC-3). null = keep it in CloudWatch only.
    bucket_arn and kms_key_arn are the audit bucket and its key; the key policy must allow Firehose
    for streams named <name>-eks-audit.
  EOT
  type = object({
    bucket_arn  = string
    kms_key_arn = string
  })
  default = null
}

variable "protect_log_group" {
  description = <<-EOT
    Keep the control-plane log group when the environment is destroyed (skip_destroy). For prod, which
    is only torn down deliberately. Must match the environments DenyEksLogTampering covers in
    modules/iam-ci (prod only), or a destroy fails with AccessDenied on the log group.
  EOT
  type        = bool
  default     = false
}
