import restaurant_service.domain;

import ballerina/constraint;

public type GeoPoint record {|
    @constraint:Float {minValue: -90, maxValue: 90}
    float lat;
    @constraint:Float {minValue: -180, maxValue: 180}
    float lon;
|};

# Persisted in `restaurant_db.restaurants`.
public type Restaurant record {|
    string restaurantId;
    string name;
    string cuisine;
    string description;
    string phone;
    string address;
    GeoPoint location;
    domain:OpeningHours[] openingHours;
    # Manual switch (e.g. kitchen overloaded) on top of the opening hours
    boolean acceptingOrders;
    float rating;
    int avgPrepMinutes;
    string createdAt;
    string updatedAt;
|};

public type RestaurantView record {|
    *Restaurant;
    boolean isOpenNow;
|};

# Persisted in `restaurant_db.menu_items` - one document per dish, `stock` is the live inventory.
public type MenuItem record {|
    string itemId;
    string restaurantId;
    string name;
    string description;
    string category;
    float price;
    int stock;
    boolean available;
    int prepMinutes;
    string updatedAt;
|};

public type TicketStatus "QUEUED"|"PREPARING"|"READY"|"CANCELLED"|"REJECTED";

public type TicketItem record {|
    string itemId;
    string name;
    int quantity;
|};

# Persisted in `restaurant_db.kitchen_tickets` - the kitchen's work queue.
public type KitchenTicket record {|
    string orderId;
    string restaurantId;
    string customerName;
    TicketItem[] items;
    TicketStatus status;
    string? notes;
    string? reason;
    string receivedAt;
    int receivedAtMs;
    string? startedAt;
    int? startedAtMs;
    string? readyAt;
    int? readyAtMs;
|};

// ---- REST payloads ----

public type RestaurantInput record {|
    @constraint:String {minLength: 2, maxLength: 80}
    string name;
    string cuisine;
    string description = "";
    string phone;
    string address;
    GeoPoint location;
    domain:OpeningHours[] openingHours = domain:everyDay("08:00", "22:00");
    int avgPrepMinutes = 15;
|};

public type MenuItemInput record {|
    @constraint:String {minLength: 2, maxLength: 80}
    string name;
    string description = "";
    string category = "Mains";
    @constraint:Float {minValue: 0.5, maxValue: 10000}
    float price;
    @constraint:Int {minValue: 0}
    int stock = 20;
    boolean available = true;
    int prepMinutes = 10;
|};

public type StockUpdate record {|
    # Absolute stock level
    int? stock = ();
    # Relative change (e.g. +10 after a delivery from a supplier)
    int? delta = ();
|};

public type AcceptingUpdate record {|
    boolean acceptingOrders;
|};

// ---- Event payloads ----

type ConfirmedOrderLine record {
    string itemId;
    string name;
    int quantity;
};

type OrderConfirmedEvent record {
    string orderId;
    string restaurantId;
    string customerName;
    ConfirmedOrderLine[] items;
    string? notes = ();
};

type OrderCancelledEvent record {
    string orderId;
    string restaurantId;
    string reason;
};

type KitchenEvent record {|
    string orderId;
    string restaurantId;
    string restaurantName;
    GeoPoint pickupLocation;
    string? reason;
    string at;
|};
