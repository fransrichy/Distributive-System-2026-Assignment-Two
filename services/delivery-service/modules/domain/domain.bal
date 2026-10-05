// Pure domain logic of the Delivery service:
//  * a simulated Windhoek road network (grid of arterial and local roads),
//  * A* route optimisation by travel time (with peak-hour congestion in the CBD),
//  * driver ranking by ETA to the restaurant,
//  * polyline geometry used to animate drivers along their route.

public type GeoPoint record {|
    float lat;
    float lon;
|};

public type RoutePlan record {|
    GeoPoint[] path;
    float distanceKm;
    float durationMinutes;
    int nodesExplored;
    string algorithm;
|};

public type RoadSegment record {|
    GeoPoint 'from;
    GeoPoint to;
    boolean arterial;
    boolean congested;
|};

public type Candidate record {|
    string driverId;
    GeoPoint location;
|};

public type RankedDriver record {|
    string driverId;
    RoutePlan route;
|};

// ---- Road network: 9 x 9 grid covering Windhoek (≈ 9 km x 9 km) ----
public const int ROWS = 9;
public const int COLS = 9;
const float ORIGIN_LAT = -22.60;
const float ORIGIN_LON = 17.04;
const float STEP = 0.01;
const float ARTERIAL_KMH = 60.0;
const float LOCAL_KMH = 35.0;
const float OFFROAD_KMH = 20.0;
const float CONGESTION_FACTOR = 0.45;
const float INFINITY = 1.0e18;

final readonly & int[] ARTERIAL_ROWS = [1, 4, 7];
final readonly & int[] ARTERIAL_COLS = [1, 4, 7];

public isolated function nodeCount() returns int => ROWS * COLS;

public isolated function nodePoint(int node) returns GeoPoint {
    int row = node / COLS;
    int col = node % COLS;
    return {lat: roundTo5(ORIGIN_LAT + <float>row * STEP), lon: roundTo5(ORIGIN_LON + <float>col * STEP)};
}

# Index of the road-network node closest to a point.
#
# + point - any coordinate
# + return - node index
public isolated function nearestNode(GeoPoint point) returns int {
    int row = int:max(0, int:min(ROWS - 1, <int>float:round((point.lat - ORIGIN_LAT) / STEP)));
    int col = int:max(0, int:min(COLS - 1, <int>float:round((point.lon - ORIGIN_LON) / STEP)));
    return row * COLS + col;
}

isolated function neighbours(int node) returns int[] {
    int row = node / COLS;
    int col = node % COLS;
    int[] result = [];
    if row > 0 {
        result.push(node - COLS);
    }
    if row < ROWS - 1 {
        result.push(node + COLS);
    }
    if col > 0 {
        result.push(node - 1);
    }
    if col < COLS - 1 {
        result.push(node + 1);
    }
    return result;
}

isolated function isArterial(int a, int b) returns boolean {
    int rowA = a / COLS;
    int rowB = b / COLS;
    int colA = a % COLS;
    if rowA == rowB {
        return ARTERIAL_ROWS.indexOf(rowA) != ();
    }
    return ARTERIAL_COLS.indexOf(colA) != ();
}

# The central business district (around Independence Avenue) congests at peak times.
isolated function isCongested(int a, int b) returns boolean {
    GeoPoint pa = nodePoint(a);
    GeoPoint pb = nodePoint(b);
    return inCbd(pa) && inCbd(pb);
}

isolated function inCbd(GeoPoint p) returns boolean =>
    p.lat >= -22.585 && p.lat <= -22.555 && p.lon >= 17.065 && p.lon <= 17.095;

isolated function edgeSpeedKmh(int a, int b, boolean peak) returns float {
    float speed = isArterial(a, b) ? ARTERIAL_KMH : LOCAL_KMH;
    return peak && isCongested(a, b) ? speed * CONGESTION_FACTOR : speed;
}

isolated function edgeMinutes(int a, int b, boolean peak) returns float =>
    haversineKm(nodePoint(a), nodePoint(b)) / edgeSpeedKmh(a, b, peak) * 60.0;

# All road segments - used by the UI to draw the network overlay.
#
# + peak - whether peak-hour congestion applies
# + return - every segment of the grid
public isolated function roadNetwork(boolean peak) returns RoadSegment[] {
    RoadSegment[] segments = [];
    foreach int node in 0 ..< nodeCount() {
        foreach int next in neighbours(node) {
            if next > node {
                segments.push({'from: nodePoint(node), to: nodePoint(next), arterial: isArterial(node, next),
                    congested: peak && isCongested(node, next)});
            }
        }
    }
    return segments;
}

