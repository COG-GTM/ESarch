variable "project_id" {
  description = "GCP project id for this environment."
  type        = string
}

variable "region" {
  description = "Primary region (subnet, NAT, Artifact Registry)."
  type        = string
}

variable "environment" {
  description = "Environment name; used in resource names."
  type        = string

  validation {
    condition     = contains(["staging", "prod"], var.environment)
    error_message = "environment must be staging or prod."
  }
}

variable "name_prefix" {
  description = "Prefix for network and registry names."
  type        = string
  default     = "esarch"
}

variable "services" {
  description = "Project service APIs to enable."
  type        = list(string)
  default = [
    "artifactregistry.googleapis.com",
    "certificatemanager.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "secretmanager.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
    "sts.googleapis.com",
  ]
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

variable "enable_private_service_access" {
  description = "Reserve a private services access range for Cloud SQL private IP."
  type        = bool
  default     = true
}

variable "nat_log_filter" {
  description = "Cloud NAT log filter."
  type        = string
  default     = "ERRORS_ONLY"
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

variable "secrets" {
  description = "Secret Manager secrets keyed by secret id; values are the workload service accounts (trader-app, trading-engine) allowed to read each one."
  type        = map(list(string))
  default = {
    "trader-app-db-password"     = ["trader-app"]
    "trading-engine-db-password" = ["trading-engine"]
    "rabbitmq-password"          = ["trader-app", "trading-engine"]
  }

  validation {
    condition     = alltrue([for sas in values(var.secrets) : alltrue([for sa in sas : contains(["trader-app", "trading-engine"], sa)])])
    error_message = "Secret accessors must be trader-app or trading-engine."
  }
}

variable "kubernetes_namespace" {
  description = "Kubernetes namespace the Axon Trader Helm release runs in."
  type        = string
  default     = "axon-trader"
}

variable "kubernetes_service_accounts" {
  description = "Kubernetes service account names of the workloads, keyed by workload."
  type        = map(string)
  default = {
    "trader-app"     = "trader-app"
    "trading-engine" = "trading-engine"
  }

  validation {
    condition     = alltrue([for k in ["trader-app", "trading-engine"] : contains(keys(var.kubernetes_service_accounts), k)])
    error_message = "kubernetes_service_accounts must define trader-app and trading-engine."
  }
}

variable "enable_gke_workload_identity_bindings" {
  description = "Bind the Kubernetes service accounts to their Google service accounts (set true once the GKE cluster exists)."
  type        = bool
  default     = false
}

variable "wif_pool_id" {
  description = "Workload identity pool id for CI."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository (<owner>/<name>) whose Actions workflows may impersonate the CI deployer."
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
  description = "Git refs allowed to authenticate from CI. Empty allows any ref of the repository."
  type        = list(string)
  default     = []
}
