import order_service.domain;

import ballerina/log;
import ballerinax/mongodb;

# Moves an order towards `target` using the domain state machine.
#
# Uses optimistic concurrency (`version`) so REST commands and Kafka events that race
# on the same order can never overwrite each other. Every applied step is published on
# `orders.status-changed`; confirmations and cancellations also get their own topics.
#
# + return - the updated order, `()` when the transition was a duplicate/stale event,
# or an error if the order does not exist
function applyTransition(string orderId, domain:OrderStatus target, string? reason, string actor,
        map<json> extraFields = {}) returns Order|error? {
    foreach int attempt in 1 ... 5 {
        Order? current = check findOrder(orderId);
        if current is () {
            return error(string `order ${orderId} not found`);
        }
        domain:OrderStatus[] steps = domain:planTransition(current.status, target);
        if steps.length() == 0 {
            log:printDebug("transition ignored", orderId = orderId, current = current.status, target = target);
            return ();
        }
        string at = nowIso();
        int atMs = nowMs();
        StatusChange[] history = current.statusHistory.clone();
        foreach domain:OrderStatus step in steps {
            history.push({status: step, at, atMs, reason: step == target ? reason : "auto-advanced", actor});
        }
        map<json> fields = {
            status: target,
            statusHistory: history.toJson(),
            updatedAt: at,
            updatedAtMs: atMs,
            version: current.version + 1
        };
        if target == domain:CANCELLED {
            fields["cancelReason"] = reason;
        }
        foreach [string, json] [key, value] in extraFields.entries() {
            fields[key] = value;
        }
        mongodb:UpdateResult result = check ordersCol->updateOne({orderId, version: current.version}, {set: fields});
        if result.matchedCount == 0 {
            log:printDebug("optimistic lock conflict, retrying", orderId = orderId, attempt = attempt);
            continue;
        }
        Order updated = check findOrder(orderId) ?: current;
        publishTransitions(updated, current.status, steps, reason, at, atMs);
        return updated;
    }
    return error(string `order ${orderId}: too many concurrent modifications`);
}

function publishTransitions(Order 'order, domain:OrderStatus initial, domain:OrderStatus[] steps, string? reason,
        string at, int atMs) {
    domain:OrderStatus previous = initial;
    foreach domain:OrderStatus step in steps {
        emit(TOPIC_ORDERS_STATUS_CHANGED, "OrderStatusChanged", 'order.orderId,
                toStatusEvent('order, previous, step, reason, at, atMs));
        incCounter("fd_order_transitions_total", "Order state transitions", {status: step});
        log:printInfo("order transition", orderId = 'order.orderId, 'from = previous, to = step);
        previous = step;
    }
    domain:OrderStatus finalStatus = 'order.status;
    if finalStatus == domain:CONFIRMED {
        emit(TOPIC_ORDERS_CONFIRMED, "OrderConfirmed", 'order.orderId, 'order);
    } else if finalStatus == domain:CANCELLED {
        OrderCancelledEvent cancelled = {
            orderId: 'order.orderId,
            customerId: 'order.customerId,
            restaurantId: 'order.restaurantId,
            previousStatus: initial,
            reason: reason ?: "Cancelled",
            paymentId: 'order.paymentId,
            refundRequired: 'order.paymentId is string,
            total: 'order.total
        };
        emit(TOPIC_ORDERS_CANCELLED, "OrderCancelled", 'order.orderId, cancelled);
    }
}

function toStatusEvent(Order o, domain:OrderStatus previous, domain:OrderStatus status, string? reason, string at,
        int atMs) returns OrderStatusChangedEvent => {
    orderId: o.orderId,
    customerId: o.customerId,
    customerName: o.customerName,
    customerEmail: o.customerEmail,
    customerPhone: o.customerPhone,
    notificationPrefs: o.notificationPrefs,
    restaurantId: o.restaurantId,
    restaurantName: o.restaurantName,
    driverId: o.driverId,
    driverName: o.driverName,
    previousStatus: previous,
    status,
    reason,
    subtotal: o.subtotal,
    deliveryFee: o.deliveryFee,
    surgeMultiplier: o.surgeMultiplier,
    total: o.total,
    currency: o.currency,
    itemCount: int:sum(...from OrderItem i in o.items select i.quantity),
    estimatedDistanceKm: o.estimatedDistanceKm,
    orderCreatedAt: o.createdAt,
    orderCreatedAtMs: o.createdAtMs,
    at,
    atMs
};

// ---------------------------------------------------------------------------
// Surge pricing inputs
// ---------------------------------------------------------------------------

function currentSurge() returns domain:SurgeQuote {
    int windowStart = nowMs() - DEMAND_WINDOW_MINUTES * 60 * 1000;
    int|error recent = ordersCol->countDocuments({"createdAtMs": {"$gte": windowStart}});
    DriverSummaryDto|error drivers = deliveryClient->get("/drivers/summary", targetType = DriverSummaryDto);
    int nowSeconds = nowMs() / 1000 + TZ_OFFSET_HOURS * 3600;
    int secondsOfDay = nowSeconds % 86400;
    domain:SurgeQuote quote = domain:calculateSurge({
        recentOrders: recent is int ? recent : 0,
        availableDrivers: drivers is DriverSummaryDto ? drivers.available : 0,
        busyDrivers: drivers is DriverSummaryDto ? drivers.busy : 0,
        driverDataAvailable: drivers is DriverSummaryDto,
        localHour: secondsOfDay / 3600,
        localMinute: (secondsOfDay % 3600) / 60
    });
    if drivers is error {
        log:printWarn("delivery service unavailable - surge pricing degraded", reason = drivers.message());
    }
    setGauge("fd_surge_multiplier", "Current surge pricing multiplier", quote.multiplier);
    return quote;
}
