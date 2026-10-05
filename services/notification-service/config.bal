const SERVICE_NAME = "notification-service";

final int HTTP_PORT = envIntOr("HTTP_PORT", 8086);
final string MONGO_URI = envOr("MONGO_URI", "mongodb://localhost:27017");
final string MONGO_DATABASE = envOr("MONGO_DATABASE", "notification_db");

final readonly & string[] SUBSCRIBED_TOPICS = [
    TOPIC_CUSTOMERS_REGISTERED,
    TOPIC_ORDERS_STATUS_CHANGED,
    TOPIC_PAYMENTS_COMPLETED,
    TOPIC_PAYMENTS_FAILED,
    TOPIC_PAYMENTS_REFUNDED,
    TOPIC_DELIVERY_ASSIGNED,
    TOPIC_DELIVERY_COMPLETED
];
