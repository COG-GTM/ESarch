#!/usr/bin/env bash
# s3.5 acceptance check for deploy/helm/axon-trader on a local kind cluster:
#   1. helm install the chart (ci/kind/values-kind.yaml + values-kind-gateway.yaml) against in-cluster MySQL/RabbitMQ
#      stand-ins, with Envoy Gateway serving the chart's Gateway + HTTPRoute in place of the GKE Gateway;
#   2. run ci/local/verify-local.sh against it: the Postman smoke collection (newman), ci/tasks/e2e-test-both-sides.sh,
#      a buy/sell trade checked in both portfolios, and the UI + same-origin /api checks through the Gateway
#      (/ -> trader-ui, /api/{command,query} -> trader-app, /api/actuator not routed);
#   3. check the NetworkPolicies with probe pods that borrow the apps' labels: the Axon apps reach each other, Eureka,
#      MySQL and RabbitMQ; anything else (an unlabelled pod, trader-ui) reaches none of them.
# Build the images first (see verify-axon-routing.sh). Needs docker, kind, kubectl, helm, jq, node (npx newman) and
# uuidgen. ESARCH_KIND_KEEP=1 keeps the cluster afterwards. Never touches GCP or TAS.
set -euo pipefail
cd "$(dirname "$0")/../.."

