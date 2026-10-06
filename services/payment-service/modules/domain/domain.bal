// -----------------------------------------------------------------------------
// Payment Domain Logic
// -----------------------------------------------------------------------------
// This module contains the core payment rules used by the Payment service.
//
// The payment service supports three payment methods:
//   1. CARD
//   2. MOBILE_MONEY
//   3. CASH_ON_DELIVERY
//
// The functions in this module do not access MongoDB, Kafka, HTTP, or any
// external service. Keeping these rules here makes the payment decisions easy
// to test and reuse.
// -----------------------------------------------------------------------------
public type PaymentDecision record {|
    boolean approved;
    string? reason;
|};

public const float CARD_LIMIT = 5000.0;
public const float MOBILE_MONEY_LIMIT = 3000.0;
public const float CASH_LIMIT = 1500.0;
# Test card: any card ending in 0000 is declined by the (simulated) issuer
public const DECLINED_TEST_CARD = "0000";

# Decides whether a simulated payment succeeds.
#
# + method - CARD, MOBILE_MONEY or CASH_ON_DELIVERY
# + amount - amount to charge (NAD)
# + cardLast4 - last four card digits, if paying by card
# + randomValue - uniform random number in [0, 1) used to simulate gateway failures
# + failureRate - probability of a random gateway failure
# + return - the decision and, if declined, the reason
public isolated function decide(string method, float amount, string? cardLast4, float randomValue, float failureRate)
        returns PaymentDecision {
    if amount <= 0.0 {
        return {approved: false, reason: "Invalid amount"};
    }
    match method {
        "CARD" => {
            if cardLast4 == DECLINED_TEST_CARD {
                return {approved: false, reason: "Card declined by issuer"};
            }
            if amount > CARD_LIMIT {
                return {approved: false, reason: "Card limit exceeded"};
            }
        }
        "MOBILE_MONEY" => {
            if amount > MOBILE_MONEY_LIMIT {
                return {approved: false, reason: "Mobile money wallet limit exceeded"};
            }
        }
        "CASH_ON_DELIVERY" => {
            if amount > CASH_LIMIT {
                return {approved: false, reason: "Cash on delivery is limited to N$1500"};
            }
        }
        _ => {
            return {approved: false, reason: "Unsupported payment method " + method};
        }
    }
    if randomValue < failureRate {
        return {approved: false, reason: "Payment gateway timeout"};
    }
    return {approved: true, reason: ()};
}

# Gateway style transaction reference, e.g. `CRD-PAY-1A2B3C4D`.
#
# + method - payment method
# + paymentId - payment identifier
# + return - transaction reference
public isolated function transactionReference(string method, string paymentId) returns string {
    string prefix = method == "CARD" ? "CRD" : method == "MOBILE_MONEY" ? "MOM" : "COD";
    return prefix + "-" + paymentId;
}
