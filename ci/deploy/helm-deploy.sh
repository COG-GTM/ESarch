#!/usr/bin/env bash
# helm upgrade --install of deploy/helm/axon-trader, then rollout wait and ci/deploy/smoke.sh; any failure rolls the
# release back to the revision that was deployed before and exits non-zero (s4.2). Used by .github/workflows/deploy.yml
# against GKE and by ci/kind/verify-deploy-rollback.sh against kind, so the same logic runs in both places.
#
# Usage: ci/deploy/helm-deploy.sh [extra helm upgrade args, e.g. -f values-staging.yaml --set k=v]
# Env:
#   RELEASE (axon-trader), NS (axon-trader), KUBE_CONTEXT (optional)
#   IMAGE_REGISTRY  Artifact Registry URL; images are <registry>/<service> as pushed by .github/workflows/ci.yml
#   IMAGE_TAG       tag for every service (git SHA)
#   IMAGE_DIGESTS   JSON {"<service>": "sha256:..."} from ci.yml's publish job; pins each image by digest
#   ROLLOUT_TIMEOUT per-Deployment `kubectl rollout status` timeout (600s)
#   PUBLIC_URL, SMOKE_LOGS  passed to ci/deploy/smoke.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

RELEASE=${RELEASE:-axon-trader}
NS=${NS:-axon-trader}
CHART=deploy/helm/axon-trader
ROLLOUT_TIMEOUT=${ROLLOUT_TIMEOUT:-600s}
DEPLOYMENTS=(discovery-server trading-engine trader-app trader-ui)
SERVICES="trading-engine trader-app discovery-server trader-ui"
export NS KUBE_CONTEXT="${KUBE_CONTEXT:-}"
kc() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} -n "$NS" "$@"; }
hm() { helm ${KUBE_CONTEXT:+--kube-context "$KUBE_CONTEXT"} -n "$NS" "$@"; }
summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat >>"$GITHUB_STEP_SUMMARY"; else cat >/dev/null; fi; }
images() { kc get deploy "${DEPLOYMENTS[@]}" -o jsonpath='{range .items[*]}{.metadata.name}={.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null || true; }

args=(--namespace "$NS" --create-namespace)
if [ -n "${IMAGE_REGISTRY:-}" ]; then
  args+=(--set "global.image.registry=$IMAGE_REGISTRY")
  for s in $SERVICES; do args+=(--set "$s.image.repository=$s"); done
fi
[ -n "${IMAGE_TAG:-}" ] && args+=(--set "global.image.tag=$IMAGE_TAG")
if [ -n "${IMAGE_DIGESTS:-}" ]; then
  for s in $SERVICES; do
    d=$(jq -r --arg s "$s" '.[$s] // empty' <<<"$IMAGE_DIGESTS")
    [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "FAIL: IMAGE_DIGESTS has no sha256 digest for $s" >&2; exit 1; }
    args+=(--set "$s.image.digest=$d")
  done
fi
args+=("$@")

previous=$(hm history "$RELEASE" --max 50 -o json 2>/dev/null | jq -r '[.[] | select(.status == "deployed")] | last | .revision // empty' || true)
echo "== deploy: release $RELEASE in $NS (currently deployed revision: ${previous:-none})"
images

failed=""
echo "== deploy: helm upgrade --install $RELEASE $CHART ${args[*]}"
if ! hm upgrade --install "$RELEASE" "$CHART" "${args[@]}"; then failed="helm upgrade"; fi

if [ -z "$failed" ]; then
  echo "== deploy: rollout status (timeout $ROLLOUT_TIMEOUT each)"
  for d in "${DEPLOYMENTS[@]}"; do
    if ! kc rollout status "deploy/$d" --timeout="$ROLLOUT_TIMEOUT"; then failed="rollout of $d"; break; fi
  done
fi
if [ -n "$failed" ]; then
  kc get pods -o wide || true
  kc get events --sort-by=.lastTimestamp 2>/dev/null | tail -20 || true
fi

if [ -z "$failed" ]; then
  current=$(hm history "$RELEASE" --max 1 -o json | jq -r '.[0].revision')
  echo "== deploy: revision $current rolled out:"
  images
  if ! bash ci/deploy/smoke.sh; then failed="smoke/e2e checks"; fi
fi

if [ -z "$failed" ]; then
  { echo "### Deployed \`$RELEASE\` revision $current to \`$NS\`"; echo; echo '```'; images; echo '```'; } | summary
  echo "DEPLOY OK: $RELEASE revision $current"
  exit 0
fi

echo "::error::$failed failed for $RELEASE; rolling back to revision ${previous:-none}"
if [ -z "$previous" ]; then
  { echo "### Deploy of \`$RELEASE\` FAILED ($failed)"; echo; echo "No earlier deployed revision to roll back to."; } | summary
  echo "DEPLOY FAILED ($failed): no earlier deployed revision to roll back to" >&2
  exit 1
fi
rollback=ok
hm rollback "$RELEASE" "$previous" --wait --timeout "$ROLLOUT_TIMEOUT" || rollback=failed
for d in "${DEPLOYMENTS[@]}"; do kc rollout status "deploy/$d" --timeout="$ROLLOUT_TIMEOUT" || rollback=failed; done
echo "== rollback: helm history"
hm history "$RELEASE" --max 5
images
{
  echo "### Deploy of \`$RELEASE\` FAILED ($failed): rolled back to revision $previous ($rollback)"
  echo
  echo '```'
  hm history "$RELEASE" --max 5
  echo '```'
} | summary
echo "DEPLOY FAILED ($failed): rolled back $RELEASE to revision $previous ($rollback)" >&2
exit 1
