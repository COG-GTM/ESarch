#!/usr/bin/env bash
# s3.3 acceptance check for the Eureka replacement of the TAS Service Registry, on a local kind cluster:
#   1. deploy discovery-server (deploy/kubernetes/discovery-server) plus two replicas of trader-app and trading-engine
#      with SPRING_PROFILES_ACTIVE=kubernetes (ci/kind/), and show each pod's Axon capabilities in the Eureka registry;
#   2. place buy/sell orders through the trader-app Service and check every command is handled exactly once (one
#      "Handling command" log line across the trading-engine pods, one *TransactionStartedEvent in the event store),
#      by both engine replicas, with each aggregate always handled by the same pod (consistent hashing);
#   3. kill (SIGKILL, no deregistration) the trading-engine pod that handled the most commands, wait for Eureka to evict
#      it, place more orders and check they are all handled exactly once by the survivor, including aggregates that the
#      killed pod owned (orders sent before the eviction must be handled once if HTTP 200, not at all otherwise);
#      then wait for the replacement pod to join the ring and check again.
# Build the images first: mvn -B -DskipTests package jib:dockerBuild (esarch/<app>:latest). Needs docker, kind,
# kubectl and jq. ESARCH_KIND_KEEP=1 keeps the cluster afterwards. Never touches GCP or TAS.
set -euo pipefail
cd "$(dirname "$0")/../.."