# A* search over the road network minimising travel time. The heuristic (straight-line
# distance at the maximum road speed) never overestimates, so the route is optimal.
#
# + 'from - start coordinate (snapped to the nearest intersection)
# + to - destination coordinate (snapped to the nearest intersection)
# + peak - whether peak-hour congestion applies
# + return - the fastest route
public isolated function planRoute(GeoPoint 'from, GeoPoint to, boolean peak) returns RoutePlan {
    int startNode = nearestNode('from);
    int goalNode = nearestNode(to);
    int n = nodeCount();
    float[] gScore = [];
    int[] cameFrom = [];
    boolean[] open = [];
    boolean[] closed = [];
    foreach int i in 0 ..< n {
        gScore.push(INFINITY);
        cameFrom.push(-1);
        open.push(false);
        closed.push(false);
    }
    GeoPoint goalPoint = nodePoint(goalNode);
    gScore[startNode] = 0.0;
    open[startNode] = true;
    int explored = 0;
    while true {
        int current = -1;
        float bestF = INFINITY;
        foreach int i in 0 ..< n {
            if open[i] {
                float f = gScore[i] + haversineKm(nodePoint(i), goalPoint) / ARTERIAL_KMH * 60.0;
                if f < bestF {
                    bestF = f;
                    current = i;
                }
            }
        }
        if current == -1 || current == goalNode {
            break;
        }
        open[current] = false;
        closed[current] = true;
        explored += 1;
        foreach int next in neighbours(current) {
            if closed[next] {
                continue;
            }
            float tentative = gScore[current] + edgeMinutes(current, next, peak);
            if tentative < gScore[next] {
                gScore[next] = tentative;
                cameFrom[next] = current;
                open[next] = true;
            }
        }
    }

    int[] nodes = [goalNode];
    int cursor = goalNode;
    while cameFrom[cursor] != -1 {
        cursor = cameFrom[cursor];
        nodes.unshift(cursor);
    }
    GeoPoint[] path = ['from];
    foreach int node in nodes {
        path.push(nodePoint(node));
    }
    path.push(to);
    path = dedupe(path);

    float firstMile = haversineKm('from, nodePoint(startNode));
    float lastMile = haversineKm(nodePoint(goalNode), to);
    float minutes = gScore[goalNode] + (firstMile + lastMile) / OFFROAD_KMH * 60.0;
    return {
        path,
        distanceKm: roundTo2(polylineLengthKm(path)),
        durationMinutes: roundTo2(minutes),
        nodesExplored: explored,
        algorithm: "A* (travel-time weighted)"
    };
}

# Ranks candidate drivers by their optimised ETA to the pickup point (fastest first).
#
# + candidates - available drivers
# + pickup - restaurant location
# + peak - whether peak-hour congestion applies
# + return - drivers with their route, fastest first
public isolated function rankDrivers(Candidate[] candidates, GeoPoint pickup, boolean peak) returns RankedDriver[] {
    RankedDriver[] ranked = from Candidate c in candidates
        select {driverId: c.driverId, route: planRoute(c.location, pickup, peak)};
    return from RankedDriver r in ranked
        order by r.route.durationMinutes ascending
        select r;
}

// ---- Geometry ----

# Great-circle distance in kilometres.
#
# + a - first point
# + b - second point
# + return - distance in km
public isolated function haversineKm(GeoPoint a, GeoPoint b) returns float {
    float dLat = toRadians(b.lat - a.lat);
    float dLon = toRadians(b.lon - a.lon);
    float h = float:sin(dLat / 2.0) * float:sin(dLat / 2.0) +
        float:cos(toRadians(a.lat)) * float:cos(toRadians(b.lat)) * float:sin(dLon / 2.0) * float:sin(dLon / 2.0);
    return 6371.0 * 2.0 * float:atan2(float:sqrt(h), float:sqrt(1.0 - h));
}

public isolated function polylineLengthKm(GeoPoint[] path) returns float {
    float total = 0.0;
    foreach int i in 1 ..< path.length() {
        total += haversineKm(path[i - 1], path[i]);
    }
    return total;
}

# The point reached after travelling `distanceKm` along a polyline (clamped to its end).
#
# + path - polyline
# + distanceKm - distance travelled from the start
# + return - interpolated position
public isolated function pointAlong(GeoPoint[] path, float distanceKm) returns GeoPoint {
    if path.length() == 0 {
        return {lat: 0, lon: 0};
    }
    float remaining = float:max(0.0, distanceKm);
    foreach int i in 1 ..< path.length() {
        float segment = haversineKm(path[i - 1], path[i]);
        if remaining <= segment && segment > 0.0 {
            float t = remaining / segment;
            return {
                lat: roundTo5(path[i - 1].lat + (path[i].lat - path[i - 1].lat) * t),
                lon: roundTo5(path[i - 1].lon + (path[i].lon - path[i - 1].lon) * t)
            };
        }
        remaining -= segment;
    }
    return path[path.length() - 1];
}

public isolated function isPeakTime(int hour, int minute) returns boolean {
    int minutes = hour * 60 + minute;
    return (minutes >= 11 * 60 + 30 && minutes < 14 * 60) || (minutes >= 17 * 60 + 30 && minutes < 20 * 60 + 30);
}

isolated function dedupe(GeoPoint[] path) returns GeoPoint[] {
    GeoPoint[] result = [];
    foreach GeoPoint p in path {
        if result.length() == 0 || haversineKm(result[result.length() - 1], p) > 0.001 {
            result.push(p);
        }
    }
    return result;
}

public isolated function roundTo2(float value) returns float => float:round(value * 100.0) / 100.0;

isolated function roundTo5(float value) returns float => float:round(value * 100000.0) / 100000.0;

isolated function toRadians(float degrees) returns float => degrees * float:PI / 180.0;
