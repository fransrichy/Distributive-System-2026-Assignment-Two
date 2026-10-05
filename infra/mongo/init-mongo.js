// MongoDB bootstrap - runs once when the data volume is first created.
//
// Database-per-service: every microservice owns exactly one database and no service
// reads another service's database. Collections get $jsonSchema validators (data
// integrity at the storage layer) and the indexes required by the access patterns,
// including the UNIQUE indexes that make Kafka consumers idempotent.

const num = { bsonType: ["double", "int", "long", "decimal"] };
const numOrNull = { bsonType: ["double", "int", "long", "decimal", "null"] };
const str = { bsonType: "string" };
const strOrNull = { bsonType: ["string", "null"] };
const bool = { bsonType: "bool" };
const geo = {
  bsonType: "object",
  required: ["lat", "lon"],
  properties: { lat: { ...num, minimum: -90, maximum: 90 }, lon: { ...num, minimum: -180, maximum: 180 } },
};
const geoOrNull = { bsonType: ["object", "null"] };

function collection(dbName, name, schema, indexes) {
  const target = db.getSiblingDB(dbName);
  if (!target.getCollectionNames().includes(name)) {
    target.createCollection(name, {
      validator: { $jsonSchema: schema },
      validationLevel: "moderate",
      validationAction: "error",
    });
  } else {
    target.runCommand({ collMod: name, validator: { $jsonSchema: schema } });
  }
  for (const [keys, options] of indexes) {
    target.getCollection(name).createIndex(keys, options || {});
  }
  print(`  ✔ ${dbName}.${name}`);
}

print("Creating databases, schemas and indexes...");

