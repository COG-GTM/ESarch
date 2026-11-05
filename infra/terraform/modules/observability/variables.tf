variable "project_id" {
  description = "GCP project id (metrics scope of the dashboards and alert policies)."
  type        = string
}

variable "environment" {
  description = "Environment name; used in resource names and display names."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,14}$", var.environment))
    error_message = "environment must be lowercase, start with a letter and be at most 15 characters."
  }
}

variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
  default     = "esarch"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,22}$", var.name_prefix))
    error_message = "name_prefix must be lowercase, start with a letter and be at most 23 characters."
  }
}

variable "cluster_name" {
  description = "GKE cluster the workloads run in (GMP label cluster, system metric label cluster_name)."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace of the Axon Trader workloads."
  type        = string
  default     = "axon-trader"
}

variable "services" {
  description = "Spring Boot services that get a dashboard. Each name is the pod label app.kubernetes.io/name (mapped to the metric label service by the PodMonitoring) and the container name."
  type        = list(string)
  default     = ["trader-app", "trading-engine"]

  validation {
    condition     = length(var.services) > 0 && alltrue([for s in var.services : can(regex("^[a-z][a-z0-9-]{0,40}$", s))])
    error_message = "services must be a non-empty list of lowercase DNS-label names."
  }
}

variable "rabbitmq_queue" {
  description = "RabbitMQ queue whose depth is charted and alerted on (declared by trader-app)."
  type        = string
  default     = "trades"
}

variable "cloudsql_instance_names" {
  description = "Cloud SQL instance names charted for server-side connections; empty charts every instance in the project."
  type        = list(string)
  default     = []
}

variable "notification_channel_emails" {
  description = "Email addresses notified by every alert policy (one email notification channel each); empty creates the policies without channels."
  type        = list(string)
  default     = []
}

variable "pod_restart_threshold" {
  description = "Container restarts within 15 minutes that open the pod-restart incident."
  type        = number
  default     = 3

  validation {
    condition     = var.pod_restart_threshold >= 1
    error_message = "pod_restart_threshold must be at least 1."
  }
}

variable "http_5xx_ratio_threshold" {
  description = "Share of HTTP requests answered with 5xx (0-1) over 5 minutes that opens the 5xx incident."
  type        = number
  default     = 0.05

  validation {
    condition     = var.http_5xx_ratio_threshold > 0 && var.http_5xx_ratio_threshold < 1
    error_message = "http_5xx_ratio_threshold must be between 0 and 1."
  }
}

variable "queue_backlog_threshold" {
  description = "Ready messages in rabbitmq_queue that open the backlog incident once sustained for queue_backlog_duration."
  type        = number
  default     = 1000

  validation {
    condition     = var.queue_backlog_threshold >= 1
    error_message = "queue_backlog_threshold must be at least 1."
  }
}

variable "queue_backlog_duration" {
  description = "How long the backlog must stay above queue_backlog_threshold (seconds, e.g. 600s)."
  type        = string
  default     = "600s"

  validation {
    condition     = can(regex("^[0-9]+s$", var.queue_backlog_duration))
    error_message = "queue_backlog_duration must be a number of seconds such as 600s."
  }
}

variable "labels" {
  description = "User labels applied to alert policies and notification channels."
  type        = map(string)
  default     = {}
}
