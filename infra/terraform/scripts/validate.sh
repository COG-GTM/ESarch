#!/usr/bin/env bash
# Offline validation (no GCP credentials, no backend): fmt, validate every root and module,
# mocked-provider tests, tflint.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> terraform fmt -check -recursive"
terraform fmt -check -recursive -diff

for dir in bootstrap envs/* modules/*; do
  echo "==> terraform validate ${dir}"
  terraform -chdir="${dir}" init -backend=false -input=false -no-color >/dev/null
  terraform -chdir="${dir}" validate -no-color
done

echo "==> terraform test modules/foundation (mocked google provider)"
terraform -chdir=modules/foundation test -no-color

echo "==> tflint --recursive"
tflint --init --config "$(pwd)/.tflint.hcl" >/dev/null
tflint --recursive --config "$(pwd)/.tflint.hcl" --format compact
echo "tflint: no issues"
