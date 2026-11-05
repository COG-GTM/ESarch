#!/usr/bin/env bash
# End-to-end rehearsal of the s6.1 copy on this machine, with rehearsal/compose.yml standing in for TAS and Cloud SQL:
#   1. TAS-like source: both apps (jars, `local` profile, ddl-auto=update) on MySQL 5.7, seeded through the app's own
#      flow (data-initializer, then SEED_ROUNDS matched buy/sell pairs plus resting orders over the HTTP API).
#   2. GKE target: both apps with SPRING_PROFILES_ACTIVE=kubernetes on MySQL 8.0 (TLS) so Flyway applies V1, then
#      stopped, as the GKE deployments are scaled to 0 before the copy.
#   3. Freeze: stop the source apps once the AMQP `trades` queue is drained, then preflight.sh, copy.sh, verify.sh.
#   4. Start both apps on the copy (fresh RabbitMQ, as on GKE): Flyway up to date, Hibernate validate passes, the
#      query API returns the same users, portfolios, order books and transactions as on the source, and a new trade
#      executes on top of the copied event store.
# Build the jars first (JDK 8): ./mvnw -B -DskipTests package. Output and timings go to $OUT.
set -euo pipefail
cd "$(dirname "$0")/../.."
here=tools/migrate-data

JAVA=${JAVA:-${JAVA_HOME:+$JAVA_HOME/bin/}java}
OUT=${OUT:-target/migrate-data/rehearsal}
SEED_ROUNDS=${SEED_ROUNDS:-300}
APP_URL=http://localhost:8080
ENGINE_URL=http://localhost:8081
compose=(docker compose -f "$here/rehearsal/compose.yml")
rm -rf "$OUT"; mkdir -p "$OUT"
pids=()

# Connections used by preflight.sh / copy.sh / verify.sh (lib.sh): the TAS stand-in and the Cloud SQL stand-in.
export SRC_HOST=127.0.0.1 SRC_PORT=${REHEARSAL_SOURCE_PORT:-3316} SRC_USER=trader SRC_PASSWORD=${REHEARSAL_SOURCE_PASSWORD:-trader} SRC_SSL_MODE=DISABLED
export TGT_HOST=127.0.0.1 TGT_PORT=${REHEARSAL_TARGET_PORT:-3317} TGT_SSL_MODE=REQUIRED
export TGT_ENGINEDB_USER=trading-engine TGT_ENGINEDB_PASSWORD=${REHEARSAL_TARGET_ENGINE_PASSWORD:-trading-engine}
export TGT_APPDB_USER=trader-app TGT_APPDB_PASSWORD=${REHEARSAL_TARGET_APP_PASSWORD:-trader-app}
export DUMP_DIR=$OUT/dump

