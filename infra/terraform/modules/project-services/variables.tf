variable "project_id" {
  description = "GCP project id the APIs are enabled in."
  type        = string
}

variable "services" {
  description = "Service APIs to enable, e.g. container.googleapis.com."
  type        = list(string)
}
