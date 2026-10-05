// Shared service bootstrap (identical in every service): HTTP listener, CORS policy,
// MongoDB client for the service's own database and the /health endpoint.
import ballerina/http;
import ballerinax/mongodb;

listener http:Listener httpListener = new (HTTP_PORT);

final http:CorsConfig CORS = {allowOrigins: ["*"], allowHeaders: ["*"], allowMethods: ["*"]};

// Database-per-service: each microservice exclusively owns its own Mongo database.
final mongodb:Client mongoClient = check new ({connection: MONGO_URI});

# Projection that strips Mongo's internal `_id` so documents map onto closed records.
final readonly & map<json> NO_ID = {"_id": 0};

function getCollection(string name) returns mongodb:Collection|error {
    mongodb:Database database = check mongoClient->getDatabase(MONGO_DATABASE);
    return database->getCollection(name);
}

function isDatabaseUp() returns boolean {
    string[]|error names = mongoClient->listDatabaseNames();
    return names is string[];
}

# Mongo duplicate-key violations (unique indexes) are used for idempotency checks.
isolated function isDuplicateKey(error err) returns boolean => err.message().includes("E11000");

@http:ServiceConfig {cors: CORS}
service /health on httpListener {
    resource function get .() returns json => {
        status: isDatabaseUp() ? "UP" : "DEGRADED",
        'service: SERVICE_NAME,
        database: MONGO_DATABASE,
        time: nowIso()
    };
}

function countIn(mongodb:Collection collection, map<json> filter) returns int|error {
    return collection->countDocuments(filter);
}
