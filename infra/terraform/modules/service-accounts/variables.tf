variable "project_id" {
  description = "GCP project id."
  type        = string
}

variable "name_prefix" {
  description = "Prefix added to every account_id (account_id must be 6-30 chars)."
  type        = string
  default     = ""
}

variable "service_accounts" {
  description = <<-EOT
    Service accounts keyed by short name. project_roles are the only project-level roles granted;
    resource-scoped grants (repository, secret) are made by the modules owning those resources.
    kubernetes_service_accounts are "<namespace>/<name>" pairs allowed to impersonate the account.
  EOT
  type = map(object({
    display_name                = string
    description                 = optional(string, "")
    project_roles               = optional(list(string), [])
    kubernetes_service_accounts = optional(list(string), [])
  }))

  validation {
    condition = alltrue(flatten([
      for sa in values(var.service_accounts) : [
        for ksa in sa.kubernetes_service_accounts : can(regex("^[a-z0-9-]+/[a-z0-9-]+$", ksa))
      ]
    ]))
    error_message = "kubernetes_service_accounts entries must look like <namespace>/<name>."
  }
}

variable "enable_gke_workload_identity_bindings" {
  description = "Create the KSA -> GSA workloadIdentityUser bindings (requires an existing Workload Identity enabled GKE cluster)."
  type        = bool
  default     = false
}
