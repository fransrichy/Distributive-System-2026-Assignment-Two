import admin_service.domain;

import ballerina/log;
import ballerinax/mongodb;

// Read models owned by the Admin service (admin_db)
final mongodb:Collection factsCol = check getCollection("order_facts");
final mongodb:Collection countersCol = check getCollection("event_counters");
final mongodb:Collection processedCol = check getCollection("processed_events");
final mongodb:Collection fleetCol = check getCollection("fleet_positions");
final mongodb:Collection deadLettersCol = check getCollection("dead_letters");

type EventCounter record {|
    string topic;
    int count;
    string lastEventAt;
    string lastEventType;
|};

type FleetPosition record {|
    string driverId;
    string deliveryId;
    string orderId;
    float lat;
    float lon;
    string leg;
    int progressPct;
    int? etaSeconds;
    string updatedAt;
|};

type DeadLetterDoc record {|
    string eventId;
    string failedTopic;
    string consumer;
    string reason;
    string failedAt;
|};

type StatusEvent record {
    string orderId;
    string customerId;
    string restaurantId;
    string restaurantName;
    string? driverId = ();
    string? driverName = ();
    string status;
    string? reason = ();
    float subtotal;
    float deliveryFee;
    float total;
    float surgeMultiplier;
    int itemCount;
    int orderCreatedAtMs;
    int atMs;
};

type OrderRef record {
    string orderId;
    string? driverId = ();
    string? driverName = ();
    float? travelledKm = ();
};

type LocationEvent record {
    string driverId;
    string deliveryId;
    string orderId;
    float lat;
    float lon;
    string leg;
    int progressPct;
    int? etaSeconds = ();
    string at;
};

type DeadLetterEvent record {
    string failedTopic;
    string consumer;
    string reason;
    string failedAt;
};

final readonly & map<string> TIMESTAMP_FIELDS = {
    "CONFIRMED": "confirmedAtMs",
    "PREPARING": "preparingAtMs",
    "READY": "readyAtMs",
    "OUT_FOR_DELIVERY": "outForDeliveryAtMs",
    "DELIVERED": "deliveredAtMs",
    "CANCELLED": "cancelledAtMs"
};

function handleEvent(string topic, EventEnvelope envelope) returns error? {
    if topic == TOPIC_DLQ {
        DeadLetterEvent letter = check envelope.data.cloneWithType();
        error? stored = deadLettersCol->insertOne(<DeadLetterDoc>{eventId: envelope.eventId,
            failedTopic: letter.failedTopic, consumer: letter.consumer, reason: letter.reason, failedAt: letter.failedAt});
        if stored is error && !isDuplicateKey(stored) {
            log:printError("could not store dead letter", stored);
        }
        check countEvent(topic, envelope);
        return;
    }
    if topic == TOPIC_DELIVERY_LOCATION {
        // High-volume telemetry: positions are naturally idempotent (last write wins)
        LocationEvent p = check envelope.data.cloneWithType();
        mongodb:UpdateResult _ = check fleetCol->updateOne({driverId: p.driverId}, {
            set: <map<json>>(<FleetPosition>{driverId: p.driverId, deliveryId: p.deliveryId, orderId: p.orderId,
                lat: p.lat, lon: p.lon, leg: p.leg, progressPct: p.progressPct, etaSeconds: p.etaSeconds,
                updatedAt: p.at}).toJson()
        }, {upsert: true});
        check countEvent(topic, envelope);
        return;
    }

    // Exactly-once effect on the read models: remember every processed eventId.
    error? first = processedCol->insertOne({"eventId": envelope.eventId, "topic": topic, "processedAt": nowIso()});
    if first is error {
        if isDuplicateKey(first) {
            return;
        }
        return first;
    }
    check countEvent(topic, envelope);

    match topic {
        TOPIC_ORDERS_STATUS_CHANGED => {
            StatusEvent event = check envelope.data.cloneWithType();
            check upsertFact(event);
        }
        TOPIC_PAYMENTS_FAILED => {
            OrderRef ref = check envelope.data.cloneWithType();
            check updateFact(ref.orderId, {paymentFailed: true});
        }
        TOPIC_PAYMENTS_REFUNDED => {
            OrderRef ref = check envelope.data.cloneWithType();
            check updateFact(ref.orderId, {refunded: true});
        }
        TOPIC_DELIVERY_ASSIGNED => {
            OrderRef ref = check envelope.data.cloneWithType();
            check updateFact(ref.orderId, {driverId: ref.driverId, driverName: ref.driverName});
        }
        TOPIC_DELIVERY_COMPLETED => {
            OrderRef ref = check envelope.data.cloneWithType();
            check updateFact(ref.orderId, {distanceKm: ref.travelledKm});
        }
    }
}

function countEvent(string topic, EventEnvelope envelope) returns error? {
    mongodb:UpdateResult _ = check countersCol->updateOne({topic},
        {inc: {count: 1}, set: {lastEventAt: envelope.occurredAt, lastEventType: envelope.eventType}}, {upsert: true});
}

function upsertFact(StatusEvent e) returns error? {
    domain:OrderFact initial = {
        orderId: e.orderId, customerId: e.customerId, restaurantId: e.restaurantId, restaurantName: e.restaurantName,
        driverId: (), driverName: (), status: e.status, subtotal: e.subtotal, deliveryFee: e.deliveryFee,
        total: e.total, surgeMultiplier: e.surgeMultiplier, itemCount: e.itemCount, distanceKm: (),
        createdAtMs: e.orderCreatedAtMs, confirmedAtMs: (), preparingAtMs: (), readyAtMs: (),
        outForDeliveryAtMs: (), deliveredAtMs: (), cancelledAtMs: (), cancelReason: (), paymentFailed: false,
        refunded: false, updatedAtMs: 0
    };
    mongodb:UpdateResult _ = check factsCol->updateOne({orderId: e.orderId},
        {setOnInsert: <map<json>>initial.toJson()}, {upsert: true});

    string? tsField = TIMESTAMP_FIELDS[e.status];
    if tsField is string {
        mongodb:UpdateResult _ = check factsCol->updateOne({orderId: e.orderId, [tsField]: ()}, {set: {[tsField]: e.atMs}});
    }
    // Only newer events may change the current status (events can be redelivered out of order)
    map<json> latest = {status: e.status, updatedAtMs: e.atMs};
    if e.driverId is string {
        latest["driverId"] = e.driverId;
        latest["driverName"] = e.driverName;
    }
    if e.status == "CANCELLED" {
        latest["cancelReason"] = e.reason;
    }
    mongodb:UpdateResult _ = check factsCol->updateOne({orderId: e.orderId, updatedAtMs: {"$lte": e.atMs}},
        {set: latest});
}

function updateFact(string orderId, map<json> fields) returns error? {
    mongodb:UpdateResult result = check factsCol->updateOne({orderId}, {set: fields});
    if result.matchedCount == 0 {
        return error("no order fact yet for " + orderId); // retried, status events normally arrive first
    }
}

function loadFacts() returns domain:OrderFact[]|error {
    stream<domain:OrderFact, error?> results = check factsCol->find({}, {sort: {"createdAtMs": -1}}, NO_ID,
        domain:OrderFact);
    domain:OrderFact[] facts = check from domain:OrderFact f in results select f;
    check results.close();
    return facts;
}
