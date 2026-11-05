# Sourced by verify-axon-routing.sh and verify-helm-smoke.sh (expects CLUSTER, NS, k and fail from the caller).
# kind_setup: kind cluster, local images, throwaway Secrets, the MySQL/RabbitMQ stand-ins (ci/kind/kustomization.yaml),
# then `helm upgrade --install` of deploy/helm/axon-trader with ci/kind/values-kind.yaml. With ESARCH_KIND_GATEWAY=1
# it also installs Envoy Gateway and renders the chart's Gateway + HTTPRoute (ci/kind/values-kind-gateway.yaml).
# ESARCH_HELM_ARGS adds extra helm flags (word-split), e.g. --set trading-engine.replicaCount=2.
# The passwords are generated per run and only ever live in the cluster. Never touches GCP or TAS.
ENVOY_GATEWAY_VERSION=${ENVOY_GATEWAY_VERSION:-v1.5.4}
KIND_IMAGES="esarch/discovery-server:latest esarch/trader-app:latest esarch/trading-engine:latest esarch/trader-ui:latest
  mysql:5.7 rabbitmq:3.7-management curlimages/curl:8.16.0"

kind_cluster() {
  echo "== kind cluster '$CLUSTER', images, namespace and throwaway secrets"
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --wait 120s
  local img
  for img in $KIND_IMAGES; do
    docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img"
    # Not `kind load docker-image`: its --all-platforms import fails on single-platform saves of multi-arch images.
    # Multi-arch images pulled for one platform can also miss layers in `docker save`; the node pulls those itself.
    if docker save "$img" | docker exec -i "$CLUSTER-control-plane" ctr --namespace=k8s.io images import \
      --digests --snapshotter=overlayfs - >/dev/null 2>&1; then
      echo "loaded $img"
    else
      docker exec "$CLUSTER-control-plane" crictl pull "$img" >/dev/null && echo "pulled $img on the node"
    fi
  done
  kubectl --context "kind-$CLUSTER" create namespace "$NS" --dry-run=client -o yaml | kubectl --context "kind-$CLUSTER" apply -f - >/dev/null
  local mysql_password rabbitmq_password app
  mysql_password=$(openssl rand -hex 16)
  rabbitmq_password=$(openssl rand -hex 16)
  k create secret generic backing-credentials --from-literal=MYSQL_ROOT_PASSWORD=$(openssl rand -hex 16) \
    --from-literal=MYSQL_PASSWORD=$mysql_password --from-literal=RABBITMQ_PASSWORD=$rabbitmq_password \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  # What the ExternalSecrets would sync on GKE (values-kind.yaml turns them off).
  for app in trader-app trading-engine; do
    k create secret generic "$app-secrets" --from-literal=SPRING_DATASOURCE_PASSWORD=$mysql_password \
      --from-literal=SPRING_RABBITMQ_PASSWORD=$rabbitmq_password --dry-run=client -o yaml | k apply -f - >/dev/null
  done
}

# kind_install: stand-ins and the chart, on a cluster with the namespace and Secrets in place.
kind_install() {
  local values=(-f ci/kind/values-kind.yaml)
  if [ "${ESARCH_KIND_GATEWAY:-0}" = 1 ]; then
    echo "== Envoy Gateway $ENVOY_GATEWAY_VERSION (Gateway API CRDs + controller) standing in for the GKE Gateway"
    helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version "$ENVOY_GATEWAY_VERSION" \
      --kube-context "kind-$CLUSTER" -n envoy-gateway-system --create-namespace --wait --timeout 10m >"${LOGS:-/tmp}/envoy-gateway-install.log" 2>&1 ||
      { cat "${LOGS:-/tmp}/envoy-gateway-install.log"; fail "Envoy Gateway install failed"; }
    kubectl --context "kind-$CLUSTER" apply -f - >/dev/null <<'YAML'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy-gateway
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
YAML
    values+=(-f ci/kind/values-kind-gateway.yaml)
  fi

  echo "== MySQL and RabbitMQ stand-ins"
  k apply -k ci/kind
  for d in mysql rabbitmq; do k rollout status "deploy/$d" --timeout=600s; done

  # shellcheck disable=SC2206
  values+=(${ESARCH_HELM_ARGS:-})
  echo "== helm upgrade --install axon-trader deploy/helm/axon-trader ${values[*]}"
  helm upgrade --install axon-trader deploy/helm/axon-trader --kube-context "kind-$CLUSTER" -n "$NS" "${values[@]}"
  for d in discovery-server trading-engine trader-app trader-ui; do k rollout status "deploy/$d" --timeout=900s; done
  k get pods -o wide
}

kind_setup() { kind_cluster; kind_install; }

# Eureka helpers (need EUREKA_URL, jq and fail()).
registry() {
  curl -sf -H 'Accept: application/json' "$EUREKA_URL/eureka/apps" | jq -r '
    .applications.application[] | .name as $n | .instance[] |
    "\($n) \(.instanceId) ip=\(.ipAddr):\(.port."$") status=\(.status) axon.loadFactor=\(.metadata.loadFactor // "-") axon.commandFilter=\(if .metadata.serializedCommandFilter then "yes" else "-" end)"' | sort
}
# Both apps publish their capabilities through Eureka metadata (Axon SpringCloudCommandRouter).
wait_registry() {
  local want=$1
  for _ in $(seq 1 60); do
    n=$(registry | grep -c 'axon.commandFilter=yes' || true)
    [ "$n" = "$want" ] && return 0
    sleep 2
  done
  registry; fail "expected $want instances with Axon metadata in Eureka, got $n"
}
