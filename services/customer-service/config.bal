const SERVICE_NAME = "customer-service";

final int HTTP_PORT = envIntOr("HTTP_PORT", 8081);
final string MONGO_URI = envOr("MONGO_URI", "mongodb://localhost:27017");
final string MONGO_DATABASE = envOr("MONGO_DATABASE", "customer_db");
final boolean SEED_DATA = envBoolOr("SEED_DATA", true);

final readonly & string[] SUBSCRIBED_TOPICS = [TOPIC_ORDERS_STATUS_CHANGED];
