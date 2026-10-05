import restaurant_service.domain;

import ballerina/lang.runtime;
import ballerina/log;
import ballerinax/mongodb;

final mongodb:Collection restaurantsCol = check getCollection("restaurants");
final mongodb:Collection menuCol = check getCollection("menu_items");
final mongodb:Collection ticketsCol = check getCollection("kitchen_tickets");

function init() {
    if SEED_DATA {
        error? seeded = seedRestaurants();
        if seeded is error {
            log:printError("restaurant seeding failed", seeded);
        }
    }
    if AUTO_KITCHEN {
        _ = start autoKitchenLoop();
    }
}

function localEpochSeconds() returns int => nowMs() / 1000 + TZ_OFFSET_HOURS * 3600;

function toView(Restaurant r) returns RestaurantView => {
    ...r,
    isOpenNow: domain:isOpenAt(r.openingHours, localEpochSeconds())
};

function findRestaurant(string restaurantId) returns Restaurant|error? {
    return restaurantsCol->findOne({restaurantId}, {}, NO_ID, Restaurant);
}

function findMenu(map<json> filter) returns MenuItem[]|error {
    stream<MenuItem, error?> results = check menuCol->find(filter, {sort: {"category": 1, "name": 1}}, NO_ID, MenuItem);
    MenuItem[] items = check from MenuItem m in results select m;
    check results.close();
    return items;
}

function findTicket(string orderId) returns KitchenTicket|error? {
    return ticketsCol->findOne({orderId}, {}, NO_ID, KitchenTicket);
}

