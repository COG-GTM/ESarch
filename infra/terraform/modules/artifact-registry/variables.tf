variable "project_id" {
  description = "GCP project id."
  type        = string
}

variable "location" {
  description = "Artifact Registry location (region)."
  type        = string
}

variable "repository_id" {
  description = "Docker repository id."
  type        = string
}

variable "description" {
  description = "Repository description."
  type        = string
  default     = "Axon Trader container images"
}

variable "labels" {
  description = "Labels applied to the repository."
  type        = map(string)
  default     = {}
}

variable "immutable_tags" {
  description = "Reject pushes that move an existing tag."
  type        = bool
  default     = false
}

variable "cleanup_policy_dry_run" {
  description = "Only log what the cleanup policies would delete."
  type        = bool
  default     = true
}

variable "keep_recent_versions" {
  description = "Number of most recent versions per image always kept."
  type        = number
  default     = 20
}

variable "untagged_retention_days" {
  description = "Untagged versions older than this are deleted."
  type        = number
  default     = 14
}

variable "reader_members" {
  description = "IAM members granted roles/artifactregistry.reader on this repository only, keyed by a static name."
  type        = map(string)
  default     = {}
}

variable "writer_members" {
  description = "IAM members granted roles/artifactregistry.writer on this repository only, keyed by a static name."
  type        = map(string)
  default     = {}
}
