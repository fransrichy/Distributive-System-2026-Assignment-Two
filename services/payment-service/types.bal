// -----------------------------------------------------------------------------
// Payment Service Data Types
// -----------------------------------------------------------------------------
// These types define the data owned and exchanged by the Payment service.
// -----------------------------------------------------------------------------

// Represents the different stages in the lifecycle of a payment.
//
// PENDING   - payment has been created and is being processed.
// COMPLETED - payment was successfully approved.
// FAILED    - payment was rejected or the gateway failed.
// REFUNDED  - a completed payment was refunded.
// VOIDED    - the order was cancelled before payment processing completed.
public type PaymentStatus "PENDING"|"COMPLETED"|"FAILED"|"REFUNDED"|"VOIDED";

// Stores the complete payment record owned by the Payment service.
//
// Payment records are persisted in the service's own MongoDB database.
// Other services should use events rather than accessing this data directly.
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

// Event received when a new order requires payment processing.
type OrderCreatedEvent record {
    string orderId;
    string customerId;
    float total;
    string currency;
    string paymentMethod;
    string? cardLast4 = ();
};

// Event received when an existing order is cancelled.
type OrderCancelledEvent record {
    string orderId;
    string customerId;
    string reason;
};

// Common payment information included in payment lifecycle events.
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