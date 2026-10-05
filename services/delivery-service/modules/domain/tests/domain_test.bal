import ballerina/test;

final GeoPoint CBD = {lat: -22.5700, lon: 17.0836};
final GeoPoint KATUTURA = {lat: -22.5290, lon: 17.0530};
final GeoPoint OLYMPIA = {lat: -22.5925, lon: 17.0915};

@test:Config {}
function routeConnectsStartAndDestination() {
    RoutePlan plan = planRoute(KATUTURA, OLYMPIA, false);
    test:assertEquals(plan.path[0], KATUTURA);
    test:assertEquals(plan.path[plan.path.length() - 1], OLYMPIA);
    test:assertTrue(plan.distanceKm >= haversineKm(KATUTURA, OLYMPIA), "route cannot be shorter than a straight line");
    test:assertTrue(plan.durationMinutes > 0.0);
}

@test:Config {}
function consecutiveRoutePointsFollowTheGrid() {
    RoutePlan plan = planRoute(KATUTURA, OLYMPIA, false);
    // Inner points are grid intersections: each hop changes either lat or lon, never both
    foreach int i in 2 ..< plan.path.length() - 1 {
        GeoPoint a = plan.path[i - 1];
        GeoPoint b = plan.path[i];
        test:assertTrue(a.lat == b.lat || a.lon == b.lon, "diagonal hop in route");
    }
}

@test:Config {}
function aStarPrefersFastArterialRoads() {
    // Travel time can never beat the straight line at arterial speed (admissible heuristic)
    RoutePlan plan = planRoute(nodePoint(0), nodePoint(80), false);
    float lowerBound = haversineKm(nodePoint(0), nodePoint(80)) / 60.0 * 60.0;
    test:assertTrue(plan.durationMinutes >= lowerBound);
    // ...and should be faster than driving the same distance on local roads only
    test:assertTrue(plan.durationMinutes < plan.distanceKm / 35.0 * 60.0);
}

@test:Config {}
function peakHourCongestionNeverMakesRoutesFaster() {
    RoutePlan offPeak = planRoute(KATUTURA, OLYMPIA, false);
    RoutePlan peak = planRoute(KATUTURA, OLYMPIA, true);
    test:assertTrue(peak.durationMinutes >= offPeak.durationMinutes);
}

@test:Config {}
function samePointRouteIsTrivial() {
    RoutePlan plan = planRoute(CBD, CBD, false);
    test:assertTrue(plan.distanceKm < 1.0);
}

@test:Config {}
function closestDriverWins() {
    RankedDriver[] ranked = rankDrivers([
        {driverId: "far", location: KATUTURA},
        {driverId: "near", location: {lat: -22.5710, lon: 17.0850}}
    ], CBD, false);
    test:assertEquals(ranked[0].driverId, "near");
    test:assertEquals(ranked.length(), 2);
}

@test:Config {}
function pointAlongInterpolatesAndClamps() {
    GeoPoint[] line = [{lat: 0.0, lon: 0.0}, {lat: 0.0, lon: 1.0}];
    float total = polylineLengthKm(line);
    GeoPoint middle = pointAlong(line, total / 2.0);
    test:assertTrue(middle.lon > 0.49 && middle.lon < 0.51);
    test:assertEquals(pointAlong(line, total * 2.0), line[1]);
    test:assertEquals(pointAlong(line, 0.0), line[0]);
}

@test:Config {}
function networkHasAllGridSegments() {
    // 9x9 grid: 2 * 9 * 8 = 144 segments
    test:assertEquals(roadNetwork(false).length(), 144);
    test:assertTrue(roadNetwork(true).some(s => s.congested));
}

@test:Config {}
function nearestNodeSnapsAndClamps() {
    test:assertEquals(nearestNode({lat: -22.60, lon: 17.04}), 0);
    test:assertEquals(nearestNode({lat: -30.0, lon: 10.0}), 0);
    test:assertEquals(nearestNode({lat: -22.52, lon: 17.12}), 80);
}
