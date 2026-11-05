variable "project_id" {
  description = "Project that owns the state bucket."
  type        = string
}

variable "bucket_name" {
  description = "Globally unique state bucket name."
  type        = string
}

variable "location" {
  description = "Bucket location (region or multi-region)."
  type        = string
  default     = "US"
}

variable "labels" {
  description = "Bucket labels."
  type        = map(string)
  default     = {}
}

variable "noncurrent_versions_to_keep" {
  description = "Noncurrent state versions kept before deletion."
  type        = number
  default     = 20
}
