#!/usr/bin/env bash
# helm lint + helm template | kubeconform for deploy/helm/axon-trader with every values file it ships with
# (defaults, staging, prod) and the kind stand-in values used by ci/kind. Custom resources (ExternalSecret,
# HTTPRoute, Gateway, HealthCheckPolicy, GCPBackendPolicy) are validated against the CRDs-catalog schemas.
set -euo pipefail

K8S_VERSION="${K8S_VERSION:-1.33.0}"
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
chart="${repo}/deploy/helm/axon-trader"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

kubeconform_args=(
  -strict -summary -output text
  -kubernetes-version "${K8S_VERSION}"
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
)

declare -A sets=(
  [default]=""
  [staging]="${chart}/values-staging.yaml"
  [prod]="${chart}/values-prod.yaml"
  [kind]="${repo}/ci/kind/values-kind.yaml"
  [kind-gateway]="${repo}/ci/kind/values-kind.yaml ${repo}/ci/kind/values-kind-gateway.yaml"
)
for name in default staging prod kind kind-gateway; do
  args=()
  for f in ${sets[$name]}; do args+=(-f "$f"); done
  echo "==> ${name}: helm lint --strict"
  helm lint --strict "${chart}" "${args[@]}"
  echo "==> ${name}: helm template | kubeconform"
  helm template axon-trader "${chart}" -n axon-trader "${args[@]}" >"${work}/${name}.yaml"
  kubeconform "${kubeconform_args[@]}" "${work}/${name}.yaml"
done

# Credentials never live in the chart: Secrets come from ExternalSecrets (or, on kind, from the test script).
if grep -n '^kind: Secret$' "${work}"/*.yaml; then
  echo "A rendered manifest contains a Secret; credentials must come from ExternalSecrets." >&2
  exit 1
fi
echo "OK"
