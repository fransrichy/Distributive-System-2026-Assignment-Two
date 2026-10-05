// Shared helpers (identical in every service): environment configuration,
// time and id utilities, HTTP error bodies and Prometheus metric helpers.
import ballerina/http;
import ballerina/observe;
import ballerina/os;
import ballerina/time;
import ballerina/uuid;
import ballerinax/prometheus as _;

isolated function envOr(string key, string defaultValue) returns string {
    string value = os:getEnv(key);
    return value == "" ? defaultValue : value;
}

isolated function envIntOr(string key, int defaultValue) returns int {
    int|error value = int:fromString(os:getEnv(key));
    return value is int ? value : defaultValue;
}

isolated function envFloatOr(string key, float defaultValue) returns float {
    float|error value = float:fromString(os:getEnv(key));
    return value is float ? value : defaultValue;
}

isolated function envBoolOr(string key, boolean defaultValue) returns boolean {
    string value = os:getEnv(key).toLowerAscii();
    if value == "" {
        return defaultValue;
    }
    return value == "true" || value == "1" || value == "yes";
}

isolated function nowMs() returns int {
    time:Utc now = time:utcNow();
    return now[0] * 1000 + <int>(now[1] * 1000d).floor();
}

isolated function nowIso() returns string => time:utcToString(time:utcNow());

# Generates a short, human friendly identifier such as `ORD-1A2B3C4D`.
isolated function newId(string prefix) returns string =>
    prefix + "-" + uuid:createType4AsString().substring(0, 8).toUpperAscii();

isolated function round2(float value) returns float => float:round(value * 100.0) / 100.0;

public type ErrorBody record {|
    string message;
    string code;
|};

isolated function notFound(string message) returns http:NotFound => {body: {message, code: "NOT_FOUND"}};

isolated function badRequest(string message) returns http:BadRequest => {body: {message, code: "BAD_REQUEST"}};

isolated function conflictError(string message) returns http:Conflict => {body: {message, code: "CONFLICT"}};

isolated function unauthorized(string message) returns http:Unauthorized => {body: {message, code: "UNAUTHORIZED"}};

isolated function unavailable(string message) returns http:ServiceUnavailable =>
    {body: {message, code: "DEPENDENCY_UNAVAILABLE"}};

// ---------------------------------------------------------------------------
// Custom business metrics, exported through the Prometheus extension (:9797)
// ---------------------------------------------------------------------------

isolated function incCounter(string name, string description, map<string> tags = {}, int amount = 1) {
    observe:Counter|observe:Gauge? existing = observe:lookupMetric(name, tags);
    if existing is observe:Counter {
        existing.increment(amount);
        return;
    }
    observe:Counter counter = new (name, description, tags);
    error? registered = counter.register();
    if registered is error {
        observe:Counter|observe:Gauge? again = observe:lookupMetric(name, tags);
        if again is observe:Counter {
            again.increment(amount);
        }
        return;
    }
    counter.increment(amount);
}

isolated function setGauge(string name, string description, float value, map<string> tags = {}) {
    observe:Counter|observe:Gauge? existing = observe:lookupMetric(name, tags);
    if existing is observe:Gauge {
        existing.setValue(value);
        return;
    }
    observe:Gauge gauge = new (name, description, tags, []);
    error? registered = gauge.register();
    if registered is error {
        observe:Counter|observe:Gauge? again = observe:lookupMetric(name, tags);
        if again is observe:Gauge {
            again.setValue(value);
        }
        return;
    }
    gauge.setValue(value);
}
