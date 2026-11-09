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
  description = "Retention of the control-plane logs"
  type        = number
  default     = 365
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
