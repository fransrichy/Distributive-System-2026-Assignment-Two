const SERVICE_NAME = "delivery-service";

final int HTTP_PORT = envIntOr("HTTP_PORT", 8085);
final string MONGO_URI = envOr("MONGO_URI", "mongodb://localhost:27017");
final string MONGO_DATABASE = envOr("MONGO_DATABASE", "delivery_db");
final boolean SEED_DATA = envBoolOr("SEED_DATA", true);
final int TZ_OFFSET_HOURS = envIntOr("TZ_OFFSET_HOURS", 2);

# Driver simulation: drivers move along their optimised route every tick.
final boolean SIMULATION_ENABLED = envBoolOr("SIMULATION_ENABLED", true);
# When enabled drivers pick up and complete deliveries on their own (otherwise use the driver app/API).
final boolean AUTO_DRIVE = envBoolOr("AUTO_DRIVE", true);
final decimal TICK_SECONDS = <decimal>envFloatOr("TICK_SECONDS", 1.0);
final float DRIVER_SPEED_KMH = envFloatOr("DRIVER_SPEED_KMH", 40.0);
# Speeds simulated time up so a 5 km trip takes ~1 minute in a demo
final float SIM_SPEED_FACTOR = envFloatOr("SIM_SPEED_FACTOR", 8.0);
# Share of the delivery fee paid to the driver
final float DRIVER_FEE_SHARE = envFloatOr("DRIVER_FEE_SHARE", 0.8);

final readonly & string[] SUBSCRIBED_TOPICS = [TOPIC_ORDERS_CONFIRMED, TOPIC_RESTAURANT_READY, TOPIC_ORDERS_CANCELLED];
