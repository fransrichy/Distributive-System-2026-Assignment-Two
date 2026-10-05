import delivery_service.domain;

import ballerina/lang.runtime;
import ballerina/log;
import ballerinax/mongodb;

final readonly & string[] ACTIVE_STATUSES = ["ASSIGNED", "AT_RESTAURANT", "PICKED_UP"];

function isPeakNow() returns boolean {
    int secondsOfDay = (nowMs() / 1000 + TZ_OFFSET_HOURS * 3600) % 86400;
    return domain:isPeakTime(secondsOfDay / 3600, (secondsOfDay % 3600) / 60);
}

# Wall-clock seconds the simulated driver needs for `km` kilometres.
function simSeconds(float km) returns int =>
    <int>float:ceiling(km / (DRIVER_SPEED_KMH * SIM_SPEED_FACTOR) * 3600.0);

# Assigns the driver with the fastest optimised route to the restaurant.
#
# Concurrency safety: the driver is claimed with a compare-and-set on `status: AVAILABLE`,
# and the delivery with a compare-and-set on `status: PENDING_ASSIGNMENT`; a lost race on
# either side is rolled back, so a driver can never be double-booked.
#
# + return - true if a driver was assigned
function tryAssign(Delivery delivery) returns boolean|error {
    Driver[] available = check findDrivers({status: "AVAILABLE"});
    if available.length() == 0 {
        return false;
    }
    boolean peak = isPeakNow();
    domain:RankedDriver[] ranked = domain:rankDrivers(
            from Driver d in available select {driverId: d.driverId, location: d.location}, delivery.pickup, peak);
    foreach domain:RankedDriver candidate in ranked {
        mongodb:UpdateResult claimed = check driversCol->updateOne({driverId: candidate.driverId, status: "AVAILABLE"},
            {set: {status: "BUSY", currentDeliveryId: delivery.deliveryId, updatedAt: nowIso(), updatedAtMs: nowMs()}});
        if claimed.modifiedCount == 0 {
            continue; // someone else claimed this driver - try the next fastest
        }
        Driver? driver = check findDriver(candidate.driverId);
        if driver is () {
            continue;
        }
        domain:RoutePlan toRestaurant = candidate.route;
        domain:RoutePlan toCustomer = domain:planRoute(delivery.pickup, delivery.dropoff, peak);
        int etaSeconds = simSeconds(toRestaurant.distanceKm);
        mongodb:UpdateResult assigned = check deliveriesCol->updateOne(
            {deliveryId: delivery.deliveryId, status: "PENDING_ASSIGNMENT"}, {
                set: {
                    status: "ASSIGNED",
                    driverId: driver.driverId,
                    driverName: driver.name,
                    leg: "TO_RESTAURANT",
                    route: toRestaurant.path.toJson(),
                    routeDistanceKm: toRestaurant.distanceKm,
                    routeDurationMinutes: toRestaurant.durationMinutes,
                    progressKm: 0.0,
                    currentLocation: driver.location.toJson(),
                    etaSeconds,
                    assignedAtMs: nowMs(),
                    updatedAt: nowIso()
                }
            });
        if assigned.modifiedCount == 0 {
            check releaseDriver(driver.driverId, 0.0, 0.0, false); // delivery was cancelled meanwhile
            return false;
        }
        int totalEtaSeconds = etaSeconds + simSeconds(toCustomer.distanceKm);
        emit(TOPIC_DELIVERY_ASSIGNED, "DeliveryAssigned", delivery.orderId, <DeliveryEvent>{
            deliveryId: delivery.deliveryId,
            orderId: delivery.orderId,
            customerId: delivery.customerId,
            restaurantId: delivery.restaurantId,
            driverId: driver.driverId,
            driverName: driver.name,
            vehicle: driver.vehicle,
            etaMinutes: <int>float:ceiling(<float>totalEtaSeconds / 60.0),
            routeDistanceKm: domain:roundTo2(toRestaurant.distanceKm + toCustomer.distanceKm),
            travelledKm: (),
            durationSeconds: (),
            algorithm: toRestaurant.algorithm,
            at: nowIso()
        });
        incCounter("fd_deliveries_total", "Delivery lifecycle events", {status: "ASSIGNED"});
        log:printInfo("driver assigned", orderId = delivery.orderId, driver = driver.name,
                pickupKm = toRestaurant.distanceKm, peak = peak);
        return true;
    }
    return false;
}

