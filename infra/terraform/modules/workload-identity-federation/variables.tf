variable "project_id" {
  description = "GCP project id."
  type        = string
}

variable "pool_id" {
  description = "Workload identity pool id. Deleted pools are soft-deleted for 30 days, so pick a new id after a destroy."
  type        = string
}

variable "pool_display_name" {
  description = "Pool display name (max 32 chars)."
  type        = string
  default     = "CI pipeline"
}

variable "provider_id" {
  description = "Workload identity pool provider id."
  type        = string
  default     = "github-actions"
}

variable "github_repository" {
  description = "GitHub repository (<owner>/<name>) whose workflows may authenticate."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must look like <owner>/<name>."
  }
}

variable "allowed_refs" {
  description = "Git refs (e.g. refs/heads/master) allowed to authenticate. Empty allows any ref of the repository."
  type        = list(string)
  default     = []
}

variable "ci_service_account_name" {
  description = "Resource name (projects/<p>/serviceAccounts/<email>) of the service account CI impersonates."
  type        = string
}
