# Cloud Logging + Google Managed Service for Prometheus replace TAS Loggregator and Apps Manager.
# Application metrics come from the PodMonitoring in infra/k8s/platform/monitoring.yaml, which
# scrapes /actuator/prometheus and maps the pod label app.kubernetes.io/name to the label
# `service`. System metrics (restarts, Cloud SQL) and the log-based metric are queried with
# PromQL through their Cloud Monitoring names.
locals {
  name = "${var.name_prefix}-${var.environment}"

  # Log-based metric names end up in PromQL metric names, which cannot contain hyphens.
  error_log_metric_name = replace("${local.name}_app_error_logs", "-", "_")
  error_log_metric_promql = format(
    "logging_googleapis_com:user_%s",
    local.error_log_metric_name,
  )

  app_selector = format("cluster=\"%s\",namespace=\"%s\"", var.cluster_name, var.namespace)
  container_selector = format(
    "monitored_resource=\"k8s_container\",cluster_name=\"%s\",namespace_name=\"%s\"",
    var.cluster_name,
    var.namespace,
  )
  cloudsql_selector = format(
    "monitored_resource=\"cloudsql_database\",database_id=~\"%s:(%s)\"",
    var.project_id,
    length(var.cloudsql_instance_names) == 0 ? ".*" : join("|", var.cloudsql_instance_names),
  )
  queue_selector = format("namespace=\"%s\",queue=\"%s\"", var.namespace, var.rabbitmq_queue)

  # Spring Boot's default console pattern logs the level as a bare word; GKE marks plain stdout
  # lines INFO, so match the text as well as structured severities.
  error_log_filter = join(" AND ", [
    "resource.type=\"k8s_container\"",
    "resource.labels.cluster_name=\"${var.cluster_name}\"",
    "resource.labels.namespace_name=\"${var.namespace}\"",
    "(severity>=ERROR OR textPayload:\" ERROR \")",
  ])

  tile = { width = 24, height = 16 }

  dashboards = {
    for svc in var.services : svc => {
      displayName = "Axon Trader ${var.environment} / ${svc}"
      mosaicLayout = {
        columns = 48
        tiles = [
          {
            xPos   = 0
            yPos   = 0
            width  = local.tile.width
            height = local.tile.height
            widget = {
              title = "Request rate (req/s) by status"
              xyChart = {
                dataSets = [{
                  plotType       = "STACKED_AREA"
                  legendTemplate = "{{status}}"
                  targetAxis     = "Y1"
                  timeSeriesQuery = {
                    prometheusQuery = "sum by (status) (rate(http_server_requests_seconds_count{${local.app_selector},service=\"${svc}\"}[5m]))"
                    unitOverride    = "1/s"
                  }
                }]
                yAxis = { label = "req/s", scale = "LINEAR" }
              }
            }
          },
          {
            xPos   = 24
            yPos   = 0
            width  = local.tile.width
            height = local.tile.height
            widget = {
              title = "Latency (p50 / p95 / p99, mean)"
              xyChart = {
                dataSets = concat(
                  [for label, q in { p50 = "0.5", p95 = "0.95", p99 = "0.99" } : {
                    plotType             = "LINE"
                    legendTemplate       = label
                    targetAxis           = "Y1"
                    timeSeriesQuery = {
                      prometheusQuery = "histogram_quantile(${q}, sum by (le) (rate(http_server_requests_seconds_bucket{${local.app_selector},service=\"${svc}\"}[5m])))"
                      unitOverride    = "s"
                    }
                  }],
                  [{
                    plotType       = "LINE"
                    legendTemplate = "mean"
                    targetAxis     = "Y1"
                    timeSeriesQuery = {
                      prometheusQuery = "sum(rate(http_server_requests_seconds_sum{${local.app_selector},service=\"${svc}\"}[5m])) / sum(rate(http_server_requests_seconds_count{${local.app_selector},service=\"${svc}\"}[5m]))"
                      unitOverride    = "s"
                    }
                  }],
                )
                yAxis = { label = "seconds", scale = "LINEAR" }
              }
            }
          },
          {
            xPos   = 0
            yPos   = 16
            width  = local.tile.width
            height = local.tile.height
            widget = {
              title = "Errors: 5xx ratio"
              xyChart = {
                dataSets = [{
                  plotType       = "LINE"
                  legendTemplate = "5xx / all"
                  targetAxis     = "Y1"
                  timeSeriesQuery = {
                    prometheusQuery = "(sum(rate(http_server_requests_seconds_count{${local.app_selector},service=\"${svc}\",status=~\"5..\"}[5m])) or vector(0)) / sum(rate(http_server_requests_seconds_count{${local.app_selector},service=\"${svc}\"}[5m]))"
                    unitOverride    = "10^2.%"
                  }
                }]
                thresholds = [{
                  label      = "alert"
                  value      = var.http_5xx_ratio_threshold
                  color      = "RED"
                  direction  = "ABOVE"
                  targetAxis = "Y1"
                }]
                yAxis = { label = "ratio", scale = "LINEAR" }
              }
            }
          },
          {
            xPos   = 24
            yPos   = 16
            width  = local.tile.width
            height = local.tile.height
            widget = {
              title = "JVM heap (used / committed / max) by pod"
              xyChart = {
                dataSets = [for area in ["used", "committed", "max"] : {
                  plotType       = "LINE"
                  legendTemplate = "{{pod}} ${area}"
                  targetAxis     = "Y1"
                  timeSeriesQuery = {
                    prometheusQuery = "sum by (pod) (jvm_memory_${area}_bytes{${local.app_selector},service=\"${svc}\",area=\"heap\"})"
                    unitOverride    = "By"
                  }
                }]
                yAxis = { label = "bytes", scale = "LINEAR" }
              }
            }
          },
          {
            xPos   = 0
            yPos   = 32
            width  = local.tile.width
            height = local.tile.height
            widget = {
              title = "RabbitMQ queue depth (${var.rabbitmq_queue})"
              xyChart = {
                dataSets = [for state in ["ready", "unacked"] : {
                  plotType       = "LINE"
                  legendTemplate = state
                  targetAxis     = "Y1"
                  timeSeriesQuery = {
                    prometheusQuery = "sum(rabbitmq_queue_messages_${state}{${local.queue_selector}})"
                    unitOverride    = "1"
                  }
                }]
                thresholds = [{
                  label      = "backlog alert"
                  value      = var.queue_backlog_threshold
                  color      = "RED"
                  direction  = "ABOVE"
                  targetAxis = "Y1"
                }]
                yAxis = { label = "messages", scale = "LINEAR" }
              }
            }
          },
          {
            xPos   = 24
            yPos   = 32
            width  = local.tile.width
            height = local.tile.height
            widget = {
              title = "Cloud SQL connections (server) and Hikari pool (${svc})"
              xyChart = {
                dataSets = concat(
                  [{
                    plotType       = "LINE"
                    legendTemplate = "Cloud SQL {{database_id}}"
                    targetAxis     = "Y1"
                    timeSeriesQuery = {
                      prometheusQuery = "sum by (database_id) (cloudsql_googleapis_com:database_network_connections{${local.cloudsql_selector}})"
                      unitOverride    = "1"
                    }
                  }],
                  [for state in ["active", "idle", "pending"] : {
                    plotType       = "LINE"
                    legendTemplate = "pool ${state}"
                    targetAxis     = "Y1"
                    timeSeriesQuery = {
                      prometheusQuery = "sum(hikaricp_connections_${state}{${local.app_selector},service=\"${svc}\"})"
                      unitOverride    = "1"
                    }
                  }],
                )
                yAxis = { label = "connections", scale = "LINEAR" }
              }
            }
          },
          {
            xPos   = 0
            yPos   = 48
            width  = local.tile.width
            height = local.tile.height
            widget = {
              title = "Container restarts (15 min) by pod"
              xyChart = {
                dataSets = [{
                  plotType       = "STACKED_BAR"
                  legendTemplate = "{{pod_name}}"
                  targetAxis     = "Y1"
                  timeSeriesQuery = {
                    prometheusQuery = "sum by (pod_name) (increase(kubernetes_io:container_restart_count{${local.container_selector},container_name=\"${svc}\"}[15m]))"
                    unitOverride    = "1"
                  }
                }]
                yAxis = { label = "restarts", scale = "LINEAR" }
              }
            }
          },
          {
            xPos   = 24
            yPos   = 48
            width  = local.tile.width
            height = local.tile.height
            widget = {
              title = "ERROR log entries (per min)"
              xyChart = {
                dataSets = [{
                  plotType       = "STACKED_BAR"
                  legendTemplate = "{{pod_name}}"
                  targetAxis     = "Y1"
                  timeSeriesQuery = {
                    prometheusQuery = "sum by (pod_name) (rate(${local.error_log_metric_promql}{${local.container_selector},container_name=\"${svc}\"}[5m])) * 60"
                    unitOverride    = "1/min"
                  }
                }]
                yAxis = { label = "entries/min", scale = "LINEAR" }
              }
            }
          },
          {
            xPos   = 0
            yPos   = 64
            width  = 48
            height = 20
            widget = {
              title = "Logs (Cloud Logging, replaces cf logs / Loggregator)"
              logsPanel = {
                resourceNames = ["projects/${var.project_id}"]
                filter = join(" AND ", [
                  "resource.type=\"k8s_container\"",
                  "resource.labels.cluster_name=\"${var.cluster_name}\"",
                  "resource.labels.namespace_name=\"${var.namespace}\"",
                  "resource.labels.container_name=\"${svc}\"",
                ])
              }
            }
          },
        ]
      }
    }
  }

  dashboard_json = { for svc, d in local.dashboards : svc => jsonencode(d) }

  notification_channels = [for c in google_monitoring_notification_channel.email : c.id]
}

