output "dashboard_ids" {
  description = "Cloud Monitoring dashboard ids, by service."
  value       = { for k, d in google_monitoring_dashboard.service : k => d.id }
}

output "dashboard_json" {
  description = "Rendered dashboard JSON, by service (what docs/observability/dashboards/ holds for the placeholder staging project)."
  value       = local.dashboard_json
}

output "alert_policy_names" {
  description = "Alert policy resource names, by policy key (pod_restarts, http_5xx, queue_backlog)."
  value = {
    pod_restarts  = google_monitoring_alert_policy.pod_restarts.name
    http_5xx      = google_monitoring_alert_policy.http_5xx.name
    queue_backlog = google_monitoring_alert_policy.queue_backlog.name
  }
}

output "error_log_metric" {
  description = "Log-based metric counting ERROR log entries of the namespace's containers."
  value       = google_logging_metric.error_logs.name
}

output "notification_channel_ids" {
  description = "Email notification channels attached to every alert policy."
  value       = [for c in google_monitoring_notification_channel.email : c.id]
}
