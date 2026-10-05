const SERVICE_NAME = "payment-service";

final int HTTP_PORT = envIntOr("HTTP_PORT", 8084);
final string MONGO_URI = envOr("MONGO_URI", "mongodb://localhost:27017");
final string MONGO_DATABASE = envOr("MONGO_DATABASE", "payment_db");
# Simulated gateway latency and random failure probability
final int PAYMENT_LATENCY_MS = envIntOr("PAYMENT_LATENCY_MS", 1200);
final float PAYMENT_FAILURE_RATE = envFloatOr("PAYMENT_FAILURE_RATE", 0.0);

final readonly & string[] SUBSCRIBED_TOPICS = [TOPIC_ORDERS_CREATED, TOPIC_ORDERS_CANCELLED];
