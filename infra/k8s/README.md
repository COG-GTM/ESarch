# Cluster add-ons (Kubernetes manifests)

Add-ons for the GKE Autopilot clusters created by `infra/terraform/envs/<env>` (module `gke`).
The GCP side (Gateway IP, Google-managed certificate, smoke-test secret) is Terraform
(`modules/gke-platform`); everything inside the cluster is here.

```
addons/eso/                 External Secrets Operator 2.12.0 (upstream Helm chart, pinned) in namespace external-secrets
addons/cert-manager/        cert-manager v1.20.5 (upstream Helm chart, pinned); required by the RabbitMQ operator
addons/rabbitmq-operator/   RabbitMQ Cluster Operator v2.23.2 (upstream release manifest, pinned) in rabbitmq-system
platform/                   namespace axon-trader, workload KSAs (Workload Identity), one SecretStore per
                            workload, Gateway (gke-l7-global-external-managed + certmap), HTTP->HTTPS redirect,
                            default-deny ingress NetworkPolicy (enforced by Dataplane V2)
components/smoke/           staging acceptance: hello-world behind the Gateway (HTTPS) + ExternalSecret platform-smoke-test
components/rabbitmq/        RabbitmqCluster `rabbitmq` (1 node, 10Gi PVC), default user from Secret Manager
                            (ExternalSecret rabbitmq-default-user), NetworkPolicy for AMQP / management / peers
components/backing-services-check/
                            staging acceptance: debug Job connecting to Cloud SQL (Auth Proxy) and RabbitMQ
components/cluster-env/     replacements that fill project / cluster / GSA / Gateway values from cluster.env
overlays/staging, prod      platform + rabbitmq (+ smoke and backing-services-check on staging; prod: 3 RabbitMQ
                            nodes spread over zones, 50Gi, PodDisruptionBudget); cluster.env is rendered from Terraform outputs
local/kind/                 kind stand-in for staging: rabbitmq + debug Job, MySQL 8.0 stand-in for Cloud SQL
scripts/validate.sh         offline: kustomize build + kubeconform (what CI runs)
scripts/kind-check.sh       local: kind cluster, ESO + cert-manager + operator, local/kind, waits for the debug Job
scripts/cluster-env.sh      writes overlays/<env>/cluster.env from `terraform output kustomize_env`
```

No project ids are committed: `overlays/<env>/cluster.env` is git-ignored and
`cluster.env.example` holds placeholders for validation only.

## Secrets

ESO does not get a GCP role. Each `SecretStore` authenticates as a workload KSA
(`trader-app`, `trading-engine`) through GKE Workload Identity, which maps to the foundation
GSA `<env>-trader-app` / `<env>-trading-engine`. Those GSAs only hold `secretAccessor` on their own
secrets, so an `ExternalSecret` can read exactly what its workload can. Cluster-scoped stores are
disabled in the chart values (`processClusterStore: false`).

## Apply order (once a project exists and the ticket is approved)

```bash
cd infra/terraform/envs/staging
terraform apply                                   # foundation + GKE cluster + gke-platform
# set enable_gke_workload_identity_bindings = true in terraform.tfvars (the
# <project>.svc.id.goog pool exists only after the cluster), then:
terraform apply
$(terraform output -raw gke_get_credentials)
# DNS: A record for each gateway_hostnames entry -> $(terraform output -raw gateway_address)

cd ../../../k8s
kubectl kustomize --enable-helm addons/eso | kubectl apply --server-side -f -
kubectl -n external-secrets rollout status deploy/external-secrets-webhook
kubectl kustomize --enable-helm addons/cert-manager | kubectl apply --server-side -f -
kubectl -n cert-manager rollout status deploy/cert-manager-webhook
kubectl apply --server-side -k addons/rabbitmq-operator
kubectl -n rabbitmq-system rollout status deploy/rabbitmq-cluster-operator
scripts/cluster-env.sh staging
kubectl apply --server-side -k overlays/staging
```

## Live checks (staging acceptance)

```bash
kubectl get nodes                                                  # Autopilot nodes Ready
kubectl -n axon-trader get externalsecret platform-smoke-test     # STATUS SecretSynced, READY True
kubectl -n axon-trader get secret platform-smoke-test -o jsonpath='{.data.value}' | base64 -d
kubectl -n axon-trader get gateway axon-trader                     # PROGRAMMED True, address = gateway_address
curl -sS https://<SMOKE_HOSTNAME>/                                 # "Hello, world!" over a Google-managed cert
kubectl -n axon-trader get externalsecret rabbitmq-default-user backing-services-check  # SecretSynced
kubectl -n axon-trader get rabbitmqcluster rabbitmq                # ALLREPLICASREADY True
kubectl -n axon-trader get pvc                                     # persistence-rabbitmq-server-0 Bound
kubectl -n axon-trader wait --for=condition=complete job/backing-services-check --timeout=5m
kubectl -n axon-trader logs job/backing-services-check -c mysql    # CURRENT_USER trading-engine@%, "mysql: OK"
kubectl -n axon-trader logs job/backing-services-check -c rabbitmq # 100 messages sent and consumed
```

The managed certificate is issued only after the hostname resolves to the Gateway address
(load balancer authorization), which can take up to an hour.

## Backing services locally (kind)

`scripts/kind-check.sh` runs the same RabbitMQ and debug-Job components on a throwaway kind cluster.
A fake-provider `SecretStore` named `gcp-sm-trading-engine` serves freshly generated passwords under
the Secret Manager ids (`trading-engine-db-password`, `rabbitmq-password`), and a MySQL 8.0
Deployment with the Terraform databases and users stands in for Cloud SQL (no Auth Proxy). Needs
kind, kubectl, kustomize, helm and openssl; `KEEP_CLUSTER=1` keeps the cluster for inspection.
