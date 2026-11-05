#!/usr/bin/env bash
# Acceptance check for the `kubernetes` Spring profile against the docker-compose stack (MySQL, RabbitMQ, Eureka):
#   1. start both apps with SPRING_PROFILES_ACTIVE=kubernetes and *only* the env vars the ConfigMap and the
#      ExternalSecret provide (env -i, no other configuration);
#   2. check Flyway applied V1, Hibernate validated the schema, /actuator/health is UP and /actuator/prometheus scrapes;
#   3. seed the demo data, place orders, restart both apps and check orders, portfolios and the event store are unchanged.
# Build the jars and images first (mvn -B -DskipTests package jib:dockerBuild). ESARCH_RESET=1 wipes the compose volumes
# first (fresh databases). ESARCH_RUNTIME=image runs the Jib images (esarch/<app>:${ESARCH_IMAGE_TAG:-latest}) on the
# Compose network instead of the jars, listening on 8080 inside the container as in the pod (host ports 8080/8081).
set -euo pipefail
cd "$(dirname "$0")/../.."

JAVA=${JAVA:-${JAVA_HOME:+$JAVA_HOME/bin/}java}
APP_URL=http://localhost:8080
ENGINE_URL=http://localhost:8081
LOGS=${LOGS:-target/verify-kubernetes}
MYSQL_USER=${ESARCH_MYSQL_USER:-trader}
MYSQL_PASSWORD=${ESARCH_MYSQL_PASSWORD:-trader}
RABBITMQ_USER=${ESARCH_RABBITMQ_USER:-trader}
RABBITMQ_PASSWORD=${ESARCH_RABBITMQ_PASSWORD:-trader}
mkdir -p "$LOGS"
RUNTIME=${ESARCH_RUNTIME:-jar}
IMAGE_TAG=${ESARCH_IMAGE_TAG:-latest}
pids=()

cleanup() {
  if [ "$RUNTIME" = image ]; then docker rm -f esarch-k8s-trading-engine esarch-k8s-trader-app >/dev/null 2>&1 || true; fi
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done; wait 2>/dev/null || true
}
trap cleanup EXIT

if [ "${ESARCH_RESET:-0}" = 1 ]; then docker compose down -v; fi
docker compose up -d --wait
NETWORK=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$(docker compose ps -q mysql)")

mysql_q() { docker compose exec -T mysql mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -N -B -e "$2" "$1" 2>/dev/null; }

# Exactly what the Deployment gets: ConfigMap keys + ExternalSecret keys (deploy/kubernetes/<app>/), nothing else.
app_env() {
  local db=$1 db_host=$2 rabbit_host=$3 eureka=$4
  echo "SPRING_PROFILES_ACTIVE=kubernetes"
  echo "SPRING_DATASOURCE_URL=jdbc:mysql://$db_host:3306/$db?useSSL=false&allowPublicKeyRetrieval=true"
  echo "SPRING_DATASOURCE_USERNAME=$MYSQL_USER"
  echo "SPRING_DATASOURCE_PASSWORD=$MYSQL_PASSWORD"
  echo "SPRING_RABBITMQ_HOST=$rabbit_host"
  echo "SPRING_RABBITMQ_PORT=5672"
  echo "SPRING_RABBITMQ_USERNAME=$RABBITMQ_USER"
  echo "SPRING_RABBITMQ_PASSWORD=$RABBITMQ_PASSWORD"
  echo "SPRING_RABBITMQ_VIRTUAL_HOST=/"
  echo "EUREKA_DEFAULT_ZONE=$eureka"
}

