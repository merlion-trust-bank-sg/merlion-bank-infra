variable "name" {
  description = "Name prefix, e.g. g4-merlion. Bucket <name>-audit-<account>, trail <name>-trail, key alias/<name>-audit"
  type        = string
}

variable "account_id" {
  type = string
}

variable "region" {
  type = string
}

variable "retention_days" {
  description = "Object Lock default retention (governance mode). HC-3 needs at least 365 days"
  type        = number
  default     = 365

  validation {
    condition     = var.retention_days >= 365
    error_message = "HC-3: audit logs must be kept for at least 365 days."
  }
}

variable "include_read_management_events" {
  description = "Record read-only management events too (ADR-004). The account is shared, so this also records other groups' reads; false keeps write events only, at a fraction of the cost"
  type        = bool
  default     = true
}
