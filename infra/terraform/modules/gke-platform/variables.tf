variable "project_id" {
  description = "GCP project id."
  type        = string
}

variable "environment" {
  description = "Environment name; used in resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,14}$", var.environment))
    error_message = "environment must be lowercase, start with a letter and be at most 15 characters."
  }
}

variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
  default     = "esarch"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,22}$", var.name_prefix))
    error_message = "name_prefix must be lowercase, start with a letter and be at most 23 characters."
  }
}

variable "hostnames" {
  description = "Hostnames served by the Gateway; each gets a certificate map entry on the Google-managed certificate."
  type        = list(string)

  validation {
    condition     = length(var.hostnames) > 0 && alltrue([for h in var.hostnames : can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", h))])
    error_message = "hostnames must be a non-empty list of lowercase DNS names."
  }

  validation {
    condition     = length(distinct(var.hostnames)) == length(var.hostnames)
    error_message = "hostnames must not repeat (each is one managed-certificate domain and one map entry)."
  }
}

variable "smoke_test_secret_id" {
  description = "Secret Manager secret read by the platform smoke-test ExternalSecret."
  type        = string
  default     = "platform-smoke-test"
}

variable "smoke_test_value" {
  description = "Non-sensitive constant stored in the smoke-test secret."
  type        = string
  default     = "resolved-from-secret-manager"
}

variable "smoke_test_accessor" {
  description = "IAM member allowed to read the smoke-test secret (the trader-app workload service account)."
  type        = string
}

variable "labels" {
  description = "Labels applied to labelable resources."
  type        = map(string)
  default     = {}
}
