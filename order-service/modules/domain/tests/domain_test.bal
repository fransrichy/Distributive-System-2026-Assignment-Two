import ballerina/test;

@test:Config {}
function happyPathTransitionsAreSingleSteps() {
    test:assertEquals(planTransition(CREATED, CONFIRMED), [CONFIRMED]);
    test:assertEquals(planTransition(CONFIRMED, PREPARING), [PREPARING]);
    test:assertEquals(planTransition(PREPARING, READY), [READY]);
    test:assertEquals(planTransition(READY, OUT_FOR_DELIVERY), [OUT_FOR_DELIVERY]);
    test:assertEquals(planTransition(OUT_FOR_DELIVERY, DELIVERED), [DELIVERED]);
}

@test:Config {}
function outOfOrderEventsCatchUpAlongTheHappyPath() {
    // delivery.picked-up observed before restaurant.order-ready
    test:assertEquals(planTransition(PREPARING, OUT_FOR_DELIVERY), [READY, OUT_FOR_DELIVERY]);
}

@test:Config {}
function duplicateAndStaleEventsAreIgnored() {
    test:assertEquals(planTransition(READY, READY), []);
    test:assertEquals(planTransition(READY, PREPARING), []);
    test:assertEquals(planTransition(DELIVERED, CANCELLED), []);
    test:assertEquals(planTransition(CANCELLED, CONFIRMED), []);
}

@test:Config {}
function cancellationOnlyBeforeKitchenStarts() {
    test:assertEquals(planTransition(CREATED, CANCELLED), [CANCELLED]);
    test:assertEquals(planTransition(CONFIRMED, CANCELLED), [CANCELLED]);
    test:assertEquals(planTransition(PREPARING, CANCELLED), []);
    test:assertTrue(customerCanCancel(CONFIRMED));
    test:assertFalse(customerCanCancel(OUT_FOR_DELIVERY));
}

@test:Config {}
function transitionTableIsConsistent() {
    test:assertTrue(canTransition(CREATED, CONFIRMED));
    test:assertFalse(canTransition(CREATED, DELIVERED));
    test:assertTrue(isTerminal(DELIVERED));
    test:assertEquals(rank(CANCELLED), -1);
}

@test:Config {}
function surgeIsNeutralWithAmpleSupplyOffPeak() {
    SurgeQuote quote = calculateSurge({recentOrders: 2, availableDrivers: 5, busyDrivers: 0,
        driverDataAvailable: true, localHour: 16, localMinute: 0});
    test:assertEquals(quote.multiplier, 1.0);
    test:assertEquals(quote.level, "NORMAL");
}

@test:Config {}
function surgeRisesWithoutDriversAndAtPeak() {
    SurgeQuote quote = calculateSurge({recentOrders: 3, availableDrivers: 0, busyDrivers: 4,
        driverDataAvailable: true, localHour: 12, localMinute: 15});
    // +0.5 no drivers, +0.2 all busy, +0.2 peak
    test:assertEquals(quote.multiplier, 1.9);
    test:assertEquals(quote.level, "HIGH");
    test:assertEquals(quote.reasons.length(), 3);
}

@test:Config {}
function surgeIsCapped() {
    SurgeQuote quote = calculateSurge({recentOrders: 500, availableDrivers: 1, busyDrivers: 20,
        driverDataAvailable: true, localHour: 18, localMinute: 0});
    test:assertTrue(quote.multiplier <= MAX_SURGE);
}

@test:Config {}
function surgeDegradesGracefullyWhenDeliveryServiceIsDown() {
    SurgeQuote quote = calculateSurge({recentOrders: 50, availableDrivers: 0, busyDrivers: 0,
        driverDataAvailable: false, localHour: 9, localMinute: 0});
    test:assertEquals(quote.multiplier, 1.0);
}

@test:Config {}
function deliveryFeeScalesWithDistanceAndSurge() {
    test:assertEquals(deliveryFee(5.0, 1.0), 35.0);
    test:assertEquals(deliveryFee(5.0, 1.5), 52.5);
}

@test:Config {}
function haversineMatchesKnownDistance() {
    // Windhoek CBD to Klein Windhoek is roughly 1.8 km
    float km = haversineKm(-22.5700, 17.0836, -22.5650, 17.1010);
    test:assertTrue(km > 1.6 && km < 2.0, string `unexpected distance ${km}`);
}
