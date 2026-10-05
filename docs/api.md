# REST API reference

Every service is reachable through the gateway at `http://localhost:8080/api/<service>/…`.
Every service also exposes `GET /health` and Prometheus metrics on port `9797`. Errors use
one shape: `{"message": "...", "code": "NOT_FOUND|BAD_REQUEST|CONFLICT|UNAUTHORIZED|DEPENDENCY_UNAVAILABLE"}`.
Request bodies are validated with `ballerina/constraint`; invalid payloads return `400`.

## Customer service – `/api/customer-service`

| Method | Path | Description |
|--------|------|-------------|
| POST | `/customers` | Register `{name, email, phone, password, address?, notificationPrefs?}` → 201 (409 if the email exists) |
| POST | `/customers/login` | `{email, password}` → customer, or 401 |
| GET | `/customers` | List customers |
| GET | `/customers/{id}` | Get a customer |
| PUT | `/customers/{id}` | Update `{name?, phone?, notificationPrefs?}` |
| GET | `/customers/{id}/addresses` | List delivery addresses |
| POST | `/customers/{id}/addresses` | Add `{label, street, city, location:{lat,lon}, isDefault}` |
| PUT | `/customers/{id}/addresses/{addressId}` | Replace an address |
| DELETE | `/customers/{id}/addresses/{addressId}` | Remove an address (the default moves to another address) |
| GET | `/customers/{id}/orders?status=` | Historical orders (read model built from events) |

## Restaurant service – `/api/restaurant-service`

| Method | Path | Description |
|--------|------|-------------|
| GET | `/restaurants?cuisine=&openNow=true` | Restaurants with a computed `isOpenNow` |
| POST | `/restaurants` | Create a restaurant |
| GET / PUT | `/restaurants/{id}` | Get / update details |
| PUT | `/restaurants/{id}/hours` | Opening hours `[{day:"MON", open:"10:00", close:"22:00"}]` (overnight allowed) |
| PUT | `/restaurants/{id}/accepting` | `{acceptingOrders: false}` pauses new orders |
| GET | `/restaurants/{id}/menu?availableOnly=true` | Digital menu with live stock |
| POST | `/restaurants/{id}/menu` | Add a dish |
| PUT / DELETE | `/restaurants/{id}/menu/{itemId}` | Update / remove a dish |
| PATCH | `/restaurants/{id}/menu/{itemId}/stock` | `{stock: 20}` or `{delta: -3}` (never below 0) |
| GET | `/restaurants/{id}/inventory/low?threshold=5` | Low-stock alert list |
| GET | `/restaurants/{id}/kitchen?status=QUEUED,PREPARING` | Kitchen tickets |
| POST | `/restaurants/{id}/kitchen/{orderId}/start` | QUEUED → PREPARING (publishes `restaurant.order-preparing`) |
| POST | `/restaurants/{id}/kitchen/{orderId}/ready` | PREPARING → READY (publishes `restaurant.order-ready`) |

## Order service – `/api/order-service`

| Method | Path | Description |
|--------|------|-------------|
| POST | `/orders` | Place `{customerId, restaurantId, items:[{itemId, quantity}], addressId?, paymentMethod, cardLast4?, notes?}` → 201 CREATED |
| GET | `/orders?customerId=&restaurantId=&driverId=&status=A,B&limit=` | Search orders |
| GET | `/orders/{id}` | Order with its full `statusHistory` |
| PUT | `/orders/{id}/cancel` | `{reason}` – allowed in CREATED / CONFIRMED (409 otherwise) |
| GET | `/orders/stats` | Live count per status |
| GET | `/pricing/quote?restaurantId=&lat=&lon=` | Delivery fee quote including surge |
| GET | `/pricing/surge` | Current surge multiplier, level and reasons |

Payment methods are `CARD`, `MOBILE_MONEY` and `CASH_ON_DELIVERY`. Test card: `cardLast4 = "0000"` is declined.

## Payment service – `/api/payment-service`

| Method | Path | Description |
|--------|------|-------------|
| GET | `/payments?orderId=&customerId=&status=` | Payments |
| GET | `/payments/{paymentId}` | One payment |
| GET | `/payments/order/{orderId}` | The payment for an order |
| GET | `/payments/stats` | Captured / refunded totals |

## Delivery service – `/api/delivery-service`

| Method | Path | Description |
|--------|------|-------------|
| GET / POST | `/drivers` | List / register drivers |
| GET | `/drivers/summary` | Available / busy / offline counts (feeds surge pricing) |
| GET | `/drivers/{id}` | Driver incl. live location and earnings |
| PUT | `/drivers/{id}/status` | `{status: AVAILABLE \| OFFLINE}` (409 while busy) |
| PUT | `/drivers/{id}/location` | Manual GPS update `{lat, lon}` |
| GET | `/drivers/{id}/deliveries` | Driver's jobs |
| GET | `/deliveries?status=&driverId=` | Deliveries |
| GET | `/deliveries/order/{orderId}` | Live tracking: route, position, ETA |
| PUT | `/deliveries/{id}/pickup` | Driver collected the food (requires the food to be READY) |
| PUT | `/deliveries/{id}/complete` | Handed over to the customer |
| GET | `/routes/plan?fromLat=&fromLon=&toLat=&toLon=&peak=` | A\* fastest route |
| GET | `/routes/network?peak=` | Road network overlay (arterial / local / congested) |

## Notification service – `/api/notification-service`

| Method | Path | Description |
|--------|------|-------------|
| GET | `/notifications?recipientType=CUSTOMER&recipientId=&orderId=&channel=` | Inbox / audit log |
| PUT | `/notifications/{id}/read` | Mark as read |
| GET | `/notifications/stats` | Counts per channel and recipient |

## Admin service – `/api/admin-service`

| Method | Path | Description |
|--------|------|-------------|
| GET | `/reports/overview` | KPIs: orders, GMV, average order value, preparation / transit / fulfilment minutes, on-time rate, surge, payment failures |
| GET | `/reports/restaurants` | Restaurant statistics leaderboard |
| GET | `/reports/deliveries` | Delivery performance per driver |
| GET | `/reports/hourly` | Orders and revenue per local hour |
| GET | `/reports/orders?limit=` | Analytics fact rows |
| GET | `/reports/events` | Events seen per Kafka topic |
| GET | `/reports/fleet` | Live driver positions |
| GET | `/reports/dead-letters` | Dead-letter queue |
| GET | `/reports/system` | Health of every service |
