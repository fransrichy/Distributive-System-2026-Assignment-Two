import ballerina/http;

// Synchronous queries to other services use retries + a circuit breaker so that a
// slow or failing dependency fails fast instead of exhausting this service.
final http:ClientConfiguration resilientConfig = {
    timeout: 5,
    retryConfig: {count: 2, interval: 0.3, backOffFactor: 2.0, statusCodes: [502, 503, 504]},
    circuitBreaker: {
        rollingWindow: {timeWindow: 10, bucketSize: 2, requestVolumeThreshold: 4},
        failureThreshold: 0.5,
        resetTime: 10,
        statusCodes: [500, 502, 503, 504]
    }
};

final http:Client customerClient = check new (CUSTOMER_SERVICE_URL, resilientConfig);
final http:Client restaurantClient = check new (RESTAURANT_SERVICE_URL, resilientConfig);
final http:Client deliveryClient = check new (DELIVERY_SERVICE_URL, resilientConfig);