CLUSTER=${ESARCH_KIND_CLUSTER:-esarch-routing}
NS=axon-trader
LOGS=${ESARCH_LOGS:-/tmp/esarch-kind-routing}
APP_PORT=${ESARCH_APP_PORT:-18080}
EUREKA_PORT=${ESARCH_EUREKA_PORT:-18761}
APP_URL=http://localhost:$APP_PORT
EUREKA_URL=http://localhost:$EUREKA_PORT
IMAGES="esarch/discovery-server:latest esarch/trader-app:latest esarch/trading-engine:latest mysql:5.7 rabbitmq:3.7-management"
mkdir -p "$LOGS"
rm -f "$LOGS"/*.log "$LOGS"/*.txt
k() { kubectl --context "kind-$CLUSTER" -n "$NS" "$@"; }
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && { kill "$p"; pkill -P "$p"; } 2>/dev/null || true; done
  if [ "${ESARCH_KIND_KEEP:-0}" != 1 ]; then kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "== 1. kind cluster '$CLUSTER', images, namespace and throwaway secrets"
kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --wait 120s
for img in $IMAGES; do
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
MYSQL_PASSWORD=$(openssl rand -hex 16)
RABBITMQ_PASSWORD=$(openssl rand -hex 16)
k create secret generic backing-credentials --from-literal=MYSQL_ROOT_PASSWORD="$(openssl rand -hex 16)" \
  --from-literal=MYSQL_PASSWORD="$MYSQL_PASSWORD" --from-literal=RABBITMQ_PASSWORD="$RABBITMQ_PASSWORD" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
for app in trader-app trading-engine; do
  k create secret generic "$app-secrets" --from-literal=SPRING_DATASOURCE_PASSWORD="$MYSQL_PASSWORD" \
    --from-literal=SPRING_RABBITMQ_PASSWORD="$RABBITMQ_PASSWORD" --dry-run=client -o yaml | k apply -f - >/dev/null
done

echo "== 2. Deploy discovery-server, MySQL, RabbitMQ, then 2x trading-engine and 2x trader-app (profile kubernetes)"
# Backing services and Eureka first, so the apps start against reachable dependencies. `notin` also selects objects
# without the label, so the generated ConfigMaps (mysql-initdb, *-config) are created in this first pass too.
k apply -k ci/kind -l 'app.kubernetes.io/name notin (trader-app,trading-engine)'
k get configmap mysql-initdb trader-app-config trading-engine-config >/dev/null || fail "generated ConfigMaps missing after the first apply"
for d in mysql rabbitmq discovery-server; do k rollout status "deploy/$d" --timeout=600s; done
k apply -k ci/kind
for d in trading-engine trader-app; do k rollout status "deploy/$d" --timeout=600s; done
k get pods -o wide

# kubectl port-forward pins one pod and exits when that pod's container restarts, so keep re-establishing it.
forward() { while :; do k port-forward "svc/$1" "$2" || true; sleep 1; done; }
forward discovery-server "$EUREKA_PORT:8761" >"$LOGS/pf-eureka.log" 2>&1 & PIDS+=($!)
forward trader-app "$APP_PORT:8080" >"$LOGS/pf-app.log" 2>&1 & PIDS+=($!)
sleep 3

registry() {
  curl -sf -H 'Accept: application/json' "$EUREKA_URL/eureka/apps" | jq -r '
    .applications.application[] | .name as $n | .instance[] |
    "\($n) \(.instanceId) ip=\(.ipAddr):\(.port."$") status=\(.status) axon.loadFactor=\(.metadata.loadFactor // "-") axon.commandFilter=\(if .metadata.serializedCommandFilter then "yes" else "-" end)"' | sort
}
lease_ts() {
  curl -sf -H 'Accept: application/json' "$EUREKA_URL/eureka/apps" |
    jq -r --arg ip "$1" '.applications.application[].instance[] | select(.ipAddr == $ip) | .leaseInfo.registrationTimestamp'
}
engine_pods() { k get pods -l app.kubernetes.io/name=trading-engine --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}={.status.podIP}{"\n"}{end}'; }
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
wait_registry 4
echo "Eureka registry:"; registry

echo "== 3. Seed demo data through trader-app (needs a trading-engine route: CommandRouter.findDestination)"
for _ in $(seq 1 30); do
  r=$(curl -s -X POST "$APP_URL/actuator/data-initializer" || true)
  [ "$r" = true ] && break
  sleep 5
done
[ "$r" = true ] || fail "data-initializer never reached trading-engine ($r)"
echo "data-initializer: $r"
sleep 10

users=$(curl -sf "$APP_URL/query/user")
company_id=$(curl -sf "$APP_URL/query/company" | jq -r '.[] | select(.name=="Pivotal") | .identifier')
order_book_id=$(curl -sf "$APP_URL/query/order-book/by-company/$company_id" | jq -r '.[0].identifier')
declare -A PORTFOLIO
for u in $(jq -r '.[].userName' <<<"$users"); do
  uid=$(jq -r --arg u "$u" '.[] | select(.userName==$u) | .identifier' <<<"$users")
  PORTFOLIO[$u]=$(curl -sf "$APP_URL/query/portfolio/by-user/$uid" | jq -r .identifier)
done
echo "order book $order_book_id, ${#PORTFOLIO[@]} portfolios"

mysql_q() { k exec deploy/mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "$1" enginedb 2>/dev/null' sh "$1"; }
# Includes the previous container, so the log of a killed JVM is still checked for replayed commands.
save_engine_logs() {
  for p in $(engine_pods | cut -d= -f1); do
    { k logs --previous "$p" 2>/dev/null || true; k logs "$p" 2>/dev/null || true; } >"$LOGS/$p.log"
  done
}

# order <phase> <Buy|Sell> <user> <count> <price>: posts Start<Type>TransactionCommand with our own transactionId.
order() {
  local tx; tx=$(uuidgen)
  code=$(curl -s -o "$LOGS/resp.txt" -w '%{http_code}' -H 'Content-Type: application/json' \
    -X POST "$APP_URL/command/Start$2TransactionCommand" \
    -d "{\"transactionId\":\"$tx\",\"orderBookId\":\"$order_book_id\",\"portfolioId\":\"${PORTFOLIO[$3]}\",\"tradeCount\":$4,\"pricePerItem\":$5}")
  echo "$1 $2 $3 $tx $code" >>"$LOGS/orders.txt"
}
place_orders() {
  local phase=$1 i
  for i in $(seq 1 "$2"); do
    order "$phase" Sell ben 1 $((10 + i % 5))
    order "$phase" Buy allard 1 $((10 + i % 5))
    order "$phase" Sell pieter 1 $((40 + i))
    order "$phase" Buy steven 1 $((1 + i % 3))
  done
  sleep 5
}

# check_at_most_once <phase>: orders sent while a route may point at a dead pod can fail, but none may be handled twice
# and every HTTP 200 must have been handled exactly once.
check_at_most_once() {
  local phase=$1 total=0 ok=0 failed=0
  save_engine_logs
  while read -r ph type user tx code; do
    [ "$ph" = "$phase" ] || continue
    total=$((total + 1))
    lines=$(cat "$LOGS"/trading-engine-*.log | grep -c "Handling command Start${type}TransactionCommand(transactionId=$tx," || true)
    events=$(mysql_q "select count(*) from domain_event_entry where aggregate_identifier='$tx' and payload_type like '%TransactionStartedEvent'")
    echo "$tx $type $user http=$code log_lines=$lines started_events=$events" >>"$LOGS/handled-$phase.txt"
    # HTTP 200 <=> handled once (one log line, one event); any other status <=> not handled at all (no log, no event).
    if [ "$code" = 200 ]; then
      [ "$lines" = 1 ] && [ "$events" = 1 ] || fail "[$phase] $tx got HTTP 200 but log_lines=$lines started_events=$events"
      ok=$((ok + 1))
    else
      [ "$lines" = 0 ] && [ "$events" = 0 ] || fail "[$phase] $tx got HTTP $code but log_lines=$lines started_events=$events"
      failed=$((failed + 1))
    fi
  done <"$LOGS/orders.txt"
  echo "[$phase] $total orders: $ok handled exactly once (HTTP 200), $failed rejected and not handled, 0 duplicates"
}

# check <phase> <expected engine pods...>: every order of the phase got HTTP 200, one handling log line and one
# TransactionStarted event; prints which pod handled it and that each aggregate stayed on one pod.
check() {
  local phase=$1; shift
  save_engine_logs
  local total=0 bad=0
  : >"$LOGS/handled-$phase.txt"
  while read -r ph type user tx code; do
    [ "$ph" = "$phase" ] || continue
    total=$((total + 1))
    handlers=$(grep -l "Handling command Start${type}TransactionCommand(transactionId=$tx," "$LOGS"/trading-engine-*.log 2>/dev/null | xargs -r -n1 basename | sed 's/\.log$//')
    lines=$(cat "$LOGS"/trading-engine-*.log | grep -c "Handling command Start${type}TransactionCommand(transactionId=$tx," || true)
    events=$(mysql_q "select count(*) from domain_event_entry where aggregate_identifier='$tx' and payload_type like '%TransactionStartedEvent'")
    echo "$tx $type $user http=$code ${handlers:-none} log_lines=$lines started_events=$events" >>"$LOGS/handled-$phase.txt"
    if [ "$code" != 200 ] || [ "$lines" != 1 ] || [ "$events" != 1 ]; then bad=$((bad + 1)); fi
  done <"$LOGS/orders.txt"
  echo "[$phase] $total orders: $((total - bad)) handled exactly once, $bad not"
  echo "[$phase] start-transaction commands per pod: $(awk '{print $5}' "$LOGS/handled-$phase.txt" | sort | uniq -c | awk '{printf "%s %s  ", $2, $1}')"
  [ "$bad" = 0 ] || { grep -v 'http=200 .* log_lines=1 started_events=1$' "$LOGS/handled-$phase.txt"; fail "[$phase] not exactly once"; }
  for pod in "$@"; do
    awk '{print $5}' "$LOGS/handled-$phase.txt" | grep -qx "$pod" || fail "[$phase] $pod handled no start-transaction command"
  done
}

# owners: for each aggregate id seen in "Handling command" lines, the set of pods that handled it.
owners() {
  for f in "$LOGS"/trading-engine-*.log; do
    p=$(basename "$f" .log)
    grep -o 'Handling command [A-Za-z]*(\(transactionId\|portfolioId\|orderBookId\)=[0-9a-f-]*' "$f" | sed 's/.*=//' | sort -u | sed "s/\$/ $p/"
  done | sort -u | awk '{o[$1]=o[$1] ? o[$1] "," $2 : $2} END {for (a in o) print a, o[a]}'
}

echo "== 4. Orders with two trading-engine replicas"
read -r -a ENGINES <<<"$(engine_pods | cut -d= -f1 | tr '\n' ' ')"
[ "${#ENGINES[@]}" = 2 ] || fail "expected 2 trading-engine pods"
place_orders before 10
check before "${ENGINES[@]}"
owners >"$LOGS/owners-before.txt"
split=$(awk '$2 ~ /,/' "$LOGS/owners-before.txt" | wc -l)
echo "aggregates handled: $(wc -l <"$LOGS/owners-before.txt"), handled by more than one pod: $split"
[ "$split" = 0 ] || fail "consistent hashing violated before the kill"
echo "sample of command handling across pods:"
for p in "${ENGINES[@]}"; do grep -m2 "Handling command" "$LOGS/$p.log" | sed "s/^/  $p: /" | cut -c1-220; done

echo "== 5. Kill the busiest trading-engine pod (SIGKILL, no Eureka deregistration)"
victim=$(awk '{print $5}' "$LOGS/handled-before.txt" | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')
for p in "${ENGINES[@]}"; do [ "$p" != "$victim" ] && survivor=$p; done
victim_ip=$(engine_pods | grep "^$victim=" | cut -d= -f2)
awk -v v="$victim" '$2 == v {print $1}' "$LOGS/owners-before.txt" >"$LOGS/victim-aggregates.txt"
echo "victim=$victim ($victim_ip) owned $(wc -l <"$LOGS/victim-aggregates.txt") aggregates; survivor=$survivor"
# SIGKILL the JVM from the node, as a crash or OOM kill would: no shutdown hook runs, so it never deregisters from
# Eureka and the lease has to expire. (`kubectl delete --force` still sends SIGTERM, which deregisters cleanly.)
# The kubelet would restart the container in place and the new JVM could re-register under the same instance id
# before the old lease expires, so scale to 1 at the same time and let the ReplicaSet delete the victim (lowest
# pod-deletion-cost); the replacement comes back in step 7.
victim_lease=$(lease_ts "$victim_ip")
k annotate pod "$victim" controller.kubernetes.io/pod-deletion-cost=-1000 --overwrite >/dev/null
cid=$(k get pod "$victim" -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|^containerd://||')
host_pid=$(docker exec "$CLUSTER-control-plane" crictl inspect --output go-template --template '{{.info.pid}}' "$cid")
t0=$(date +%s)
docker exec "$CLUSTER-control-plane" kill -9 "$host_pid"
echo "kill -9 $host_pid (java in $victim)"
# Watch Eureka from the moment of the kill: orders routed to the dead pod can block for the TCP connect timeout.
(
  while sleep 1; do
    apps=$(curl -sf -H 'Accept: application/json' "$EUREKA_URL/eureka/apps") || continue
    ts=$(jq -r --arg ip "$victim_ip" '.applications.application[].instance[] | select(.ipAddr == $ip) | .leaseInfo.registrationTimestamp' <<<"$apps")
    if [ -z "$ts" ]; then echo "evicted $(date +%s)" >"$LOGS/eviction.txt"; break; fi
    if [ "$ts" != "$victim_lease" ]; then echo "re-registered $ts" >"$LOGS/eviction.txt"; break; fi
  done
) & PIDS+=($!)
k scale deploy/trading-engine --replicas=1
sleep 2
[ -z "$(k get pod "$survivor" -o jsonpath='{.metadata.deletionTimestamp}')" ] || fail "scale-down picked $survivor"

echo "== 5a. Orders while Eureka still lists the dead pod: at most once, and HTTP 200 only if handled"
place_orders during-eviction 2
check_at_most_once during-eviction

for _ in $(seq 1 180); do [ -s "$LOGS/eviction.txt" ] && break; sleep 1; done
read -r outcome at <"$LOGS/eviction.txt" 2>/dev/null || fail "Eureka never evicted $victim"
[ "$outcome" = evicted ] || fail "$victim re-registered (lease $victim_lease -> $at) instead of expiring"
evicted_after=$((at - t0))
echo "Eureka evicted $victim after $evicted_after s (lease expiry, not a deregistration); registry now:"; registry
# A graceful deregistration would remove it within a couple of seconds; lease expiry takes >= 15 s.
[ "$evicted_after" -ge 10 ] || fail "$victim left Eureka after $evicted_after s: deregistered, not a crash"
sleep 6  # one registry fetch + Axon membership update on the trader-app and trading-engine side

echo "== 6. Orders with one trading-engine replica left (deployment scaled to 1)"
place_orders after-kill 10
check after-kill "$survivor"
grep -h "Handling command [A-Za-z]*(\(portfolioId\|orderBookId\)=" "$LOGS/$survivor.log" | sed 's/.*(\(portfolioId\|orderBookId\)=\([0-9a-f-]*\).*/\2/' | sort -u >"$LOGS/survivor-aggregates.txt"
moved=$(comm -12 <(sort "$LOGS/victim-aggregates.txt") "$LOGS/survivor-aggregates.txt" | wc -l)
echo "aggregates owned by $victim before the kill and handled by $survivor after it: $moved"
[ "$moved" -gt 0 ] || fail "no aggregate failed over from $victim to $survivor"

