import restaurant_service.domain;

import ballerina/http;
import ballerinax/mongodb;

@http:ServiceConfig {cors: CORS}
service /restaurants on httpListener {

    resource function get .(string? cuisine, boolean openNow = false) returns RestaurantView[]|error {
        map<json> filter = cuisine is string ? {cuisine} : {};
        stream<Restaurant, error?> results = check restaurantsCol->find(filter, {sort: {"name": 1}}, NO_ID, Restaurant);
        RestaurantView[] views = check from Restaurant r in results select toView(r);
        check results.close();
        return openNow ? views.filter(v => v.isOpenNow) : views;
    }

    resource function post .(@http:Payload RestaurantInput input) returns http:Created|http:BadRequest|error {
        string? invalid = domain:validateHours(input.openingHours);
        if invalid is string {
            return badRequest(invalid);
        }
        string now = nowIso();
        Restaurant restaurant = {
            restaurantId: newId("R"),
            name: input.name,
            cuisine: input.cuisine,
            description: input.description,
            phone: input.phone,
            address: input.address,
            location: input.location,
            openingHours: input.openingHours,
            acceptingOrders: true,
            rating: 0.0,
            avgPrepMinutes: input.avgPrepMinutes,
            createdAt: now,
            updatedAt: now
        };
        check restaurantsCol->insertOne(restaurant);
        http:Created created = {body: toView(restaurant)};
        return created;
    }

    resource function get [string restaurantId]() returns RestaurantView|http:NotFound|error {
        Restaurant? restaurant = check findRestaurant(restaurantId);
        return restaurant is Restaurant ? toView(restaurant) : notFound("Restaurant not found: " + restaurantId);
    }

    resource function put [string restaurantId](@http:Payload RestaurantInput input)
            returns RestaurantView|http:NotFound|http:BadRequest|error {
        string? invalid = domain:validateHours(input.openingHours);
        if invalid is string {
            return badRequest(invalid);
        }
        mongodb:UpdateResult result = check restaurantsCol->updateOne({restaurantId}, {
            set: {
                name: input.name,
                cuisine: input.cuisine,
                description: input.description,
                phone: input.phone,
                address: input.address,
                location: input.location.toJson(),
                openingHours: input.openingHours.toJson(),
                avgPrepMinutes: input.avgPrepMinutes,
                updatedAt: nowIso()
            }
        });
        return result.matchedCount == 0 ? notFound("Restaurant not found: " + restaurantId) : refreshed(restaurantId);
    }

    # Kitchen opening hours (local time, Africa/Windhoek).
    resource function put [string restaurantId]/hours(@http:Payload domain:OpeningHours[] hours)
            returns RestaurantView|http:NotFound|http:BadRequest|error {
        string? invalid = domain:validateHours(hours);
        if invalid is string {
            return badRequest(invalid);
        }
        mongodb:UpdateResult result = check restaurantsCol->updateOne({restaurantId},
            {set: {openingHours: hours.toJson(), updatedAt: nowIso()}});
        return result.matchedCount == 0 ? notFound("Restaurant not found: " + restaurantId) : refreshed(restaurantId);
    }

    # Pause / resume taking orders (e.g. when the kitchen is overloaded).
    resource function put [string restaurantId]/accepting(@http:Payload AcceptingUpdate update)
            returns RestaurantView|http:NotFound|error {
        mongodb:UpdateResult result = check restaurantsCol->updateOne({restaurantId},
            {set: {acceptingOrders: update.acceptingOrders, updatedAt: nowIso()}});
        return result.matchedCount == 0 ? notFound("Restaurant not found: " + restaurantId) : refreshed(restaurantId);
    }

    // ---- Digital menu & real-time inventory ----

    resource function get [string restaurantId]/menu(boolean availableOnly = false) returns MenuItem[]|error {
        map<json> filter = {restaurantId};
        if availableOnly {
            filter["available"] = true;
            filter["stock"] = {"$gt": 0};
        }
        return findMenu(filter);
    }

    resource function post [string restaurantId]/menu(@http:Payload MenuItemInput input)
            returns http:Created|http:NotFound|error {
        Restaurant? restaurant = check findRestaurant(restaurantId);
        if restaurant is () {
            return notFound("Restaurant not found: " + restaurantId);
        }
        MenuItem item = {
            itemId: newId("M"),
            restaurantId,
            name: input.name,
            description: input.description,
            category: input.category,
            price: input.price,
            stock: input.stock,
            available: input.available,
            prepMinutes: input.prepMinutes,
            updatedAt: nowIso()
        };
        check menuCol->insertOne(item);
        http:Created created = {body: item};
        return created;
    }

    resource function put [string restaurantId]/menu/[string itemId](@http:Payload MenuItemInput input)
            returns MenuItem|http:NotFound|error {
        mongodb:UpdateResult result = check menuCol->updateOne({restaurantId, itemId}, {
            set: {
                name: input.name,
                description: input.description,
                category: input.category,
                price: input.price,
                stock: input.stock,
                available: input.available,
                prepMinutes: input.prepMinutes,
                updatedAt: nowIso()
            }
        });
        return result.matchedCount == 0 ? notFound("Menu item not found: " + itemId) : menuItem(restaurantId, itemId);
    }

    # Real-time inventory adjustment: absolute (`stock`) or relative (`delta`).
    resource function patch [string restaurantId]/menu/[string itemId]/stock(@http:Payload StockUpdate update)
            returns MenuItem|http:NotFound|http:BadRequest|error {
        mongodb:Update change;
        int? stock = update.stock;
        int? delta = update.delta;
        if stock is int && stock >= 0 {
            change = {set: {stock, updatedAt: nowIso()}};
        } else if delta is int {
            change = {inc: {stock: delta}, set: {updatedAt: nowIso()}};
        } else {
            return badRequest("Provide a non-negative 'stock' or a 'delta'");
        }
        map<json> filter = {restaurantId, itemId};
        if delta is int && delta < 0 {
            filter["stock"] = {"$gte": -delta};
        }
        mongodb:UpdateResult result = check menuCol->updateOne(filter, change);
        if result.matchedCount == 0 {
            return notFound("Menu item not found (or not enough stock): " + itemId);
        }
        return menuItem(restaurantId, itemId);
    }

    resource function delete [string restaurantId]/menu/[string itemId]() returns http:NoContent|http:NotFound|error {
        mongodb:DeleteResult result = check menuCol->deleteOne({restaurantId, itemId});
        return result.deletedCount == 0 ? notFound("Menu item not found: " + itemId) : http:NO_CONTENT;
    }

    resource function get [string restaurantId]/inventory/low(int? threshold) returns MenuItem[]|error =>
        findMenu({restaurantId, stock: {"$lte": threshold ?: LOW_STOCK_THRESHOLD}});

    // ---- Kitchen workflow ----

    resource function get [string restaurantId]/kitchen(string? status) returns KitchenTicket[]|error {
        map<json> filter = {restaurantId};
        if status is string {
            filter["status"] = {"$in": re `,`.split(status.toUpperAscii())};
        }
        return findTickets(filter);
    }

    resource function post [string restaurantId]/kitchen/[string orderId]/'start()
            returns KitchenTicket|http:NotFound|http:Conflict|error {
        boolean done = check startPreparing(orderId, restaurantId);
        return ticketResult(orderId, done, "QUEUED");
    }

    resource function post [string restaurantId]/kitchen/[string orderId]/ready()
            returns KitchenTicket|http:NotFound|http:Conflict|error {
        boolean done = check markReady(orderId, restaurantId);
        return ticketResult(orderId, done, "PREPARING");
    }
}

function refreshed(string restaurantId) returns RestaurantView|http:NotFound|error {
    Restaurant? restaurant = check findRestaurant(restaurantId);
    return restaurant is Restaurant ? toView(restaurant) : notFound("Restaurant not found: " + restaurantId);
}

function menuItem(string restaurantId, string itemId) returns MenuItem|http:NotFound|error {
    MenuItem? item = check menuCol->findOne({restaurantId, itemId}, {}, NO_ID, MenuItem);
    return item ?: notFound("Menu item not found: " + itemId);
}

function ticketResult(string orderId, boolean transitioned, string expected)
        returns KitchenTicket|http:NotFound|http:Conflict|error {
    KitchenTicket? ticket = check findTicket(orderId);
    if ticket is () {
        return notFound("No kitchen ticket for order " + orderId);
    }
    if !transitioned {
        return conflictError(string `Ticket is ${ticket.status}, expected ${expected}`);
    }
    return ticket;
}
