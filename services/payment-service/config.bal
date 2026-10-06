// -----------------------------------------------------------------------------
// Payment Service Configuration
// -----------------------------------------------------------------------------
// Configuration values are read from environment variables where available.
// Defaults are provided so the service can also run in a local development
// environment without requiring every variable to be configured manually.
// -----------------------------------------------------------------------------

// Unique service name used for logs, Kafka consumers, and service identity.
const SERVICE_NAME = "payment-service";

// HTTP port exposed by the Payment service.
final int HTTP_PORT = envIntOr("HTTP_PORT", 8084);

// MongoDB connection used by the Payment service.
final string MONGO_URI = envOr("MONGO_URI", "mongodb://localhost:27017");

// Database owned exclusively by the Payment service.
final string MONGO_DATABASE = envOr("MONGO_DATABASE", "payment_db");

// Simulated payment gateway processing delay in milliseconds.
final int PAYMENT_LATENCY_MS = envIntOr("PAYMENT_LATENCY_MS", 1200);

// Probability of a simulated payment gateway failure.
// 0.0 means no simulated failures.
// 1.0 means every otherwise-valid payment fails.
final float PAYMENT_FAILURE_RATE = envFloatOr("PAYMENT_FAILURE_RATE", 0.0);

// Kafka topics consumed by the Payment service.
final readonly & string[] SUBSCRIBED_TOPICS =
    [TOPIC_ORDERS_CREATED, TOPIC_ORDERS_CANCELLED];