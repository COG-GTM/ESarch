#!/usr/bin/env bash
# s4.3 offline proof of the production promotion (.github/workflows/deploy-prod.yml) on kind, with two local registries
# standing in for the staging and production Artifact Registries. The cluster can only pull from the "prod" one, and
# values-prod.yaml (plus the kind stand-ins of values-kind.yaml) is what gets deployed:
#   1. publish the CI images to the staging registry and promote that release with ci/deploy/promote-images.sh: same
#      digests in prod, no rebuild; deploy them with ci/deploy/helm-deploy.sh (rollout + smoke + e2e) and check every
#      pod runs exactly the staging digest, trading-engine at one replica (d-engine-replicas);
#   2. promote a release whose trader-app crash-loops: the rollout fails and helm rolls back to release 1 automatically;
#   3. promote a second good release, then follow the manual rollback of docs/deploy-gke.md: find the previous digests
#      in the helm history, `helm rollback` to that revision and re-run the smoke + e2e.
# Build the images first (see verify-axon-routing.sh). Needs docker, kind, kubectl, helm, jq, node (npx newman)
# and uuidgen. ESARCH_KIND_KEEP=1 keeps the cluster and registries. Never touches GCP or TAS.
set -euo pipefail
cd "$(dirname "$0")/../.."

