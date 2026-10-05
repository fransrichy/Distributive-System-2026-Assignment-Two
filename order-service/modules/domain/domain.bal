// Pure domain logic of the Order service: the order state machine and the
// surge-pricing model. No I/O lives here, which keeps it fully unit-testable.

// ---------------------------------------------------------------------------
// Order lifecycle state machine
//   CREATED -> CONFIRMED -> PREPARING -> READY -> OUT_FOR_DELIVERY -> DELIVERED
//   CREATED | CONFIRMED -> CANCELLED
// ---------------------------------------------------------------------------

public const CREATED = "CREATED";
public const CONFIRMED = "CONFIRMED";
public const PREPARING = "PREPARING";
public const READY = "READY";
public const OUT_FOR_DELIVERY = "OUT_FOR_DELIVERY";
public const DELIVERED = "DELIVERED";
public const CANCELLED = "CANCELLED";

public type OrderStatus CREATED|CONFIRMED|PREPARING|READY|OUT_FOR_DELIVERY|DELIVERED|CANCELLED;

final readonly & OrderStatus[] HAPPY_PATH = [CREATED, CONFIRMED, PREPARING, READY, OUT_FOR_DELIVERY, DELIVERED];

# Single-step transitions that the platform allows.
public final readonly & map<OrderStatus[]> TRANSITIONS = {
    "CREATED": [CONFIRMED, CANCELLED],
    "CONFIRMED": [PREPARING, CANCELLED],
    "PREPARING": [READY],
    "READY": [OUT_FOR_DELIVERY],
    "OUT_FOR_DELIVERY": [DELIVERED],
    "DELIVERED": [],
    "CANCELLED": []
};

# Position of a status on the happy path (`-1` for CANCELLED).
public isolated function rank(OrderStatus status) returns int {
    int? index = HAPPY_PATH.indexOf(status);
    return index ?: -1;
}

public isolated function isTerminal(OrderStatus status) returns boolean => status == DELIVERED || status == CANCELLED;

public isolated function canTransition(OrderStatus fromStatus, OrderStatus toStatus) returns boolean {
    OrderStatus[] allowed = TRANSITIONS[fromStatus] ?: [];
    return allowed.indexOf(toStatus) != ();
}

# Plans the steps needed to move an order from `current` to `target`.
#
# Events arrive on different topics, so they may be observed out of order (e.g. a
# `delivery.picked-up` before `restaurant.order-ready`). Forward targets are reached by
# walking the happy path, which keeps the recorded history complete. Duplicate, stale
# or illegal events yield an empty plan and are ignored - this makes every consumer
# idempotent.
#
# + current - the status currently stored
# + target - the status implied by the incoming event or command
# + return - ordered list of statuses to apply (empty = ignore)
public isolated function planTransition(OrderStatus current, OrderStatus target) returns OrderStatus[] {
    if current == target || isTerminal(current) {
        return [];
    }
    if target == CANCELLED {
        return canTransition(current, CANCELLED) ? [CANCELLED] : [];
    }
    int fromRank = rank(current);
    int toRank = rank(target);
    if toRank <= fromRank {
        return [];
    }
    OrderStatus[] steps = [];
    foreach int i in fromRank + 1 ... toRank {
        steps.push(HAPPY_PATH[i]);
    }
    return steps;
}

# Customers may cancel only before the kitchen starts cooking.
public isolated function customerCanCancel(OrderStatus status) returns boolean =>
    status == CREATED || status == CONFIRMED;

// ---------------------------------------------------------------------------
// Pricing: distance based delivery fee with surge multiplier
// ---------------------------------------------------------------------------

public const float BASE_DELIVERY_FEE = 15.0;
public const float FEE_PER_KM = 4.0;
public const float MAX_SURGE = 2.5;
const float ROAD_DETOUR_FACTOR = 1.3;

public type SurgeInput record {|
    # Orders placed during the demand window (last 10 minutes)
    int recentOrders;
    # Drivers currently AVAILABLE
    int availableDrivers;
    # Drivers currently BUSY
    int busyDrivers;
    # False when the Delivery service could not be reached
    boolean driverDataAvailable;
    # Local (Africa/Windhoek) time of day
    int localHour;
    int localMinute;
|};

public type SurgeQuote record {|
    float multiplier;
    string level;
    string[] reasons;
|};

# Dynamic pricing model based on demand, driver supply and peak meal times.
public isolated function calculateSurge(SurgeInput input) returns SurgeQuote {
    float multiplier = 1.0;
    string[] reasons = [];
    if input.driverDataAvailable {
        if input.availableDrivers == 0 {
            multiplier += 0.5;
            reasons.push("No drivers available right now");
        } else {
            float demandRatio = <float>input.recentOrders / <float>input.availableDrivers;
            if demandRatio > 1.5 {
                float extra = float:min(0.8, (demandRatio - 1.5) * 0.25);
                multiplier += extra;
                reasons.push(string `High demand: ${input.recentOrders} orders for ${input.availableDrivers} drivers`);
            }
        }
        int totalDrivers = input.availableDrivers + input.busyDrivers;
        if totalDrivers > 0 && <float>input.busyDrivers / <float>totalDrivers >= 0.75 {
            multiplier += 0.2;
            reasons.push("Most drivers are busy");
        }
    }
    if isPeakTime(input.localHour, input.localMinute) {
        multiplier += 0.2;
        reasons.push("Peak meal time");
    }
    multiplier = float:min(MAX_SURGE, roundTo2(multiplier));
    return {multiplier, level: surgeLevel(multiplier), reasons};
}

public isolated function isPeakTime(int hour, int minute) returns boolean {
    int minutes = hour * 60 + minute;
    boolean lunch = minutes >= 11 * 60 + 30 && minutes < 14 * 60;
    boolean dinner = minutes >= 17 * 60 + 30 && minutes < 20 * 60 + 30;
    return lunch || dinner;
}

public isolated function surgeLevel(float multiplier) returns string {
    if multiplier <= 1.0 {
        return "NORMAL";
    } else if multiplier < 1.5 {
        return "MODERATE";
    } else if multiplier < 2.0 {
        return "HIGH";
    }
    return "EXTREME";
}

public isolated function deliveryFee(float distanceKm, float surge) returns float =>
    roundTo2((BASE_DELIVERY_FEE + FEE_PER_KM * distanceKm) * surge);

# Great-circle distance between two coordinates in kilometres.
public isolated function haversineKm(float lat1, float lon1, float lat2, float lon2) returns float {
    float earthRadiusKm = 6371.0;
    float dLat = toRadians(lat2 - lat1);
    float dLon = toRadians(lon2 - lon1);
    float a = float:sin(dLat / 2.0) * float:sin(dLat / 2.0) +
        float:cos(toRadians(lat1)) * float:cos(toRadians(lat2)) * float:sin(dLon / 2.0) * float:sin(dLon / 2.0);
    return earthRadiusKm * 2.0 * float:atan2(float:sqrt(a), float:sqrt(1.0 - a));
}

# Road distance estimate used for quoting before the Delivery service plans the real route.
public isolated function estimateRoadKm(float lat1, float lon1, float lat2, float lon2) returns float =>
    roundTo2(haversineKm(lat1, lon1, lat2, lon2) * ROAD_DETOUR_FACTOR);

public isolated function roundTo2(float value) returns float => float:round(value * 100.0) / 100.0;

isolated function toRadians(float degrees) returns float => degrees * float:PI / 180.0;
