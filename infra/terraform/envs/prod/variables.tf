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

variable "ci_allowed_environments" {
  description = "GitHub environments whose jobs may authenticate; production keeps the deploy-prod.yml approval gate in front of every prod token."
  type        = list(string)
  default     = ["production"]
}

variable "gke_master_ipv4_cidr_block" {
  description = "/28 control plane range of the GKE cluster (must not overlap the VPC ranges)."
  type        = string
}

variable "gke_enable_private_endpoint" {
  description = "Expose the GKE control plane on its private IP only."
  type        = bool
  default     = false
}

variable "gke_master_authorized_networks" {
  description = "CIDRs allowed to reach the GKE control plane (operators, CI runners)."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "gke_deletion_protection" {
  description = "Block terraform destroy of the GKE cluster."
  type        = bool
  default     = true
}

variable "gateway_hostnames" {
  description = "Hostnames served by the Gateway with a Google-managed certificate; the first one serves the hello-world smoke test on staging."
  type        = list(string)
}

variable "cloudsql_instance_names" {
  description = "Cloud SQL instances charted on the service dashboards; empty charts every instance in the project."
  type        = list(string)
  default     = []
}

variable "alert_notification_emails" {
  description = "Email addresses notified by the alert policies (pod restarts, 5xx rate, queue backlog)."
  type        = list(string)
  default     = []
}

variable "cloudsql_tier" {
  description = "Cloud SQL machine tier."
  type        = string
  default     = "db-custom-2-7680"
}

variable "cloudsql_availability_type" {
  description = "Cloud SQL availability: ZONAL or REGIONAL (HA standby)."
  type        = string
  default     = "REGIONAL"
}

variable "cloudsql_disk_size_gb" {
  description = "Initial Cloud SQL SSD size in GB (auto-resize is on)."
  type        = number
  default     = 20
}

variable "cloudsql_point_in_time_recovery_enabled" {
  description = "Enable binary logs for point-in-time recovery."
  type        = bool
  default     = true
}

variable "cloudsql_retained_backups" {
  description = "Number of automated daily backups kept."
  type        = number
  default     = 30
}

variable "cloudsql_deletion_protection" {
  description = "Block deletion of the Cloud SQL instance."
  type        = bool
  default     = true
}
