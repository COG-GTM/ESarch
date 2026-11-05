#!/usr/bin/env bash
# Renders the observability module's dashboards offline (placeholder staging values, no GCP access)
# and writes them to docs/observability/dashboards/<service>.json. The observability module test
# fails when these files drift from the Terraform definition, so rerun this after changing it.
set -euo pipefail

cd "$(dirname "$0")/../modules/observability"
out="../../../../docs/observability/dashboards"
mkdir -p "${out}"

terraform init -backend=false -input=false -no-color >/dev/null
echo 'jsonencode(local.dashboard_json)' | terraform console -no-color \
  -var project_id=axon-trader-staging-placeholder \
  -var environment=staging \
  -var cluster_name=esarch-staging |
  python3 -c '
import json, pathlib, sys
dashboards = json.loads(json.loads(sys.stdin.read()))
out = pathlib.Path(sys.argv[1])
for service, body in sorted(dashboards.items()):
    path = out / f"{service}.json"
    path.write_text(json.dumps(json.loads(body), indent=2) + "\n")
    print(f"wrote {path.resolve().relative_to(pathlib.Path.cwd().parents[3])}")
' "${out}"
