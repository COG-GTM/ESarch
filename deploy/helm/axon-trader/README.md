# axon-trader Helm chart

Umbrella chart for Axon Trader on GKE (plan step s3.5). One subchart per service under `charts/`, all rendered from
the `axon-common` library chart so the four Deployments share one template:

| Subchart | Objects |
| --- | --- |
| `trading-engine` (1 replica), `trader-app` | Deployment (Cloud SQL Auth Proxy native sidecar), Service `:8080`, ConfigMap `<app>-config`, ExternalSecret `<app>-secrets`, ServiceAccount (Workload Identity), PodDisruptionBudget, HPA |
| `discovery-server` | Deployment (1 replica, `Recreate`), Service `:8761`, ConfigMap, ServiceAccount |
| `trader-ui` | Deployment (nginx, read-only root fs), Service `:8080`, ServiceAccount, PodDisruptionBudget, HPA |
| umbrella `templates/` | HTTPRoute, optional Gateway, GKE `HealthCheckPolicy` / `GCPBackendPolicy`, NetworkPolicies |

The chart replaces the manifests that used to live in `deploy/kubernetes/` (discovery-server, ConfigMaps,
ExternalSecrets) and keeps their names, keys and labels, so `infra/k8s/platform` (SecretStores, PodMonitoring,
default-deny) works unchanged. Each subchart documents its values in `charts/<service>/values.yaml`.

## Environments

```sh
helm upgrade --install axon-trader deploy/helm/axon-trader -n axon-trader -f deploy/helm/axon-trader/values-staging.yaml \
  --set global.image.registry=<artifact_registry_url> --set global.image.tag=<git sha> \
  --set trading-engine.cloudSqlProxy.instanceConnectionName=<instance_connection_name> \
  --set trader-app.cloudSqlProxy.instanceConnectionName=<instance_connection_name> \
  --set 'networkPolicy.mysql.peers[0].ipBlock.cidr=<psa range>'
```

`values-staging.yaml` / `values-prod.yaml` sit on top of `infra/k8s/overlays/<env>`, which owns the namespace, the
Gateway with the Google-managed certificate (Certificate Manager map), the SecretStores and the trader-app /
trading-engine KSAs. The UPPER_CASE placeholders are Terraform outputs passed with `--set`; nothing secret is in the
chart.

## Routing (TAS routes RTE-2, RTE-3)

`/` goes to `trader-ui`; `/api/command/*` and `/api/query/*` go to `trader-app` with `/api` stripped, the same
contract as `docker/local-proxy`. Other `/api` paths fall through to nginx, which answers 404, so `/actuator` stays
cluster-internal (CHG-12). `GCPBackendPolicy` gives `trader-app` a 3600 s backend timeout for the order-book SSE
stream; `HealthCheckPolicy` points the load balancer at `/actuator/health` and `/healthz`.

## NetworkPolicies (TAS NET-1, NET-2)

| Policy | Allows |
| --- | --- |
| `axon-command-bus` | trader-app <-> trading-engine on 8080 (the two `cf add-network-policy` rules) |
| `discovery-server` | trader-app, trading-engine -> Eureka 8761; Eureka egress DNS only |
| `gateway-to-frontends` | Gateway (GFE / health-check ranges on GKE) -> trader-ui, trader-app 8080 |
| `axon-apps-egress` | trader-app, trading-engine -> each other, Eureka, MySQL, RabbitMQ, DNS, plus `extraEgress` (metadata server and Google APIs on GKE) |
| `trader-ui-egress` | nothing |

## trading-engine runs one replica

On TAS the engine ran one instance (APP-1), and the chart keeps it that way: with two engine pods the kind smoke lost
trades. The buy/sell sagas run on a subscribing processor, so a saga started on pod A (by `Start*TransactionCommand`,
routed by transaction id) is only committed after `ReserveItemsCommand` (routed by portfolio id) already ran on pod B,
whose saga manager finds no saga for the resulting `ItemsReservedEvent`; the sell is never confirmed and the trade
never matches. `ci/kind/verify-axon-routing.sh` still proves command routing and failover with two engine replicas
(`--set trading-engine.replicaCount=2`); scaling the engine for real needs the sagas on a tracking processor first.
`trader-app` (no sagas) scales with its HPA.

## Checks

- `deploy/helm/scripts/validate.sh`: `helm lint --strict` and `helm template | kubeconform -strict` for the default,
  staging, prod and kind values (CI: `.github/workflows/helm.yml`).
- `ci/kind/verify-helm-smoke.sh`: installs the chart on kind with MySQL/RabbitMQ stand-ins and Envoy Gateway, runs the
  Postman smoke collection and the UI/Gateway checks (`ci/local/verify-local.sh`), then probes the NetworkPolicies.
- `ci/kind/verify-axon-routing.sh`: Axon command routing over Eureka with two replicas per app, on the same chart.