CLUSTER=${ESARCH_KIND_CLUSTER:-esarch-prod}
NS=axon-trader
LOGS=${ESARCH_LOGS:-/tmp/esarch-kind-prod}
STAGING_REGISTRY=localhost:5001
PROD_REGISTRY=localhost:5002
SERVICES="trading-engine trader-app discovery-server trader-ui"
mkdir -p "$LOGS"
rm -rf "${LOGS:?}"/*
k() { kubectl --context "kind-$CLUSTER" -n "$NS" "$@"; }
hm() { helm --kube-context "kind-$CLUSTER" -n "$NS" "$@"; }
cleanup() {
  if [ "${ESARCH_KIND_KEEP:-0}" != 1 ]; then
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
    docker rm -f esarch-staging-registry esarch-prod-registry >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export KUBE_CONTEXT=kind-$CLUSTER NS
revision() { hm history axon-trader --max 1 -o json | jq -r '.[0] | "\(.revision) \(.status) \(.description)"'; }
image_of() { k get deploy "$1" -o jsonpath='{.spec.template.spec.containers[0].image}'; }

echo "== 0. staging + prod registries, release images"
for r in staging:5001 prod:5002; do
  docker rm -f "esarch-${r%:*}-registry" >/dev/null 2>&1 || true
  docker run -d --name "esarch-${r%:*}-registry" -p "127.0.0.1:${r#*:}:5000" registry:2 >/dev/null
done
# The two local registries speak plain HTTP (Artifact Registry is HTTPS + an OAuth token in CI).
export REGISTRY_TLS_VERIFY=false
docker build -q -t esarch/trader-app:broken - >/dev/null <<'DOCKERFILE'
FROM esarch/trader-app:latest
ENTRYPOINT ["java", "-XX:+NoSuchJvmOption", "-version"]
DOCKERFILE
# Release 2: a real new trader-ui image (new digest), otherwise identical.
docker build -q -t esarch/trader-ui:release2 - >/dev/null <<'DOCKERFILE'
FROM esarch/trader-ui:latest
LABEL org.opencontainers.image.version=release2
DOCKERFILE

# What ci.yml's publish job does: push <service>:<sha> to the staging registry, emit {"<service>": "sha256:..."}.
publish() {
  local tag=$1 digests='{}' s src target digest
  shift
  for s in $SERVICES; do
    src="esarch/$s:latest"
    for o in "$@"; do [ "${o%%=*}" = "$s" ] && src=${o#*=}; done
    target="$STAGING_REGISTRY/$s:$tag"
    docker tag "$src" "$target"
    docker push -q "$target" >/dev/null
    digest=$(docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$target" | grep -F "$STAGING_REGISTRY/$s@" | head -1)
    digests=$(jq -c --arg s "$s" --arg d "${digest#*@}" '. + {($s): $d}' <<<"$digests")
  done
  echo "$digests"
}
TAG1=$(git rev-parse HEAD)
TAG2=$(printf '%040d' 2)
TAG_BROKEN=$(printf '%040d' 9)
REL1=$(publish "$TAG1")
REL_BROKEN=$(publish "$TAG_BROKEN" trader-app=esarch/trader-app:broken)
REL2=$(publish "$TAG2" trader-ui=esarch/trader-ui:release2)
echo "release 1 ($TAG1): $REL1"
echo "release broken: $REL_BROKEN"
echo "release 2: $REL2"

echo
echo "== kind cluster pulling from the prod registry only"
cat >"$LOGS/kind.yaml" <<'KIND'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
KIND
# shellcheck source=ci/kind/setup.sh
. ci/kind/setup.sh
KIND_CONFIG=$LOGS/kind.yaml
KIND_IMAGES="mysql:5.7 rabbitmq:3.7-management curlimages/curl:8.16.0"
kind_cluster
docker network connect kind esarch-prod-registry 2>/dev/null || true
docker exec "$CLUSTER-control-plane" mkdir -p "/etc/containerd/certs.d/$PROD_REGISTRY"
printf '[host."http://esarch-prod-registry:5000"]\n' | docker exec -i "$CLUSTER-control-plane" tee "/etc/containerd/certs.d/$PROD_REGISTRY/hosts.toml" >/dev/null
for s in $SERVICES; do docker exec "$CLUSTER-control-plane" crictl rmi "esarch/$s:latest" >/dev/null 2>&1 || true; done
# values-prod.yaml expects the platform (Terraform foundation) to own the Workload Identity KSAs.
for s in trading-engine trader-app; do k create serviceaccount "$s" --dry-run=client -o yaml | k apply -f - >/dev/null; done
kind_backing

# deploy-prod.yml's promote job: promote-images.sh, then helm-deploy.sh with values-prod.yaml.
promote_and_deploy() {
  local name=$1 tag=$2 digests=$3
  shift 3
  echo "-- promote $tag"
  SOURCE_REGISTRY=$STAGING_REGISTRY TARGET_REGISTRY=$PROD_REGISTRY IMAGE_TAG=$tag IMAGE_DIGESTS=$digests \
    bash ci/deploy/promote-images.sh >"$LOGS/promote-$name.txt" || { cat "$LOGS/promote-$name.txt"; return 1; }
  cat "$LOGS/promote-$name.txt"
  echo "-- deploy $tag"
  SMOKE_LOGS="$LOGS/$name" IMAGE_REGISTRY=$PROD_REGISTRY IMAGE_TAG=$tag IMAGE_DIGESTS=$digests \
    bash ci/deploy/helm-deploy.sh -f deploy/helm/axon-trader/values-prod.yaml -f ci/kind/values-kind.yaml "$@"
}
# Every Deployment spec and every running pod is on <prod registry>/<service>@<the staging digest>.
expect_release() {
  local digests=$1 s d ids
  for s in $SERVICES; do
    d=$(jq -r --arg s "$s" '.[$s]' <<<"$digests")
    [ "$(image_of "$s")" = "$PROD_REGISTRY/$s@$d" ] || fail "$s spec image is $(image_of "$s"), expected $PROD_REGISTRY/$s@$d"
    ids=$(k get pods -l "app.kubernetes.io/name=$s" -o jsonpath='{range .items[*]}{.status.containerStatuses[0].imageID}{"\n"}{end}' | sort -u)
    [ "$ids" = "$PROD_REGISTRY/$s@$d" ] || fail "$s pods run '$ids', expected $PROD_REGISTRY/$s@$d"
    echo "$s: spec + pods on $PROD_REGISTRY/$s@$d"
  done
}

echo
echo "== 1. promote release 1 (staging digests, no rebuild) and deploy with values-prod.yaml"
promote_and_deploy rel1 "$TAG1" "$REL1" || fail "the release 1 promotion failed"
for s in $SERVICES; do
  got=$(docker run --rm --network host quay.io/skopeo/stable:v1.16.1 inspect --tls-verify=false --raw "docker://$PROD_REGISTRY/$s:$TAG1" | sha256sum | cut -d' ' -f1)
  [ "sha256:$got" = "$(jq -r --arg s "$s" '.[$s]' <<<"$REL1")" ] || fail "prod registry $s:$TAG1 is sha256:$got"
done
echo "prod registry serves the staging digests under $TAG1"
expect_release "$REL1"
[ "$(k get deploy trading-engine -o jsonpath='{.spec.replicas}')" = 1 ] || fail "trading-engine is not at 1 replica"
k get hpa
echo "release: $(revision)"

echo
echo "== 2. promote a release whose trader-app crash-loops: expect rollout failure + automatic rollback to release 1"
status=0
ROLLOUT_TIMEOUT=240s promote_and_deploy broken "$TAG_BROKEN" "$REL_BROKEN" || status=$?
[ "$status" != 0 ] || fail "the broken promotion exited 0"
echo "exit status: $status (expected non-zero)"
rev=$(revision); echo "release: $rev"
grep -q 'Rollback to 1' <<<"$rev" || fail "expected the latest revision to be 'Rollback to 1', got: $rev"
k rollout status deploy/trader-app --timeout=300s
expect_release "$REL1"

echo
echo "== 3. promote release 2, then the manual rollback of docs/deploy-gke.md back to release 1"
promote_and_deploy rel2 "$TAG2" "$REL2" || fail "the release 2 promotion failed"
expect_release "$REL2"
hm history axon-trader
# docs/deploy-gke.md: the last deployed revision before the current one, and the digests it ran.
previous=$(hm history axon-trader -o json | jq -r '[.[] | select(.status == "superseded")] | last | .revision')
prev_digests=$(hm get values axon-trader --revision "$previous" -o json |
  jq -c '{"trading-engine", "trader-app", "discovery-server", "trader-ui"} | map_values(.image.digest)')
echo "previous revision $previous ran: $prev_digests"
[ "$prev_digests" = "$(jq -c '{"trading-engine", "trader-app", "discovery-server", "trader-ui"}' <<<"$REL1")" ] ||
  fail "helm history says revision $previous ran $prev_digests, not release 1"
hm rollback axon-trader "$previous" --wait --timeout 600s
for d in discovery-server trading-engine trader-app trader-ui; do k rollout status "deploy/$d" --timeout=600s; done
expect_release "$REL1"
SMOKE_LOGS="$LOGS/after-manual-rollback" bash ci/deploy/smoke.sh || fail "smoke/e2e failed after the manual rollback"

echo
hm history axon-trader
k get deploy -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,REPLICAS:.spec.replicas,IMAGE:.spec.template.spec.containers[0].image
[ "$(k get deploy trading-engine -o jsonpath='{.spec.replicas}')" = 1 ] || fail "trading-engine is not at 1 replica"
echo "PASS: staging digests promoted without rebuild and deployed with values-prod.yaml (smoke + e2e green); crash-looping release rolled back automatically; manual helm rollback to the previous digests green"
