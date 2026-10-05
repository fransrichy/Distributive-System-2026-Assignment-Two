import admin_service.domain;

import ballerina/http;

type ServiceHealth record {|
    string 'service;
    string url;
    string status;
    int latencyMs;
    string? detail;
|};

type DeliveryReport record {|
    domain:DriverStats[] drivers;
    int delivered;
    float avgTransitMinutes;
    float avgFulfilmentMinutes;
    float onTimeRate;
    int onTimeTargetMinutes;
|};

@http:ServiceConfig {cors: CORS}
service /reports on httpListener {

    # Platform KPIs: volumes, revenue, timings, on-time rate, surge, payment failures.
    resource function get overview() returns domain:Overview|error {
        domain:Overview result = domain:overview(check loadFacts(), ON_TIME_TARGET_MINUTES);
        setGauge("fd_gmv_nad", "Gross merchandise value of delivered orders", result.grossMerchandiseValue);
        setGauge("fd_on_time_rate", "Share of deliveries within the delivery promise", result.onTimeRate);
        setGauge("fd_avg_fulfilment_minutes", "Average order-to-door minutes", result.avgFulfilmentMinutes);
        return result;
    }

    # Restaurant statistics (leaderboard by revenue).
    resource function get restaurants() returns domain:RestaurantStats[]|error =>
        domain:restaurantStats(check loadFacts());

    # Delivery performance per driver.
    resource function get deliveries() returns DeliveryReport|error {
        domain:OrderFact[] facts = check loadFacts();
        domain:Overview totals = domain:overview(facts, ON_TIME_TARGET_MINUTES);
        return {
            drivers: domain:driverStats(facts),
            delivered: totals.delivered,
            avgTransitMinutes: totals.avgTransitMinutes,
            avgFulfilmentMinutes: totals.avgFulfilmentMinutes,
            onTimeRate: totals.onTimeRate,
            onTimeTargetMinutes: ON_TIME_TARGET_MINUTES
        };
    }

    # Demand per local hour of day.
    resource function get hourly() returns domain:HourBucket[]|error =>
        domain:hourly(check loadFacts(), TZ_OFFSET_HOURS);

    # Order facts (the analytics read model), newest first.
    resource function get orders(int 'limit = 50) returns domain:OrderFact[]|error {
        domain:OrderFact[] facts = check loadFacts();
        return facts.length() > 'limit ? facts.slice(0, 'limit) : facts;
    }

    # Number of events seen per Kafka topic.
    resource function get events() returns EventCounter[]|error {
        stream<EventCounter, error?> results = check countersCol->find({}, {sort: {"topic": 1}}, NO_ID, EventCounter);
        EventCounter[] counters = check from EventCounter c in results select c;
        check results.close();
        return counters;
    }

    # Last known position of every driver on the road (live fleet map).
    resource function get fleet() returns FleetPosition[]|error {
        stream<FleetPosition, error?> results = check fleetCol->find({}, {}, NO_ID, FleetPosition);
        FleetPosition[] positions = check from FleetPosition p in results select p;
        check results.close();
        return positions;
    }

    resource function get dead\-letters() returns DeadLetterDoc[]|error {
        stream<DeadLetterDoc, error?> results = check deadLettersCol->find({}, {sort: {"failedAt": -1}, 'limit: 100},
            NO_ID, DeadLetterDoc);
        DeadLetterDoc[] letters = check from DeadLetterDoc d in results select d;
        check results.close();
        return letters;
    }

    # Health of every microservice (service discovery through Docker DNS).
    resource function get system() returns ServiceHealth[] {
        ServiceHealth[] result = [];
        foreach [string, string] [name, url] in SERVICE_URLS.entries() {
            result.push(probe(name, url));
        }
        result.push({'service: SERVICE_NAME, url: "self", status: isDatabaseUp() ? "UP" : "DEGRADED", latencyMs: 0,
            detail: ()});
        return result;
    }
}

function probe(string name, string url) returns ServiceHealth {
    int started = nowMs();
    http:Client|error 'client = new (url, {timeout: 3});
    if 'client is error {
        return {'service: name, url, status: "DOWN", latencyMs: 0, detail: 'client.message()};
    }
    json|error health = 'client->get("/health");
    int latency = nowMs() - started;
    if health is error {
        return {'service: name, url, status: "DOWN", latencyMs: latency, detail: health.message()};
    }
    json|error status = health.status;
    return {'service: name, url, status: status is string ? status : "UNKNOWN", latencyMs: latency, detail: ()};
}
