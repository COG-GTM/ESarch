# Axon Trader TAS → GKE chart

This chart is the phase-one lift-and-shift target for the legacy Axon Trader
reference application. It deliberately keeps Java 8, Spring Boot 2.0.3,
Spring Cloud Finchley, Axon 3.3, Eureka, and the SCS starter dependencies.
The chart replaces TAS platform services without changing application source.

## TAS to Kubernetes mapping

| TAS resource or behavior | Chart resource |
| --- | --- |
| `cf push` Java apps | `trader-app` and `trading-engine` Deployments |
| SCS Service Registry tile | `discovery-server` Deployment and Service |
| Staticfile buildpack and `pushstate: enabled` | nginx UI Deployment and Ingress |
| ClearDB `appdb`/`enginedb` | kind-only MySQL-compatible StatefulSet; GKE uses Cloud SQL |
| CloudAMQP RabbitMQ | kind-only RabbitMQ Deployment; GKE points at managed/operator RabbitMQ |
| SCS Config Server | ConfigMap mounted as `application-cloud.yml` |
| `VCAP_SERVICES` | Secret-backed Spring datasource and RabbitMQ environment |
| `cf add-network-policy` in `deploy-backend.sh` | mutual backend NetworkPolicies, plus UI-to-`trader-app` API access |
| CF port health check | actuator readiness/liveness probes |
| CF `timeout: 120` | startup probes with 24 × 5-second budget |
| one TAS instance | one replica by default |
| CF route | UI Ingress |

The UI image contains the nginx configuration from branch one. Its same-origin
`/query` and `/command` proxy target is intentionally the fixed Kubernetes
Service name `trader-app`; changing that name requires rebuilding the UI image.
The `/query` proxy has buffering disabled for the order-book SSE endpoint.

## Kind validation

Build images from the repository root, create a kind cluster, and load the
images before installing:

```bash
kind create cluster --name axon-trader
for image in \
  tas-to-gke-axon-trader-discovery-server \
  tas-to-gke-axon-trader-trader-app \
  tas-to-gke-axon-trader-trading-engine \
  tas-to-gke-axon-trader-trader-app-ui; do
  kind load docker-image "$image:latest" --name axon-trader
done

helm lint deploy/helm/axon-trader
helm upgrade --install axon-trader deploy/helm/axon-trader \
  --namespace axon-trader --create-namespace \
  -f deploy/helm/axon-trader/values-kind.yaml
kubectl -n axon-trader wait --for=condition=ready pod --all --timeout=10m
kubectl -n axon-trader port-forward service/trader-app-ui 8089:80
```

With the port-forward running, use `http://localhost:8089/`. The UI calls
`/query/company` and `/query/order-book/by-company/{id}` through nginx, and
commands use `/command/StartBuyTransactionCommand` or
`/command/StartSellTransactionCommand`.

The kind override uses an ephemeral MariaDB image as a MySQL-compatible
development dependency. This avoids the memory-heavy MySQL 5.7 initialization
path in a single-node kind container; the default chart values retain MySQL
and persistent storage for a non-kind deployment.

## Real GKE path

For GKE, set `mysql.enabled=false` and `rabbitmq.enabled=false`, set
`mysql.host` to the Cloud SQL proxy loopback endpoint (the chart's backend
Deployments add a Cloud SQL Auth Proxy sidecar when
`cloudSqlProxy.enabled=true`), and point `rabbitmq.host` at the RabbitMQ
Cluster Operator service or managed RabbitMQ endpoint. Set
`cloudSqlProxy.instanceConnectionName` to the Cloud SQL instance connection
name and use a Workload Identity-bound Kubernetes service account.

Example starting point:

```bash
helm upgrade --install axon-trader deploy/helm/axon-trader \
  --namespace axon-trader --create-namespace \
  --set mysql.enabled=false \
  --set rabbitmq.enabled=false \
  --set cloudSqlProxy.enabled=true \
  --set cloudSqlProxy.instanceConnectionName=PROJECT:REGION:INSTANCE \
  --set cloudSqlProxy.serviceAccountName=axon-trader
```

The Cloud SQL Auth Proxy and Workload Identity establish connectivity, but
database dump/restore for the Axon event store remains a cutover activity and
is intentionally not automated by this chart. Store chart credentials in a
secret manager or an externally managed Secret in production; the default
values are demo-only credentials for kind.
