#!/usr/bin/env bash
# Post-deploy checks for a deploy/helm/axon-trader release (s4.2, CI-5/CI-6/CI-7 of docs/migration/tas-gke-mapping.md):
#   1. wait until trader-app can route commands to trading-engine (POST /actuator/data-initializer answers true);
#   2. the Postman smoke collection (newman) against trader-app and trading-engine;
#   3. ci/tasks/e2e-test-both-sides.sh with engineURL, appURL and uiURL;
#   4. with PUBLIC_URL, the public Gateway route: GET $PUBLIC_URL/api/command/api answers 200.
# Actuator has no public route (CHG-12), so engineURL and appURL are kubectl port-forwards to the Services; uiURL is
# PUBLIC_URL when set, a port-forward to svc/trader-ui otherwise.
# Env: NS (axon-trader), KUBE_CONTEXT (optional), PUBLIC_URL (optional), SMOKE_LOGS (directory for the newman report).
# Writes a results table to $GITHUB_STEP_SUMMARY when it is set. Exit status is non-zero if any check failed.
set -euo pipefail
cd "$(dirname "$0")/../.."

NS=${NS:-axon-trader}
LOGS=${SMOKE_LOGS:-$(mktemp -d)}
APP_PORT=${SMOKE_APP_PORT:-28080}
ENGINE_PORT=${SMOKE_ENGINE_PORT:-28081}
UI_PORT=${SMOKE_UI_PORT:-28082}
PUBLIC_URL=${PUBLIC_URL:-}
PUBLIC_URL=${PUBLIC_URL%/}
mkdir -p "$LOGS"
kc() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} -n "$NS" "$@"; }
summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat >>"$GITHUB_STEP_SUMMARY"; else cat >/dev/null; fi; }

PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do
    if [ -n "$p" ]; then pkill -P "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true; fi
  done
}
trap cleanup EXIT
# kubectl port-forward pins one pod and exits when that pod goes away, so keep re-establishing it.
forward() { while :; do kc port-forward "svc/$1" "$2" || true; sleep 1; done; }
forward trader-app "$APP_PORT:8080" >"$LOGS/pf-trader-app.log" 2>&1 & PIDS+=($!)
forward trading-engine "$ENGINE_PORT:8080" >"$LOGS/pf-trading-engine.log" 2>&1 & PIDS+=($!)
APP_URL=http://localhost:$APP_PORT
ENGINE_URL=http://localhost:$ENGINE_PORT
if [ -n "$PUBLIC_URL" ]; then
  UI_URL=$PUBLIC_URL
else
  forward trader-ui "$UI_PORT:8080" >"$LOGS/pf-trader-ui.log" 2>&1 & PIDS+=($!)
  UI_URL=http://localhost:$UI_PORT
fi
for _ in $(seq 1 30); do
  curl -s -o /dev/null "$APP_URL/actuator/health" && curl -s -o /dev/null "$ENGINE_URL/actuator/health" && break
  sleep 2
done

results=()
record() { results+=("| $1 | $2 |"); }

echo "== smoke 1. trader-app routes commands to trading-engine (data-initializer)"
# Health is UP before trader-app's Axon router has seen trading-engine in Eureka ("No node known to accept"), so retry.
initialised=false
for _ in $(seq 1 30); do
  if [ "$(curl -s -m 20 -X POST "$APP_URL/actuator/data-initializer")" = "true" ]; then initialised=true; break; fi
  sleep 5
done
# The query models are built asynchronously from the events the initializer published. The smoke collection reads
# the order book of the first company and the portfolio of the first user; wait for those, or it races the projections.
projections_ready() {
  local company user
  company=$(curl -sf -m 10 "$APP_URL/query/company" | jq -r '.[0].identifier // empty') && [ -n "$company" ] || return 1
  [ "$(curl -sf -m 10 "$APP_URL/query/order-book/by-company/$company" | jq 'length')" -gt 0 ] 2>/dev/null || return 1
  user=$(curl -sf -m 10 "$APP_URL/query/user" | jq -r '.[0].identifier // empty') && [ -n "$user" ] || return 1
  curl -sf -m 10 -o /dev/null "$APP_URL/query/portfolio/by-user/$user"
}
if [ "$initialised" = true ]; then
  for _ in $(seq 1 60); do projections_ready && break; sleep 2; done
  projections_ready || echo "WARN: query projections not complete after 120s; the smoke collection may fail" >&2
fi
if [ "$initialised" = true ]; then echo "data-initializer: true"; record "Command routing (data-initializer)" pass
else echo "FAIL: trader-app never answered true on /actuator/data-initializer" >&2; record "Command routing (data-initializer)" "**FAIL**"; fi

echo "== smoke 2. Postman smoke collection (newman)"
# The collection prefixes http:// itself, so pass host:port only.
newman_status=0
npx --yes newman@6 run ESArchSmokeTest.postman_collection.json \
  --env-var "appURL=${APP_URL#http://}" --env-var "engineURL=${ENGINE_URL#http://}" \
  --reporters cli,json --reporter-json-export "$LOGS/newman.json" || newman_status=$?
if [ -f "$LOGS/newman.json" ]; then
  newman_counts=$(jq -r '.run.stats | "\(.requests.total - .requests.failed)/\(.requests.total) requests, \(.assertions.total - .assertions.failed)/\(.assertions.total) assertions"' "$LOGS/newman.json")
else
  newman_counts="no report"
fi
if [ "$newman_status" = 0 ]; then record "Postman smoke (newman): $newman_counts" pass
else record "Postman smoke (newman): $newman_counts" "**FAIL** (exit $newman_status)"; fi

echo "== smoke 3. ci/tasks/e2e-test-both-sides.sh (engineURL=$ENGINE_URL appURL=$APP_URL uiURL=$UI_URL)"
# The Concourse task starts with apt-get install (curl, uuid-runtime, jq); off Concourse that step fails and the
# script carries on, so curl and jq must already be on the PATH.
e2e_status=0
engineURL="$ENGINE_URL" appURL="$APP_URL" uiURL="$UI_URL" bash ci/tasks/e2e-test-both-sides.sh >"$LOGS/e2e.log" 2>&1 ||
  e2e_status=$?
grep -v -E '^(E: |W: |Reading package lists)' "$LOGS/e2e.log" || true
if [ "$e2e_status" = 0 ]; then record "e2e-test-both-sides.sh" pass; else record "e2e-test-both-sides.sh" "**FAIL** (exit $e2e_status)"; fi

route_status=0
if [ -n "$PUBLIC_URL" ]; then
  echo "== smoke 4. public route $PUBLIC_URL/api/command/api"
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 30 "$PUBLIC_URL/api/command/api" || true)
  echo "GET $PUBLIC_URL/api/command/api -> $code"
  if [ "$code" = 200 ]; then record "Public route /api/command/api" pass; else route_status=1; record "Public route /api/command/api" "**FAIL** (HTTP $code)"; fi
fi

status=0
[ "$initialised" = true ] && [ "$newman_status" = 0 ] && [ "$e2e_status" = 0 ] && [ "$route_status" = 0 ] || status=1
{
  echo "### Smoke + e2e against \`$NS\`"
  echo
  echo "| Check | Result |"
  echo "|---|---|"
  printf '%s\n' "${results[@]}"
  echo
} | summary
printf '%s\n' "${results[@]}"
if [ "$status" = 0 ]; then echo "SMOKE PASS"; else echo "SMOKE FAIL" >&2; fi
exit "$status"
