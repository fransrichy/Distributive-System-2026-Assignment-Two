import ballerina/test;

// -----------------------------------------------------------------------------
// Payment Domain Test Suite
// -----------------------------------------------------------------------------
// These tests verify the core payment rules independently from HTTP, MongoDB,
// Kafka, Docker, and other infrastructure.
//
// Keeping these tests focused on domain behaviour makes it easier to identify
// whether a payment failure is caused by business rules or by infrastructure.
// -----------------------------------------------------------------------------

@test:Config {}
function cardPaymentsAreApproved() {
    PaymentDecision decision = decide("CARD", 250.0, "4242", 0.9, 0.0);

    test:assertTrue(decision.approved);
    test:assertEquals(decision.reason, ());
}

@test:Config {}
function cardPaymentWithDifferentCardNumberIsApproved() {
    PaymentDecision decision = decide("CARD", 500.0, "1234", 0.8, 0.0);

    test:assertTrue(decision.approved);
    test:assertEquals(decision.reason, ());
}

@test:Config {}
function testCardIsDeclined() {
    PaymentDecision decision = decide("CARD", 250.0, "0000", 0.9, 0.0);

    test:assertFalse(decision.approved);
    test:assertEquals(decision.reason, "Card declined by issuer");
}

@test:Config {}
function cardLimitIsEnforced() {
    PaymentDecision decision = decide("CARD", 5000.01, "4242", 0.9, 0.0);

    test:assertFalse(decision.approved);
    test:assertEquals(decision.reason, "Card limit exceeded");
}

@test:Config {}
function cardAtMaximumLimitIsAccepted() {
    PaymentDecision decision = decide("CARD", 5000.0, "4242", 0.9, 0.0);

    test:assertTrue(decision.approved);
}

@test:Config {}
function mobileMoneyWithinLimitIsApproved() {
    PaymentDecision decision = decide("MOBILE_MONEY", 1000.0, (), 0.9, 0.0);

    test:assertTrue(decision.approved);
}

@test:Config {}
function mobileMoneyLimitIsEnforced() {
    PaymentDecision decision = decide("MOBILE_MONEY", 3000.01, (), 0.9, 0.0);

    test:assertFalse(decision.approved);
    test:assertEquals(decision.reason, "Mobile money wallet limit exceeded");
}

@test:Config {}
function mobileMoneyAtMaximumLimitIsAccepted() {
    PaymentDecision decision = decide("MOBILE_MONEY", 3000.0, (), 0.9, 0.0);

    test:assertTrue(decision.approved);
}

@test:Config {}
function cashOnDeliveryWithinLimitIsApproved() {
    PaymentDecision decision = decide("CASH_ON_DELIVERY", 750.0, (), 0.9, 0.0);

    test:assertTrue(decision.approved);
}

@test:Config {}
function cashOnDeliveryLimitIsEnforced() {
    PaymentDecision decision = decide("CASH_ON_DELIVERY", 1500.01, (), 0.9, 0.0);

    test:assertFalse(decision.approved);
    test:assertEquals(decision.reason, "Cash on delivery is limited to N$1500");
}

@test:Config {}
function cashOnDeliveryAtMaximumLimitIsAccepted() {
    PaymentDecision decision = decide("CASH_ON_DELIVERY", 1500.0, (), 0.9, 0.0);

    test:assertTrue(decision.approved);
}

@test:Config {}
function limitsAreEnforcedPerMethod() {
    test:assertFalse(decide("CARD", 5000.01, (), 0.9, 0.0).approved);
    test:assertFalse(decide("MOBILE_MONEY", 3000.01, (), 0.9, 0.0).approved);
    test:assertFalse(decide("CASH_ON_DELIVERY", 1500.01, (), 0.9, 0.0).approved);

    test:assertTrue(decide("CARD", 5000.0, "4242", 0.9, 0.0).approved);
    test:assertTrue(decide("MOBILE_MONEY", 3000.0, (), 0.9, 0.0).approved);
    test:assertTrue(decide("CASH_ON_DELIVERY", 1500.0, (), 0.9, 0.0).approved);
}

@test:Config {}
function invalidAmountIsDeclined() {
    PaymentDecision decision = decide("CARD", 0.0, "4242", 0.9, 0.0);

    test:assertFalse(decision.approved);
    test:assertEquals(decision.reason, "Invalid amount");
}

