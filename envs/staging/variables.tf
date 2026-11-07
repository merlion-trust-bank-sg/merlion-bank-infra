variable "region" {
  description = "The one approved region for data residency"
  type        = string
  default     = "us-east-1"

  validation {
    condition     = var.region == "us-east-1"
    error_message = "Data residency: only us-east-1 is approved."
  }
}

variable "account_id" {
  type    = string
  default = "255945442255"
}

variable "project" {
  type    = string
  default = "merlion-trust-bank"
}

variable "team" {
  type    = string
  default = "g4"
}
