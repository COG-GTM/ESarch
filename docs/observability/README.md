# Observability on GKE (replaces TAS Loggregator / Apps Manager)

| TAS | GKE / GCP | Defined in |
| --- | --- | --- |
| Loggregator `cf logs` | Cloud Logging (Autopilot ships container stdout/stderr) + ERROR log-based metric | `infra/terraform/modules/observability` |
| Apps Manager metrics | Google Managed Service for Prometheus (managed collection) | `infra/terraform/modules/gke` (`monitoring_config`) |
| App metrics endpoint | `PodMonitoring` scraping `/actuator/prometheus` on port 8080, pod label `app.kubernetes.io/name` -> `service` | `infra/k8s/platform/monitoring.yaml` |
| RabbitMQ tile (p-rabbitmq) | `PodMonitoring` scraping RabbitMQ `/metrics/per-object` on port 15692 | `infra/k8s/platform/monitoring.yaml` |
| Apps Manager app page | Cloud Monitoring dashboard per service | `dashboards/<service>.json` (exported) |
| Autoscaler / crash notifications | Alert policies: pod restarts, 5xx rate, queue backlog | `infra/terraform/modules/observability` |

## Dashboards (one per service: `trader-app`, `trading-engine`)

Request rate by status, latency (p50/p95/p99 + mean), 5xx ratio, JVM heap (used/committed/max),
RabbitMQ `trades` queue depth (ready/unacked), Cloud SQL connections + Hikari pool, container
restarts, ERROR log rate and a Cloud Logging panel. `dashboards/*.json` is the rendered JSON for
the placeholder staging project; regenerate with `infra/terraform/scripts/export-dashboards.sh`
(the module test fails if they drift).

## Alert policies (PromQL, Cloud Monitoring)

| Policy | Condition (defaults, variables in the module) |
| --- | --- |
| Pod restarts | any container in `axon-trader` restarted >= 3 times in 15 min |
| 5xx rate | 5xx share of a service's requests > 5% for 5 min |
| Queue backlog | `trades` ready messages > 1000 for 10 min |

Recipients: `alert_notification_emails` in the env tfvars (one email channel each).

## Prerequisites for live data

- p3 services expose `/actuator/prometheus` (micrometer-registry-prometheus, histogram
  percentiles enabled for `http.server.requests`) and carry `app.kubernetes.io/name`.
- RabbitMQ pods carry `app.kubernetes.io/component: rabbitmq` (RabbitMQ Cluster Operator default)
  with the `rabbitmq_prometheus` plugin.

Live-data screenshot of the staging dashboards: owed until a GCP project exists and p3 deploys.
