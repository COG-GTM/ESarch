#!/usr/bin/env bash
# s4.2 offline proof of the staging deploy logic (ci/deploy/helm-deploy.sh, the script .github/workflows/deploy.yml
# runs against GKE), on a local kind cluster with the MySQL/RabbitMQ stand-ins:
#   1. deploy the good images: helm upgrade --install + rollout wait + Postman smoke (newman) + e2e pass -> revision 1;
#   2. deploy a trader-app image that crash-loops (JVM rejects its options): the rollout never completes, so the script
#      rolls back to revision 1 and exits non-zero;
#   3. deploy a trader-ui image without index.html: the rollout succeeds (/healthz is fine) but the e2e UI check gets
#      404, so the script rolls back to the last good revision and exits non-zero;
#   4. check the release is back on the good images and the smoke + e2e pass again.
# trading-engine keeps one replica (decision d-engine-replicas). Build the images first (see verify-axon-routing.sh).
# Needs docker, kind, kubectl, helm, jq, node (npx newman) and uuidgen. ESARCH_KIND_KEEP=1 keeps the cluster.
# Never touches GCP or TAS.
set -euo pipefail
cd "$(dirname "$0")/../.."

CLUSTER=${ESARCH_KIND_CLUSTER:-esarch-deploy}
NS=axon-trader
LOGS=${ESARCH_LOGS:-/tmp/esarch-kind-deploy}
mkdir -p "$LOGS"
rm -rf "${LOGS:?}"/*
k() { kubectl --context "kind-$CLUSTER" -n "$NS" "$@"; }
cleanup() { if [ "${ESARCH_KIND_KEEP:-0}" != 1 ]; then kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export KUBE_CONTEXT=kind-$CLUSTER NS
deploy() { SMOKE_LOGS="$LOGS/$1" bash ci/deploy/helm-deploy.sh -f ci/kind/values-kind.yaml "${@:2}"; }
revision() { helm --kube-context "kind-$CLUSTER" -n "$NS" history axon-trader --max 1 -o json | jq -r '.[0] | "\(.revision) \(.status) \(.description)"'; }
image_of() { k get deploy "$1" -o jsonpath='{.spec.template.spec.containers[0].image}'; }

echo "== 0. deliberately broken images"
docker build -q -t esarch/trader-app:broken - >/dev/null <<'DOCKERFILE'
FROM esarch/trader-app:latest
ENTRYPOINT ["java", "-XX:+NoSuchJvmOption", "-version"]
DOCKERFILE
docker build -q -t esarch/trader-ui:broken - >/dev/null <<'DOCKERFILE'
FROM esarch/trader-ui:latest
USER root
RUN rm /usr/share/nginx/html/index.html
USER 101
DOCKERFILE
echo "built esarch/trader-app:broken (crash loop) and esarch/trader-ui:broken (no index.html)"
# shellcheck source=ci/kind/setup.sh
. ci/kind/setup.sh
KIND_IMAGES="$KIND_IMAGES esarch/trader-app:broken esarch/trader-ui:broken"
kind_cluster
kind_backing

echo
echo "== 1. good images: expect deploy + smoke + e2e to pass"
deploy good || fail "the good deploy failed"
good_app=$(image_of trader-app); good_ui=$(image_of trader-ui)
echo "release: $(revision)"

echo
echo "== 2. broken trader-app image (crash loop): expect rollout failure + automatic rollback"
status=0
ROLLOUT_TIMEOUT=240s deploy broken-app --set trader-app.image.tag=broken || status=$?
[ "$status" != 0 ] || fail "helm-deploy.sh exited 0 with a crash-looping trader-app"
echo "helm-deploy.sh exit status: $status (expected non-zero)"
rev=$(revision); echo "release: $rev"
grep -q 'Rollback to 1' <<<"$rev" || fail "expected the latest revision to be 'Rollback to 1', got: $rev"
[ "$(image_of trader-app)" = "$good_app" ] || fail "trader-app is on $(image_of trader-app), not $good_app"
k rollout status deploy/trader-app --timeout=60s

echo
echo "== 3. broken trader-ui image (no index.html): rollout passes, e2e fails, expect automatic rollback"
good_rev=$(revision | cut -d' ' -f1)
status=0
deploy broken-ui --set trader-ui.image.tag=broken || status=$?
[ "$status" != 0 ] || fail "helm-deploy.sh exited 0 with a trader-ui that answers 404 on /"
echo "helm-deploy.sh exit status: $status (expected non-zero)"
rev=$(revision); echo "release: $rev"
grep -q "Rollback to $good_rev" <<<"$rev" || fail "expected the latest revision to be 'Rollback to $good_rev', got: $rev"
[ "$(image_of trader-ui)" = "$good_ui" ] || fail "trader-ui is on $(image_of trader-ui), not $good_ui"

echo
echo "== 4. after the rollbacks: release history, images and smoke + e2e"
helm --kube-context "kind-$CLUSTER" -n "$NS" history axon-trader
k get deploy -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,REPLICAS:.spec.replicas,IMAGE:.spec.template.spec.containers[0].image
[ "$(k get deploy trading-engine -o jsonpath='{.spec.replicas}')" = 1 ] || fail "trading-engine is not at 1 replica"
SMOKE_LOGS="$LOGS/after-rollback" bash ci/deploy/smoke.sh || fail "smoke/e2e failed after the rollbacks"
echo "PASS: good deploy green; crash-looping and 404ing images both rolled back automatically; smoke + e2e green after"
