# Kafka topic catalogue

All topics are created by `infra/kafka/create-topics.sh` (auto-creation is disabled on the broker).

| Topic | Partitions | Key | Retention | Producer | Consumer groups |
|-------|-----------:|-----|-----------|----------|-----------------|
| `customers.registered` | 3 | customerId | 7 d | customer-service | notification, admin |
| `orders.created` | 6 | orderId | 7 d | order-service | payment, admin |
| `orders.confirmed` | 6 | orderId | 7 d | order-service | restaurant, delivery, admin |
| `orders.status-changed` | 6 | orderId | 7 d | order-service | customer, notification, admin |
| `orders.cancelled` | 3 | orderId | 7 d | order-service | payment, restaurant, delivery, admin |
| `payments.completed` | 6 | orderId | 7 d | payment-service | order, notification, admin |
| `payments.failed` | 3 | orderId | 7 d | payment-service | order, notification, admin |
| `payments.refunded` | 3 | orderId | 7 d | payment-service | notification, admin |
| `restaurant.order-preparing` | 3 | orderId | 7 d | restaurant-service | order, admin |
| `restaurant.order-ready` | 3 | orderId | 7 d | restaurant-service | order, delivery, admin |
| `restaurant.order-rejected` | 3 | orderId | 7 d | restaurant-service | order, admin |
| `delivery.assigned` | 3 | orderId | 7 d | delivery-service | order, notification, admin |
| `delivery.picked-up` | 3 | orderId | 7 d | delivery-service | order, admin |
| `delivery.location-updated` | 6 | **driverId** | **1 h** (telemetry) | delivery-service | admin (live fleet) |
| `delivery.completed` | 3 | orderId | 7 d | delivery-service | order, notification, admin |
| `notifications.sent` | 3 | orderId | 1 d | notification-service | admin |
| `events.dlq` | 1 | original topic | 14 d | every service | admin |

## Envelope

```json
{
  "eventId": "EVT-1A2B3C4D",
  "eventType": "PaymentCompleted",
  "source": "payment-service",
  "occurredAt": "2026-10-05T10:15:30.123Z",
  "occurredAtMs": 1791195330123,
  "key": "ORD-9F8E7D6C",
  "schemaVersion": 1,
  "data": { "orderId": "ORD-9F8E7D6C", "paymentId": "PAY-...", "amount": 245.5, "currency": "NAD",
            "method": "CARD", "transactionRef": "CRD-PAY-...", "reason": null }
}
```

Kafka headers `eventType` and `source` are also set, so tools such as Kafka UI can filter
messages without parsing the body.

## Delivery guarantees

| Concern | Mechanism |
|---------|-----------|
| No duplicates from producer retries | `enable.idempotence=true`, `acks=all` |
| Per-order ordering | partition key = `orderId` |
| No lost events on consumer crash | `autoCommit=false`; offsets are committed after the batch is handled |
| Duplicate deliveries (at-least-once) | idempotent handlers: unique indexes (`payments.orderId`, `kitchen_tickets.orderId`, `deliveries.orderId`, `notifications.notificationId`, `processed_events.eventId`) and state-machine checks |
| Poison messages | 3 attempts with back-off, then `events.dlq`; a DLQ message is never re-dead-lettered |
| Consumer scaling | consumer group per service + 3–6 partitions per topic |

## Inspecting topics

```bash
# list topics with partition counts
docker exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe

# follow the order lifecycle live
docker exec -it kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic orders.status-changed --property print.key=true --property print.partition=true

# consumer-group lag per service
docker exec kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --all-groups
```
