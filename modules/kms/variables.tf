variable "name" {
  description = "Key name, used for the alias alias/<name>, e.g. g4-merlion-staging-logs"
  type        = string
}

variable "description" {
  description = "What the key encrypts"
  type        = string
}

variable "deletion_window_in_days" {
  description = "Days before a deleted key is gone for good (7-30). Data encrypted with it can't be read after that."
  type        = number
  default     = 7
}

variable "service_statements" {
  description = "AWS services allowed to use the key directly (e.g. CloudWatch Logs), each with optional conditions"
  type = list(object({
    sid     = string
    service = string
    actions = list(string)
    conditions = optional(list(object({
      test     = string
      variable = string
      values   = list(string)
    })), [])
  }))
  default = []
}
