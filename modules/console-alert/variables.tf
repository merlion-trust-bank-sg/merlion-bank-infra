variable "name" {
  description = "Name prefix, e.g. g4-merlion. Topic and rule <name>-console-writes, key alias/<name>-alerts"
  type        = string
}

variable "watched_principal_arns" {
  description = "IAM users whose console write calls raise an alert (the team)"
  type        = list(string)

  validation {
    condition     = length(var.watched_principal_arns) > 0
    error_message = "List at least one team member."
  }
}

variable "alert_email" {
  description = "Where the alert goes. null = topic only (no subscription). Keep it out of Git"
  type        = string
  default     = null
}
