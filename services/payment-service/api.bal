import ballerina/http;

@http:ServiceConfig {cors: CORS}
service /payments on httpListener {

    resource function get .(string? orderId, string? customerId, string? status, int 'limit = 100)
            returns Payment[]|error {
        map<json> filter = {};
        if orderId is string {
            filter["orderId"] = orderId;
        }
        if customerId is string {
            filter["customerId"] = customerId;
        }
        if status is string {
            filter["status"] = status.toUpperAscii();
        }
        stream<Payment, error?> results = check paymentsCol->find(filter, {sort: {"createdAtMs": -1}, 'limit},
            NO_ID, Payment);
        Payment[] payments = check from Payment p in results select p;
        check results.close();
        return payments;
    }

    resource function get stats() returns PaymentStats|error {
        stream<Payment, error?> results = check paymentsCol->find({}, {}, NO_ID, Payment);
        PaymentStats stats = {completed: 0, failed: 0, refunded: 0, pending: 0, capturedAmount: 0, refundedAmount: 0};
        check from Payment p in results
            do {
                match p.status {
                    "COMPLETED" => {
                        stats.completed += 1;
                        stats.capturedAmount += p.amount;
                    }
                    "FAILED" => {
                        stats.failed += 1;
                    }
                    "REFUNDED" => {
                        stats.refunded += 1;
                        stats.refundedAmount += p.amount;
                    }
                    "PENDING" => {
                        stats.pending += 1;
                    }
                }
            };
        check results.close();
        stats.capturedAmount = round2(stats.capturedAmount);
        stats.refundedAmount = round2(stats.refundedAmount);
        return stats;
    }

    resource function get 'order/[string orderId]() returns Payment|http:NotFound|error {
        Payment? payment = check findPaymentByOrder(orderId);
        return payment ?: notFound("No payment for order " + orderId);
    }

    resource function get [string paymentId]() returns Payment|http:NotFound|error {
        Payment? payment = check paymentsCol->findOne({paymentId}, {}, NO_ID, Payment);
        return payment ?: notFound("Payment not found: " + paymentId);
    }
}
