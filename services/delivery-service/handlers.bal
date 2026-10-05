import ballerina/log;
import ballerinax/mongodb;

function handleEvent(string topic, EventEnvelope envelope) returns error? {
    match topic {
        TOPIC_ORDERS_CONFIRMED => {
            OrderConfirmedEvent event = check envelope.data.cloneWithType();
            check onOrderConfirmed(event);
        }
        TOPIC_RESTAURANT_READY => {
            OrderReadyEvent event = check envelope.data.cloneWithType();
            mongodb:UpdateResult result = check deliveriesCol->updateOne({orderId: event.orderId},
                {set: {foodReady: true, updatedAt: nowIso()}});
            if result.matchedCount == 0 {
                return error("no delivery for order " + event.orderId + " yet");
            }
        }
        TOPIC_ORDERS_CANCELLED => {
            OrderCancelledEvent event = check envelope.data.cloneWithType();
            check onOrderCancelled(event);
        }
    }
}

# A confirmed (paid) order gets a delivery job; a driver is dispatched immediately so
# they travel to the restaurant while the kitchen is cooking.
function onOrderConfirmed(OrderConfirmedEvent event) returns error? {
    Delivery? existing = check findDelivery({orderId: event.orderId});
    if existing is Delivery {
        return;
    }
    string now = nowIso();
    Delivery delivery = {
        deliveryId: newId("DLV"),
        orderId: event.orderId,
        customerId: event.customerId,
        customerName: event.customerName,
        restaurantId: event.restaurantId,
        restaurantName: event.restaurantName,
        pickup: event.restaurantLocation,
        dropoff: event.deliveryAddress.location,
        dropoffAddress: event.deliveryAddress.street,
        driverId: (),
        driverName: (),
        status: "PENDING_ASSIGNMENT",
        foodReady: false,
        leg: "NONE",
        route: [],
        routeDistanceKm: 0.0,
        routeDurationMinutes: 0.0,
        progressKm: 0.0,
        currentLocation: (),
        etaSeconds: (),
        travelledKm: 0.0,
        deliveryFee: event.deliveryFee,
        cancelReason: (),
        createdAt: now,
        createdAtMs: nowMs(),
        assignedAtMs: (),
        pickedUpAtMs: (),
        deliveredAtMs: (),
        updatedAt: now
    };
    error? inserted = deliveriesCol->insertOne(delivery);
    if inserted is error {
        return isDuplicateKey(inserted) ? () : inserted;
    }
    incCounter("fd_deliveries_total", "Delivery lifecycle events", {status: "CREATED"});
    boolean assigned = check tryAssign(delivery);
    if !assigned {
        log:printWarn("no driver available - delivery queued", orderId = event.orderId);
    }
}

function onOrderCancelled(OrderCancelledEvent event) returns error? {
    Delivery? delivery = check findDelivery({orderId: event.orderId});
    if delivery is () {
        return;
    }
    mongodb:UpdateResult result = check deliveriesCol->updateOne(
        {orderId: event.orderId, status: {"$in": ["PENDING_ASSIGNMENT", "ASSIGNED", "AT_RESTAURANT"]}},
        {set: {status: "CANCELLED", cancelReason: event.reason, etaSeconds: (), updatedAt: nowIso()}});
    if result.modifiedCount == 0 {
        return;
    }
    string? driverId = delivery.driverId;
    if driverId is string {
        check releaseDriver(driverId, delivery.progressKm, 0.0, false);
    }
    incCounter("fd_deliveries_total", "Delivery lifecycle events", {status: "CANCELLED"});
    log:printInfo("delivery cancelled", orderId = event.orderId, driverReleased = driverId);
}
