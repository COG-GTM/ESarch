# Offline unit tests: the google provider is mocked, so no credentials or project are needed.
mock_provider "google" {}

variables {
  project_id   = "axon-trader-staging-placeholder"
  environment  = "staging"
  cluster_name = "esarch-staging"
}

run "dashboards_per_service" {
  command = apply

  assert {
    condition     = sort(keys(google_monitoring_dashboard.service)) == tolist(["trader-app", "trading-engine"])
    error_message = "Each Spring Boot service needs its own dashboard."
  }

  assert {
    condition = alltrue([for svc, d in google_monitoring_dashboard.service : alltrue([
      for t in jsondecode(d.dashboard_json).mosaicLayout.tiles : t.xPos + t.width <= 48
    ])])
    error_message = "Tiles must fit the 48-column mosaic layout."
  }

  assert {
    condition = alltrue([for svc, d in google_monitoring_dashboard.service : alltrue([
      for needle in [
        "http_server_requests_seconds_count",
        "http_server_requests_seconds_bucket",
        "status=~\\\"5..\\\"",
        "jvm_memory_used_bytes",
        "rabbitmq_queue_messages_ready{namespace=\\\"axon-trader\\\",queue=\\\"trades\\\"}",
        "cloudsql_googleapis_com:database_network_connections",
        "hikaricp_connections_active",
        "kubernetes_io:container_restart_count",
        "logging_googleapis_com:user_esarch_staging_app_error_logs",
        "service=\\\"${svc}\\\"",
        "logsPanel",
      ] : strcontains(d.dashboard_json, needle)
    ])])
    error_message = "Each dashboard must chart request rate, latency, errors, JVM heap, queue depth, Cloud SQL connections, restarts and logs for its own service."
  }

  assert {
    condition     = jsondecode(google_monitoring_dashboard.service["trader-app"].dashboard_json).displayName == "Axon Trader staging / trader-app"
    error_message = "Dashboard display name unexpected."
  }

  assert {
    condition = alltrue([for svc in ["trader-app", "trading-engine"] :
      jsondecode(output.dashboard_json[svc]) == jsondecode(file("../../../../docs/observability/dashboards/${svc}.json"))
    ])
    error_message = "docs/observability/dashboards/*.json drifted from the module; run infra/terraform/scripts/export-dashboards.sh."
  }

  assert {
    condition     = strcontains(google_monitoring_alert_policy.pod_restarts.conditions[0].condition_prometheus_query_language[0].query, "kubernetes_io:container_restart_count{monitored_resource=\"k8s_container\",cluster_name=\"esarch-staging\",namespace_name=\"axon-trader\"}[15m])) >= 3")
    error_message = "Pod-restart policy must count restarts of the namespace's containers over 15 minutes."
  }

  assert {
    condition = alltrue([
      strcontains(google_monitoring_alert_policy.http_5xx.conditions[0].condition_prometheus_query_language[0].query, "status=~\"5..\""),
      endswith(google_monitoring_alert_policy.http_5xx.conditions[0].condition_prometheus_query_language[0].query, "> 0.05"),
      google_monitoring_alert_policy.http_5xx.conditions[0].condition_prometheus_query_language[0].duration == "300s",
    ])
    error_message = "5xx policy must alert on the 5xx share of requests above 5% for 5 minutes."
  }

  assert {
    condition = alltrue([
      google_monitoring_alert_policy.queue_backlog.conditions[0].condition_prometheus_query_language[0].query == "sum(rabbitmq_queue_messages_ready{namespace=\"axon-trader\",queue=\"trades\"}) > 1000",
      google_monitoring_alert_policy.queue_backlog.conditions[0].condition_prometheus_query_language[0].duration == "600s",
    ])
    error_message = "Queue backlog policy must watch ready messages of the trades queue for 10 minutes."
  }

  assert {
    condition     = length(google_monitoring_notification_channel.email) == 0 && length(google_monitoring_alert_policy.http_5xx.notification_channels) == 0
    error_message = "No notification channel is created unless emails are given."
  }

  assert {
    condition     = google_logging_metric.error_logs.name == "esarch_staging_app_error_logs" && strcontains(google_logging_metric.error_logs.filter, "resource.labels.namespace_name=\"axon-trader\"")
    error_message = "Error log metric must be named for PromQL (no hyphens) and scoped to the namespace."
  }
}

run "notification_channels_and_cloudsql_filter" {
  command = plan

  variables {
    notification_channel_emails = ["oncall@example.com"]
    cloudsql_instance_names     = ["esarch-staging-mysql"]
  }

  assert {
    condition     = google_monitoring_notification_channel.email["oncall@example.com"].type == "email" && google_monitoring_notification_channel.email["oncall@example.com"].labels.email_address == "oncall@example.com"
    error_message = "Each email gets an email notification channel."
  }

  assert {
    condition     = strcontains(google_monitoring_dashboard.service["trading-engine"].dashboard_json, "database_id=~\\\"axon-trader-staging-placeholder:(esarch-staging-mysql)\\\"")
    error_message = "Cloud SQL panel must filter on the given instances."
  }
}

run "rejects_bad_threshold" {
  command = plan

  variables {
    http_5xx_ratio_threshold = 5
  }

  expect_failures = [var.http_5xx_ratio_threshold]
}

run "rejects_bad_backlog_duration" {
  command = plan

  variables {
    queue_backlog_duration = "10m"
  }

  expect_failures = [var.queue_backlog_duration]
}
