import ballerina/log;
import ballerinax/mongodb;

# Atomically reserves inventory for every line of an order. Each decrement is guarded by
# `stock >= quantity`, so concurrent orders can never oversell. If any line fails the
# lines already reserved are released again (compensation).
#
# + return - `()` on success, or the reason the order cannot be fulfilled
function reserveStock(string restaurantId, TicketItem[] items) returns string|error? {
    TicketItem[] reserved = [];
    foreach TicketItem item in items {
        mongodb:UpdateResult result = check menuCol->updateOne(
            {restaurantId, itemId: item.itemId, available: true, stock: {"$gte": item.quantity}},
            {inc: {stock: -item.quantity}, set: {updatedAt: nowIso()}});
        if result.matchedCount == 0 {
            check releaseStock(restaurantId, reserved);
            return string `${item.name} sold out before the order could be confirmed`;
        }
        reserved.push(item);
    }
    return ();
}

function releaseStock(string restaurantId, TicketItem[] items) returns error? {
    foreach TicketItem item in items {
        mongodb:UpdateResult _ = check menuCol->updateOne({restaurantId, itemId: item.itemId},
            {inc: {stock: item.quantity}, set: {updatedAt: nowIso()}});
    }
}

# QUEUED -> PREPARING. Conditional on the current status so that the REST endpoint and the
# kitchen simulation can never both apply it.
#
# + return - true when this call performed the transition
function startPreparing(string orderId, string restaurantId) returns boolean|error {
    string now = nowIso();
    mongodb:UpdateResult result = check ticketsCol->updateOne({orderId, restaurantId, status: "QUEUED"},
        {set: {status: "PREPARING", startedAt: now, startedAtMs: nowMs()}});
    if result.modifiedCount == 0 {
        return false;
    }
    check publishKitchenEvent(TOPIC_RESTAURANT_PREPARING, "OrderPreparing", orderId, restaurantId, ());
    incCounter("fd_kitchen_tickets_total", "Kitchen ticket transitions", {status: "PREPARING"});
    log:printInfo("kitchen started order", orderId = orderId);
    return true;
}

# PREPARING -> READY, which triggers the driver pickup.
#
# + return - true when this call performed the transition
function markReady(string orderId, string restaurantId) returns boolean|error {
    string now = nowIso();
    mongodb:UpdateResult result = check ticketsCol->updateOne({orderId, restaurantId, status: "PREPARING"},
        {set: {status: "READY", readyAt: now, readyAtMs: nowMs()}});
    if result.modifiedCount == 0 {
        return false;
    }
    check publishKitchenEvent(TOPIC_RESTAURANT_READY, "OrderReady", orderId, restaurantId, ());
    incCounter("fd_kitchen_tickets_total", "Kitchen ticket transitions", {status: "READY"});
    log:printInfo("order ready for pickup", orderId = orderId);
    return true;
}

function publishKitchenEvent(string topic, string eventType, string orderId, string restaurantId, string? reason)
        returns error? {
    Restaurant? restaurant = check findRestaurant(restaurantId);
    KitchenEvent event = {
        orderId,
        restaurantId,
        restaurantName: restaurant is Restaurant ? restaurant.name : restaurantId,
        pickupLocation: restaurant is Restaurant ? restaurant.location : {lat: 0, lon: 0},
        reason,
        at: nowIso()
    };
    check publishEvent(topic, eventType, orderId, event);
}
