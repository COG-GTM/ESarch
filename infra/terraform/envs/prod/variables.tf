variable "project_id" {
  description = "GCP project id for this environment (provided by the platform owner; never committed)."
  type        = string
}

variable "region" {
  description = "Primary region."
  type        = string
}

variable "labels" {
  description = "Extra labels applied to every resource."
  type        = map(string)
  default     = {}
}

variable "subnet_cidr" {
  description = "Primary range of the private GKE subnet."
  type        = string
}

variable "pods_cidr" {
  description = "Secondary range for GKE pods."
  type        = string
}

variable "services_cidr" {
  description = "Secondary range for GKE services."
  type        = string
}

variable "artifact_registry_immutable_tags" {
  description = "Reject tag overwrites in the Docker repository."
  type        = bool
  default     = false
}

variable "artifact_registry_cleanup_dry_run" {
  description = "Run Artifact Registry cleanup policies in dry-run mode."
  type        = bool
  default     = true
}

variable "kubernetes_namespace" {
  description = "Namespace of the Axon Trader Helm release."
  type        = string
  default     = "axon-trader"
}

variable "enable_gke_workload_identity_bindings" {
  description = "Bind workload KSAs to their GSAs; set true after the GKE cluster exists."
  type        = bool
  default     = false
}

variable "wif_pool_id" {
  description = "Workload identity pool id for CI."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository (<owner>/<name>) allowed to impersonate the CI deployer."
  type        = string
}

variable "github_repository_id" {
  description = "Numeric id of github_repository; pins CI authentication to that exact repository."
  type        = string
}

variable "github_repository_owner_id" {
  description = "Numeric id of the github_repository owner; pins CI authentication to that exact owner."
  type        = string
}

variable "ci_allowed_refs" {
  description = "Git refs allowed to authenticate from CI; empty allows any ref."
  type        = list(string)
  default     = []
}
