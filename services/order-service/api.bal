import order_service.domain;

import ballerina/http;
import ballerina/log;

@http:ServiceConfig {cors: CORS}
service /orders on httpListener {

    # Places a new order (status CREATED) and publishes `orders.created`.
    resource function post .(@http:Payload CreateOrderRequest request)
            returns http:Created|http:BadRequest|http:NotFound|http:Conflict|http:ServiceUnavailable|error {
        CustomerDto|error customer = customerClient->get("/customers/" + request.customerId, targetType = CustomerDto);
        if customer is http:ClientRequestError {
            return notFound("Customer not found: " + request.customerId);
        }
        if customer is error {
            return unavailable("Customer service unavailable: " + customer.message());
        }
        Address? address = pickAddress(customer.addresses, request.addressId);
        if address is () {
            return badRequest("The customer has no matching delivery address - add one first");
        }

        RestaurantDto|error restaurant = restaurantClient->get("/restaurants/" + request.restaurantId,
            targetType = RestaurantDto);
        if restaurant is http:ClientRequestError {
            return notFound("Restaurant not found: " + request.restaurantId);
        }
        if restaurant is error {
            return unavailable("Restaurant service unavailable: " + restaurant.message());
        }
        if !restaurant.isOpenNow || !restaurant.acceptingOrders {
            return conflictError(restaurant.name + " is closed and not accepting orders right now");
        }
        MenuItemDto[]|error menu = restaurantClient->get(string `/restaurants/${request.restaurantId}/menu`,
            targetType = MenuItemDtoList);
        if menu is error {
            return unavailable("Could not load the menu: " + menu.message());
        }
        map<MenuItemDto> menuById = map from MenuItemDto m in menu select [m.itemId, m];

        OrderItem[] items = [];
        float subtotal = 0.0;
        foreach OrderLine line in request.items {
            MenuItemDto? item = menuById[line.itemId];
            if item is () {
                return badRequest(string `Item ${line.itemId} is not on the menu of ${restaurant.name}`);
            }
            if !item.available || item.stock < line.quantity {
                return conflictError(string `${item.name} is out of stock (available: ${item.stock})`);
            }
            float lineTotal = round2(item.price * <float>line.quantity);
            items.push({itemId: item.itemId, name: item.name, unitPrice: item.price, quantity: line.quantity, lineTotal});
            subtotal += lineTotal;
        }

        float distanceKm = domain:estimateRoadKm(restaurant.location.lat, restaurant.location.lon,
                address.location.lat, address.location.lon);
        domain:SurgeQuote surge = currentSurge();
        float fee = domain:deliveryFee(distanceKm, surge.multiplier);
        string now = nowIso();
        int nowMillis = nowMs();
        Order newOrder = {
            orderId: newId("ORD"),
            customerId: customer.customerId,
            customerName: customer.name,
            customerEmail: customer.email,
            customerPhone: customer.phone,
            notificationPrefs: customer.notificationPrefs,
            restaurantId: restaurant.restaurantId,
            restaurantName: restaurant.name,
            restaurantLocation: restaurant.location,
            deliveryAddress: address,
            items,
            subtotal: round2(subtotal),
            deliveryFee: fee,
            surgeMultiplier: surge.multiplier,
            estimatedDistanceKm: distanceKm,
            total: round2(subtotal + fee),
            currency: "NAD",
            paymentMethod: request.paymentMethod,
            paymentId: (),
            status: domain:CREATED,
            statusHistory: [{status: domain:CREATED, at: now, atMs: nowMillis, reason: "Order placed", actor: "customer"}],
            driverId: (),
            driverName: (),
            etaMinutes: (),
            cancelReason: (),
            notes: request.notes,
            version: 1,
            createdAt: now,
            createdAtMs: nowMillis,
            updatedAt: now,
            updatedAtMs: nowMillis
        };
        check ordersCol->insertOne(newOrder);

        OrderCreatedEvent created = {...newOrder, cardLast4: request.cardLast4};
        error? published = publishEvent(TOPIC_ORDERS_CREATED, "OrderCreated", newOrder.orderId, created);
        if published is error {
            // Without the event the saga can never progress: compensate immediately.
            log:printError("could not publish orders.created - cancelling order", published, orderId = newOrder.orderId);
            _ = check applyTransition(newOrder.orderId, domain:CANCELLED, "Messaging unavailable", "system");
            return unavailable("The order could not be submitted, please retry");
        }
        emit(TOPIC_ORDERS_STATUS_CHANGED, "OrderStatusChanged", newOrder.orderId,
                toStatusEvent(newOrder, domain:CREATED, domain:CREATED, "Order placed", now, nowMillis));
        incCounter("fd_orders_created_total", "Orders placed", {restaurant: restaurant.restaurantId});
        log:printInfo("order created", orderId = newOrder.orderId, total = newOrder.total, surge = surge.multiplier);
        http:Created response = {body: newOrder, headers: {"Location": "/orders/" + newOrder.orderId}};
        return response;
    }

    resource function get .(string? customerId, string? restaurantId, string? driverId, string? status,
            int 'limit = 50) returns Order[]|error {
        map<json> filter = {};
        if customerId is string {
            filter["customerId"] = customerId;
        }
        if restaurantId is string {
            filter["restaurantId"] = restaurantId;
        }
        if driverId is string {
            filter["driverId"] = driverId;
        }
        if status is string {
            filter["status"] = {"$in": re `,`.split(status.toUpperAscii())};
        }
        return findOrders(filter, int:min(int:max('limit, 1), 500));
    }

    # Live counts per status (used by dashboards).
    resource function get stats() returns map<int>|error {
        map<int> counts = {};
        foreach string status in [domain:CREATED, domain:CONFIRMED, domain:PREPARING, domain:READY,
                domain:OUT_FOR_DELIVERY, domain:DELIVERED, domain:CANCELLED] {
            int count = check ordersCol->countDocuments({status});
            counts[status] = count;
            setGauge("fd_orders_by_status", "Orders currently in each status", <float>count, {status});
        }
        return counts;
    }

    resource function get [string orderId]() returns Order|http:NotFound|error {
        Order? found = check findOrder(orderId);
        return found ?: notFound("Order not found: " + orderId);
    }

    # Customer cancellation - only allowed before the kitchen starts preparing.
    resource function put [string orderId]/cancel(@http:Payload CancelRequest request)
            returns Order|http:NotFound|http:Conflict|error {
        Order? found = check findOrder(orderId);
        if found is () {
            return notFound("Order not found: " + orderId);
        }
        if !domain:customerCanCancel(found.status) {
            return conflictError(string `Order is ${found.status} and can no longer be cancelled`);
        }
        Order? updated = check applyTransition(orderId, domain:CANCELLED, request.reason, "customer");
        if updated is () {
            return conflictError("Order changed state concurrently and can no longer be cancelled");
        }
        return updated;
    }
}

@http:ServiceConfig {cors: CORS}
service /pricing on httpListener {

    # Quote for the delivery fee (distance based) including the current surge multiplier.
    resource function get quote(string restaurantId, float lat, float lon)
            returns PriceQuote|http:NotFound|http:ServiceUnavailable {
        RestaurantDto|error restaurant = restaurantClient->get("/restaurants/" + restaurantId, targetType = RestaurantDto);
        if restaurant is http:ClientRequestError {
            return notFound("Restaurant not found: " + restaurantId);
        }
        if restaurant is error {
            return unavailable("Restaurant service unavailable");
        }
        float distanceKm = domain:estimateRoadKm(restaurant.location.lat, restaurant.location.lon, lat, lon);
        domain:SurgeQuote surge = currentSurge();
        return {
            restaurantId,
            estimatedDistanceKm: distanceKm,
            baseDeliveryFee: domain:deliveryFee(distanceKm, 1.0),
            surgeMultiplier: surge.multiplier,
            surgeLevel: surge.level,
            surgeReasons: surge.reasons,
            deliveryFee: domain:deliveryFee(distanceKm, surge.multiplier),
            currency: "NAD"
        };
    }

    resource function get surge() returns domain:SurgeQuote => currentSurge();
}

function pickAddress(Address[] addresses, string? addressId) returns Address? {
    foreach Address address in addresses {
        if addressId is string ? address.addressId == addressId : address.isDefault {
            return address;
        }
    }
    return addressId is () && addresses.length() > 0 ? addresses[0] : ();
}
