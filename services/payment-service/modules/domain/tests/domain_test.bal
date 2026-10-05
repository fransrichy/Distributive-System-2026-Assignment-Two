import ballerina/test;

@test:Config {}
function cardPaymentsAreApproved() {
    test:assertEquals(decide("CARD", 250.0, "4242", 0.9, 0.0), {approved: true, reason: ()});
}

@test:Config {}
function testCardIsDeclined() {
    PaymentDecision decision = decide("CARD", 250.0, "0000", 0.9, 0.0);
    test:assertFalse(decision.approved);
    test:assertEquals(decision.reason, "Card declined by issuer");
}

@test:Config {}
function limitsAreEnforcedPerMethod() {
    test:assertFalse(decide("CARD", 5000.01, (), 0.9, 0.0).approved);
    test:assertFalse(decide("MOBILE_MONEY", 3500.0, (), 0.9, 0.0).approved);
    test:assertFalse(decide("CASH_ON_DELIVERY", 1600.0, (), 0.9, 0.0).approved);
    test:assertTrue(decide("CASH_ON_DELIVERY", 300.0, (), 0.9, 0.0).approved);
}

@test:Config {}
function randomGatewayFailures() {
    test:assertFalse(decide("CARD", 100.0, (), 0.05, 0.1).approved);
    test:assertTrue(decide("CARD", 100.0, (), 0.5, 0.1).approved);
}

@test:Config {}
function invalidInputsAreDeclined() {
    test:assertFalse(decide("BITCOIN", 100.0, (), 0.9, 0.0).approved);
    test:assertFalse(decide("CARD", 0.0, (), 0.9, 0.0).approved);
}

@test:Config {}
function transactionReferencesArePrefixed() {
    test:assertEquals(transactionReference("MOBILE_MONEY", "PAY-1"), "MOM-PAY-1");
}
