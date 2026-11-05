variable "project_id" {
  description = "GCP project id."
  type        = string
}

variable "region" {
  description = "Region of the Cloud SQL instance (same as the GKE cluster)."
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
  description = "Prefix of the Cloud SQL instance name."
  type        = string
  default     = "esarch"
}

variable "network_self_link" {
  description = "VPC with private services access (foundation network); the instance only gets a private IP in it."
  type        = string
}

variable "databases" {
  description = "Databases to create, each mapped to the MySQL user that owns it (one user per workload)."
  type        = map(string)
  default = {
    "appdb"    = "trader-app"
    "enginedb" = "trading-engine"
  }

  validation {
    condition     = length(distinct(values(var.databases))) == length(var.databases)
    error_message = "Each database needs its own user."
  }
}

variable "user_password_secrets" {
  description = "Secret Manager secret (projects/<project>/secrets/<id>) that receives the password of each database user, keyed by user name."
  type        = map(string)

  validation {
    condition     = alltrue([for s in values(var.user_password_secrets) : can(regex("^projects/[^/]+/secrets/[^/]+$", s))])
    error_message = "Secrets must be full resource names: projects/<project>/secrets/<id>."
  }
}

variable "admin_password_secret" {
  description = "Secret Manager secret (projects/<project>/secrets/<id>) that receives the Cloud SQL root password."
  type        = string
}

variable "rabbitmq_password_secret" {
  description = "Secret Manager secret (projects/<project>/secrets/<id>) that receives the RabbitMQ application user password."
  type        = string
}

variable "tier" {
  description = "Cloud SQL machine tier."
  type        = string
  default     = "db-custom-1-3840"
}

variable "availability_type" {
  description = "ZONAL or REGIONAL (HA with a standby in another zone)."
  type        = string
  default     = "ZONAL"

  validation {
    condition     = contains(["ZONAL", "REGIONAL"], var.availability_type)
    error_message = "availability_type must be ZONAL or REGIONAL."
  }
}

variable "disk_size_gb" {
  description = "Initial SSD size in GB (auto-resize is on)."
  type        = number
  default     = 10
}

variable "point_in_time_recovery_enabled" {
  description = "Enable binary logging for point-in-time recovery."
  type        = bool
  default     = false
}

variable "transaction_log_retention_days" {
  description = "Days of binary logs kept for point-in-time recovery (1-7)."
  type        = number
  default     = 7

  validation {
    condition     = var.transaction_log_retention_days >= 1 && var.transaction_log_retention_days <= 7
    error_message = "transaction_log_retention_days must be between 1 and 7."
  }
}

variable "retained_backups" {
  description = "Number of automated daily backups kept."
  type        = number
  default     = 7
}

variable "backup_start_time" {
  description = "Start of the daily backup window (HH:MM, UTC)."
  type        = string
  default     = "03:00"
}

variable "maintenance_window" {
  description = "Weekly maintenance window: day (1 = Monday) and hour (UTC)."
  type = object({
    day  = number
    hour = number
  })
  default = {
    day  = 7
    hour = 4
  }
}

variable "deletion_protection" {
  description = "Block deletion of the instance (Terraform and Cloud SQL API)."
  type        = bool
  default     = true
}

variable "labels" {
  description = "Labels on the Cloud SQL instance."
  type        = map(string)
  default     = {}
}
