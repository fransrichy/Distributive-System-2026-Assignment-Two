import ballerina/constraint;

public type GeoPoint record {|
    @constraint:Float {minValue: -90, maxValue: 90}
    float lat;
    @constraint:Float {minValue: -180, maxValue: 180}
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

# Persisted in `customer_db.customers`. Password hashes never leave the service.
public type Customer record {|
    string customerId;
    string name;
    string email;
    string phone;
    string passwordHash;
    Address[] addresses;
    NotificationPrefs notificationPrefs;
    int totalOrders;
    float totalSpent;
    string createdAt;
    string updatedAt;
|};

# Public representation of a customer account.
public type CustomerView record {|
    string customerId;
    string name;
    string email;
    string phone;
    Address[] addresses;
    NotificationPrefs notificationPrefs;
    int totalOrders;
    float totalSpent;
    string createdAt;
    string updatedAt;
|};

# Read model in `customer_db.order_history`, built from `orders.status-changed` events.
public type OrderHistoryEntry record {|
    string orderId;
    string customerId;
    string restaurantId;
    string restaurantName;
    string status;
    float total;
    string currency;
    int itemCount;
    string? driverName;
    string? reason;
    string orderCreatedAt;
    int orderCreatedAtMs;
    string updatedAt;
    int updatedAtMs;
|};

public type AddressInput record {|
    @constraint:String {minLength: 1, maxLength: 40}
    string label = "Home";
    @constraint:String {minLength: 3, maxLength: 200}
    string street;
    string city = "Windhoek";
    GeoPoint location;
    boolean isDefault = false;
|};

public type RegisterRequest record {|
    @constraint:String {minLength: 2, maxLength: 80}
    string name;
    @constraint:String {pattern: re `[^@\s]+@[^@\s]+\.[^@\s]+`}
    string email;
    @constraint:String {minLength: 7, maxLength: 20}
    string phone;
    @constraint:String {minLength: 6, maxLength: 100}
    string password;
    AddressInput? address = ();
    NotificationPrefs notificationPrefs = {email: true, sms: true, push: true};
|};

public type LoginRequest record {|
    string email;
    string password;
|};

public type UpdateCustomerRequest record {|
    string? name = ();
    string? phone = ();
    NotificationPrefs? notificationPrefs = ();
|};

type OrderStatusChangedEvent record {
    string orderId;
    string customerId;
    string restaurantId;
    string restaurantName;
    string? driverName = ();
    string previousStatus;
    string status;
    string? reason = ();
    float total;
    string currency;
    int itemCount;
    string orderCreatedAt;
    int orderCreatedAtMs;
    string at;
    int atMs;
};

type CustomerRegisteredEvent record {|
    string customerId;
    string name;
    string email;
    string phone;
    NotificationPrefs notificationPrefs;
|};