stop_apps() {
  [ ${#pids[@]} -gt 0 ] || return 0
  kill "${pids[@]}" 2>/dev/null || true; wait "${pids[@]}" 2>/dev/null || true; pids=()
}
cleanup() { stop_apps; if [ "${KEEP_STACK:-0}" != 1 ]; then "${compose[@]}" down -v >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT
step() { echo; echo "== $*"; }
now() { date +%s; }

wait_up() {
  for _ in $(seq 1 80); do
    if curl -sf "$1/actuator/health" | grep -q '"UP"'; then echo "$2 UP"; return; fi
    sleep 3
  done
  echo "$2 never became healthy; see $OUT/*.log" >&2; exit 1
}

start_source_app() { # app port
  SPRING_PROFILES_ACTIVE=local SERVER_PORT=$2 ESARCH_MYSQL_PORT=$SRC_PORT ESARCH_MYSQL_PASSWORD=$SRC_PASSWORD \
    ESARCH_RABBITMQ_PASSWORD=${REHEARSAL_RABBITMQ_PASSWORD:-trader} \
    "$JAVA" -jar "$1/target/$1.jar" >"$OUT/$1-source.log" 2>&1 &
  pids+=($!)
}

start_target_app() { # app db port user password run  (only the ConfigMap/Secret keys, as in the pod)
  env -i PATH="$PATH" SERVER_PORT="$3" SPRING_PROFILES_ACTIVE=kubernetes \
    SPRING_DATASOURCE_URL="jdbc:mysql://127.0.0.1:$TGT_PORT/$2?useSSL=true&requireSSL=true&enabledTLSProtocols=TLSv1.2&verifyServerCertificate=false" \
    "SPRING_DATASOURCE_USERNAME=$4" "SPRING_DATASOURCE_PASSWORD=$5" \
    SPRING_RABBITMQ_HOST=localhost SPRING_RABBITMQ_PORT=5672 SPRING_RABBITMQ_USERNAME=trader \
    "SPRING_RABBITMQ_PASSWORD=${REHEARSAL_RABBITMQ_PASSWORD:-trader}" SPRING_RABBITMQ_VIRTUAL_HOST=/ \
    EUREKA_DEFAULT_ZONE=http://localhost:8761/eureka/ \
    "$JAVA" -jar "$1/target/$1.jar" >"$OUT/$1-target-$6.log" 2>&1 &
  pids+=($!)
}

start_target_apps() {
  start_target_app trading-engine enginedb 8081 "$TGT_ENGINEDB_USER" "$TGT_ENGINEDB_PASSWORD" "$1"; wait_up "$ENGINE_URL" trading-engine
  start_target_app trader-app appdb 8080 "$TGT_APPDB_USER" "$TGT_APPDB_PASSWORD" "$1"; wait_up "$APP_URL" trader-app
}

trades_queue() { "${compose[@]}" exec -T rabbitmq rabbitmqctl -q list_queues name messages 2>/dev/null | awk '$1 == "trades" { print $2 }'; }
src_q() { mysql -h127.0.0.1 -P"$SRC_PORT" -u"$SRC_USER" --ssl-mode=DISABLED -N -B -e "$2" "$1" 2>/dev/null; }

# Wait until the source stops moving: trades queue empty and the same event counts twice in a row.
wait_settled() {
  local last="" cur
  for _ in $(seq 1 60); do
    cur="$(MYSQL_PWD=$SRC_PASSWORD src_q enginedb 'select count(*) from domain_event_entry') $(MYSQL_PWD=$SRC_PASSWORD src_q appdb 'select count(*) from domain_event_entry') q=$(trades_queue)"
    if [ "$cur" = "$last" ] && [[ "$cur" == *" q=0" ]]; then echo "settled: enginedb/appdb events and trades queue = $cur"; return; fi
    last=$cur; sleep 3
  done
  echo "source never settled ($cur)" >&2; exit 1
}

# What a user sees through the query API, normalised (sorted, ids of users/portfolios/order books kept because they
# must survive the copy unchanged).
api_snapshot() {
  local users companies
  users=$(curl -sf "$APP_URL/query/user")
  companies=$(curl -sf "$APP_URL/query/company")
  jq -S 'sort_by(.identifier)' <<<"$users" | jq -c '{users: .}'
  jq -S 'sort_by(.identifier)' <<<"$companies" | jq -c '{companies: .}'
  for cid in $(jq -r '.[].identifier' <<<"$companies" | sort); do
    curl -sf "$APP_URL/query/order-book/by-company/$cid" |
      jq -S -c --arg c "$cid" '{orderbooks: $c, books: [.[] | {identifier, buyOrders: (.buyOrders | sort_by(.identifier)), sellOrders: (.sellOrders | sort_by(.identifier))}]}'
  done
  for uid in $(jq -r '.[].identifier' <<<"$users" | sort); do
    local portfolio pid
    portfolio=$(curl -sf "$APP_URL/query/portfolio/by-user/$uid")
    pid=$(jq -r .identifier <<<"$portfolio")
    jq -S -c --arg u "$uid" '{portfolio: $u, value: .}' <<<"$portfolio"
    curl -sf "$APP_URL/query/transaction/by-portfolio/$pid" | jq -S -c --arg p "$pid" '{transactions: $p, value: sort_by(.identifier)}'
  done
}

order() { # command orderbook portfolio count price
  curl -sf -o /dev/null -H 'Content-Type: application/json' -X POST "$APP_URL/command/$1" \
    -d "{\"orderBookId\":\"$2\",\"portfolioId\":\"$3\",\"tradeCount\":$4,\"pricePerItem\":$5}"
}

step "0. Start the stand-ins (MySQL 5.7 source, MySQL 8.0 target, RabbitMQ) and Eureka"
"${compose[@]}" down -v >/dev/null 2>&1 || true
"${compose[@]}" up -d --wait
"$JAVA" -jar discovery-server/target/discovery-server-*.jar --eureka.client.register-with-eureka=false \
  --eureka.client.fetch-registry=false >"$OUT/discovery-server.log" 2>&1 &
discovery_pid=$!
trap 'kill $discovery_pid 2>/dev/null || true; cleanup' EXIT
for _ in $(seq 1 40); do curl -sf http://localhost:8761/actuator/health >/dev/null && break; sleep 3; done

step "1. TAS-like source: apps with the local profile (ddl-auto=update) on MySQL 5.7, seeded through the API"
start_source_app trading-engine 8081; wait_up "$ENGINE_URL" trading-engine
start_source_app trader-app 8080; wait_up "$APP_URL" trader-app
for _ in $(seq 1 30); do [ "$(curl -s -X POST "$APP_URL/actuator/data-initializer")" = true ] && break; sleep 5; done
echo "data-initializer: done"
sleep 10
users=$(curl -sf "$APP_URL/query/user")
companies=$(curl -sf "$APP_URL/query/company")
portfolio_of() { curl -sf "$APP_URL/query/portfolio/by-user/$(jq -r --arg u "$1" '.[] | select(.userName==$u) | .identifier' <<<"$users")" | jq -r .identifier; }
book_of() { curl -sf "$APP_URL/query/order-book/by-company/$(jq -r --arg c "$1" '.[] | select(.name==$c) | .identifier' <<<"$companies")" | jq -r '.[0].identifier'; }
declare -A pf
for u in allard steven ben pieter sampath haridu jakub kenny david; do pf[$u]=$(portfolio_of "$u"); done
pivotal=$(book_of Pivotal); axoniq=$(book_of AxonIQ); solstice=$(book_of Solstice)
sellers=(ben pieter jakub); buyers=(allard steven kenny david sampath haridu)
seed_start=$(now)
for i in $(seq 1 "$SEED_ROUNDS"); do
  s=${sellers[$((i % 3))]} b=${buyers[$((i % 6))]} n=$((1 + i % 3)) p=$((1 + i % 20))
  order StartSellTransactionCommand "$pivotal" "${pf[$s]}" "$n" "$p"
  order StartBuyTransactionCommand "$pivotal" "${pf[$b]}" "$n" "$p"
  if [ $((i % 5)) = 0 ]; then # some AxonIQ and Solstice trades too
    order StartSellTransactionCommand "$axoniq" "${pf[allard]}" 2 $((10 + i % 7))
    order StartBuyTransactionCommand "$axoniq" "${pf[kenny]}" 2 $((10 + i % 7))
    order StartSellTransactionCommand "$solstice" "${pf[haridu]}" 1 $((5 + i % 4))
    order StartBuyTransactionCommand "$solstice" "${pf[david]}" 1 $((5 + i % 4))
  fi
done
# Resting orders that never match, so the order books and reserved money/items are not empty.
order StartSellTransactionCommand "$pivotal" "${pf[ben]}" 4 900
order StartBuyTransactionCommand "$pivotal" "${pf[steven]}" 3 1
order StartSellTransactionCommand "$solstice" "${pf[sampath]}" 6 700
echo "seeded $SEED_ROUNDS rounds of buy/sell orders in $(( $(now) - seed_start ))s"
wait_settled
api_snapshot >"$OUT/api-source.jsonl"
echo "source query API: $(wc -l <"$OUT/api-source.jsonl") snapshot lines, $(grep -c '"EXECUTED"' "$OUT/api-source.jsonl" || true) portfolios/transactions lines with EXECUTED transactions"

step "2. GKE target: apps with the kubernetes profile once on the empty MySQL 8.0 (Flyway applies V1), then scaled to 0"
stop_apps
start_target_apps 1
grep -h "Successfully applied\|Migrating schema" "$OUT"/*-target-1.log | sed 's/^.*\] //' | sort -u
stop_apps

step "3. Freeze: source apps stopped (cf stop on TAS), trades queue drained"
freeze_start=$(now)
echo "trades queue at freeze: $(trades_queue) messages"
"$here/preflight.sh" | tee "$OUT/preflight.txt"
copy_start=$(now)
"$here/copy.sh" all | tee "$OUT/copy.txt"
copy_seconds=$(( $(now) - copy_start ))
verify_start=$(now)
"$here/verify.sh" | tee "$OUT/verify.txt"
verify_seconds=$(( $(now) - verify_start ))

step "4. Start the apps on the copy (fresh RabbitMQ, as on GKE)"
"${compose[@]}" up -d --force-recreate --wait rabbitmq
start_target_apps 2
up_seconds=$(( $(now) - freeze_start ))
grep -h "Schema .* is up to date\|Successfully baselined\|Successfully applied\|SchemaManagementException" "$OUT"/*-target-2.log | sed 's/^.*\] //' | sort -u
sleep 10
api_snapshot >"$OUT/api-target.jsonl"
if diff -u "$OUT/api-source.jsonl" "$OUT/api-target.jsonl" >"$OUT/api-diff.txt"; then
  echo "PASS: query API on the copy is identical to the source ($(wc -l <"$OUT/api-target.jsonl") lines: users, companies, order books, portfolios, transactions)"
else
  cat "$OUT/api-diff.txt"; echo "FAIL: query API differs between source and copy" >&2; exit 1
fi

step "5. New trade on the copy (event store keeps appending after the copied global_index / sequence numbers)"
tgt_q() { MYSQL_PWD=$TGT_ENGINEDB_PASSWORD mysql -h127.0.0.1 -P"$TGT_PORT" -u"$TGT_ENGINEDB_USER" --ssl-mode=REQUIRED -N -B -e "$1" enginedb 2>/dev/null; }
before_max=$(tgt_q 'select max(global_index) from domain_event_entry')
ben_before=$(curl -sf "$APP_URL/query/portfolio/by-user/$(jq -r '.[] | select(.userName=="ben") | .identifier' <<<"$users")" | jq -c '{amountOfMoney}')
allard_before=$(curl -sf "$APP_URL/query/portfolio/by-user/$(jq -r '.[] | select(.userName=="allard") | .identifier' <<<"$users")" | jq -c --arg ob "$pivotal" '{amountOfMoney, pivotal: (.itemsInPossession[$ob].amount // 0)}')
order StartSellTransactionCommand "$pivotal" "${pf[ben]}" 7 99
order StartBuyTransactionCommand "$pivotal" "${pf[allard]}" 7 99
expected=$(jq -c '{amountOfMoney: (.amountOfMoney - 693), pivotal: (.pivotal + 7)}' <<<"$allard_before")
for _ in $(seq 1 30); do
  allard_after=$(curl -sf "$APP_URL/query/portfolio/by-user/$(jq -r '.[] | select(.userName=="allard") | .identifier' <<<"$users")" | jq -c --arg ob "$pivotal" '{amountOfMoney, pivotal: (.itemsInPossession[$ob].amount // 0)}')
  [ "$allard_after" = "$expected" ] && break; sleep 1
done
after_max=$(tgt_q 'select max(global_index) from domain_event_entry')
echo "allard before $allard_before, after $allard_after (expected $expected); ben before $ben_before"
echo "enginedb max(global_index): $before_max after the copy, $after_max after the new trade"
if grep -l "Duplicate entry\|ConstraintViolation" "$OUT"/*-target-2.log; then echo "FAIL: duplicate keys after the copy" >&2; exit 1; fi
if [ "$allard_after" != "$expected" ] || [ "$after_max" -le "$before_max" ]; then echo "FAIL: new trade did not execute on the copy" >&2; exit 1; fi
echo "PASS: new trade executed on the copied event store"

step "Timings (seed rounds: $SEED_ROUNDS)"
column -t -s $'\t' "$DUMP_DIR/timings.tsv"
echo "copy.sh (dump + load, both databases): ${copy_seconds}s; verify.sh: ${verify_seconds}s"
echo "freeze start -> both apps healthy on the copy: ${up_seconds}s"
du -sh "$DUMP_DIR"/*.sql
