#!/usr/bin/env bash
# Writes overlays/<env>/cluster.env (git-ignored) from the Terraform outputs of envs/<env>.
# Usage: infra/k8s/scripts/cluster-env.sh staging|prod
set -euo pipefail

env="${1:?usage: cluster-env.sh staging|prod}"
case "${env}" in staging | prod) ;; *) echo "unknown environment: ${env}" >&2; exit 1 ;; esac

root="$(cd "$(dirname "$0")/../.." && pwd)"
terraform -chdir="${root}/terraform/envs/${env}" output -json kustomize_env \
  | jq -r 'to_entries[] | "\(.key)=\(.value)"' >"${root}/k8s/overlays/${env}/cluster.env"
echo "wrote infra/k8s/overlays/${env}/cluster.env"
