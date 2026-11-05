#!/usr/bin/env bash
# Promotes the exact images that passed staging into the production Artifact Registry, without rebuilding (s4.3):
# for each service, copies <SOURCE_REGISTRY>/<service>@<digest> (the whole index, attestations included) to
# <TARGET_REGISTRY>/<service>:<IMAGE_TAG> with `skopeo copy --all --preserve-digests`, which fails rather than rewrite
# a manifest, then checks the target tag serves that same digest. Re-running a promotion is a no-op.
#
# Env: SOURCE_REGISTRY, TARGET_REGISTRY  e.g. us-central1-docker.pkg.dev/<project>/axon-trader
#      IMAGE_TAG                         git SHA the images were published with
#      IMAGE_DIGESTS                     JSON {"<service>": "sha256:..."} (ci.yml publish output, deploy-staging artifact)
#      SOURCE_TOKEN, TARGET_TOKEN        optional OAuth access tokens (google-github-actions/auth token_format:
#                                        access_token); each registry gets its own throwaway auth file
#      REGISTRY_TLS_VERIFY               false for plain-HTTP local registries (ci/kind/verify-prod-promotion.sh)
#      SKOPEO_IMAGE                      pinned skopeo image (distro skopeo 1.13 has no --preserve-digests); runs on docker
# Prints "<service> <digest>" for every promoted image; ci/kind/verify-prod-promotion.sh proves it offline.
set -euo pipefail

SERVICES=${SERVICES:-"trading-engine trader-app discovery-server trader-ui"}
SKOPEO_IMAGE=${SKOPEO_IMAGE:-quay.io/skopeo/stable:v1.16.1@sha256:94f5c5e26997e2e78c234ec9abf19a391c234b39eb22e6d1210d0b527c97dcc8}
: "${SOURCE_REGISTRY:?SOURCE_REGISTRY is required}" "${TARGET_REGISTRY:?TARGET_REGISTRY is required}"
: "${IMAGE_TAG:?IMAGE_TAG is required}" "${IMAGE_DIGESTS:?IMAGE_DIGESTS is required}"
tls=${REGISTRY_TLS_VERIFY:-true}

auth=$(mktemp -d)
trap 'rm -rf "$auth"' EXIT
skopeo() { docker run --rm -i --network host -v "$auth:/auth" "$SKOPEO_IMAGE" "$@"; }
docker pull -q "$SKOPEO_IMAGE" >/dev/null
src_auth=() dst_auth=() dst_inspect_auth=()
if [ -n "${SOURCE_TOKEN:-}" ]; then
  skopeo login --tls-verify="$tls" --authfile /auth/source.json -u oauth2accesstoken --password-stdin "${SOURCE_REGISTRY%%/*}" <<<"$SOURCE_TOKEN" >/dev/null
  src_auth=(--src-authfile /auth/source.json)
fi
if [ -n "${TARGET_TOKEN:-}" ]; then
  skopeo login --tls-verify="$tls" --authfile /auth/target.json -u oauth2accesstoken --password-stdin "${TARGET_REGISTRY%%/*}" <<<"$TARGET_TOKEN" >/dev/null
  dst_auth=(--dest-authfile /auth/target.json)
  dst_inspect_auth=(--authfile /auth/target.json)
fi

for s in $SERVICES; do
  d=$(jq -r --arg s "$s" '.[$s] // empty' <<<"$IMAGE_DIGESTS")
  [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "FAIL: IMAGE_DIGESTS has no sha256 digest for $s" >&2; exit 1; }
  skopeo copy --src-tls-verify="$tls" --dest-tls-verify="$tls" "${src_auth[@]}" "${dst_auth[@]}" --all --preserve-digests --quiet \
    "docker://$SOURCE_REGISTRY/$s@$d" "docker://$TARGET_REGISTRY/$s:$IMAGE_TAG" </dev/null
  got=$(skopeo inspect --tls-verify="$tls" "${dst_inspect_auth[@]}" --raw "docker://$TARGET_REGISTRY/$s:$IMAGE_TAG" </dev/null | sha256sum | cut -d' ' -f1)
  [ "sha256:$got" = "$d" ] || { echo "FAIL: $TARGET_REGISTRY/$s:$IMAGE_TAG is sha256:$got, staging passed $d" >&2; exit 1; }
  echo "$s $d"
done
