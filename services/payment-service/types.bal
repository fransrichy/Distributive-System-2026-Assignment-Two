public type PaymentStatus "PENDING"|"COMPLETED"|"FAILED"|"REFUNDED"|"VOIDED";

# Persisted in `payment_db.payments` (unique per orderId).
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
