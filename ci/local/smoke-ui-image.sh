#!/usr/bin/env bash
# Checks the trader-ui image and the local reverse proxy without the Java services: a stub stands in for trader-app,
# so it runs anywhere Docker runs (CI included). The full login + buy check against the real trader-app is
# `proxyURL=http://localhost:8088 ci/local/verify-local.sh`.
set -euo pipefail

cd "$(dirname "$0")/../.."

export ESARCH_PROXY_PORT=${ESARCH_PROXY_PORT:-18088}
export ESARCH_UI_PORT=${ESARCH_UI_PORT:-18090}
export ESARCH_TRADER_APP_PORT=${ESARCH_TRADER_APP_PORT:-18080}
PROXY="http://127.0.0.1:$ESARCH_PROXY_PORT"
UI="http://127.0.0.1:$ESARCH_UI_PORT"
project=esarch-ui-smoke
stub_dir=$(mktemp -d)
override_dir=$(mktemp -d)
stub_pid=

cleanup() {
  [ -n "$stub_pid" ] && kill "$stub_pid" 2>/dev/null || true
  docker rm -f "$project-override" >/dev/null 2>&1 || true
  docker compose -p "$project" --profile ui down --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$stub_dir" "$override_dir"
}
trap cleanup EXIT

mkdir -p "$stub_dir/query" "$stub_dir/actuator"
echo '[{"identifier":"u1","name":"Allard Buijze","userName":"allard"}]' > "$stub_dir/query/user"
echo '{"status":"UP"}' > "$stub_dir/actuator/health"
python3 -m http.server "$ESARCH_TRADER_APP_PORT" --bind 127.0.0.1 --directory "$stub_dir" >/dev/null 2>&1 &
stub_pid=$!

docker compose -p "$project" --profile ui up -d --build --wait trader-ui edge-proxy
for _ in $(seq 1 30); do curl -sf -o /dev/null "$PROXY/" && break; sleep 1; done

status=0
check() { # name, url, expected status, grep pattern for the body
  local out code body
  out=$(curl -s -w '\n%{http_code}' "$2")
  code=${out##*$'\n'}
  body=${out%$'\n'*}
  if [ "$code" = "$3" ] && grep -q -- "$4" <<<"$body"; then
    echo "OK   $1: GET $2 -> $code"
  else
    echo "FAIL $1: GET $2 -> $code (expected $3 and a body matching '$4')" >&2
    status=1
  fi
}

echo "== trader-ui image ($UI)"
check "serves the app" "$UI/" 200 '<div id="root">'
check "loads config.js before the bundle" "$UI/" 200 '<script src="/config.js">'
check "deep link /dashboard" "$UI/dashboard" 200 '<div id="root">'
check "deep link /orderbooks/<id>" "$UI/orderbooks/0f6c3a4e-1d2b-4c5d-9e8f-0123456789ab" 200 '<div id="root">'
check "default runtime config" "$UI/config.js" 200 'AXON_TRADER_CONFIG'
check "probe endpoint" "$UI/healthz" 200 'ok'
check "API is not served by the UI" "$UI/api/query/user" 404 'routed to trader-app'
main_js=$(curl -sf "$UI/" | grep -o '/static/js/main\.[0-9a-f]*\.js' | head -1)
check "bundle" "$UI$main_js" 200 'AXON_TRADER_CONFIG'
if curl -sI "$UI/" | grep -qi '^cache-control: no-cache'; then echo "OK   index.html is not cached"; else echo "FAIL index.html cache header" >&2; status=1; fi
if curl -sI "$UI$main_js" | grep -qi '^cache-control: .*immutable'; then echo "OK   hashed bundle is cached"; else echo "FAIL bundle cache header" >&2; status=1; fi

echo "== reverse proxy ($PROXY)"
check "UI at /" "$PROXY/" 200 '<div id="root">'
check "deep link through the proxy" "$PROXY/orderbooks/abc" 200 '<div id="root">'
check "/api/query -> trader-app /query" "$PROXY/api/query/user" 200 '"userName":"allard"'
check "actuator not routed" "$PROXY/api/actuator/health" 404 'not routed'

echo "== runtime override (mounted config.js)"
echo "window.AXON_TRADER_CONFIG = { apiRoot: 'http://localhost:8080' };" > "$override_dir/config.js"
chmod 644 "$override_dir/config.js"
docker run -d --name "$project-override" -p "127.0.0.1:18091:8080" \
  -v "$override_dir/config.js:/usr/share/nginx/html/config.js:ro" axon-trader/trader-ui:local >/dev/null
for _ in $(seq 1 30); do curl -sf -o /dev/null "http://127.0.0.1:18091/healthz" && break; sleep 1; done
check "mounted config.js is served" "http://127.0.0.1:18091/config.js" 200 "apiRoot: 'http://localhost:8080'"

exit "$status"
