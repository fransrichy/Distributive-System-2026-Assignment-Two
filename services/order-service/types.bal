import order_service.domain;

import ballerina/constraint;

public type GeoPoint record {|
    float lat;
    float lon;
|};

public type Address record {|
    string addressId;
    string label;
    string street;
    string city;
    GeoPoint location;
    boolean isDefault;
|};

public type NotificationPrefs record {|
    boolean email;
    boolean sms;
    boolean push;
|};

public type OrderItem record {|
    string itemId;
    string name;
    float unitPrice;
    int quantity;
    float lineTotal;
|};

public type StatusChange record {|
    domain:OrderStatus status;
    string at;
    int atMs;
    string? reason;
    string actor;
|};

public type PaymentMethod "CARD"|"MOBILE_MONEY"|"CASH_ON_DELIVERY";

# Aggregate root persisted in `order_db.orders`.
public type Order record {|
    string orderId;
    string customerId;
    string customerName;
    string customerEmail;
    string customerPhone;
    NotificationPrefs notificationPrefs;
    string restaurantId;
    string restaurantName;
    GeoPoint restaurantLocation;
    Address deliveryAddress;
    OrderItem[] items;
    float subtotal;
    float deliveryFee;
    float surgeMultiplier;
    float estimatedDistanceKm;
    float total;
    string currency;
    PaymentMethod paymentMethod;
    string? paymentId;
    domain:OrderStatus status;
    StatusChange[] statusHistory;
    string? driverId;
    string? driverName;
    int? etaMinutes;
    string? cancelReason;
    string? notes;
    # Optimistic-locking version, incremented on every state change
    int version;
    string createdAt;
    int createdAtMs;
    string updatedAt;
    int updatedAtMs;
|};

// ---- REST payloads ----

public type OrderLine record {|
    @constraint:String {minLength: 1}
    string itemId;
    @constraint:Int {minValue: 1, maxValue: 50}
    int quantity;
|};

public type CreateOrderRequest record {|
    @constraint:String {minLength: 1}
    string customerId;
    @constraint:String {minLength: 1}
    string restaurantId;
    @constraint:Array {minLength: 1, maxLength: 30}
    OrderLine[] items;
    string? addressId = ();
    PaymentMethod paymentMethod = "CARD";
    # Only the last four digits are ever sent - card numbers are never stored
    string? cardLast4 = ();
    string? notes = ();
|};

public type CancelRequest record {|
    string reason = "Cancelled by customer";
|};

public type PriceQuote record {|
    string restaurantId;
    float estimatedDistanceKm;
    float baseDeliveryFee;
    float surgeMultiplier;
    string surgeLevel;
    string[] surgeReasons;
    float deliveryFee;
    string currency;
|};

// ---- DTOs returned by other services (open records tolerate extra fields) ----

type CustomerDto record {
    string customerId;
    string name;
    string email;
    string phone;
    Address[] addresses;
    NotificationPrefs notificationPrefs;
};

type RestaurantDto record {
    string restaurantId;
    string name;
    GeoPoint location;
    boolean isOpenNow;
    boolean acceptingOrders;
};

type MenuItemDto record {
    string itemId;
    string name;
    float price;
    int stock;
    boolean available;
};

type DriverSummaryDto record {
    int available;
    int busy;
    int offline;
};

// ---- Event payloads ----

type OrderCreatedEvent record {|
    *Order;
    string? cardLast4;
|};

type OrderStatusChangedEvent record {|
    string orderId;
    string customerId;
    string customerName;
    string customerEmail;
    string customerPhone;
    NotificationPrefs notificationPrefs;
    string restaurantId;
    string restaurantName;
    string? driverId;
    string? driverName;
    domain:OrderStatus previousStatus;
    domain:OrderStatus status;
    string? reason;
    float subtotal;
    float deliveryFee;
    float surgeMultiplier;
    float total;
    string currency;
    int itemCount;
    float estimatedDistanceKm;
    string orderCreatedAt;
    int orderCreatedAtMs;
    string at;
    int atMs;
|};

type OrderCancelledEvent record {|
    string orderId;
    string customerId;
    string restaurantId;
    domain:OrderStatus previousStatus;
    string reason;
    string? paymentId;
    boolean refundRequired;
    float total;
|};

type PaymentEvent record {
    string orderId;
    string paymentId;
    string? reason = ();
};

type RestaurantOrderEvent record {
    string orderId;
    string? reason = ();
};

type DeliveryEvent record {
    string orderId;
    string? driverId = ();
    string? driverName = ();
    int? etaMinutes = ();
};

type MenuItemDtoList MenuItemDto[];
