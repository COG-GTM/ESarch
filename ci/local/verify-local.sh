#!/usr/bin/env bash
# Runs the existing smoke/e2e checks against a local (off-TAS) Axon Trader started as described in the
# README section "Running Axon Trader Locally (off TAS)", then places a matching buy and sell order and
# prints both portfolios so the trade can be seen landing in the portfolio view.
set -euo pipefail

cd "$(dirname "$0")/../.."

APP_URL=${appURL:-http://localhost:8080}
ENGINE_URL=${engineURL:-http://localhost:8081}
UI_URL=${uiURL:-http://localhost:3000}

echo "== 0. Wait until trader-app can route commands to trading-engine"
# Health goes UP before trader-app's Axon command router has seen trading-engine in Eureka; until then commands fail
# with "No node known to accept ...". Initialising the demo data only writes events once routing works, so retry it.
initialised=false
for _ in $(seq 1 30); do
  if [ "$(curl -s -X POST "$APP_URL/actuator/data-initializer")" = "true" ]; then initialised=true; break; fi
  sleep 5
done
if [ "$initialised" != true ]; then echo "trader-app never reached trading-engine; check both are registered at http://localhost:8761" >&2; exit 1; fi
echo "Demo data initialised."

echo "== 1. Postman smoke collection (newman)"
# The collection prefixes http:// itself, so pass host:port only.
newman_status=0
npx --yes newman@6 run ESArchSmokeTest.postman_collection.json \
  --env-var "appURL=${APP_URL#http://}" \
  --env-var "engineURL=${ENGINE_URL#http://}" \
  --reporters cli || newman_status=$?

echo "== 2. ci/tasks/e2e-test-both-sides.sh"
# The Concourse task starts with apt-get install (curl, uuid-runtime, jq); off Concourse that step just fails and the
# script carries on, so curl and jq must already be on the PATH.
engineURL="$ENGINE_URL" appURL="$APP_URL" uiURL="$UI_URL" bash ci/tasks/e2e-test-both-sides.sh

echo "== 3. Matched buy/sell through to the portfolio view"
users=$(curl -sf "$APP_URL/query/user")
companies=$(curl -sf "$APP_URL/query/company")
company_id=$(jq -r '.[] | select(.name=="Pivotal") | .identifier' <<<"$companies")
order_book_id=$(curl -sf "$APP_URL/query/order-book/by-company/$company_id" | jq -r '.[0].identifier')
buyer_id=$(jq -r '.[] | select(.userName=="allard") | .identifier' <<<"$users")
seller_id=$(jq -r '.[] | select(.userName=="ben") | .identifier' <<<"$users")
buyer_portfolio=$(curl -sf "$APP_URL/query/portfolio/by-user/$buyer_id" | jq -r .identifier)
seller_portfolio=$(curl -sf "$APP_URL/query/portfolio/by-user/$seller_id" | jq -r .identifier)

snapshot() {
  curl -sf "$APP_URL/query/portfolio/by-user/$1" |
    jq -c --arg ob "$order_book_id" '{amountOfMoney, reservedAmountOfMoney, pivotalInPossession: (.itemsInPossession[$ob].amount // 0), pivotalReserved: (.itemsReserved[$ob].amount // 0)}'
}
field() { jq -r ".$2" <<<"$1"; }

buyer_before=$(snapshot "$buyer_id")
seller_before=$(snapshot "$seller_id")
echo "Before: allard (buyer) $buyer_before"
echo "Before: ben (seller)   $seller_before"

curl -sf -o /dev/null -w "StartSellTransactionCommand (ben, 5 Pivotal @ 10): HTTP %{http_code}\n" \
  -H 'Content-Type: application/json' -X POST "$APP_URL/command/StartSellTransactionCommand" \
  -d "{\"orderBookId\":\"$order_book_id\",\"portfolioId\":\"$seller_portfolio\",\"tradeCount\":5,\"pricePerItem\":10}"
curl -sf -o /dev/null -w "StartBuyTransactionCommand (allard, 5 Pivotal @ 10): HTTP %{http_code}\n" \
  -H 'Content-Type: application/json' -X POST "$APP_URL/command/StartBuyTransactionCommand" \
  -d "{\"orderBookId\":\"$order_book_id\",\"portfolioId\":\"$buyer_portfolio\",\"tradeCount\":5,\"pricePerItem\":10}"

# Commands are accepted before the trade is matched and projected, so poll the portfolio view for the expected deltas.
# This assumes the Pivotal order book has no resting orders that cross 5 @ 10 (true on a fresh database).
expected_buyer_money=$(( $(field "$buyer_before" amountOfMoney) - 50 ))
expected_buyer_items=$(( $(field "$buyer_before" pivotalInPossession) + 5 ))
expected_seller_money=$(( $(field "$seller_before" amountOfMoney) + 50 ))
expected_seller_items=$(( $(field "$seller_before" pivotalInPossession) - 5 ))
settled=false
for _ in $(seq 1 30); do
  buyer_after=$(snapshot "$buyer_id")
  seller_after=$(snapshot "$seller_id")
  if [ "$(field "$buyer_after" amountOfMoney)" -eq "$expected_buyer_money" ] &&
     [ "$(field "$buyer_after" pivotalInPossession)" -eq "$expected_buyer_items" ] &&
     [ "$(field "$seller_after" amountOfMoney)" -eq "$expected_seller_money" ] &&
     [ "$(field "$seller_after" pivotalInPossession)" -eq "$expected_seller_items" ]; then
    settled=true; break
  fi
  sleep 1
done
echo "After:  allard (buyer) $buyer_after"
echo "After:  ben (seller)   $seller_after"
echo "allard's transactions:"
transactions=$(curl -sf "$APP_URL/query/transaction/by-portfolio/$buyer_portfolio")
jq -c '.[] | {type, companyName, amountOfItems, amountOfExecutedItems, pricePerItem, state}' <<<"$transactions"

status=0
if [ "$settled" != true ]; then
  echo "FAIL: portfolios did not reach allard money=$expected_buyer_money pivotal=$expected_buyer_items, ben money=$expected_seller_money pivotal=$expected_seller_items" >&2
  status=1
elif ! jq -e 'any(.[]; .type=="BUY" and .companyName=="Pivotal" and .amountOfExecutedItems==5 and .state=="EXECUTED")' <<<"$transactions" >/dev/null; then
  echo "FAIL: no EXECUTED Pivotal BUY of 5 in allard's transactions" >&2
  status=1
else
  echo "OK: the trade executed and both portfolio views moved by 5 Pivotal / 50 cash."
fi

if [ "$newman_status" -ne 0 ]; then
  echo "FAIL: newman reported failing assertions (exit $newman_status); see the summary above." >&2
  status=1
fi
exit "$status"
