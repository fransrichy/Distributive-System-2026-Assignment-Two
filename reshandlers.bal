import ballerina/log;
import ballerinax/mongodb;

function handleEvent(string topic, EventEnvelope envelope) returns error? {
    match topic {
        TOPIC_ORDERS_CONFIRMED => {
            OrderConfirmedEvent event = check envelope.data.cloneWithType();
            check onOrderConfirmed(event);
        }
        TOPIC_ORDERS_CANCELLED => {
            OrderCancelledEvent event = check envelope.data.cloneWithType();
            check onOrderCancelled(event);
        }
    }
}

# A paid order enters the kitchen: reserve inventory and queue a ticket, or reject it.
function onOrderConfirmed(OrderConfirmedEvent event) returns error? {
    KitchenTicket? existing = check findTicket(event.orderId);
    if existing is KitchenTicket {
        return; // redelivered event - already handled
    }
    TicketItem[] items = from ConfirmedOrderLine line in event.items
        select {itemId: line.itemId, name: line.name, quantity: line.quantity};
    Restaurant? restaurant = check findRestaurant(event.restaurantId);
    string? rejection = ();
    if restaurant is () {
        rejection = "Unknown restaurant";
    } else if !restaurant.acceptingOrders {
        rejection = restaurant.name + " stopped accepting orders";
    } else {
        rejection = check reserveStock(event.restaurantId, items);
    }

    string now = nowIso();
    KitchenTicket ticket = {
        orderId: event.orderId,
        restaurantId: event.restaurantId,
        customerName: event.customerName,
        items,
        status: rejection is string ? "REJECTED" : "QUEUED",
        notes: event.notes,
        reason: rejection,
        receivedAt: now,
        receivedAtMs: nowMs(),
        startedAt: (),
        startedAtMs: (),
        readyAt: (),
        readyAtMs: ()
    };
    error? inserted = ticketsCol->insertOne(ticket);
    if inserted is error {
        if isDuplicateKey(inserted) {
            return;
        }
        return inserted;
    }
    if rejection is string {
        log:printWarn("order rejected by kitchen", orderId = event.orderId, reason = rejection);
        incCounter("fd_kitchen_tickets_total", "Kitchen ticket transitions", {status: "REJECTED"});
        check publishKitchenEvent(TOPIC_RESTAURANT_REJECTED, "OrderRejected", event.orderId, event.restaurantId,
                rejection);
        return;
    }
    incCounter("fd_kitchen_tickets_total", "Kitchen ticket transitions", {status: "QUEUED"});
    log:printInfo("order queued in kitchen", orderId = event.orderId, restaurantId = event.restaurantId);
}

# Cancelled before cooking started: drop the ticket and put the stock back.
function onOrderCancelled(OrderCancelledEvent event) returns error? {
    KitchenTicket? ticket = check findTicket(event.orderId);
    if ticket is () || ticket.status != "QUEUED" {
        return;
    }
    mongodb:UpdateResult result = check ticketsCol->updateOne({orderId: event.orderId, status: "QUEUED"},
        {set: {status: "CANCELLED", reason: event.reason}});
    if result.modifiedCount == 1 {
        check releaseStock(ticket.restaurantId, ticket.items);
        incCounter("fd_kitchen_tickets_total", "Kitchen ticket transitions", {status: "CANCELLED"});
        log:printInfo("ticket cancelled and stock released", orderId = event.orderId);
    }
}
