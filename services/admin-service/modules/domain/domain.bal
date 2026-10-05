// Pure reporting logic of the Admin service. Reports are computed from `OrderFact`
// documents - a denormalised read model built from the platform's Kafka events.

# One row per order, built from order, payment and delivery events.
public type OrderFact record {|
    string orderId;
    string customerId;
    string restaurantId;
    string restaurantName;
    string? driverId;
    string? driverName;
    string status;
    float subtotal;
    float deliveryFee;
    float total;
    float surgeMultiplier;
    int itemCount;
    float? distanceKm;
    int createdAtMs;
    int? confirmedAtMs;
    int? preparingAtMs;
    int? readyAtMs;
    int? outForDeliveryAtMs;
    int? deliveredAtMs;
    int? cancelledAtMs;
    string? cancelReason;
    boolean paymentFailed;
    boolean refunded;
    int updatedAtMs;
|};

public type Overview record {|
    int totalOrders;
    int activeOrders;
    int delivered;
    int cancelled;
    float cancellationRate;
    float grossMerchandiseValue;
    float deliveryFeeRevenue;
    float avgOrderValue;
    float avgPrepMinutes;
    float avgTransitMinutes;
    float avgFulfilmentMinutes;
    float onTimeRate;
    int onTimeTargetMinutes;
    float avgSurgeMultiplier;
    int surgedOrders;
    int paymentFailures;
    int refunds;
|};

public type RestaurantStats record {|
    string restaurantId;
    string restaurantName;
    int orders;
    int delivered;
    int cancelled;
    float revenue;
    float avgOrderValue;
    float avgPrepMinutes;
    float cancellationRate;
    int itemsSold;
|};

public type DriverStats record {|
    string driverId;
    string driverName;
    int deliveries;
    int inProgress;
    float totalDistanceKm;
    float avgTransitMinutes;
    float avgPickupToDoorKm;
    float deliveryFeesEarned;
|};

public type HourBucket record {|
    int hour;
    int orders;
    float revenue;
|};

final readonly & string[] TERMINAL = ["DELIVERED", "CANCELLED"];

public isolated function overview(OrderFact[] facts, int onTimeTargetMinutes) returns Overview {
    OrderFact[] delivered = facts.filter(f => f.status == "DELIVERED");
    int cancelled = facts.filter(f => f.status == "CANCELLED").length();
    int active = facts.filter(f => TERMINAL.indexOf(f.status) is ()).length();
    float gmv = sum(from OrderFact f in delivered select f.total);
    float[] fulfilment = durations(delivered, f => f.createdAtMs, f => f.deliveredAtMs);
    int onTime = fulfilment.filter(m => m <= <float>onTimeTargetMinutes).length();
    int closed = delivered.length() + cancelled;
    return {
        totalOrders: facts.length(),
        activeOrders: active,
        delivered: delivered.length(),
        cancelled,
        cancellationRate: ratio(cancelled, closed),
        grossMerchandiseValue: round2(gmv),
        deliveryFeeRevenue: round2(sum(from OrderFact f in delivered select f.deliveryFee)),
        avgOrderValue: delivered.length() == 0 ? 0.0 : round2(gmv / <float>delivered.length()),
        avgPrepMinutes: average(durations(facts, f => f.confirmedAtMs, f => f.readyAtMs)),
        avgTransitMinutes: average(durations(delivered, f => f.outForDeliveryAtMs, f => f.deliveredAtMs)),
        avgFulfilmentMinutes: average(fulfilment),
        onTimeRate: ratio(onTime, fulfilment.length()),
        onTimeTargetMinutes,
        avgSurgeMultiplier: facts.length() == 0 ? 1.0 : round2(sum(from OrderFact f in facts select f.surgeMultiplier)
            / <float>facts.length()),
        surgedOrders: facts.filter(f => f.surgeMultiplier > 1.0).length(),
        paymentFailures: facts.filter(f => f.paymentFailed).length(),
        refunds: facts.filter(f => f.refunded).length()
    };
}

