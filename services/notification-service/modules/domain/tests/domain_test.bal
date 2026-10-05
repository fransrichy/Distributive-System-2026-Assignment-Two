import ballerina/test;

final Contact ALL_CHANNELS = {email: "demo@example.com", phone: "+264811234567", emailOn: true, smsOn: true,
    pushOn: true};

@test:Config {}
function confirmedOrderNotifiesCustomerAndRestaurant() {
    Message[] messages = messagesFor("orders.status-changed", {
        orderId: "ORD-1", customerId: "C-1", customerName: "Demo", restaurantId: "R-1", restaurantName: "Grill",
        status: "CONFIRMED", itemCount: 2
    }, ALL_CHANNELS);
    test:assertEquals(messages.length(), 2);
    test:assertEquals(messages[0].recipientType, "CUSTOMER");
    test:assertEquals(messages[1].recipientType, "RESTAURANT");
    test:assertEquals(messages[1].recipientId, "R-1");
}

@test:Config {}
function preferencesAreHonoured() {
    Contact pushOnly = {email: "a@b.c", phone: "+2648", emailOn: false, smsOn: false, pushOn: true};
    Message[] messages = messagesFor("orders.status-changed",
        {orderId: "ORD-1", customerId: "C-1", status: "OUT_FOR_DELIVERY", driverName: "Maria"}, pushOnly);
    test:assertEquals(messages.length(), 1);
    test:assertEquals(messages[0].channel, "PUSH");
}

@test:Config {}
function outForDeliveryUsesSmsAndPush() {
    Message[] messages = messagesFor("orders.status-changed",
        {orderId: "ORD-1", customerId: "C-1", status: "OUT_FOR_DELIVERY", driverName: "Maria"}, ALL_CHANNELS);
    test:assertEquals(messages.map(m => m.channel), ["PUSH", "SMS"]);
    test:assertTrue(messages[0].body.includes("Maria"));
}

@test:Config {}
function driverAssignmentNotifiesDriverAndCustomer() {
    Message[] messages = messagesFor("delivery.assigned", {orderId: "ORD-1", customerId: "C-1", driverId: "D-1",
        driverName: "Maria", vehicle: "Scooter", etaMinutes: 4, routeDistanceKm: 3.2}, ALL_CHANNELS);
    test:assertEquals(messages.length(), 2);
    test:assertEquals(messages[0].recipientType, "DRIVER");
}

@test:Config {}
function unknownContactsOnlyGetPush() {
    Message[] messages = messagesFor("payments.completed", {orderId: "ORD-1", customerId: "C-1", amount: 99.5},
        UNKNOWN_CONTACT);
    test:assertEquals(messages.length(), 0, "email receipt needs a known email address");
}

@test:Config {}
function destinationsResolvePerChannel() {
    Message sms = {recipientType: "CUSTOMER", recipientId: "C-1", channel: "SMS", title: "", body: ""};
    Message push = {recipientType: "DRIVER", recipientId: "D-1", channel: "PUSH", title: "", body: ""};
    test:assertEquals(destinationOf(sms, ALL_CHANNELS), "+264811234567");
    test:assertEquals(destinationOf(push, ALL_CHANNELS), "push://driver/D-1");
}

@test:Config {}
function cancellationAlertsRestaurantOnlyIfItHadTheOrder() {
    Message[] early = messagesFor("orders.status-changed",
        {orderId: "ORD-1", customerId: "C-1", status: "CANCELLED", previousStatus: "CREATED", reason: "x"},
        ALL_CHANNELS);
    Message[] late = messagesFor("orders.status-changed",
        {orderId: "ORD-1", customerId: "C-1", status: "CANCELLED", previousStatus: "CONFIRMED", reason: "x"},
        ALL_CHANNELS);
    test:assertFalse(early.some(m => m.recipientType == "RESTAURANT"));
    test:assertTrue(late.some(m => m.recipientType == "RESTAURANT"));
}
