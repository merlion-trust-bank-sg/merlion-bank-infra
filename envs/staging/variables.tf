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
  description = "Value of the Project tag. The training account's nightly cleanup skips resources tagged with the group's value (case-sensitive)."
  type        = string
  default     = "capstone-project-group-04"

  validation {
    condition     = var.project == "capstone-project-group-04"
    error_message = "Project must be exactly capstone-project-group-04 (lower case): the nightly cleanup only skips resources with that tag."
  }
}

variable "team" {
  type    = string
  default = "g4"
}

variable "app_hostname" {
  description = "The bank's public hostname. Must match the staging entry of dns_names in bootstrap (the CI role may only change records under it)."
  type        = string
  default     = "merlion-staging.sctp-sandbox.com"
}

variable "dns_zone_id" {
  description = "The course's shared public zone, sctp-sandbox.com. Not ours: we only add records under app_hostname."
  type        = string
  default     = "Z00541411T1NGPV97B5C0"
}
