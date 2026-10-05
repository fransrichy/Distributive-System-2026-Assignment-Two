// Pure domain logic of the Notification service: which recipients get which message on
// which channel for every platform event.

public type Recipient "CUSTOMER"|"RESTAURANT"|"DRIVER";

public type Channel "EMAIL"|"SMS"|"PUSH";

public type Message record {|
    Recipient recipientType;
    string recipientId;
    Channel channel;
    string title;
    string body;
|};

# Customer contact details and channel preferences.
public type Contact record {|
    string? email;
    string? phone;
    boolean emailOn;
    boolean smsOn;
    boolean pushOn;
|};

public final readonly & Contact UNKNOWN_CONTACT = {email: (), phone: (), emailOn: false, smsOn: false, pushOn: true};

# Builds the notifications for one event.
#
# + topic - Kafka topic the event was read from
# + data - event payload
# + contact - the customer's contact details (if known)
# + return - messages to dispatch (may be empty)
public isolated function messagesFor(string topic, map<json> data, Contact contact) returns Message[] {
    string orderId = text(data, "orderId");
    string customerId = text(data, "customerId");
    Message[] out = [];
    match topic {
        "customers.registered" => {
            toCustomer(out, contact, customerId, ["EMAIL"], "Welcome to Namibia Eats!",
                    string `Hi ${text(data, "name")}, your account is ready. Hungry? Order from local restaurants now.`);
        }
        "orders.status-changed" => {
            statusMessages(out, data, contact, orderId, customerId);
        }
        "payments.completed" => {
            toCustomer(out, contact, customerId, ["EMAIL"], "Payment receipt",
                    string `We received N$${money(data, "amount")} for order ${orderId} (ref ${text(data, "transactionRef")}).`);
        }
        "payments.failed" => {
            toCustomer(out, contact, customerId, ["SMS", "PUSH"], "Payment failed",
                    string `Payment for order ${orderId} failed: ${text(data, "reason")}. The order was cancelled.`);
        }
        "payments.refunded" => {
            toCustomer(out, contact, customerId, ["EMAIL"], "Refund issued",
                    string `N$${money(data, "amount")} for order ${orderId} has been refunded to your ${text(data, "method")} account.`);
        }
        "delivery.assigned" => {
            string driverId = text(data, "driverId");
            out.push({recipientType: "DRIVER", recipientId: driverId, channel: "PUSH", title: "New delivery",
                body: string `Collect order ${orderId} at restaurant ${text(data, "restaurantId")}. Route: ${money(data, "routeDistanceKm")} km.`});
            toCustomer(out, contact, customerId, ["PUSH"], "Driver assigned",
                    string `${text(data, "driverName")} (${text(data, "vehicle")}) will deliver order ${orderId}. ETA ${text(data, "etaMinutes")} min.`);
        }
        "delivery.completed" => {
            out.push({recipientType: "DRIVER", recipientId: text(data, "driverId"), channel: "PUSH",
                title: "Delivery complete",
                body: string `Order ${orderId} delivered - ${money(data, "travelledKm")} km driven. Great job!`});
        }
    }
    return out;
}

isolated function statusMessages(Message[] out, map<json> data, Contact contact, string orderId, string customerId) {
    string restaurantId = text(data, "restaurantId");
    string restaurant = text(data, "restaurantName");
    match text(data, "status") {
        "CREATED" => {
            toCustomer(out, contact, customerId, ["PUSH"], "Order received",
                    string `We received order ${orderId} from ${restaurant} (N$${money(data, "total")}). Processing payment...`);
        }
        "CONFIRMED" => {
            toCustomer(out, contact, customerId, ["PUSH"], "Order confirmed",
                    string `${restaurant} has your order ${orderId}.`);
            out.push({recipientType: "RESTAURANT", recipientId: restaurantId, channel: "PUSH", title: "New order",
                body: string `Order ${orderId}: ${text(data, "itemCount")} item(s) for ${text(data, "customerName")}.`});
        }
        "PREPARING" => {
            toCustomer(out, contact, customerId, ["PUSH"], "Being prepared",
                    string `${restaurant} is preparing your food.`);
        }
        "READY" => {
            toCustomer(out, contact, customerId, ["PUSH"], "Food is ready",
                    string `Your order ${orderId} is packed and waiting for the driver.`);
        }
        "OUT_FOR_DELIVERY" => {
            toCustomer(out, contact, customerId, ["PUSH", "SMS"], "On the way",
                    string `${text(data, "driverName")} picked up order ${orderId} and is on the way.`);
        }
        "DELIVERED" => {
            toCustomer(out, contact, customerId, ["PUSH", "EMAIL"], "Delivered",
                    string `Order ${orderId} was delivered. Enjoy your meal!`);
        }
        "CANCELLED" => {
            toCustomer(out, contact, customerId, ["PUSH", "SMS"], "Order cancelled",
                    string `Order ${orderId} was cancelled: ${text(data, "reason")}.`);
            if text(data, "previousStatus") == "CONFIRMED" {
                out.push({recipientType: "RESTAURANT", recipientId: restaurantId, channel: "PUSH",
                    title: "Order cancelled", body: string `Order ${orderId} was cancelled - do not prepare it.`});
            }
        }
    }
}

# Adds customer messages on the requested channels, honouring the customer's preferences.
isolated function toCustomer(Message[] out, Contact contact, string customerId, Channel[] channels, string title,
        string body) {
    foreach Channel channel in channels {
        boolean allowed = channel == "EMAIL" ? contact.emailOn && contact.email is string
            : channel == "SMS" ? contact.smsOn && contact.phone is string
                : contact.pushOn;
        if allowed {
            out.push({recipientType: "CUSTOMER", recipientId: customerId, channel, title, body});
        }
    }
}

# Where a message is physically sent.
#
# + message - the message
# + contact - customer contact details
# + return - email address, phone number or push topic
public isolated function destinationOf(Message message, Contact contact) returns string {
    if message.recipientType == "CUSTOMER" {
        if message.channel == "EMAIL" {
            return contact.email ?: "-";
        }
        if message.channel == "SMS" {
            return contact.phone ?: "-";
        }
    }
    return string `push://${message.recipientType.toLowerAscii()}/${message.recipientId}`;
}

isolated function text(map<json> data, string key) returns string {
    json value = data[key];
    return value is () ? "" : value.toString();
}

isolated function money(map<json> data, string key) returns string {
    json value = data[key];
    if value is int|float|decimal {
        float amount = value is float ? value : <float>value;
        return (float:round(amount * 100.0) / 100.0).toString();
    }
    return "0";
}
