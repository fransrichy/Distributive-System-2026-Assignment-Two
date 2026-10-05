import delivery_service.domain;

import ballerina/constraint;

public type GeoPoint domain:GeoPoint;

public type DriverStatus "OFFLINE"|"AVAILABLE"|"BUSY";

# Persisted in `delivery_db.drivers`.
public type Driver record {|
    string driverId;
    string name;
    string phone;
    string vehicle;
    DriverStatus status;
    GeoPoint location;
    float rating;
    string? currentDeliveryId;
    int completedDeliveries;
    float totalDistanceKm;
    float earnings;
    string updatedAt;
    int updatedAtMs;
|};

public type DeliveryStatus "PENDING_ASSIGNMENT"|"ASSIGNED"|"AT_RESTAURANT"|"PICKED_UP"|"DELIVERED"|"CANCELLED";

public type Leg "NONE"|"TO_RESTAURANT"|"TO_CUSTOMER";

# Persisted in `delivery_db.deliveries` (one per order).
public type Delivery record {|
    string deliveryId;
    string orderId;
    string customerId;
    string customerName;
    string restaurantId;
    string restaurantName;
    GeoPoint pickup;
    GeoPoint dropoff;
    string dropoffAddress;
    string? driverId;
    string? driverName;
    DeliveryStatus status;
    boolean foodReady;
    Leg leg;
    # Optimised route of the current leg
    GeoPoint[] route;
    float routeDistanceKm;
    float routeDurationMinutes;
    float progressKm;
    GeoPoint? currentLocation;
    int? etaSeconds;
    float travelledKm;
    float deliveryFee;
    string? cancelReason;
    string createdAt;
    int createdAtMs;
    int? assignedAtMs;
    int? pickedUpAtMs;
    int? deliveredAtMs;
    string updatedAt;
|};

public type DriverSummary record {|
    int available;
    int busy;
    int offline;
    int pendingDeliveries;
    int activeDeliveries;
|};

// ---- REST payloads ----

public type DriverInput record {|
    @constraint:String {minLength: 2, maxLength: 80}
    string name;
    string phone;
    string vehicle = "Motorbike";
    GeoPoint location = {lat: -22.5700, lon: 17.0836};
|};

public type DriverStatusUpdate record {|
    "AVAILABLE"|"OFFLINE" status;
|};

// ---- Event payloads ----

type ConfirmedOrderAddress record {
    string street;
    GeoPoint location;
};

type OrderConfirmedEvent record {
    string orderId;
    string customerId;
    string customerName;
    string restaurantId;
    string restaurantName;
    GeoPoint restaurantLocation;
    ConfirmedOrderAddress deliveryAddress;
    float deliveryFee;
};

type OrderReadyEvent record {
    string orderId;
};

type OrderCancelledEvent record {
    string orderId;
    string reason;
};

type DeliveryEvent record {|
    string deliveryId;
    string orderId;
    string customerId;
    string restaurantId;
    string? driverId;
    string? driverName;
    string? vehicle;
    int? etaMinutes;
    float? routeDistanceKm;
    float? travelledKm;
    int? durationSeconds;
    string? algorithm;
    string at;
|};

type LocationEvent record {|
    string driverId;
    string deliveryId;
    string orderId;
    float lat;
    float lon;
    Leg leg;
    int progressPct;
    int? etaSeconds;
    string at;
|};