echo "== 7. Scale back to 2: a replacement pod joins the ring"
k scale deploy/trading-engine --replicas=2
k rollout status deploy/trading-engine --timeout=600s
wait_registry 4
registry
read -r -a ENGINES <<<"$(engine_pods | cut -d= -f1 | tr '\n' ' ')"
sleep 6
place_orders rejoined 10
check rejoined "${ENGINES[@]}"

echo "== 8. Whole event store: duplicates and totals"
dup_seq=$(mysql_q 'select count(*) from (select 1 from domain_event_entry group by aggregate_identifier, sequence_number having count(*) > 1) d')
dup_started=$(mysql_q "select count(*) from (select aggregate_identifier from domain_event_entry where payload_type like '%TransactionStartedEvent' group by aggregate_identifier having count(*) > 1) d")
echo "duplicate (aggregate, sequence) pairs: $dup_seq"
echo "TransactionStarted events per transaction > 1: $dup_started"
[ "$dup_seq" = 0 ] && [ "$dup_started" = 0 ] || fail "duplicate events in the event store"
mysql_q "select substring_index(payload_type, '.', -1), count(*) from domain_event_entry group by payload_type order by 1" | column -t
echo "orders posted: $(wc -l <"$LOGS/orders.txt"), HTTP 200: $(awk '$5 == 200' "$LOGS/orders.txt" | wc -l)"
echo "PASS: two replicas of each service, every buy/sell handled exactly once, routing survived killing $victim"
