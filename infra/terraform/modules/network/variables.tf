variable "project_id" {
  description = "GCP project id."
  type        = string
}

variable "region" {
  description = "Region for the subnet, router and NAT."
  type        = string
}

variable "network_name" {
  description = "VPC name."
  type        = string
}

variable "subnet_name" {
  description = "Private subnet name (GKE nodes)."
  type        = string
}

variable "subnet_cidr" {
  description = "Primary range of the private subnet."
  type        = string
}

variable "pods_range_name" {
  description = "Name of the secondary range used for GKE pods."
  type        = string
  default     = "pods"
}

variable "pods_cidr" {
  description = "Secondary range for GKE pods."
  type        = string
}

variable "services_range_name" {
  description = "Name of the secondary range used for GKE services."
  type        = string
  default     = "services"
}

variable "services_cidr" {
  description = "Secondary range for GKE services."
  type        = string
}

variable "flow_log_sampling" {
  description = "VPC flow log sampling rate (0.0 - 1.0)."
  type        = number
  default     = 0.5
}

variable "nat_log_filter" {
  description = "Cloud NAT log filter: ERRORS_ONLY, TRANSLATIONS_ONLY or ALL."
  type        = string
  default     = "ERRORS_ONLY"

  validation {
    condition     = contains(["ERRORS_ONLY", "TRANSLATIONS_ONLY", "ALL"], var.nat_log_filter)
    error_message = "nat_log_filter must be ERRORS_ONLY, TRANSLATIONS_ONLY or ALL."
  }
}

variable "enable_private_service_access" {
  description = "Reserve a peering range and connect servicenetworking (needed for Cloud SQL private IP)."
  type        = bool
  default     = true
}

variable "private_service_access_prefix_length" {
  description = "Prefix length of the private services access range."
  type        = number
  default     = 20
}
