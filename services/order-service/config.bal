const SERVICE_NAME = "order-service";

final int HTTP_PORT = envIntOr("HTTP_PORT", 8083);
final string MONGO_URI = envOr("MONGO_URI", "mongodb://localhost:27017");
final string MONGO_DATABASE = envOr("MONGO_DATABASE", "order_db");
final string CUSTOMER_SERVICE_URL = envOr("CUSTOMER_SERVICE_URL", "http://localhost:8081");
final string RESTAURANT_SERVICE_URL = envOr("RESTAURANT_SERVICE_URL", "http://localhost:8082");
final string DELIVERY_SERVICE_URL = envOr("DELIVERY_SERVICE_URL", "http://localhost:8085");
# Africa/Windhoek is UTC+2 all year round
final int TZ_OFFSET_HOURS = envIntOr("TZ_OFFSET_HOURS", 2);
# Window used to measure demand for surge pricing
final int DEMAND_WINDOW_MINUTES = envIntOr("DEMAND_WINDOW_MINUTES", 10);

final readonly & string[] SUBSCRIBED_TOPICS = [
    TOPIC_PAYMENTS_COMPLETED,
    TOPIC_PAYMENTS_FAILED,
    TOPIC_RESTAURANT_PREPARING,
    TOPIC_RESTAURANT_READY,
    TOPIC_RESTAURANT_REJECTED,
    TOPIC_DELIVERY_ASSIGNED,
    TOPIC_DELIVERY_PICKED_UP,
    TOPIC_DELIVERY_COMPLETED
];
