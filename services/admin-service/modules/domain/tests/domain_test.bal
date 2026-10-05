import ballerina/test;

const int T0 = 1791158400000; // 2026-10-05 00:00 UTC
const int MINUTE = 60000;

function fact(string orderId, string restaurantId, string status, float total, string? driverId = (),
        int createdOffset = 0) returns OrderFact {
    boolean delivered = status == "DELIVERED";
    int created = T0 + createdOffset;
    return {
        orderId, customerId: "C-1", restaurantId, restaurantName: "Restaurant " + restaurantId,
        driverId, driverName: driverId, status, subtotal: total - 20.0, deliveryFee: 20.0, total,
        surgeMultiplier: 1.0, itemCount: 2, distanceKm: delivered ? 4.0 : (),
        createdAtMs: created, confirmedAtMs: created + MINUTE, preparingAtMs: created + 2 * MINUTE,
        readyAtMs: created + 11 * MINUTE, outForDeliveryAtMs: delivered ? created + 15 * MINUTE : (),
        deliveredAtMs: delivered ? created + 30 * MINUTE : (), cancelledAtMs: status == "CANCELLED" ? created : (),
        cancelReason: (), paymentFailed: false, refunded: false, updatedAtMs: created
    };
}

final OrderFact[] FACTS = [
    fact("O1", "R-1", "DELIVERED", 120.0, "D-1"),
    fact("O2", "R-1", "DELIVERED", 80.0, "D-1"),
    fact("O3", "R-2", "DELIVERED", 220.0, "D-2"),
    fact("O4", "R-2", "CANCELLED", 50.0),
    fact("O5", "R-1", "PREPARING", 60.0, "D-2")
];

@test:Config {}
function overviewTotals() {
    Overview o = overview(FACTS, 45);
    test:assertEquals(o.totalOrders, 5);
    test:assertEquals(o.delivered, 3);
    test:assertEquals(o.cancelled, 1);
    test:assertEquals(o.activeOrders, 1);
    test:assertEquals(o.grossMerchandiseValue, 420.0);
    test:assertEquals(o.avgOrderValue, 140.0);
    test:assertEquals(o.cancellationRate, 0.25);
    test:assertEquals(o.avgFulfilmentMinutes, 30.0);
    test:assertEquals(o.avgTransitMinutes, 15.0);
    test:assertEquals(o.avgPrepMinutes, 10.0);
    test:assertEquals(o.onTimeRate, 1.0);
    test:assertEquals(overview(FACTS, 20).onTimeRate, 0.0);
}

@test:Config {}
function restaurantLeaderboardIsSortedByRevenue() {
    RestaurantStats[] stats = restaurantStats(FACTS);
    test:assertEquals(stats.length(), 2);
    test:assertEquals(stats[0].restaurantId, "R-2"); // 200 vs 160 subtotal revenue
    test:assertEquals(stats[0].revenue, 200.0);
    test:assertEquals(stats[1].orders, 3);
    test:assertEquals(stats[1].itemsSold, 4);
    test:assertEquals(stats[0].cancellationRate, 0.5);
}

@test:Config {}
function driverPerformance() {
    DriverStats[] stats = driverStats(FACTS);
    test:assertEquals(stats[0].driverId, "D-1");
    test:assertEquals(stats[0].deliveries, 2);
    test:assertEquals(stats[0].totalDistanceKm, 8.0);
    test:assertEquals(stats[0].avgTransitMinutes, 15.0);
    test:assertEquals(stats[1].inProgress, 1);
}

@test:Config {}
function hourlyBucketsUseLocalTime() {
    HourBucket[] buckets = hourly([fact("O1", "R-1", "DELIVERED", 100.0, "D-1", 10 * 60 * MINUTE)], 2);
    test:assertEquals(buckets.length(), 24);
    test:assertEquals(buckets[12].orders, 1); // 10:00 UTC = 12:00 in Windhoek
    test:assertEquals(buckets[12].revenue, 100.0);
}

@test:Config {}
function emptyInputsAreSafe() {
    Overview o = overview([], 45);
    test:assertEquals(o.totalOrders, 0);
    test:assertEquals(o.avgOrderValue, 0.0);
    test:assertEquals(restaurantStats([]).length(), 0);
}