// ---------------------------------------------------------------- customer_db
collection("customer_db", "customers", {
  bsonType: "object",
  required: ["customerId", "name", "email", "phone", "passwordHash", "addresses", "notificationPrefs"],
  properties: {
    customerId: str,
    name: { ...str, minLength: 2 },
    email: { ...str, pattern: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$" },
    phone: str,
    passwordHash: str,
    addresses: {
      bsonType: "array",
      items: {
        bsonType: "object",
        required: ["addressId", "label", "street", "city", "location", "isDefault"],
        properties: { addressId: str, label: str, street: str, city: str, location: geo, isDefault: bool },
      },
    },
    notificationPrefs: {
      bsonType: "object",
      required: ["email", "sms", "push"],
      properties: { email: bool, sms: bool, push: bool },
    },
    totalOrders: num,
    totalSpent: num,
  },
}, [
  [{ customerId: 1 }, { unique: true }],
  [{ email: 1 }, { unique: true }],
]);

collection("customer_db", "order_history", {
  bsonType: "object",
  required: ["orderId", "customerId", "status", "total"],
  properties: { orderId: str, customerId: str, status: str, total: num },
}, [
  [{ orderId: 1 }, { unique: true }],
  [{ customerId: 1, orderCreatedAtMs: -1 }],
]);

// -------------------------------------------------------------- restaurant_db
collection("restaurant_db", "restaurants", {
  bsonType: "object",
  required: ["restaurantId", "name", "cuisine", "location", "openingHours", "acceptingOrders"],
  properties: {
    restaurantId: str,
    name: str,
    cuisine: str,
    location: geo,
    acceptingOrders: bool,
    openingHours: {
      bsonType: "array",
      items: {
        bsonType: "object",
        required: ["day", "open", "close"],
        properties: {
          day: { enum: ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"] },
          open: { ...str, pattern: "^([01][0-9]|2[0-3]):[0-5][0-9]$" },
          close: { ...str, pattern: "^([01][0-9]|2[0-3]):[0-5][0-9]$" },
        },
      },
    },
  },
}, [
  [{ restaurantId: 1 }, { unique: true }],
  [{ cuisine: 1 }],
]);

collection("restaurant_db", "menu_items", {
  bsonType: "object",
  required: ["itemId", "restaurantId", "name", "price", "stock", "available"],
  properties: {
    itemId: str,
    restaurantId: str,
    name: str,
    price: { ...num, minimum: 0 },
    stock: { ...num, minimum: 0 }, // inventory can never go negative
    available: bool,
  },
}, [
  [{ itemId: 1 }, { unique: true }],
  [{ restaurantId: 1, category: 1 }],
  [{ restaurantId: 1, stock: 1 }],
]);

collection("restaurant_db", "kitchen_tickets", {
  bsonType: "object",
  required: ["orderId", "restaurantId", "items", "status", "receivedAtMs"],
  properties: {
    orderId: str,
    restaurantId: str,
    status: { enum: ["QUEUED", "PREPARING", "READY", "CANCELLED", "REJECTED"] },
    items: { bsonType: "array" },
  },
}, [
  [{ orderId: 1 }, { unique: true }],
  [{ restaurantId: 1, status: 1 }],
  [{ status: 1, receivedAtMs: 1 }],
]);

// ------------------------------------------------------------------- order_db
collection("order_db", "orders", {
  bsonType: "object",
  required: ["orderId", "customerId", "restaurantId", "items", "subtotal", "deliveryFee", "total", "status",
    "statusHistory", "version", "createdAtMs"],
  properties: {
    orderId: str,
    customerId: str,
    restaurantId: str,
    restaurantLocation: geo,
    deliveryAddress: { bsonType: "object", required: ["street", "location"], properties: { street: str, location: geo } },
    items: {
      bsonType: "array",
      minItems: 1,
      items: {
        bsonType: "object",
        required: ["itemId", "name", "unitPrice", "quantity", "lineTotal"],
        properties: { itemId: str, name: str, unitPrice: num, quantity: { ...num, minimum: 1 }, lineTotal: num },
      },
    },
    subtotal: { ...num, minimum: 0 },
    deliveryFee: { ...num, minimum: 0 },
    surgeMultiplier: { ...num, minimum: 1, maximum: 2.5 },
    total: { ...num, minimum: 0 },
    paymentMethod: { enum: ["CARD", "MOBILE_MONEY", "CASH_ON_DELIVERY"] },
    status: { enum: ["CREATED", "CONFIRMED", "PREPARING", "READY", "OUT_FOR_DELIVERY", "DELIVERED", "CANCELLED"] },
    statusHistory: { bsonType: "array" },
    driverId: strOrNull,
    paymentId: strOrNull,
    version: num,
  },
}, [
  [{ orderId: 1 }, { unique: true }],
  [{ customerId: 1, createdAtMs: -1 }],
  [{ restaurantId: 1, status: 1 }],
  [{ status: 1 }],
  [{ createdAtMs: -1 }],
]);

// ----------------------------------------------------------------- payment_db
collection("payment_db", "payments", {
  bsonType: "object",
  required: ["paymentId", "orderId", "amount", "currency", "method", "status"],
  properties: {
    paymentId: str,
    orderId: str,
    amount: { ...num, minimum: 0 },
    currency: str,
    method: str,
    cardLast4: { bsonType: ["string", "null"], pattern: "^[0-9]{4}$" },
    status: { enum: ["PENDING", "COMPLETED", "FAILED", "REFUNDED", "VOIDED"] },
  },
}, [
  [{ paymentId: 1 }, { unique: true }],
  [{ orderId: 1 }, { unique: true }], // one payment per order => idempotent charging
  [{ customerId: 1, createdAtMs: -1 }],
  [{ status: 1 }],
]);

// ---------------------------------------------------------------- delivery_db
collection("delivery_db", "drivers", {
  bsonType: "object",
  required: ["driverId", "name", "status", "location"],
  properties: {
    driverId: str,
    name: str,
    status: { enum: ["OFFLINE", "AVAILABLE", "BUSY"] },
    location: geo,
    currentDeliveryId: strOrNull,
  },
}, [
  [{ driverId: 1 }, { unique: true }],
  [{ status: 1 }],
]);

collection("delivery_db", "deliveries", {
  bsonType: "object",
  required: ["deliveryId", "orderId", "pickup", "dropoff", "status", "route"],
  properties: {
    deliveryId: str,
    orderId: str,
    pickup: geo,
    dropoff: geo,
    driverId: strOrNull,
    status: { enum: ["PENDING_ASSIGNMENT", "ASSIGNED", "AT_RESTAURANT", "PICKED_UP", "DELIVERED", "CANCELLED"] },
    leg: { enum: ["NONE", "TO_RESTAURANT", "TO_CUSTOMER"] },
    route: { bsonType: "array" },
    currentLocation: geoOrNull,
    progressKm: num,
    routeDistanceKm: num,
  },
}, [
  [{ deliveryId: 1 }, { unique: true }],
  [{ orderId: 1 }, { unique: true }],
  [{ status: 1 }],
  [{ driverId: 1, createdAtMs: -1 }],
]);

// ------------------------------------------------------------ notification_db
collection("notification_db", "notifications", {
  bsonType: "object",
  required: ["notificationId", "eventId", "recipientType", "recipientId", "channel", "title", "body"],
  properties: {
    notificationId: str,
    eventId: str,
    recipientType: { enum: ["CUSTOMER", "RESTAURANT", "DRIVER"] },
    recipientId: str,
    channel: { enum: ["EMAIL", "SMS", "PUSH"] },
    orderId: strOrNull,
  },
}, [
  [{ notificationId: 1 }, { unique: true }], // eventId-recipient-channel => no duplicate alerts
  [{ recipientType: 1, recipientId: 1, createdAtMs: -1 }],
  [{ orderId: 1 }],
]);

collection("notification_db", "contacts", {
  bsonType: "object",
  required: ["customerId"],
  properties: { customerId: str, email: strOrNull, phone: strOrNull },
}, [
  [{ customerId: 1 }, { unique: true }],
]);

// ------------------------------------------------------------------- admin_db
collection("admin_db", "order_facts", {
  bsonType: "object",
  required: ["orderId", "restaurantId", "status", "total", "createdAtMs"],
  properties: {
    orderId: str,
    restaurantId: str,
    driverId: strOrNull,
    status: str,
    total: num,
    distanceKm: numOrNull,
  },
}, [
  [{ orderId: 1 }, { unique: true }],
  [{ restaurantId: 1 }],
  [{ driverId: 1 }],
  [{ createdAtMs: -1 }],
]);

collection("admin_db", "processed_events", {
  bsonType: "object",
  required: ["eventId"],
  properties: { eventId: str },
}, [
  [{ eventId: 1 }, { unique: true }],
]);

collection("admin_db", "event_counters", {
  bsonType: "object",
  required: ["topic"],
  properties: { topic: str, count: num },
}, [
  [{ topic: 1 }, { unique: true }],
]);

collection("admin_db", "fleet_positions", {
  bsonType: "object",
  required: ["driverId", "lat", "lon"],
  properties: { driverId: str, lat: num, lon: num },
}, [
  [{ driverId: 1 }, { unique: true }],
]);

collection("admin_db", "dead_letters", {
  bsonType: "object",
  required: ["eventId", "failedTopic", "reason"],
  properties: { eventId: str, failedTopic: str, reason: str },
}, [
  [{ eventId: 1 }, { unique: true }],
]);

print("MongoDB initialisation complete.");