start() {
  local app=$1 db=$2 port=$3 run=$4
  if [ "$RUNTIME" = image ]; then
    # Only the image's own environment (JAVA_TOOL_OPTIONS) plus the ConfigMap/Secret keys; server.port stays 8080.
    docker run -d --name "esarch-k8s-$app" --network "$NETWORK" -p "127.0.0.1:$port:8080" --memory 1g \
      --env-file <(app_env "$db" mysql rabbitmq http://discovery-server:8761/eureka/) \
      "${ESARCH_IMAGE_REGISTRY:-esarch}/$app:$IMAGE_TAG" >/dev/null
    docker logs -f "esarch-k8s-$app" >"$LOGS/$app-$run.log" 2>&1 &
  else
    # shellcheck disable=SC2046
    env -i PATH="$PATH" SERVER_PORT="$port" $(app_env "$db" localhost localhost http://localhost:8761/eureka/) \
      "$JAVA" -jar "$app/target/$app.jar" >"$LOGS/$app-$run.log" 2>&1 &
  fi
  pids+=($!)
}

wait_up() {
  local url=$1 name=$2
  for _ in $(seq 1 60); do
    if curl -sf "$url/actuator/health" | grep -q '"UP"'; then echo "$name: $(curl -s "$url/actuator/health")"; return; fi
    sleep 3
  done
  echo "$name never became healthy; see $LOGS" >&2; exit 1
}

start_both() {
  start trading-engine enginedb 8081 "$1"; wait_up "$ENGINE_URL" trading-engine
  start trader-app appdb 8080 "$1"; wait_up "$APP_URL" trader-app
}

stop_both() { cleanup; pids=(); }

snapshot() {
  local users companies company_id order_book_id
  users=$(curl -sf "$APP_URL/query/user")
  companies=$(curl -sf "$APP_URL/query/company")
  company_id=$(jq -r '.[] | select(.name=="Pivotal") | .identifier' <<<"$companies")
  order_book_id=$(curl -sf "$APP_URL/query/order-book/by-company/$company_id" | jq -r '.[0].identifier')
  echo "users=$(jq -c '[.[].userName] | sort' <<<"$users")"
  echo "companies=$(jq -c '[.[].name] | sort' <<<"$companies")"
  echo "orderbook=$(curl -sf "$APP_URL/query/order-book/by-company/$company_id" | jq -c '.[0] | {buyOrders: [.buyOrders[] | {tradeCount, itemPrice, itemsRemaining}], sellOrders: [.sellOrders[] | {tradeCount, itemPrice, itemsRemaining}]}')"
  for u in allard ben; do
    local uid pid
    uid=$(jq -r --arg u "$u" '.[] | select(.userName==$u) | .identifier' <<<"$users")
    pid=$(curl -sf "$APP_URL/query/portfolio/by-user/$uid" | jq -r .identifier)
    echo "portfolio[$u]=$(curl -sf "$APP_URL/query/portfolio/by-user/$uid" | jq -c --arg ob "$order_book_id" '{amountOfMoney, reservedAmountOfMoney, inPossession: (.itemsInPossession[$ob].amount // 0), reserved: (.itemsReserved[$ob].amount // 0)}')"
    echo "transactions[$u]=$(curl -sf "$APP_URL/query/transaction/by-portfolio/$pid" | jq -c '[.[] | {type, amountOfItems, amountOfExecutedItems, pricePerItem, state}] | sort_by(.type, .pricePerItem)')"
  done
  echo "enginedb.domain_event_entry=$(mysql_q enginedb 'select count(*) from domain_event_entry')"
  echo "appdb.domain_event_entry=$(mysql_q appdb 'select count(*) from domain_event_entry')"
  echo "appdb.portfolio_view=$(mysql_q appdb 'select count(*) from portfolio_view')"
  echo "appdb.order_view=$(mysql_q appdb 'select count(*) from order_view')"
}

echo "== 1. Start both apps ($RUNTIME) with SPRING_PROFILES_ACTIVE=kubernetes and only ConfigMap/Secret env vars"
start_both 1

echo "== 2. Flyway, actuator health and Prometheus"
for db in enginedb appdb; do
  echo "$db flyway_schema_history: $(mysql_q "$db" 'select concat_ws(" ", version, description, type, success) from flyway_schema_history order by installed_rank' | paste -sd ';')"
done
grep -h "Successfully applied\|Successfully baselined\|Schema .* is up to date" "$LOGS"/*-1.log | sed 's/^.*\] //' | sort -u || true
for url in "$APP_URL" "$ENGINE_URL"; do
  echo "$url/actuator/prometheus: $(curl -sf "$url/actuator/prometheus" | grep -c '^jvm_memory_used_bytes') jvm_memory_used_bytes series, $(curl -sf "$url/actuator/prometheus" | grep -m1 '^hikaricp_connections_active')"
done
echo "trader-app exposed endpoints: $(curl -sf "$APP_URL/actuator" | jq -c '._links | keys')"
echo "trading-engine exposed endpoints: $(curl -sf "$ENGINE_URL/actuator" | jq -c '._links | keys')"

echo "== 3. Seed demo data and place orders"
initialised=false
for _ in $(seq 1 30); do
  result=$(curl -s -X POST "$APP_URL/actuator/data-initializer" || true)
  # false means trader-app has no route to trading-engine in Eureka yet; true means seeded (or already seeded).
  if [ "$result" = true ]; then initialised=true; echo "data-initializer: $result"; break; fi
  sleep 5
done
[ "$initialised" = true ] || { echo "trader-app never reached trading-engine" >&2; exit 1; }
sleep 5
users=$(curl -sf "$APP_URL/query/user")
company_id=$(curl -sf "$APP_URL/query/company" | jq -r '.[] | select(.name=="Pivotal") | .identifier')
order_book_id=$(curl -sf "$APP_URL/query/order-book/by-company/$company_id" | jq -r '.[0].identifier')
portfolio() { curl -sf "$APP_URL/query/portfolio/by-user/$(jq -r --arg u "$1" '.[] | select(.userName==$u) | .identifier' <<<"$users")" | jq -r .identifier; }
order() {
  curl -sf -o /dev/null -w "$1 ($2, $3 @ $4): HTTP %{http_code}\n" -H 'Content-Type: application/json' -X POST "$APP_URL/command/$1" \
    -d "{\"orderBookId\":\"$order_book_id\",\"portfolioId\":\"$(portfolio "$2")\",\"tradeCount\":$3,\"pricePerItem\":$4}"
}
order StartSellTransactionCommand ben 5 10
order StartBuyTransactionCommand allard 5 10
order StartSellTransactionCommand ben 3 50
order StartBuyTransactionCommand allard 2 1
sleep 10

echo "== 4. State before restart"
snapshot | tee "$LOGS/before.txt"

echo "== 5. Restart both apps"
stop_both
start_both 2
sleep 10

echo "== 6. State after restart"
snapshot | tee "$LOGS/after.txt"
grep -h "Successfully applied\|Schema .* is up to date" "$LOGS"/*-2.log | sed 's/^.*\] //' | sort -u || true

if diff -u "$LOGS/before.txt" "$LOGS/after.txt"; then
  echo "PASS: orders, portfolios and event store unchanged across restart"
else
  echo "FAIL: state changed across restart" >&2; exit 1
fi
