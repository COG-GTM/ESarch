variable "project_id" {
  description = "GCP project id."
  type        = string
}

variable "region" {
  description = "Region of the regional Autopilot cluster."
  type        = string
}

variable "name" {
  description = "Cluster name."
  type        = string
}

variable "network_self_link" {
  description = "VPC self link."
  type        = string
}

variable "subnet_name" {
  description = "Private subnet the nodes use (same region as the cluster)."
  type        = string
}

variable "pods_range_name" {
  description = "Subnet secondary range for pods."
  type        = string
}

variable "services_range_name" {
  description = "Subnet secondary range for services."
  type        = string
}

variable "node_service_account_email" {
  description = "Least-privilege node service account (foundation <env>-gke-nodes)."
  type        = string
}

variable "release_channel" {
  description = "GKE release channel."
  type        = string
  default     = "REGULAR"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], var.release_channel)
    error_message = "release_channel must be RAPID, REGULAR or STABLE."
  }
}

variable "master_ipv4_cidr_block" {
  description = "/28 range for the control plane endpoint; must not overlap the VPC ranges."
  type        = string

  validation {
    condition     = can(cidrhost(var.master_ipv4_cidr_block, 0)) && endswith(var.master_ipv4_cidr_block, "/28")
    error_message = "master_ipv4_cidr_block must be a /28 CIDR."
  }
}

variable "enable_private_endpoint" {
  description = "Expose the control plane on its private IP only (needs a bastion or VPN for kubectl)."
  type        = bool
  default     = false
}

variable "master_authorized_networks" {
  description = "CIDRs allowed to reach the control plane endpoint. Empty allows no external CIDR."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "maintenance_window" {
  description = "Recurring maintenance window (RFC 3339 start/end, RFC 5545 recurrence)."
  type = object({
    start_time = string
    end_time   = string
    recurrence = string
  })
  default = {
    start_time = "2026-01-03T06:00:00Z"
    end_time   = "2026-01-03T12:00:00Z"
    recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
  }
}

variable "deletion_protection" {
  description = "Block terraform destroy of the cluster."
  type        = bool
  default     = true
}

variable "labels" {
  description = "Cluster resource labels."
  type        = map(string)
  default     = {}
}
