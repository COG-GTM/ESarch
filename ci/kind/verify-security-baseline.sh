#!/usr/bin/env bash
# s5.4 security baseline for deploy/helm/axon-trader on kind (the GKE staging re-check is separate and still owed):
#   1. Pod Security Standard: the namespace enforces `restricted` (setup.sh, as infra/k8s/platform/namespace.yaml);
#      a server-side dry run reports no violating pod, a root pod is rejected, every container runs as a non-zero uid;
#   2. NetworkPolicies: blocked curls from throwaway pods (unlabelled, trader-ui, discovery-server, trader-app -> trader-ui)
#      next to the allowed s3.5 flows; egress to a policy-free target and the internet is reported (kind CNI);
#   3. credentials: the Secret values generated for this run appear nowhere in the Helm values, the rendered
#      manifests, ConfigMaps or pod specs (only secretKeyRef/envFrom), nor in the images' config;
#   4. actuator: through the Gateway nothing under /actuator or /api/actuator is served; in-cluster only
#      health/info/prometheus (+ data-initializer on trader-app) are exposed, env/beans/heapdump answer 404;
#   5. HTTPS-only (static): the staging/prod chart and the platform Gateway serve the app on HTTPS only, HTTP
#      listeners only 301 to HTTPS, HSTS is set and a TLS 1.2+ SSL policy is attached.
# Build the images first (see verify-axon-routing.sh). Needs docker, kind, kubectl, helm, kustomize and jq.
# ESARCH_KIND_KEEP=1 keeps the cluster afterwards. Never touches GCP or TAS.
set -euo pipefail
cd "$(dirname "$0")/../.."

CLUSTER=${ESARCH_KIND_CLUSTER:-esarch-sec}
NS=axon-trader
LOGS=${ESARCH_LOGS:-/tmp/esarch-kind-sec}
APP_PORT=${ESARCH_APP_PORT:-18080}
ENGINE_PORT=${ESARCH_ENGINE_PORT:-18081}
GATEWAY_PORT=${ESARCH_GATEWAY_PORT:-18088}
mkdir -p "$LOGS"
k() { kubectl --context "kind-$CLUSTER" -n "$NS" "$@"; }
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && { pkill -P "$p"; kill "$p"; } 2>/dev/null || true; done
  k delete pod -l esarch-probe=1 --ignore-not-found --wait=false >/dev/null 2>&1 || true
  if [ "${ESARCH_KIND_KEEP:-0}" != 1 ]; then kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
status=0
check() { if [ "$1" = ok ]; then echo "OK   $2"; else echo "FAIL $2" >&2; status=1; fi; }
APPS="discovery-server trading-engine trader-app trader-ui"

echo "== 0. kind cluster, stand-ins, Envoy Gateway and the axon-trader Helm chart"
# shellcheck source=ci/kind/setup.sh
. ci/kind/setup.sh
ESARCH_KIND_GATEWAY=1 kind_setup
k wait --for=condition=Accepted gateway/axon-trader --timeout=300s >/dev/null
kubectl --context "kind-$CLUSTER" -n envoy-gateway-system wait --for=condition=Available deploy \
  -l gateway.envoyproxy.io/owning-gateway-name=axon-trader --timeout=300s >/dev/null

echo "== 1. Pod Security Standard restricted"
kubectl --context "kind-$CLUSTER" get ns "$NS" -o json | jq -c '.metadata.labels | with_entries(select(.key | startswith("pod-security")))'
[ "$(kubectl --context "kind-$CLUSTER" get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')" = restricted ] &&
  check ok "namespace enforces restricted" || check fail "namespace does not enforce restricted"
warn=$(kubectl --context "kind-$CLUSTER" label --dry-run=server --overwrite ns "$NS" pod-security.kubernetes.io/enforce=restricted 2>&1 | grep -i warning || true)
[ -z "$warn" ] && check ok "dry-run enforce=restricted: no running pod violates it" || { echo "$warn"; check fail "pods violate restricted"; }
root_out=$(k run psa-root-probe --image=curlimages/curl:8.16.0 --restart=Never --overrides='{"spec":{"securityContext":{"runAsUser":0}}}' --command -- true 2>&1 || true)
k delete pod psa-root-probe --ignore-not-found --wait=false >/dev/null 2>&1
grep -q 'violates PodSecurity "restricted' <<<"$root_out" && check ok "root pod rejected: $(grep -o 'violates PodSecurity[^:]*' <<<"$root_out")" ||
  { echo "$root_out"; check fail "root pod was not rejected"; }
for d in $APPS mysql rabbitmq; do
  uid=$(k exec "deploy/$d" -c "$(k get deploy "$d" -o jsonpath='{.spec.template.spec.containers[0].name}')" -- id -u)
  [ "$uid" != 0 ] && check ok "$d runs as uid $uid" || check fail "$d runs as root"