@test:Config {}
function negativeAmountIsDeclined() {
    PaymentDecision decision = decide("CARD", -100.0, "4242", 0.9, 0.0);

    test:assertFalse(decision.approved);
    test:assertEquals(decision.reason, "Invalid amount");
}

@test:Config {}
function invalidAmountIsCheckedBeforePaymentMethod() {
    PaymentDecision decision = decide("BITCOIN", 0.0, (), 0.9, 0.0);

    test:assertFalse(decision.approved);
    test:assertEquals(decision.reason, "Invalid amount");
}

@test:Config {}
function unsupportedPaymentMethodIsDeclined() {
    PaymentDecision decision = decide("BITCOIN", 100.0, (), 0.9, 0.0);

    test:assertFalse(decision.approved);
    test:assertEquals(decision.reason, "Unsupported payment method BITCOIN");
}

@test:Config {}
function randomGatewayFailures() {
    PaymentDecision failed = decide("CARD", 100.0, (), 0.05, 0.1);
    PaymentDecision approved = decide("CARD", 100.0, (), 0.5, 0.1);

    test:assertFalse(failed.approved);
    test:assertEquals(failed.reason, "Payment gateway timeout");

    test:assertTrue(approved.approved);
    test:assertEquals(approved.reason, ());
}

@test:Config {}
function zeroFailureRateDoesNotCauseRandomFailure() {
    PaymentDecision decision = decide("CARD", 100.0, "4242", 0.0, 0.0);

    test:assertTrue(decision.approved);
}

@test:Config {}
function failureRateOfOneCausesGatewayFailure() {
    PaymentDecision decision = decide("CARD", 100.0, "4242", 0.0, 1.0);

    test:assertFalse(decision.approved);
    test:assertEquals(decision.reason, "Payment gateway timeout");
}

@test:Config {}
function issuerDeclineTakesPriorityOverGatewayFailure() {
    PaymentDecision decision = decide("CARD", 100.0, "0000", 0.0, 1.0);

    test:assertFalse(decision.approved);
    test:assertEquals(decision.reason, "Card declined by issuer");
}

@test:Config {}
function cardLimitTakesPriorityOverGatewayFailure() {
    PaymentDecision decision = decide("CARD", 5000.01, "4242", 0.0, 1.0);

    test:assertFalse(decision.approved);
    test:assertEquals(decision.reason, "Card limit exceeded");
}

@test:Config {}
function mobileMoneyLimitTakesPriorityOverGatewayFailure() {
    PaymentDecision decision = decide("MOBILE_MONEY", 3000.01, (), 0.0, 1.0);

    test:assertFalse(decision.approved);
    test:assertEquals(decision.reason, "Mobile money wallet limit exceeded");
}

@test:Config {}
function cashLimitTakesPriorityOverGatewayFailure() {
    PaymentDecision decision = decide("CASH_ON_DELIVERY", 1500.01, (), 0.0, 1.0);

    test:assertFalse(decision.approved);
    test:assertEquals(decision.reason, "Cash on delivery is limited to N$1500");
}

@test:Config {}
function transactionReferencesArePrefixed() {
    test:assertEquals(
        transactionReference("CARD", "PAY-1"),
        "CRD-PAY-1"
    );

    test:assertEquals(
        transactionReference("MOBILE_MONEY", "PAY-2"),
        "MOM-PAY-2"
    );

    test:assertEquals(
        transactionReference("CASH_ON_DELIVERY", "PAY-3"),
        "COD-PAY-3"
    );
}

@test:Config {}
function transactionReferencePreservesPaymentId() {
    string paymentId = "PAY-ABC123";

    test:assertEquals(
        transactionReference("CARD", paymentId),
        "CRD-PAY-ABC123"
    );
}

@test:Config {}
function transactionReferenceUsesExpectedPrefixes() {
    test:assertTrue(transactionReference("CARD", "PAY-1").startsWith("CRD-"));
    test:assertTrue(transactionReference("MOBILE_MONEY", "PAY-2").startsWith("MOM-"));
    test:assertTrue(transactionReference("CASH_ON_DELIVERY", "PAY-3").startsWith("COD-"));
}