import payment_service.domain;

import ballerina/lang.runtime;
import ballerina/log;
import ballerina/random;
import ballerinax/mongodb;

final mongodb:Collection paymentsCol = check getCollection("payments");

function handleEvent(string topic, EventEnvelope envelope) returns error? {
    match topic {
        TOPIC_ORDERS_CREATED => {
            OrderCreatedEvent event = check envelope.data.cloneWithType();
            check processPayment(event);
        }
        TOPIC_ORDERS_CANCELLED => {
            OrderCancelledEvent event = check envelope.data.cloneWithType();
            check onOrderCancelled(event);
        }
    }
}

function findPaymentByOrder(string orderId) returns Payment|error? {
    return paymentsCol->findOne({orderId}, {}, NO_ID, Payment);
}

# Charges an order. The unique index on `orderId` makes processing idempotent: a
# redelivered `orders.created` event can never charge the customer twice.
// Processes a payment for a newly created order.
//
// The payment starts in the PENDING state while the simulated gateway
// evaluates the payment rules. Once a decision is available, the payment
// is updated to COMPLETED or FAILED and the corresponding Kafka event
// is published for other services to consume.
function processPayment(OrderCreatedEvent event) returns error? {
    Payment? existing = check findPaymentByOrder(event.orderId);
    if existing is Payment {
        log:printInfo("payment already processed - skipping", orderId = event.orderId, status = existing.status);
        return;
    }
    int startedMs = nowMs();
    string now = nowIso();
    Payment payment = {
        paymentId: newId("PAY"),
        orderId: event.orderId,
        customerId: event.customerId,
        amount: event.total,
        currency: event.currency,
        method: event.paymentMethod,
        cardLast4: event.cardLast4,
        status: "PENDING",
        transactionRef: (),
        failureReason: (),
        createdAt: now,
        createdAtMs: startedMs,
        updatedAt: now,
        processingMs: ()
    };
    error? inserted = paymentsCol->insertOne(payment);
    if inserted is error {
        return isDuplicateKey(inserted) ? () : inserted;
    }

    // Simulated call to the external payment gateway
    runtime:sleep(<decimal>PAYMENT_LATENCY_MS / 1000d);
    domain:PaymentDecision decision = domain:decide(event.paymentMethod, event.total, event.cardLast4,
            random:createDecimal(), PAYMENT_FAILURE_RATE);
    PaymentStatus status = decision.approved ? "COMPLETED" : "FAILED";
    string? reference = decision.approved ? domain:transactionReference(event.paymentMethod, payment.paymentId) : ();
    int elapsed = nowMs() - startedMs;
    mongodb:UpdateResult _ = check paymentsCol->updateOne({paymentId: payment.paymentId, status: "PENDING"}, {
        set: {
            status,
            transactionRef: reference,
            failureReason: decision.reason,
            updatedAt: nowIso(),
            processingMs: elapsed
        }
    });

    PaymentEvent result = {
        paymentId: payment.paymentId,
        orderId: event.orderId,
        customerId: event.customerId,
        amount: event.total,
        currency: event.currency,
        method: event.paymentMethod,
        transactionRef: reference,
        reason: decision.reason
    };
    incCounter("fd_payments_total", "Processed payments", {status, method: event.paymentMethod});
    if decision.approved {
        check publishEvent(TOPIC_PAYMENTS_COMPLETED, "PaymentCompleted", event.orderId, result);
        log:printInfo("payment completed", orderId = event.orderId, amount = event.total, ref = reference);
    } else {
        check publishEvent(TOPIC_PAYMENTS_FAILED, "PaymentFailed", event.orderId, result);
        log:printWarn("payment failed", orderId = event.orderId, reason = decision.reason);
    }
}

# Compensation for cancelled orders: refund captured payments, or void the payment if the
# cancellation overtook the `orders.created` event.
// Handles payment-related actions when an order is cancelled.
//
// Completed payments are changed to REFUNDED. If the order was cancelled
// before a payment record existed, a VOIDED record is created so that the
// cancellation is still represented in the payment service's history.
function onOrderCancelled(OrderCancelledEvent event) returns error? {
    Payment? payment = check findPaymentByOrder(event.orderId);
    if payment is () {
        string now = nowIso();
        error? voided = paymentsCol->insertOne(<Payment>{
            paymentId: newId("PAY"), orderId: event.orderId, customerId: event.customerId, amount: 0.0,
            currency: "NAD", method: "NONE", cardLast4: (), status: "VOIDED", transactionRef: (),
            failureReason: "Order cancelled before payment: " + event.reason, createdAt: now, createdAtMs: nowMs(),
            updatedAt: now, processingMs: ()
        });
        if voided is error && !isDuplicateKey(voided) {
            return voided;
        }
        return;
    }
    if payment.status != "COMPLETED" {
        return;
    }
    mongodb:UpdateResult result = check paymentsCol->updateOne({paymentId: payment.paymentId, status: "COMPLETED"},
        {set: {status: "REFUNDED", failureReason: "Refund: " + event.reason, updatedAt: nowIso()}});
    if result.modifiedCount == 0 {
        return;
    }
    incCounter("fd_payments_total", "Processed payments", {status: "REFUNDED", method: payment.method});
    check publishEvent(TOPIC_PAYMENTS_REFUNDED, "PaymentRefunded", event.orderId, <PaymentEvent>{
        paymentId: payment.paymentId,
        orderId: payment.orderId,
        customerId: payment.customerId,
        amount: payment.amount,
        currency: payment.currency,
        method: payment.method,
        transactionRef: payment.transactionRef,
        reason: event.reason
    });
    log:printInfo("payment refunded", orderId = event.orderId, amount = payment.amount);
}
