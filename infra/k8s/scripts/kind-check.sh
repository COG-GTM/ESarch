#!/usr/bin/env bash
# Local acceptance of the backing-service manifests on kind (no GCP): installs ESO, cert-manager
# and the RabbitMQ Cluster Operator, applies local/kind (RabbitMQ component, MySQL stand-in, debug Job)
# with a fake SecretStore holding freshly generated passwords, and waits for the debug Job.
# Usage: infra/k8s/scripts/kind-check.sh   (KEEP_CLUSTER=1 to keep the cluster afterwards)
set -euo pipefail

cluster="${KIND_CLUSTER:-esarch-backing-services}"
root="$(cd "$(dirname "$0")/.." && pwd)"
ns=axon-trader

if ! kind get clusters | grep -qx "${cluster}"; then
  kind create cluster --name "${cluster}" --wait 120s
fi
[ "${KEEP_CLUSTER:-0}" = 1 ] || trap 'kind delete cluster --name "${cluster}"' EXIT
kubectl config use-context "kind-${cluster}" >/dev/null

work="$(mktemp -d)"
apply_chart_addon() {
  cp -R "${root}/addons/$1" "${work}/$1"
  kustomize build --enable-helm "${work}/$1" | kubectl apply --server-side -f - >/dev/null
  kubectl -n "$2" rollout status deploy --timeout=180s
}
echo "==> External Secrets Operator (addons/eso)"
apply_chart_addon eso external-secrets
echo "==> cert-manager (addons/cert-manager)"
apply_chart_addon cert-manager cert-manager
rm -rf "${work}"

echo "==> RabbitMQ Cluster Operator (addons/rabbitmq-operator)"
kubectl apply --server-side -k "${root}/addons/rabbitmq-operator" >/dev/null
kubectl -n rabbitmq-system rollout status deploy/rabbitmq-cluster-operator --timeout=180s

echo "==> generated credentials (never written to the repo)"
kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# Reused on a kept cluster: the MySQL users and the RabbitMQ user already exist with these passwords.
if ! kubectl -n "${ns}" get secret kind-check-credentials >/dev/null 2>&1; then
  gen() { openssl rand -hex 16; }
  kubectl -n "${ns}" create secret generic kind-check-credentials \
    --from-literal=root="$(gen)" --from-literal=app="$(gen)" \
    --from-literal=engine="$(gen)" --from-literal=rabbit="$(gen)" >/dev/null
fi
cred() { kubectl -n "${ns}" get secret kind-check-credentials -o jsonpath="{.data.$1}" | base64 -d; }
root_pw="$(cred root)" app_pw="$(cred app)" engine_pw="$(cred engine)" rabbit_pw="$(cred rabbit)"
# Users get a cloudsqlsuperuser role like the ones Cloud SQL creates; scripts/cloudsql-grants.sh narrows them.
kubectl -n "${ns}" create secret generic mysql-standin \
  --from-literal=root-password="${root_pw}" \
  --from-literal=init.sql="
CREATE DATABASE appdb CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE enginedb CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE ROLE cloudsqlsuperuser;
GRANT ALL PRIVILEGES ON *.* TO cloudsqlsuperuser;
CREATE USER 'trader-app'@'%' IDENTIFIED BY '${app_pw}' DEFAULT ROLE cloudsqlsuperuser;
CREATE USER 'trading-engine'@'%' IDENTIFIED BY '${engine_pw}' DEFAULT ROLE cloudsqlsuperuser;
GRANT cloudsqlsuperuser TO 'trader-app'@'%', 'trading-engine'@'%';" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# Fake provider in place of Secret Manager, same store name and remote keys as staging.
kubectl apply -f - >/dev/null <<YAML
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: gcp-sm-trading-engine
  namespace: ${ns}
spec:
  provider:
    fake:
      data:
        - key: trading-engine-db-password
          value: "${engine_pw}"
        - key: rabbitmq-password
          value: "${rabbit_pw}"
YAML

echo "==> kubectl apply -k local/kind"
# Retry while the operator webhook (cert-manager issued certificate) comes up.
for attempt in $(seq 1 30); do
  kubectl apply --server-side -k "${root}/local/kind" && break
  [ "${attempt}" -lt 30 ] || exit 1
  sleep 5
done
kubectl -n "${ns}" wait --for=condition=Ready externalsecret --all --timeout=120s
kubectl -n "${ns}" rollout status deploy/mysql-standin --timeout=300s
kubectl -n "${ns}" wait --for=condition=AllReplicasReady rabbitmqcluster/rabbitmq --timeout=600s

echo "==> scripts/cloudsql-grants.sh against the stand-in"
MYSQL_HOST=mysql-standin MYSQL_ADMIN_PASSWORD="${root_pw}" NAMESPACE="${ns}" "${root}/scripts/cloudsql-grants.sh"
# Re-run the debug Job from scratch now that the grants are in place (also drops a Job from an earlier run).
kubectl -n "${ns}" delete job backing-services-check --ignore-not-found --wait
kubectl apply --server-side -k "${root}/local/kind" >/dev/null

echo "==> debug Job backing-services-check"
if ! kubectl -n "${ns}" wait --for=condition=complete job/backing-services-check --timeout=300s; then
  kubectl -n "${ns}" describe job/backing-services-check
  kubectl -n "${ns}" logs job/backing-services-check --all-containers --prefix || true
  exit 1
fi
kubectl -n "${ns}" logs job/backing-services-check -c mysql
kubectl -n "${ns}" logs job/backing-services-check -c rabbitmq | tail -n 5
kubectl -n "${ns}" get rabbitmqcluster,statefulset,pvc,externalsecret,job
echo "kind check: OK"