function releaseDriver(string driverId, float distanceKm, float earnings, boolean completed) returns error? {
    mongodb:UpdateResult _ = check driversCol->updateOne({driverId}, {
        set: {status: "AVAILABLE", currentDeliveryId: (), updatedAt: nowIso(), updatedAtMs: nowMs()},
        inc: {completedDeliveries: completed ? 1 : 0, totalDistanceKm: distanceKm, earnings}
    });
}

# Driver collects the food: switch to the optimised route to the customer.
#
# + return - the updated delivery, or an error message when not allowed
function pickup(Delivery delivery) returns Delivery|string|error {
    if delivery.status != "ASSIGNED" && delivery.status != "AT_RESTAURANT" {
        return string `Delivery is ${delivery.status}`;
    }
    if !delivery.foodReady {
        return "The restaurant has not marked the food as ready yet";
    }
    domain:RoutePlan toCustomer = domain:planRoute(delivery.pickup, delivery.dropoff, isPeakNow());
    int etaSeconds = simSeconds(toCustomer.distanceKm);
    // If the driver had not reached the restaurant yet (manual pickup) count the full first leg.
    float firstLeg = delivery.routeDistanceKm;
    mongodb:UpdateResult result = check deliveriesCol->updateOne(
        {deliveryId: delivery.deliveryId, status: delivery.status}, {
            set: {
                status: "PICKED_UP",
                leg: "TO_CUSTOMER",
                route: toCustomer.path.toJson(),
                routeDistanceKm: toCustomer.distanceKm,
                routeDurationMinutes: toCustomer.durationMinutes,
                progressKm: 0.0,
                currentLocation: delivery.pickup.toJson(),
                travelledKm: domain:roundTo2(firstLeg),
                etaSeconds,
                pickedUpAtMs: nowMs(),
                updatedAt: nowIso()
            }
        });
    if result.modifiedCount == 0 {
        return "Delivery changed state concurrently";
    }
    emit(TOPIC_DELIVERY_PICKED_UP, "DeliveryPickedUp", delivery.orderId, <DeliveryEvent>{
        deliveryId: delivery.deliveryId,
        orderId: delivery.orderId,
        customerId: delivery.customerId,
        restaurantId: delivery.restaurantId,
        driverId: delivery.driverId,
        driverName: delivery.driverName,
        vehicle: (),
        etaMinutes: <int>float:ceiling(<float>etaSeconds / 60.0),
        routeDistanceKm: toCustomer.distanceKm,
        travelledKm: (),
        durationSeconds: (),
        algorithm: toCustomer.algorithm,
        at: nowIso()
    });
    incCounter("fd_deliveries_total", "Delivery lifecycle events", {status: "PICKED_UP"});
    log:printInfo("order picked up", orderId = delivery.orderId, driver = delivery.driverName);
    return check findDelivery({deliveryId: delivery.deliveryId}) ?: delivery;
}

# Driver hands over the food: delivery DELIVERED and the driver becomes available again.
#
# + return - the updated delivery, or an error message when not allowed
function complete(Delivery delivery) returns Delivery|string|error {
    if delivery.status != "PICKED_UP" {
        return string `Delivery is ${delivery.status}, it must be PICKED_UP first`;
    }
    int now = nowMs();
    float travelled = domain:roundTo2(delivery.travelledKm + delivery.routeDistanceKm);
    mongodb:UpdateResult result = check deliveriesCol->updateOne(
        {deliveryId: delivery.deliveryId, status: "PICKED_UP"}, {
            set: {
                status: "DELIVERED",
                progressKm: delivery.routeDistanceKm,
                currentLocation: delivery.dropoff.toJson(),
                travelledKm: travelled,
                etaSeconds: 0,
                deliveredAtMs: now,
                updatedAt: nowIso()
            }
        });
    if result.modifiedCount == 0 {
        return "Delivery changed state concurrently";
    }
    string? driverId = delivery.driverId;
    if driverId is string {
        check releaseDriver(driverId, travelled, domain:roundTo2(delivery.deliveryFee * DRIVER_FEE_SHARE), true);
        mongodb:UpdateResult _ = check driversCol->updateOne({driverId}, {set: {location: delivery.dropoff.toJson()}});
    }
    int? assignedAt = delivery.assignedAtMs;
    emit(TOPIC_DELIVERY_COMPLETED, "DeliveryCompleted", delivery.orderId, <DeliveryEvent>{
        deliveryId: delivery.deliveryId,
        orderId: delivery.orderId,
        customerId: delivery.customerId,
        restaurantId: delivery.restaurantId,
        driverId: delivery.driverId,
        driverName: delivery.driverName,
        vehicle: (),
        etaMinutes: 0,
        routeDistanceKm: (),
        travelledKm: travelled,
        durationSeconds: assignedAt is int ? (now - assignedAt) / 1000 : (),
        algorithm: (),
        at: nowIso()
    });
    incCounter("fd_deliveries_total", "Delivery lifecycle events", {status: "DELIVERED"});
    log:printInfo("order delivered", orderId = delivery.orderId, driver = delivery.driverName, km = travelled);
    return check findDelivery({deliveryId: delivery.deliveryId}) ?: delivery;
}

