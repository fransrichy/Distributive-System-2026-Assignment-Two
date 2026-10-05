const SERVICE_NAME = "restaurant-service";

final int HTTP_PORT = envIntOr("HTTP_PORT", 8082);
final string MONGO_URI = envOr("MONGO_URI", "mongodb://localhost:27017");
final string MONGO_DATABASE = envOr("MONGO_DATABASE", "restaurant_db");
final boolean SEED_DATA = envBoolOr("SEED_DATA", true);
# Africa/Windhoek is UTC+2 all year round
final int TZ_OFFSET_HOURS = envIntOr("TZ_OFFSET_HOURS", 2);

# Kitchen simulation: when enabled, queued tickets are started and completed automatically.
final boolean AUTO_KITCHEN = envBoolOr("AUTO_KITCHEN", true);
final int AUTO_START_SECONDS = envIntOr("AUTO_START_SECONDS", 5);
final int AUTO_PREP_SECONDS = envIntOr("AUTO_PREP_SECONDS", 15);
final int LOW_STOCK_THRESHOLD = envIntOr("LOW_STOCK_THRESHOLD", 5);

final readonly & string[] SUBSCRIBED_TOPICS = [TOPIC_ORDERS_CONFIRMED, TOPIC_ORDERS_CANCELLED];
