import ballerinax/mongodb;

# Maintains the customer's order history read model from order lifecycle events.
function handleEvent(string topic, EventEnvelope envelope) returns error? {
    if topic != TOPIC_ORDERS_STATUS_CHANGED {
        return;
    }
    OrderStatusChangedEvent event = check envelope.data.cloneWithType();
    OrderHistoryEntry? previous = check historyCol->findOne({orderId: event.orderId}, {}, NO_ID, OrderHistoryEntry);
    // Ignore events older than what we already stored (redelivery / out of order).
    if previous is OrderHistoryEntry && previous.updatedAtMs > event.atMs {
        return;
    }
    OrderHistoryEntry entry = {
        orderId: event.orderId,
        customerId: event.customerId,
        restaurantId: event.restaurantId,
        restaurantName: event.restaurantName,
        status: event.status,
        total: event.total,
        currency: event.currency,
        itemCount: event.itemCount,
        driverName: event.driverName,
        reason: event.reason,
        orderCreatedAt: event.orderCreatedAt,
        orderCreatedAtMs: event.orderCreatedAtMs,
        updatedAt: event.at,
        updatedAtMs: event.atMs
    };
    mongodb:UpdateResult _ = check historyCol->updateOne({orderId: event.orderId}, {set: <map<json>>entry.toJson()},
        {upsert: true});

    // Lifetime statistics are counted exactly once, on the first DELIVERED event.
    boolean newlyDelivered = event.status == "DELIVERED" && (previous is () || previous.status != "DELIVERED");
    if newlyDelivered {
        mongodb:UpdateResult _ = check customersCol->updateOne({customerId: event.customerId},
            {inc: {totalOrders: 1, totalSpent: event.total}});
    }
}