// ---------------------------------------------------------------------------
// Driver location simulation (real-time coordinate updates for the map overlay)
// ---------------------------------------------------------------------------

function simulationLoop() {
    log:printInfo("driver simulation enabled", autoDrive = AUTO_DRIVE, speedKmh = DRIVER_SPEED_KMH,
            speedFactor = SIM_SPEED_FACTOR);
    while true {
        error? result = simulationTick();
        if result is error {
            log:printWarn("simulation tick failed", reason = result.message());
        }
        runtime:sleep(TICK_SECONDS);
    }
}

function simulationTick() returns error? {
    // 1. Retry deliveries that are waiting for a free driver
    foreach Delivery pending in check findDeliveries({status: "PENDING_ASSIGNMENT"}) {
        _ = check tryAssign(pending);
    }
    // 2. Move drivers that are en route
    float stepKm = DRIVER_SPEED_KMH * SIM_SPEED_FACTOR * <float>TICK_SECONDS / 3600.0;
    foreach Delivery d in check findDeliveries({status: {"$in": ["ASSIGNED", "PICKED_UP"]}}) {
        check moveDriver(d, stepKm);
    }
    // 3. Drivers waiting at the restaurant collect food as soon as it is ready
    if AUTO_DRIVE {
        foreach Delivery d in check findDeliveries({status: "AT_RESTAURANT", foodReady: true}) {
            _ = check pickup(d);
        }
    }
    setGauge("fd_active_deliveries", "Deliveries currently in progress",
            <float>check countIn(deliveriesCol, {status: {"$in": ACTIVE_STATUSES}}));
}

function moveDriver(Delivery d, float stepKm) returns error? {
    if d.progressKm >= d.routeDistanceKm {
        check arrive(d);
        return;
    }
    float progress = float:min(d.routeDistanceKm, d.progressKm + stepKm);
    GeoPoint position = domain:pointAlong(d.route, progress);
    int etaSeconds = simSeconds(d.routeDistanceKm - progress);
    mongodb:UpdateResult result = check deliveriesCol->updateOne({deliveryId: d.deliveryId, status: d.status},
        {set: {progressKm: progress, currentLocation: position.toJson(), etaSeconds, updatedAt: nowIso()}});
    if result.modifiedCount == 0 {
        return;
    }
    string? driverId = d.driverId;
    if driverId is string {
        mongodb:UpdateResult _ = check driversCol->updateOne({driverId},
            {set: {location: position.toJson(), updatedAt: nowIso(), updatedAtMs: nowMs()}});
        emit(TOPIC_DELIVERY_LOCATION, "DriverLocationUpdated", driverId, <LocationEvent>{
            driverId,
            deliveryId: d.deliveryId,
            orderId: d.orderId,
            lat: position.lat,
            lon: position.lon,
            leg: d.leg,
            progressPct: d.routeDistanceKm > 0.0 ? <int>(progress / d.routeDistanceKm * 100.0) : 100,
            etaSeconds,
            at: nowIso()
        });
    }
    if progress >= d.routeDistanceKm {
        Delivery arrived = d.clone();
        arrived.progressKm = progress;
        check arrive(arrived);
    }
}

function arrive(Delivery d) returns error? {
    if d.status == "ASSIGNED" {
        mongodb:UpdateResult _ = check deliveriesCol->updateOne({deliveryId: d.deliveryId, status: "ASSIGNED"},
            {set: {status: "AT_RESTAURANT", etaSeconds: 0, currentLocation: d.pickup.toJson(), updatedAt: nowIso()}});
        log:printInfo("driver arrived at restaurant", orderId = d.orderId, driver = d.driverName);
    } else if d.status == "PICKED_UP" && AUTO_DRIVE {
        _ = check complete(d);
    }
}
