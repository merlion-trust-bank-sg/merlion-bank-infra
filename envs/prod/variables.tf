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
