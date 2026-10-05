#!/usr/bin/env bash
# End-to-end demonstration of the order saga through the API gateway (requires curl + jq).
#   ./scripts/demo.sh [http://localhost:8080]
set -euo pipefail
GW="${1:-http://localhost:8080}"

api() { # api METHOD PATH [JSON]
  if [ $# -ge 3 ]; then
    curl -sf -X "$1" "$GW$2" -H 'Content-Type: application/json' -d "$3"
  else
    curl -sf -X "$1" "$GW$2"
  fi
}
title() { printf '\n\033[36m=== %s ===\033[0m\n' "$1"; }

title "Waiting for the platform"
for s in customer restaurant order payment delivery notification admin; do
  for _ in $(seq 1 90); do
    status=$(api GET "/api/$s-service/health" 2>/dev/null | jq -r .status || true)
    [ "$status" = "UP" ] && break
    sleep 2
  done
  printf '  %-22s %s\n' "$s-service" "${status:-DOWN}"
done

watch_order() { # watch_order ORDER_ID FINAL_REGEX
  local last=""
  for _ in $(seq 1 180); do
    local o; o=$(api GET "/api/order-service/orders/$1")
    local st; st=$(jq -r .status <<<"$o")
    if [ "$st" != "$last" ]; then
      printf '  %s  %-17s %s\n' "$(date +%T)" "$st" "$(jq -r '.driverName // ""' <<<"$o")"
      last=$st
    fi
    [[ "$st" =~ $2 ]] && { echo "$o" > /tmp/fd-last-order.json; return 0; }
    sleep 2
  done
  return 1
}

title "Scenario 1 - happy path"
order=$(api POST /api/order-service/orders '{"customerId":"C-3001","restaurantId":"R-1002","paymentMethod":"CARD","cardLast4":"4242","items":[{"itemId":"M-105","quantity":2},{"itemId":"M-107","quantity":1}]}')
id=$(jq -r .orderId <<<"$order")
echo "  placed $id total=N\$$(jq -r .total <<<"$order") surge=x$(jq -r .surgeMultiplier <<<"$order")"
watch_order "$id" "DELIVERED|CANCELLED"
jq -r '.statusHistory[] | "    \(.status) by \(.actor): \(.reason)"' /tmp/fd-last-order.json

title "Scenario 2 - declined card -> CANCELLED"
bad=$(api POST /api/order-service/orders '{"customerId":"C-3002","restaurantId":"R-1003","paymentMethod":"CARD","cardLast4":"0000","items":[{"itemId":"M-109","quantity":1}]}')
watch_order "$(jq -r .orderId <<<"$bad")" "CANCELLED|DELIVERED"
echo "  reason: $(jq -r .cancelReason /tmp/fd-last-order.json)"

title "Scenario 3 - cancel after payment -> refund"
c=$(api POST /api/order-service/orders '{"customerId":"C-3003","restaurantId":"R-1004","paymentMethod":"MOBILE_MONEY","items":[{"itemId":"M-114","quantity":1}]}')
cid=$(jq -r .orderId <<<"$c")
for _ in $(seq 1 40); do
  [ "$(api GET "/api/order-service/orders/$cid" | jq -r .status)" != "CREATED" ] && break
  sleep 0.25
done
api PUT "/api/order-service/orders/$cid/cancel" '{"reason":"Ordered by mistake"}' | jq -r '"  \(.orderId) -> \(.status)"'
sleep 4
api GET "/api/payment-service/payments/order/$cid" | jq -r '"  payment: \(.status) (\(.failureReason))"'

title "Admin overview"
api GET /api/admin-service/reports/overview | jq '{totalOrders, delivered, cancelled, grossMerchandiseValue, avgFulfilmentMinutes, onTimeRate}'
api GET /api/admin-service/reports/events | jq -r '.[] | "  \(.topic)\t\(.count)"'
echo -e "\nDone. Open $GW for the UI."
