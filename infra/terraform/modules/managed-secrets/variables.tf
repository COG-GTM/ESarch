variable "project_id" {
  description = "GCP project id."
  type        = string
}

variable "secrets" {
  description = "Secrets to create, keyed by secret id. accessors maps a static name to the IAM member granted secretAccessor on that secret only."
  type = map(object({
    accessors = optional(map(string), {})
    labels    = optional(map(string), {})
  }))
  default = {}
}

variable "labels" {
  description = "Labels applied to every secret."
  type        = map(string)
  default     = {}
}

variable "replica_locations" {
  description = "User-managed replica locations. Empty means automatic replication."
  type        = list(string)
  default     = []
}