resource "google_monitoring_notification_channel" "email" {
  for_each = toset(var.notification_channel_emails)

  project      = var.project_id
  display_name = "Axon Trader ${var.environment} alerts (${each.key})"
  type         = "email"
  labels       = { email_address = each.key }
  user_labels  = var.labels
}

resource "google_logging_metric" "error_logs" {
  project     = var.project_id
  name        = local.error_log_metric_name
  description = "ERROR log entries of containers in ${var.namespace} on ${var.cluster_name}."
  filter      = local.error_log_filter

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_monitoring_dashboard" "service" {
  for_each = local.dashboard_json

  project        = var.project_id
  dashboard_json = each.value

  # The panels query the log-based metric by name; create it first.
  depends_on = [google_logging_metric.error_logs]
}

resource "google_monitoring_alert_policy" "pod_restarts" {
  project               = var.project_id
  display_name          = "Axon Trader ${var.environment}: pod restarts"
  combiner              = "OR"
  severity              = "WARNING"
  notification_channels = local.notification_channels
  user_labels           = var.labels

  conditions {
    display_name = "Container restarted ${var.pod_restart_threshold}+ times in 15 min"

    condition_prometheus_query_language {
      query               = "sum by (pod_name, container_name) (increase(kubernetes_io:container_restart_count{${local.container_selector}}[15m])) >= ${var.pod_restart_threshold}"
      duration            = "0s"
      evaluation_interval = "60s"
      alert_rule          = "AxonTraderPodRestarts"
      rule_group          = local.name
      labels              = { severity = "warning" }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "A container in `${var.namespace}` on `${var.cluster_name}` is crash-looping (TAS equivalent: app instance crashes in Apps Manager). Check `kubectl -n ${var.namespace} describe pod <pod>` for OOMKilled / failed probes and the service dashboard's logs panel."
  }
}

resource "google_monitoring_alert_policy" "http_5xx" {
  project               = var.project_id
  display_name          = "Axon Trader ${var.environment}: HTTP 5xx rate"
  combiner              = "OR"
  severity              = "ERROR"
  notification_channels = local.notification_channels
  user_labels           = var.labels

  conditions {
    display_name = "5xx above ${format("%g", var.http_5xx_ratio_threshold * 100)}% of requests for 5 min"

    condition_prometheus_query_language {
      query               = "sum by (service) (rate(http_server_requests_seconds_count{${local.app_selector},status=~\"5..\"}[5m])) / sum by (service) (rate(http_server_requests_seconds_count{${local.app_selector}}[5m])) > ${var.http_5xx_ratio_threshold}"
      duration            = "300s"
      evaluation_interval = "60s"
      alert_rule          = "AxonTraderHttp5xx"
      rule_group          = local.name
      labels              = { severity = "error" }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "A Spring Boot service in `${var.namespace}` answers more than ${format("%g", var.http_5xx_ratio_threshold * 100)}% of requests with 5xx. Open the service dashboard (errors and logs panels) and check Cloud SQL / RabbitMQ health."
  }
}

resource "google_monitoring_alert_policy" "queue_backlog" {
  project               = var.project_id
  display_name          = "Axon Trader ${var.environment}: RabbitMQ ${var.rabbitmq_queue} backlog"
  combiner              = "OR"
  severity              = "WARNING"
  notification_channels = local.notification_channels
  user_labels           = var.labels

  conditions {
    display_name = "${var.rabbitmq_queue} has more than ${var.queue_backlog_threshold} ready messages for ${var.queue_backlog_duration}"

    condition_prometheus_query_language {
      query               = "sum(rabbitmq_queue_messages_ready{${local.queue_selector}}) > ${var.queue_backlog_threshold}"
      duration            = var.queue_backlog_duration
      evaluation_interval = "60s"
      alert_rule          = "AxonTraderQueueBacklog"
      rule_group          = local.name
      labels              = { severity = "warning" }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "Messages pile up in RabbitMQ queue `${var.rabbitmq_queue}`: the trader-app consumers are down or too slow. Check trader-app pods, restarts and logs on its dashboard."
  }
}