CLUSTER=${ESARCH_KIND_CLUSTER:-esarch-helm}
NS=axon-trader
LOGS=${ESARCH_LOGS:-/tmp/esarch-kind-helm}
APP_PORT=${ESARCH_APP_PORT:-18080}
ENGINE_PORT=${ESARCH_ENGINE_PORT:-18081}
GATEWAY_PORT=${ESARCH_GATEWAY_PORT:-18088}
EUREKA_PORT=${ESARCH_EUREKA_PORT:-18761}
EUREKA_URL=http://localhost:$EUREKA_PORT
mkdir -p "$LOGS"
rm -f "$LOGS"/*.log
k() { kubectl --context "kind-$CLUSTER" -n "$NS" "$@"; }
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && { pkill -P "$p"; kill "$p"; } 2>/dev/null || true; done
  k delete pod -l esarch-probe=1 --ignore-not-found --wait=false >/dev/null 2>&1 || true
  if [ "${ESARCH_KIND_KEEP:-0}" != 1 ]; then kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "== 1. kind cluster, stand-ins, Envoy Gateway and the axon-trader Helm chart"
# shellcheck source=ci/kind/setup.sh
. ci/kind/setup.sh
ESARCH_KIND_GATEWAY=1 kind_setup
# Programmed stays False on kind (no LoadBalancer address), so wait for Accepted and the Envoy proxy pods instead.
k wait --for=condition=Accepted gateway/axon-trader --timeout=300s
k wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}'=True httproute/axon-trader --timeout=300s
kubectl --context "kind-$CLUSTER" -n envoy-gateway-system wait --for=condition=Available deploy \
  -l gateway.envoyproxy.io/owning-gateway-name=axon-trader --timeout=300s
k get gateway,httproute
helm --kube-context "kind-$CLUSTER" -n "$NS" list

envoy_svc=$(kubectl --context "kind-$CLUSTER" -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=axon-trader,gateway.envoyproxy.io/owning-gateway-namespace="$NS" \
  -o jsonpath='{.items[0].metadata.name}')
[ -n "$envoy_svc" ] || fail "no Envoy proxy Service for gateway/axon-trader"
# kubectl port-forward pins one pod and exits when that pod's container restarts, so keep re-establishing it.
forward() { while :; do kubectl --context "kind-$CLUSTER" -n "$1" port-forward "svc/$2" "$3" || true; sleep 1; done; }
forward "$NS" trader-app "$APP_PORT:8080" >"$LOGS/pf-app.log" 2>&1 & PIDS+=($!)
forward "$NS" trading-engine "$ENGINE_PORT:8080" >"$LOGS/pf-engine.log" 2>&1 & PIDS+=($!)
forward envoy-gateway-system "$envoy_svc" "$GATEWAY_PORT:80" >"$LOGS/pf-gateway.log" 2>&1 & PIDS+=($!)
forward "$NS" discovery-server "$EUREKA_PORT:8761" >"$LOGS/pf-eureka.log" 2>&1 & PIDS+=($!)
sleep 3
# Ready pods are not yet on every Axon routing ring: seeding before all four instances publish their command
# metadata (plus one registry fetch) loses the first AddOrderBookToCompanyCommand.
wait_registry "$(k get deploy trader-app trading-engine -o json | jq '[.items[].spec.replicas] | add')"
sleep 6

echo "== 2. Postman smoke collection, e2e script, trade and Gateway routing (ci/local/verify-local.sh)"
appURL=http://localhost:$APP_PORT engineURL=http://localhost:$ENGINE_PORT proxyURL=http://localhost:$GATEWAY_PORT \
  bash ci/local/verify-local.sh

echo "== 3. NetworkPolicies"
# probe <name> <app label|-> <host> <port>: curl from a throwaway pod carrying that label. Blocked means curl timed
# out (exit 28) without ever connecting (time_connect 0), i.e. the policy dropped the SYN; anything else (HTTP status,
# a protocol error from MySQL/AMQP, or a response timeout after the connect) means the TCP connection was accepted.
# Hosts are ClusterIPs so the result does not depend on DNS egress.
ip() { k get svc "$1" -o jsonpath='{.spec.clusterIP}'; }
probe() {
  local labels="esarch-probe=1"
  [ "$2" != - ] && labels="$labels,app.kubernetes.io/name=$2"
  k run "np-$1" --image=curlimages/curl:8.16.0 --image-pull-policy=IfNotPresent --restart=Never --labels="$labels" \
    --command -- sh -c "t=\$(curl -s -o /dev/null -w '%{time_connect}' --connect-timeout 5 -m 8 http://$3:$4/); echo rc=\$? connect=\$t" >/dev/null
  k wait --for=jsonpath='{.status.phase}'=Succeeded "pod/np-$1" --timeout=120s >/dev/null || true
  local out rc connect
  out=$(k logs "np-$1" | grep '^rc=' || true)
  rc=$(sed -n 's/^rc=\([0-9]*\).*/\1/p' <<<"$out"); connect=$(sed -n 's/.*connect=//p' <<<"$out")
  k delete pod "np-$1" --wait=false >/dev/null
  if [ "$rc" = 28 ] && [ "${connect:-0}" = 0.000000 ]; then echo blocked; else echo "open(rc=$rc)"; fi
}
status=0
src() { if [ "$1" = - ]; then echo 'unlabelled pod'; else echo "$1 pod"; fi; }
expect() { # want name label service port
  local got; got=$(probe "$2" "$3" "$(ip "$4")" "$5")
  if [ "${got%%(*}" = "$1" ]; then echo "OK   $2: $(src "$3") -> $4:$5 $got"
  else echo "FAIL $2: $(src "$3") -> $4:$5 $got (want $1)" >&2; status=1; fi
}
expect open   app-to-engine     trader-app     trading-engine   8080
expect open   engine-to-app     trading-engine trader-app       8080
expect open   app-to-eureka     trader-app     discovery-server 8761
expect open   engine-to-mysql   trading-engine mysql            3306
expect open   app-to-rabbitmq   trader-app     rabbitmq         5672
expect blocked other-to-engine  -              trading-engine   8080
expect blocked other-to-app     -              trader-app       8080
expect blocked other-to-eureka  -              discovery-server 8761
expect blocked other-to-mysql   -              mysql            3306
expect blocked other-to-rabbit  -              rabbitmq         5672
expect blocked ui-to-app        trader-ui      trader-app       8080
expect blocked ui-to-mysql      trader-ui      mysql            3306
expect blocked eureka-to-engine discovery-server trading-engine 8080
[ "$status" = 0 ] || fail "NetworkPolicy checks failed"
echo "PASS: chart installed on kind, smoke collection green, Gateway routing and NetworkPolicies as specified"