function findTickets(map<json> filter, int 'limit = 100) returns KitchenTicket[]|error {
    stream<KitchenTicket, error?> results = check ticketsCol->find(filter, {sort: {"receivedAtMs": -1}, 'limit},
        NO_ID, KitchenTicket);
    KitchenTicket[] tickets = check from KitchenTicket t in results select t;
    check results.close();
    return tickets;
}

// ---------------------------------------------------------------------------
// Kitchen simulation
// ---------------------------------------------------------------------------

function autoKitchenLoop() {
    log:printInfo("automatic kitchen simulation enabled", startAfterSeconds = AUTO_START_SECONDS,
            prepSeconds = AUTO_PREP_SECONDS);
    while true {
        error? result = advanceKitchens();
        if result is error {
            log:printWarn("kitchen simulation tick failed", reason = result.message());
        }
        runtime:sleep(2);
    }
}

function advanceKitchens() returns error? {
    int now = nowMs();
    KitchenTicket[] queued = check findTickets({status: "QUEUED", receivedAtMs: {"$lte": now - AUTO_START_SECONDS * 1000}});
    foreach KitchenTicket t in queued {
        _ = check startPreparing(t.orderId, t.restaurantId);
    }
    KitchenTicket[] cooking = check findTickets({status: "PREPARING",
        startedAtMs: {"$lte": now - AUTO_PREP_SECONDS * 1000}});
    foreach KitchenTicket t in cooking {
        _ = check markReady(t.orderId, t.restaurantId);
    }
}

// ---------------------------------------------------------------------------
// Seed data - Windhoek restaurants
// ---------------------------------------------------------------------------

function seedRestaurants() returns error? {
    int existing = check restaurantsCol->countDocuments({});
    if existing > 0 {
        return;
    }
    string now = nowIso();
    domain:OpeningHours[] allDay = domain:everyDay("00:00", "23:59");
    Restaurant[] restaurants = [
        {restaurantId: "R-1001", name: "Kalahari Grill House", cuisine: "Grill",
            description: "Flame-grilled game meat and steaks", phone: "+264612001001",
            address: "Sam Nujoma Dr, Klein Windhoek", location: {lat: -22.5640, lon: 17.0985},
            openingHours: allDay, acceptingOrders: true, rating: 4.6, avgPrepMinutes: 20, createdAt: now, updatedAt: now},
        {restaurantId: "R-1002", name: "Namib Pizza Co.", cuisine: "Pizza",
            description: "Wood-fired pizza in the heart of the city", phone: "+264612001002",
            address: "Post Street Mall, CBD", location: {lat: -22.5705, lon: 17.0840},
            openingHours: allDay, acceptingOrders: true, rating: 4.4, avgPrepMinutes: 15, createdAt: now, updatedAt: now},
        {restaurantId: "R-1003", name: "Kapana Corner", cuisine: "Namibian",
            description: "Authentic kapana and vetkoek from Single Quarters", phone: "+264612001003",
            address: "Single Quarters Market, Katutura", location: {lat: -22.5290, lon: 17.0530},
            openingHours: allDay, acceptingOrders: true, rating: 4.8, avgPrepMinutes: 10, createdAt: now, updatedAt: now},
        {restaurantId: "R-1004", name: "Swakop Sushi Bar", cuisine: "Sushi",
            description: "Fresh Atlantic fish from the coast", phone: "+264612001004",
            address: "Eros Shopping Centre, Eros", location: {lat: -22.5540, lon: 17.0960},
            openingHours: allDay, acceptingOrders: true, rating: 4.3, avgPrepMinutes: 18, createdAt: now, updatedAt: now},
        {restaurantId: "R-1005", name: "Oshana Green Kitchen", cuisine: "Vegan",
            description: "Plant-based bowls (closed on Sundays)", phone: "+264612001005",
            address: "Bahnhof St, Windhoek West", location: {lat: -22.5660, lon: 17.0700},
            openingHours: [
                {day: "MON", open: "10:00", close: "21:00"}, {day: "TUE", open: "10:00", close: "21:00"},
                {day: "WED", open: "10:00", close: "21:00"}, {day: "THU", open: "10:00", close: "21:00"},
                {day: "FRI", open: "10:00", close: "23:00"}, {day: "SAT", open: "11:00", close: "23:00"}
            ],
            acceptingOrders: true, rating: 4.5, avgPrepMinutes: 12, createdAt: now, updatedAt: now}
    ];
    check restaurantsCol->insertMany(restaurants);

    [string, string, string, string, float, int][] dishes = [
        ["R-1001", "Oryx Steak", "Mains", "300g oryx fillet with pap and chakalaka", 189.0, 25],
        ["R-1001", "Kudu Burger", "Mains", "Game burger with chips", 129.0, 30],
        ["R-1001", "Boerewors Roll", "Snacks", "Traditional farm sausage roll", 69.0, 40],
        ["R-1001", "Windhoek Lager (non-alc)", "Drinks", "Chilled 330ml", 25.0, 60],
        ["R-1002", "Margherita", "Pizza", "Tomato, mozzarella, basil", 95.0, 30],
        ["R-1002", "Kalahari BBQ Chicken", "Pizza", "BBQ chicken, peppers, onion", 135.0, 25],
        ["R-1002", "Garlic Bread", "Sides", "Wood-fired garlic bread", 45.0, 40],
        ["R-1002", "Lemonade", "Drinks", "Freshly squeezed", 30.0, 50],
        ["R-1003", "Kapana Platter", "Mains", "Grilled beef strips with chilli salt and salsa", 85.0, 50],
        ["R-1003", "Vetkoek & Mince", "Mains", "Fried dough with savoury mince", 55.0, 40],
        ["R-1003", "Mahangu Porridge", "Sides", "Pearl millet porridge", 35.0, 30],
        ["R-1003", "Oshikundu", "Drinks", "Traditional millet drink", 20.0, 3],
        ["R-1004", "Salmon Roses (8)", "Sushi", "Salmon roses with mayo", 145.0, 20],
        ["R-1004", "California Roll (8)", "Sushi", "Crab, avocado, cucumber", 115.0, 25],
        ["R-1004", "Miso Soup", "Sides", "Classic miso", 40.0, 30],
        ["R-1004", "Green Tea", "Drinks", "Hot pot of green tea", 28.0, 40],
        ["R-1005", "Buddha Bowl", "Bowls", "Quinoa, roasted veg, tahini", 110.0, 20],
        ["R-1005", "Lentil Curry", "Mains", "Red lentil dhal with rice", 95.0, 20],
        ["R-1005", "Green Smoothie", "Drinks", "Spinach, banana, mango", 48.0, 25]
    ];
    MenuItem[] items = [];
    int counter = 1;
    foreach var [restaurantId, name, category, description, price, stock] in dishes {
        items.push({itemId: string `M-${counter + 100}`, restaurantId, name, description, category, price, stock,
            available: true, prepMinutes: 10, updatedAt: now});
        counter += 1;
    }
    check menuCol->insertMany(items);
    log:printInfo("seeded restaurants and menus", restaurants = restaurants.length(), menuItems = items.length());
}
