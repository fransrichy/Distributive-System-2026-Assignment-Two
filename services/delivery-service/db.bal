import ballerina/log;
import ballerinax/mongodb;

final mongodb:Collection driversCol = check getCollection("drivers");
final mongodb:Collection deliveriesCol = check getCollection("deliveries");

function init() {
    if SEED_DATA {
        error? seeded = seedDrivers();
        if seeded is error {
            log:printError("driver seeding failed", seeded);
        }
    }
    if SIMULATION_ENABLED {
        _ = start simulationLoop();
    }
}

function findDriver(string driverId) returns Driver|error? {
    return driversCol->findOne({driverId}, {}, NO_ID, Driver);
}

function findDrivers(map<json> filter) returns Driver[]|error {
    stream<Driver, error?> results = check driversCol->find(filter, {sort: {"name": 1}}, NO_ID, Driver);
    Driver[] drivers = check from Driver d in results select d;
    check results.close();
    return drivers;
}

function findDelivery(map<json> filter) returns Delivery|error? {
    return deliveriesCol->findOne(filter, {}, NO_ID, Delivery);
}

function findDeliveries(map<json> filter, int 'limit = 100) returns Delivery[]|error {
    stream<Delivery, error?> results = check deliveriesCol->find(filter, {sort: {"createdAtMs": -1}, 'limit},
        NO_ID, Delivery);
    Delivery[] deliveries = check from Delivery d in results select d;
    check results.close();
    return deliveries;
}

function seedDrivers() returns error? {
    int existing = check driversCol->countDocuments({});
    if existing > 0 {
        return;
    }
    string now = nowIso();
    int nowMillis = nowMs();
    [string, string, string, string, float, float, float][] seed = [
        ["D-2001", "Tangeni Nghifikwa", "+264814000001", "Motorbike", -22.5600, 17.0700, 4.9],
        ["D-2002", "Maria Gomes", "+264814000002", "Scooter", -22.5820, 17.0900, 4.7],
        ["D-2003", "Johannes Hamutenya", "+264814000003", "Car", -22.5350, 17.0600, 4.8],
        ["D-2004", "Selma Amupolo", "+264814000004", "Motorbike", -22.5650, 17.1050, 4.6],
        ["D-2005", "Petrus Kandjii", "+264814000005", "Bicycle", -22.5720, 17.0820, 4.5]
    ];
    Driver[] drivers = from var [driverId, name, phone, vehicle, lat, lon, rating] in seed
        select {
            driverId, name, phone, vehicle, status: "AVAILABLE", location: {lat, lon}, rating,
            currentDeliveryId: (), completedDeliveries: 0, totalDistanceKm: 0.0, earnings: 0.0,
            updatedAt: now, updatedAtMs: nowMillis
        };
    check driversCol->insertMany(drivers);
    log:printInfo("seeded drivers", count = drivers.length());
}
