#!/usr/bin/env bash
# Offline validation of the cluster add-on manifests (no cluster, no GCP): render every
# kustomization (overlays with their cluster.env.example placeholders) and check the output
# with kubeconform against the Kubernetes and CRD (External Secrets, Gateway API) schemas.
set -euo pipefail

K8S_VERSION="${K8S_VERSION:-1.33.0}"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

cp -R "${root}/." "${work}/"
for env_dir in "${work}"/overlays/*/; do
  cp "${env_dir}cluster.env.example" "${env_dir}cluster.env"
done

kubeconform_args=(
  -strict -summary -output text
  -kubernetes-version "${K8S_VERSION}"
  # Upstream ESO chart CRDs: no CRD schema is published in kubernetes-json-schema; the custom
  # resources we write (SecretStore, ExternalSecret, Gateway, HTTPRoute) are validated below.
  -skip CustomResourceDefinition
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
)

for target in addons/eso overlays/staging overlays/prod; do
  echo "==> kustomize build ${target} | kubeconform"
  rendered="${work}/$(echo "${target}" | tr '/' '-').yaml"
  kustomize build --enable-helm "${work}/${target}" >"${rendered}"
  if grep -nE '(PROJECT_ID|CLUSTER_NAME|CLUSTER_LOCATION|_GSA|GATEWAY_ADDRESS_NAME|CERT_MAP_NAME|SMOKE_HOSTNAME|SMOKE_SECRET_ID)$' "${rendered}"; then
    echo "unreplaced cluster-env placeholder in ${target}" >&2
    exit 1
  fi
  kubeconform "${kubeconform_args[@]}" "${rendered}"
done
