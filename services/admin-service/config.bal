const SERVICE_NAME = "admin-service";

final int HTTP_PORT = envIntOr("HTTP_PORT", 8087);
final string MONGO_URI = envOr("MONGO_URI", "mongodb://localhost:27017");
final string MONGO_DATABASE = envOr("MONGO_DATABASE", "admin_db");
final int TZ_OFFSET_HOURS = envIntOr("TZ_OFFSET_HOURS", 2);
# Delivery promise used for the on-time rate KPI
final int ON_TIME_TARGET_MINUTES = envIntOr("ON_TIME_TARGET_MINUTES", 45);

# Base URLs of the other services, monitored by /reports/system
final readonly & map<string> SERVICE_URLS = {
    "customer-service": envOr("CUSTOMER_SERVICE_URL", "http://localhost:8081"),
    "restaurant-service": envOr("RESTAURANT_SERVICE_URL", "http://localhost:8082"),
    "order-service": envOr("ORDER_SERVICE_URL", "http://localhost:8083"),
    "payment-service": envOr("PAYMENT_SERVICE_URL", "http://localhost:8084"),
    "delivery-service": envOr("DELIVERY_SERVICE_URL", "http://localhost:8085"),
    "notification-service": envOr("NOTIFICATION_SERVICE_URL", "http://localhost:8086")
};

# The Admin service listens to (almost) every topic to build its analytics read models.
final readonly & string[] SUBSCRIBED_TOPICS = [
    TOPIC_CUSTOMERS_REGISTERED,
    TOPIC_ORDERS_CREATED,
    TOPIC_ORDERS_CONFIRMED,
    TOPIC_ORDERS_STATUS_CHANGED,
    TOPIC_ORDERS_CANCELLED,
    TOPIC_PAYMENTS_COMPLETED,
    TOPIC_PAYMENTS_FAILED,
    TOPIC_PAYMENTS_REFUNDED,
    TOPIC_RESTAURANT_PREPARING,
    TOPIC_RESTAURANT_READY,
    TOPIC_RESTAURANT_REJECTED,
    TOPIC_DELIVERY_ASSIGNED,
    TOPIC_DELIVERY_PICKED_UP,
    TOPIC_DELIVERY_LOCATION,
    TOPIC_DELIVERY_COMPLETED,
    TOPIC_NOTIFICATIONS_SENT,
    TOPIC_DLQ
];