# Restaurant leaderboard, ordered by revenue.
public isolated function restaurantStats(OrderFact[] facts) returns RestaurantStats[] {
    map<OrderFact[]> byRestaurant = {};
    foreach OrderFact f in facts {
        OrderFact[] group = byRestaurant[f.restaurantId] ?: [];
        group.push(f);
        byRestaurant[f.restaurantId] = group;
    }
    RestaurantStats[] stats = [];
    foreach [string, OrderFact[]] [restaurantId, group] in byRestaurant.entries() {
        OrderFact[] delivered = group.filter(f => f.status == "DELIVERED");
        int cancelled = group.filter(f => f.status == "CANCELLED").length();
        float revenue = sum(from OrderFact f in delivered select f.subtotal);
        stats.push({
            restaurantId,
            restaurantName: group[0].restaurantName,
            orders: group.length(),
            delivered: delivered.length(),
            cancelled,
            revenue: round2(revenue),
            avgOrderValue: delivered.length() == 0 ? 0.0 : round2(revenue / <float>delivered.length()),
            avgPrepMinutes: average(durations(group, f => f.confirmedAtMs, f => f.readyAtMs)),
            cancellationRate: ratio(cancelled, delivered.length() + cancelled),
            itemsSold: int:sum(...from OrderFact f in delivered select f.itemCount)
        });
    }
    return from RestaurantStats s in stats order by s.revenue descending, s.orders descending select s;
}

# Delivery performance per driver, ordered by completed deliveries.
public isolated function driverStats(OrderFact[] facts) returns DriverStats[] {
    map<OrderFact[]> byDriver = {};
    foreach OrderFact f in facts {
        string? driverId = f.driverId;
        if driverId is string {
            OrderFact[] group = byDriver[driverId] ?: [];
            group.push(f);
            byDriver[driverId] = group;
        }
    }
    DriverStats[] stats = [];
    foreach [string, OrderFact[]] [driverId, group] in byDriver.entries() {
        OrderFact[] delivered = group.filter(f => f.status == "DELIVERED");
        float distance = sum(from OrderFact f in delivered select f.distanceKm ?: 0.0);
        stats.push({
            driverId,
            driverName: group[0].driverName ?: driverId,
            deliveries: delivered.length(),
            inProgress: group.filter(f => TERMINAL.indexOf(f.status) is ()).length(),
            totalDistanceKm: round2(distance),
            avgTransitMinutes: average(durations(delivered, f => f.outForDeliveryAtMs, f => f.deliveredAtMs)),
            avgPickupToDoorKm: delivered.length() == 0 ? 0.0 : round2(distance / <float>delivered.length()),
            deliveryFeesEarned: round2(sum(from OrderFact f in delivered select f.deliveryFee))
        });
    }
    return from DriverStats s in stats order by s.deliveries descending, s.totalDistanceKm descending select s;
}

# Orders per local hour of day (demand curve used to tune surge pricing).
public isolated function hourly(OrderFact[] facts, int tzOffsetHours) returns HourBucket[] {
    HourBucket[] buckets = from int h in 0 ..< 24 select {hour: h, orders: 0, revenue: 0.0};
    foreach OrderFact f in facts {
        int hour = ((f.createdAtMs / 1000 + tzOffsetHours * 3600) % 86400) / 3600;
        buckets[hour].orders += 1;
        if f.status == "DELIVERED" {
            buckets[hour].revenue = round2(buckets[hour].revenue + f.total);
        }
    }
    return buckets;
}

// ---- helpers ----

type Timestamp isolated function (OrderFact) returns int?;

isolated function durations(OrderFact[] facts, Timestamp startOf, Timestamp endOf) returns float[] {
    float[] minutes = [];
    foreach OrderFact f in facts {
        int? 'start = startOf(f);
        int? end = endOf(f);
        if 'start is int && end is int && end >= 'start {
            minutes.push(<float>(end - 'start) / 60000.0);
        }
    }
    return minutes;
}

public isolated function average(float[] values) returns float =>
    values.length() == 0 ? 0.0 : round2(sum(values) / <float>values.length());

isolated function sum(float[] values) returns float {
    float total = 0.0;
    foreach float v in values {
        total += v;
    }
    return total;
}

isolated function ratio(int part, int whole) returns float =>
    whole == 0 ? 0.0 : round2(<float>part / <float>whole);

public isolated function round2(float value) returns float => float:round(value * 100.0) / 100.0;
