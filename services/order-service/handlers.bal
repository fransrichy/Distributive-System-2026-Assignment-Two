import order_service.domain;

import ballerinax/mongodb;

# Routes consumed events to the order state machine (the saga orchestrator).
function handleEvent(string topic, EventEnvelope envelope) returns error? {
    match topic {
        TOPIC_PAYMENTS_COMPLETED => {
            PaymentEvent payment = check envelope.data.cloneWithType();
            _ = check applyTransition(payment.orderId, domain:CONFIRMED, "Payment " + payment.paymentId + " completed",
                    "payment-service", {paymentId: payment.paymentId});
        }
        TOPIC_PAYMENTS_FAILED => {
            PaymentEvent payment = check envelope.data.cloneWithType();
            _ = check applyTransition(payment.orderId, domain:CANCELLED,
                    "Payment failed: " + (payment.reason ?: "declined"), "payment-service");
        }
        TOPIC_RESTAURANT_PREPARING => {
            RestaurantOrderEvent kitchen = check envelope.data.cloneWithType();
            _ = check applyTransition(kitchen.orderId, domain:PREPARING, "Kitchen started preparing", "restaurant-service");
        }
        TOPIC_RESTAURANT_READY => {
            RestaurantOrderEvent kitchen = check envelope.data.cloneWithType();
            _ = check applyTransition(kitchen.orderId, domain:READY, "Food is ready for pickup", "restaurant-service");
        }
        TOPIC_RESTAURANT_REJECTED => {
            RestaurantOrderEvent kitchen = check envelope.data.cloneWithType();
            _ = check applyTransition(kitchen.orderId, domain:CANCELLED,
                    "Restaurant rejected the order: " + (kitchen.reason ?: "unavailable"), "restaurant-service");
        }
        TOPIC_DELIVERY_ASSIGNED => {
            DeliveryEvent delivery = check envelope.data.cloneWithType();
            mongodb:UpdateResult _ = check ordersCol->updateOne({orderId: delivery.orderId}, {
                set: {
                    driverId: delivery.driverId,
                    driverName: delivery.driverName,
                    etaMinutes: delivery.etaMinutes,
                    updatedAt: nowIso(),
                    updatedAtMs: nowMs()
                }
            });
        }
        TOPIC_DELIVERY_PICKED_UP => {
            DeliveryEvent delivery = check envelope.data.cloneWithType();
            _ = check applyTransition(delivery.orderId, domain:OUT_FOR_DELIVERY, "Driver picked up the order",
                    "delivery-service", {etaMinutes: delivery.etaMinutes});
        }
        TOPIC_DELIVERY_COMPLETED => {
            DeliveryEvent delivery = check envelope.data.cloneWithType();
            _ = check applyTransition(delivery.orderId, domain:DELIVERED, "Delivered to customer", "delivery-service",
                    {etaMinutes: 0});
        }
    }
}
