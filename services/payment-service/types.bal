// Represents the different stages in the lifecycle of a payment.
// A payment can remain pending, complete successfully, fail, be refunded,
// or be voided when an order is cancelled before payment processing.
public type PaymentStatus "PENDING"|"COMPLETED"|"FAILED"|"REFUNDED"|"VOIDED";

# Persisted in `payment_db.payments` (unique per orderId).
// Stores the complete payment record owned by the Payment service.
// These records are persisted in the service's MongoDB database.
public type Payment record {|
    string paymentId;
    string orderId;
    string customerId;
    float amount;
    string currency;
    string method;
    string? cardLast4;
    PaymentStatus status;
    string? transactionRef;
    string? failureReason;
    string createdAt;
    int createdAtMs;
    string updatedAt;
    int? processingMs;
|};

// Contains summary information used to monitor payment activity.
public type PaymentStats record {|
    int completed;
    int failed;
    int refunded;
    int pending;
    float capturedAmount;
    float refundedAmount;
|};

type OrderCreatedEvent record {
    string orderId;
    string customerId;
    float total;
    string currency;
    string paymentMethod;
    string? cardLast4 = ();
};

type OrderCancelledEvent record {
    string orderId;
    string customerId;
    string reason;
};

type PaymentEvent record {|
    string paymentId;
    string orderId;
    string customerId;
    float amount;
    string currency;
    string method;
    string? transactionRef;
    string? reason;
|};
