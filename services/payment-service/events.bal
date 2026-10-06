// Shared Kafka plumbing (identical in every service).
//  * Topic catalogue      - the single list of topics used by the platform (see docs/events.md)
//  * EventEnvelope        - the common message format carried by every topic
//  * publishEvent()       - idempotent, acks=all producer keyed by aggregate id (orderId / driverId)
//  * eventListener        - consumer-group listener with manual offset commits, retries and a DLQ
import ballerina/lang.runtime;
import ballerina/log;
import ballerinax/kafka;

public const TOPIC_CUSTOMERS_REGISTERED = "customers.registered";
public const TOPIC_ORDERS_CREATED = "orders.created";
public const TOPIC_ORDERS_CONFIRMED = "orders.confirmed";
public const TOPIC_ORDERS_STATUS_CHANGED = "orders.status-changed";
public const TOPIC_ORDERS_CANCELLED = "orders.cancelled";
// Payment lifecycle events published by the Payment service.
// Other services can consume these events to react to payment completion,
// failure, or refund operations.
public const TOPIC_PAYMENTS_COMPLETED = "payments.completed";
public const TOPIC_PAYMENTS_FAILED = "payments.failed";
public const TOPIC_PAYMENTS_REFUNDED = "payments.refunded";
public const TOPIC_RESTAURANT_PREPARING = "restaurant.order-preparing";
public const TOPIC_RESTAURANT_READY = "restaurant.order-ready";
public const TOPIC_RESTAURANT_REJECTED = "restaurant.order-rejected";
public const TOPIC_DELIVERY_ASSIGNED = "delivery.assigned";
public const TOPIC_DELIVERY_PICKED_UP = "delivery.picked-up";
public const TOPIC_DELIVERY_LOCATION = "delivery.location-updated";
public const TOPIC_DELIVERY_COMPLETED = "delivery.completed";
public const TOPIC_NOTIFICATIONS_SENT = "notifications.sent";
public const TOPIC_DLQ = "events.dlq";

const int MAX_HANDLER_ATTEMPTS = 3;

final string KAFKA_BOOTSTRAP = envOr("KAFKA_BOOTSTRAP_SERVERS", "localhost:9094");

# Common envelope wrapped around every event published on the platform.
// Standard envelope used for events published through Kafka.
// It provides common metadata such as the event ID, source service,
// timestamp, partition key, and event payload.
public type EventEnvelope record {|
    # Globally unique id - consumers use it for idempotent processing
    string eventId;
    # Business event name, e.g. `OrderCreated`
    string eventType;
    # Name of the producing microservice
    string 'source;
    string occurredAt;
    int occurredAtMs;
    # Partition key (orderId for order lifecycle events, driverId for telemetry)
    string key;
    int schemaVersion;
    json data;
|};

type DeadLetter record {|
    string failedTopic;
    string consumer;
    string reason;
    string payload;
    string failedAt;
|};

final kafka:Producer eventProducer = check new (KAFKA_BOOTSTRAP, {
    clientId: SERVICE_NAME,
    acks: kafka:ACKS_ALL,
    enableIdempotence: true,
    maxInFlightRequestsPerConnection: 5,
    retryCount: 10,
    linger: 0.005,
    maxBlock: 15
});

# Publishes a domain event. The key determines the partition, which guarantees
# that all events of one order (or one driver) are consumed in order.
isolated function publishEvent(string topic, string eventType, string key, anydata data) returns error? {
    EventEnvelope envelope = {
        eventId: newId("EVT"),
        eventType,
        'source: SERVICE_NAME,
        occurredAt: nowIso(),
        occurredAtMs: nowMs(),
        key,
        schemaVersion: 1,
        data: data.toJson()
    };
    kafka:RecordMetadata metadata = check eventProducer->sendWithMetadata({
        topic,
        key: key.toBytes(),
        value: envelope.toJsonString().toBytes(),
        headers: {"eventType": eventType.toBytes(), "source": SERVICE_NAME.toBytes()}
    });
    incCounter("fd_events_published_total", "Events published to Kafka", {topic});
    if topic != TOPIC_DELIVERY_LOCATION {
        log:printInfo("event published", topic = topic, eventType = eventType, key = key,
                partition = metadata.partition, offset = metadata.offset);
    }
}

# Publishes an event but never fails the caller - used where the state change is
# already committed and the event is best-effort (errors are logged and counted).
isolated function emit(string topic, string eventType, string key, anydata data) {
    error? result = publishEvent(topic, eventType, key, data);
    if result is error {
        incCounter("fd_events_publish_failures_total", "Failed Kafka publishes", {topic});
        log:printError("failed to publish event", result, topic = topic, key = key);
    }
}

listener kafka:Listener eventListener = new (KAFKA_BOOTSTRAP, {
    groupId: SERVICE_NAME,
    clientId: SERVICE_NAME + "-consumer",
    // copy into a plain array - the Kafka native layer cannot read a readonly (intersection) array
    topics: [...SUBSCRIBED_TOPICS],
    offsetReset: kafka:OFFSET_RESET_EARLIEST,
    autoCommit: false,
    pollingInterval: 0.2,
    metadataMaxAge: 5,
    sessionTimeout: 30
});

service on eventListener {
    remote function onConsumerRecord(kafka:Caller caller, kafka:BytesConsumerRecord[] records) returns error? {
        foreach kafka:BytesConsumerRecord rec in records {
            processRecord(rec);
        }
        // At-least-once delivery: offsets are committed only after the batch was handled
        // (successfully or parked in the dead-letter topic).
        kafka:Error? committed = caller->'commit();
        if committed is kafka:Error {
            log:printError("offset commit failed", committed);
        }
    }

    remote function onError(kafka:Error kafkaError) {
        log:printError("kafka consumer error", kafkaError);
    }
}

function processRecord(kafka:BytesConsumerRecord rec) {
    string topic = rec.offset.partition.topic;
    string|error raw = string:fromBytes(rec.value);
    if raw is error {
        sendToDeadLetter(topic, "<binary>", "payload is not UTF-8: " + raw.message());
        return;
    }
    EventEnvelope|error envelope = raw.fromJsonStringWithType();
    if envelope is error {
        sendToDeadLetter(topic, raw, "malformed envelope: " + envelope.message());
        return;
    }
    int attempt = 1;
    while true {
        error? handled = handleEvent(topic, envelope);
        if handled is () {
            incCounter("fd_events_consumed_total", "Events consumed from Kafka", {topic});
            return;
        }
        log:printWarn("event handling failed", topic = topic, eventId = envelope.eventId, attempt = attempt,
                reason = handled.message());
        if attempt >= MAX_HANDLER_ATTEMPTS {
            sendToDeadLetter(topic, raw, handled.message());
            return;
        }
        runtime:sleep(<decimal>attempt * 0.5d);
        attempt += 1;
    }
}

function sendToDeadLetter(string topic, string payload, string reason) {
    if topic == TOPIC_DLQ {
        log:printError("dead letter could not be processed - dropping", reason = reason);
        return; // never dead-letter a dead letter (prevents loops)
    }
    incCounter("fd_events_dead_lettered_total", "Events moved to the dead-letter topic", {topic});
    DeadLetter letter = {failedTopic: topic, consumer: SERVICE_NAME, reason, payload, failedAt: nowIso()};
    emit(TOPIC_DLQ, "DeadLetter", topic, letter);
}