done
k get pods -o json | jq -r '.items[] | .metadata.name as $p | .spec.containers[] |
  "\($p)/\(.name) runAsNonRoot=\(.securityContext.runAsNonRoot // "pod") readOnlyRootFilesystem=\(.securityContext.readOnlyRootFilesystem // false) caps.drop=\(.securityContext.capabilities.drop // [] | join(","))"' |
  grep -v '^np-'

echo "== 2. NetworkPolicies (blocked = no TCP connect within 5 s; open = TCP connected; refused/DNS errors fail)"
ip() { k get svc "$1" -o jsonpath='{.spec.clusterIP}'; }
expect() { # want name label host port
  local got; got=$(kind_probe "$2" "$3" "$4" "$5")
  [ "${got%%(*}" = "$1" ] && check ok "$2: ${3/#-/unlabelled} pod -> $4:$5 $got" || check fail "$2: ${3/#-/unlabelled} pod -> $4:$5 $got (want $1)"
}
expect open    app-to-engine     trader-app       "$(ip trading-engine)"   8080
expect open    app-to-rabbitmq   trader-app       "$(ip rabbitmq)"         5672
expect open    engine-to-mysql   trading-engine   "$(ip mysql)"            3306
expect blocked other-to-app      -                "$(ip trader-app)"       8080
expect blocked other-to-engine   -                "$(ip trading-engine)"   8080
expect blocked other-to-mysql    -                "$(ip mysql)"            3306
expect blocked other-to-ui       -                "$(ip trader-ui)"        8080
expect blocked ui-to-app         trader-ui        "$(ip trader-app)"       8080
expect blocked ui-to-rabbitmq    trader-ui        "$(ip rabbitmq)"         5672
expect blocked eureka-to-engine  discovery-server "$(ip trading-engine)"   8080
expect blocked app-to-ui         trader-app       "$(ip trader-ui)"        8080
# Egress allow-list: a target pod in a namespace without NetworkPolicies, and an internet address. kindnet
# (kube-network-policies) enforces the ingress rules above but on some hosts lets egress through, so these are
# reported, not gated; the egress deny has to be shown on GKE Dataplane V2 (live staging re-check).
kubectl --context "kind-$CLUSTER" create namespace np-egress-target --dry-run=client -o yaml | kubectl --context "kind-$CLUSTER" apply -f - >/dev/null
kubectl --context "kind-$CLUSTER" -n np-egress-target run egress-target --image=esarch/trader-ui:latest --image-pull-policy=Never \
  --port=8080 --dry-run=client -o json |
  jq '.spec.securityContext = {runAsNonRoot: true, runAsUser: 101, seccompProfile: {type: "RuntimeDefault"}}
    | .spec.containers[0].securityContext = {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
    | .spec.containers[0].readinessProbe = {tcpSocket: {port: 8080}, periodSeconds: 2}' |
  kubectl --context "kind-$CLUSTER" apply -f - >/dev/null
kubectl --context "kind-$CLUSTER" -n np-egress-target wait --for=condition=Ready pod/egress-target --timeout=120s >/dev/null
# Pod IP, not the ClusterIP: right after Ready, kube-proxy may still REJECT the endpoint-less Service (curl exit 7).
target=$(kubectl --context "kind-$CLUSTER" -n np-egress-target get pod egress-target -o jsonpath='{.status.podIP}')
expect open    other-to-target   -                "$target"                8080
for a in trader-app trading-engine discovery-server trader-ui; do
  echo "INFO $a pod -> egress-target:8080 $(kind_probe "$a-tgt" "$a" "$target" 8080) (want blocked; kind CNI egress, re-check on GKE)"
done
for a in trader-app trader-ui; do
  echo "INFO $a pod -> 1.1.1.1:80 $(kind_probe "$a-net" "$a" 1.1.1.1 80) (want blocked; kind CNI egress, re-check on GKE)"
done
kubectl --context "kind-$CLUSTER" delete namespace np-egress-target --wait=false >/dev/null

echo "== 3. No credentials in Helm values, manifests, ConfigMaps, pod specs or images"
secrets=$(k get secret backing-credentials trader-app-secrets trading-engine-secrets -o json | jq -r '.items[].data[] | @base64d' | sort -u)
leak() { local f=$1 s; while read -r s; do [ -n "$s" ] && grep -qF "$s" "$f" && return 0; done <<<"$secrets"; return 1; }
helm --kube-context "kind-$CLUSTER" -n "$NS" get values axon-trader --all -o yaml >"$LOGS/values.yaml"
helm --kube-context "kind-$CLUSTER" -n "$NS" get manifest axon-trader >"$LOGS/manifest.yaml"
k get configmap,deploy -o yaml >"$LOGS/objects.yaml"
for f in values.yaml manifest.yaml objects.yaml; do
  leak "$LOGS/$f" && check fail "a generated credential appears in $f" || check ok "no credential in $f ($(wc -l <"$LOGS/$f") lines)"
done
literal=$(k get deploy -o json | jq -r '.items[] | .metadata.name as $d | .spec.template.spec.containers[].env[]? |
  select((.name | test("PASS|SECRET|TOKEN|KEY|CREDENTIAL"; "i")) and has("value")) | "\($d) \(.name)"')
[ -z "$literal" ] && check ok "credential-like env vars only come from secretKeyRef/envFrom" || check fail "literal credential env: $literal"
for app in $APPS; do
  docker image inspect "esarch/$app:latest" --format '{{json .Config.Env}} {{json .Config.Labels}}' >"$LOGS/image-$app.json"
  grep -qiE 'password|secret|token|apikey' "$LOGS/image-$app.json" && check fail "esarch/$app image config mentions a credential" ||
    check ok "esarch/$app image env/labels hold no credential"
done

echo "== 4. Actuator exposure"
envoy_svc=$(kubectl --context "kind-$CLUSTER" -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=axon-trader,gateway.envoyproxy.io/owning-gateway-namespace="$NS" \
  -o jsonpath='{.items[0].metadata.name}')
kubectl --context "kind-$CLUSTER" -n envoy-gateway-system port-forward "svc/$envoy_svc" "$GATEWAY_PORT:80" >"$LOGS/pf-gateway.log" 2>&1 & PIDS+=($!)
k port-forward svc/trader-app "$APP_PORT:8080" >"$LOGS/pf-app.log" 2>&1 & PIDS+=($!)
k port-forward svc/trading-engine "$ENGINE_PORT:8080" >"$LOGS/pf-engine.log" 2>&1 & PIDS+=($!)
sleep 4
code() { curl -s -o "$LOGS/body" -w '%{http_code}' -m 10 "$@"; }
for path in /actuator/env /actuator/health /api/actuator/env /api/actuator/health /api/actuator/heapdump \
  /api/command/../actuator/env /api/query/..%2factuator/env /api/command/actuator/env; do
  c=$(code --path-as-is "http://localhost:$GATEWAY_PORT$path")
  # trader-ui answers unknown paths with the SPA index (200 text/html) and /api/* with 404; neither is actuator JSON.
  grep -q '"propertySources"\|"_links"\|"status":"UP"' "$LOGS/body" && check fail "Gateway $path -> $c serves actuator" ||
    check ok "Gateway $path -> $c (not actuator)"
done
for t in "trader-app $APP_PORT health:200 info:200 prometheus:200 env:404 beans:404 heapdump:404 configprops:404 loggers:404 mappings:404" \
  "trading-engine $ENGINE_PORT health:200 info:200 prometheus:200 env:404 beans:404 heapdump:404 configprops:404 loggers:404 mappings:404"; do
  set -- $t; app=$1 port=$2; shift 2
  exposed=$(curl -s -m 10 "http://localhost:$port/actuator" | jq -r '._links | keys | map(select(. != "self")) | join(",")')
  echo "     $app (in-cluster) /actuator links: $exposed"
  for e in "$@"; do
    c=$(code "http://localhost:$port/actuator/${e%%:*}")
    [ "$c" = "${e##*:}" ] && check ok "$app in-cluster /actuator/${e%%:*} -> $c" || check fail "$app in-cluster /actuator/${e%%:*} -> $c (want ${e##*:})"
  done
done

echo "== 5. HTTPS-only (rendered staging/prod chart and platform Gateway)"
H=deploy/helm/axon-trader
for env in staging prod; do
  out=$(helm template axon-trader "$H" -f "$H/values-$env.yaml")
  routes=$(grep -A3 'parentRefs:' <<<"$out")
  grep -q 'sectionName: https$' <<<"$routes" && ! grep -q 'sectionName: http$' <<<"$routes" &&
    check ok "$env: app HTTPRoute attaches to the https listener only" || check fail "$env: app HTTPRoute not HTTPS-only"
  grep -q 'name: Strict-Transport-Security' <<<"$out" && check ok "$env: HSTS set on routed responses" || check fail "$env: no HSTS"
  out=$(helm template axon-trader "$H" -f "$H/values-$env.yaml" --set gateway.create=true)
  grep -q 'axon-trader-http-to-https' <<<"$out" && grep -q 'statusCode: 301' <<<"$out" &&
    check ok "$env: chart-owned Gateway redirects its HTTP listener (301)" || check fail "$env: chart-owned Gateway serves plain HTTP"
done
plat=$(kustomize build infra/k8s/platform)
grep -q 'sectionName: http$' <<<"$plat" && grep -q 'statusCode: 301' <<<"$plat" && check ok "platform Gateway: HTTP listener only 301s to HTTPS" ||
  check fail "platform Gateway: no HTTP->HTTPS redirect"
grep -q 'kind: GCPGatewayPolicy' <<<"$plat" && grep -q 'sslPolicy:' <<<"$plat" && check ok "platform Gateway: SSL policy attached (Terraform: MODERN, TLS 1.2+)" ||
  check fail "platform Gateway: no SSL policy"

[ "$status" = 0 ] || fail "security baseline checks failed"
echo "PASS: restricted PSS, NetworkPolicy denials, no credentials, actuator internal-only, HTTPS-only Gateway config"
