#!/bin/bash
# Creates every Kafka topic of the platform with an explicit partition count and
# retention policy (broker-side auto topic creation is disabled on purpose).
#
# Partitioning: producers key every order-lifecycle event by orderId and telemetry by
# driverId, so all events of one order are stored in - and consumed from - one partition
# in order, while different orders are processed in parallel by consumer-group members.
set -euo pipefail

BOOTSTRAP="${KAFKA_BOOTSTRAP:-kafka:9092}"
KT=/opt/kafka/bin/kafka-topics.sh

echo "Waiting for Kafka at ${BOOTSTRAP} ..."
for i in $(seq 1 60); do
  if ${KT} --bootstrap-server "${BOOTSTRAP}" --list >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

HOUR=3600000
DAY=$((24 * HOUR))

# topic                         partitions  retention.ms
TOPICS=(
  "customers.registered          3 $((7 * DAY))"
  "orders.created                6 $((7 * DAY))"
  "orders.confirmed              6 $((7 * DAY))"
  "orders.status-changed         6 $((7 * DAY))"
  "orders.cancelled              3 $((7 * DAY))"
  "payments.completed            6 $((7 * DAY))"
  "payments.failed               3 $((7 * DAY))"
  "payments.refunded             3 $((7 * DAY))"
  "restaurant.order-preparing    3 $((7 * DAY))"
  "restaurant.order-ready        3 $((7 * DAY))"
  "restaurant.order-rejected     3 $((7 * DAY))"
  "delivery.assigned             3 $((7 * DAY))"
  "delivery.picked-up            3 $((7 * DAY))"
  "delivery.completed            3 $((7 * DAY))"
  "delivery.location-updated     6 $((1 * HOUR))"
  "notifications.sent            3 $((1 * DAY))"
  "events.dlq                    1 $((14 * DAY))"
)

for entry in "${TOPICS[@]}"; do
  read -r name partitions retention <<<"${entry}"
  ${KT} --bootstrap-server "${BOOTSTRAP}" --create --if-not-exists \
    --topic "${name}" --partitions "${partitions}" --replication-factor 1 \
    --config retention.ms="${retention}" --config cleanup.policy=delete \
    --config min.insync.replicas=1
  echo "  ✔ ${name} (partitions=${partitions}, retention.ms=${retention})"
done

echo
echo "Topic overview:"
${KT} --bootstrap-server "${BOOTSTRAP}" --describe | grep -E "^Topic:" | awk '{print "  " $2, $4, $6}'
echo "Kafka topics ready."
