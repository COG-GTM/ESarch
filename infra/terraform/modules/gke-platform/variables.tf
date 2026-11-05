variable "project_id" {
  description = "GCP project id."
  type        = string
}

variable "environment" {
  description = "Environment name; used in resource names."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
  default     = "esarch"
}

variable "hostnames" {
  description = "Hostnames served by the Gateway; each gets a certificate map entry on the Google-managed certificate."
  type        = list(string)

  validation {
    condition     = length(var.hostnames) > 0 && alltrue([for h in var.hostnames : can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", h))])
    error_message = "hostnames must be a non-empty list of lowercase DNS names."
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
