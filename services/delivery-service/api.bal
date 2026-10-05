import delivery_service.domain;

import ballerina/http;
import ballerinax/mongodb;

@http:ServiceConfig {cors: CORS}
service /drivers on httpListener {

    resource function get .(string? status) returns Driver[]|error =>
        findDrivers(status is string ? {status: status.toUpperAscii()} : {});

    resource function post .(@http:Payload DriverInput input) returns http:Created|error {
        Driver driver = {
            driverId: newId("D"),
            name: input.name,
            phone: input.phone,
            vehicle: input.vehicle,
            status: "OFFLINE",
            location: input.location,
            rating: 5.0,
            currentDeliveryId: (),
            completedDeliveries: 0,
            totalDistanceKm: 0.0,
            earnings: 0.0,
            updatedAt: nowIso(),
            updatedAtMs: nowMs()
        };
        check driversCol->insertOne(driver);
        http:Created created = {body: driver};
        return created;
    }

    # Supply-side snapshot used by the Order service for surge pricing.
    resource function get summary() returns DriverSummary|error {
        DriverSummary summary = {
            available: check countIn(driversCol, {status: "AVAILABLE"}),
            busy: check countIn(driversCol, {status: "BUSY"}),
            offline: check countIn(driversCol, {status: "OFFLINE"}),
            pendingDeliveries: check countIn(deliveriesCol, {status: "PENDING_ASSIGNMENT"}),
            activeDeliveries: check countIn(deliveriesCol, {status: {"$in": ACTIVE_STATUSES}})
        };
        setGauge("fd_drivers", "Drivers by status", <float>summary.available, {status: "AVAILABLE"});
        setGauge("fd_drivers", "Drivers by status", <float>summary.busy, {status: "BUSY"});
        setGauge("fd_drivers", "Drivers by status", <float>summary.offline, {status: "OFFLINE"});
        return summary;
    }

    resource function get [string driverId]() returns Driver|http:NotFound|error {
        Driver? driver = check findDriver(driverId);
        return driver ?: notFound("Driver not found: " + driverId);
    }

    # Driver goes online / offline. A busy driver must finish the delivery first.
    resource function put [string driverId]/status(@http:Payload DriverStatusUpdate update)
            returns Driver|http:NotFound|http:Conflict|error {
        Driver? driver = check findDriver(driverId);
        if driver is () {
            return notFound("Driver not found: " + driverId);
        }
        if driver.status == "BUSY" {
            return conflictError("Driver is on a delivery and cannot change status");
        }
        mongodb:UpdateResult _ = check driversCol->updateOne({driverId, status: {"$ne": "BUSY"}},
            {set: {status: update.status, updatedAt: nowIso(), updatedAtMs: nowMs()}});
        return check findDriver(driverId) ?: notFound("Driver not found: " + driverId);
    }

    # Manual location report (e.g. from a phone GPS).
    resource function put [string driverId]/location(@http:Payload GeoPoint location)
            returns Driver|http:NotFound|error {
        mongodb:UpdateResult result = check driversCol->updateOne({driverId},
            {set: {location: location.toJson(), updatedAt: nowIso(), updatedAtMs: nowMs()}});
        if result.matchedCount == 0 {
            return notFound("Driver not found: " + driverId);
        }
        return check findDriver(driverId) ?: notFound("Driver not found: " + driverId);
    }

    resource function get [string driverId]/deliveries(string? status) returns Delivery[]|error {
        map<json> filter = {driverId};
        if status is string {
            filter["status"] = {"$in": re `,`.split(status.toUpperAscii())};
        }
        return findDeliveries(filter);
    }
}

@http:ServiceConfig {cors: CORS}
service /deliveries on httpListener {

    resource function get .(string? status, string? driverId, int 'limit = 100) returns Delivery[]|error {
        map<json> filter = {};
        if status is string {
            filter["status"] = {"$in": re `,`.split(status.toUpperAscii())};
        }
        if driverId is string {
            filter["driverId"] = driverId;
        }
        return findDeliveries(filter, 'limit);
    }

    resource function get 'order/[string orderId]() returns Delivery|http:NotFound|error {
        Delivery? delivery = check findDelivery({orderId});
        return delivery ?: notFound("No delivery for order " + orderId);
    }

    resource function get [string deliveryId]() returns Delivery|http:NotFound|error {
        Delivery? delivery = check findDelivery({deliveryId});
        return delivery ?: notFound("Delivery not found: " + deliveryId);
    }

    resource function put [string deliveryId]/pickup() returns Delivery|http:NotFound|http:Conflict|error {
        Delivery? delivery = check findDelivery({deliveryId});
        if delivery is () {
            return notFound("Delivery not found: " + deliveryId);
        }
        Delivery|string result = check pickup(delivery);
        return result is string ? conflictError(result) : result;
    }

    resource function put [string deliveryId]/complete() returns Delivery|http:NotFound|http:Conflict|error {
        Delivery? delivery = check findDelivery({deliveryId});
        if delivery is () {
            return notFound("Delivery not found: " + deliveryId);
        }
        Delivery|string result = check complete(delivery);
        return result is string ? conflictError(result) : result;
    }
}

@http:ServiceConfig {cors: CORS}
service /routes on httpListener {

    # Fastest route between two points (A* over the simulated road network).
    resource function get plan(float fromLat, float fromLon, float toLat, float toLon, boolean? peak)
            returns domain:RoutePlan =>
        domain:planRoute({lat: fromLat, lon: fromLon}, {lat: toLat, lon: toLon}, peak ?: isPeakNow());

    # Road network overlay for the map (arterial / local / congested segments).
    resource function get network(boolean? peak) returns domain:RoadSegment[] =>
        domain:roadNetwork(peak ?: isPeakNow());
}
