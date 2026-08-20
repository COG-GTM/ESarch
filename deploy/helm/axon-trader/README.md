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
ConfigMap-backed files use `subPath`, so Kubernetes does not live-update them;
the chart's ConfigMap checksum annotation rolls each workload on `helm upgrade`.
Keep each `deploy/helm/axon-trader/config/*-cloud.yml` copy byte-identical to its
`deploy/config/*/application-cloud.yml` source: Helm `.Files.Get` only packages
files inside the chart, so symlinks and `../` paths cannot replace the copies.

### Trader-app live updates and scaling

`autoscaling.enabled` defaults to `false` intentionally. TAS's `instances: 1`
was a load-bearing application constraint, not merely a resource choice:
`trader-app` order-book SSE updates are emitted by a JVM-local subscription
query emitter, while events are consumed by one competing replica. Scaling the
trader-app live-update path can therefore strand an SSE client on a replica
that did not consume the event, even though the persisted projection remains
correct on refresh.

Before enabling the chart's HPA, trader-app needs tracking processors with
per-replica queues plus a distributed or store-backed mechanism for
subscription-query updates. The constraint applies to the trader-app
live-update path specifically; the existing HPA remains available as a
one-flag demo step with `autoscaling.enabled=true`.

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

For GKE, set `mysql.enabled=false` and `rabbitmq.enabled=false`. When
`cloudSqlProxy.enabled=true`, the backend datasource host automatically becomes
`127.0.0.1`, which reaches the Cloud SQL Auth Proxy sidecar. The chart rejects
configurations that enable both the in-cluster MySQL and the Cloud SQL proxy.
Point `rabbitmq.host` at the RabbitMQ Cluster Operator service or managed
RabbitMQ endpoint. Set `cloudSqlProxy.instanceConnectionName` to the Cloud SQL
instance connection name and use a Workload Identity-bound Kubernetes service
account.

Example starting point:

```bash
helm upgrade --install axon-trader deploy/helm/axon-trader \
  --namespace axon-trader --create-namespace \
  --set mysql.enabled=false \
  --set rabbitmq.enabled=false \
  --set cloudSqlProxy.enabled=true \
  --set cloudSqlProxy.instanceConnectionName=PROJECT:REGION:INSTANCE \
  --set cloudSqlProxy.serviceAccountName=axon-trader \
  --set secrets.existingName=axon-trader-production
```

The Cloud SQL Auth Proxy and Workload Identity establish connectivity, but
database dump/restore for the Axon event store remains a cutover activity and
is intentionally not automated by this chart. In production, set
`secrets.existingName` to an externally managed Secret containing the keys
`db-username`, `db-password`, `rabbitmq-username`, `rabbitmq-password`, and
`mysql-root-password`; the chart does not create a Secret in that mode. The
default values leave `secrets.existingName` empty, so demo credentials are
generated for kind.

The default JDBC parameters use `useSSL=false`: kind's in-cluster MySQL path is
plain TCP, while the Cloud SQL Auth Proxy encrypts its outbound Cloud SQL
connection and the backend-to-proxy hop is local loopback. Set
`database.jdbcQueryParameters` for a TLS-capable MySQL endpoint; in-cluster
RabbitMQ is also plain TCP unless separately configured for TLS.
