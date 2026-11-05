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

variable "github_repository_id" {
  description = "Numeric GitHub repository id (gh api repos/<owner>/<name> --jq .id). Pins WIF to this exact repository."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "github_repository_id must be the numeric repository id."
  }
}

variable "github_repository_owner_id" {
  description = "Numeric GitHub owner id (gh api repos/<owner>/<name> --jq .owner.id). Pins WIF to this exact owner."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_owner_id))
    error_message = "github_repository_owner_id must be the numeric owner id."
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
