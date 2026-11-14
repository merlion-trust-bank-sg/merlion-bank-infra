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
  description = "Object Lock default retention (governance mode). HC-3 needs at least 365 days. The bucket policy denies changing it (PutBucketObjectLockConfiguration) to everyone: to change it later, remove that statement first, in a reviewed PR"
  type        = number
  default     = 365

  validation {
    condition     = var.retention_days >= 365
    error_message = "HC-3: audit logs must be kept for at least 365 days."
  }
}

variable "include_read_management_events" {
  description = "Record read-only management events too. Off: the account already has a trail, so ours is a paid copy, and in this shared account reads are mostly other groups' and controllers' polling. Write events (who changed what) are what HC-2 needs"
  type        = bool
  default     = false
}
