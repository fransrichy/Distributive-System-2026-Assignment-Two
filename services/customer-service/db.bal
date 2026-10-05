import ballerina/crypto;
import ballerina/log;
import ballerinax/mongodb;

final mongodb:Collection customersCol = check getCollection("customers");
final mongodb:Collection historyCol = check getCollection("order_history");

function init() {
    if SEED_DATA {
        error? seeded = seedCustomers();
        if seeded is error {
            log:printError("customer seeding failed", seeded);
        }
    }
}

function findCustomer(string customerId) returns Customer|error? {
    return customersCol->findOne({customerId}, {}, NO_ID, Customer);
}

function findCustomerByEmail(string email) returns Customer|error? {
    return customersCol->findOne({email: email.toLowerAscii()}, {}, NO_ID, Customer);
}

function toView(Customer c) returns CustomerView => {
    customerId: c.customerId,
    name: c.name,
    email: c.email,
    phone: c.phone,
    addresses: c.addresses,
    notificationPrefs: c.notificationPrefs,
    totalOrders: c.totalOrders,
    totalSpent: c.totalSpent,
    createdAt: c.createdAt,
    updatedAt: c.updatedAt
};

isolated function hashPassword(string password) returns string|error => crypto:hashBcrypt(password, 10);

isolated function verifyPassword(string password, string hash) returns boolean {
    boolean|error ok = crypto:verifyBcrypt(password, hash);
    return ok is boolean && ok;
}

# Applies the "exactly one default address" invariant.
isolated function normaliseDefault(Address[] addresses, string? preferredDefault) returns Address[] {
    if addresses.length() == 0 {
        return addresses;
    }
    string defaultId = preferredDefault ?: "";
    if defaultId == "" {
        foreach Address a in addresses {
            if a.isDefault {
                defaultId = a.addressId;
                break;
            }
        }
    }
    if defaultId == "" {
        defaultId = addresses[0].addressId;
    }
    return from Address a in addresses select {addressId: a.addressId, label: a.label, street: a.street, city: a.city, location: a.location,
        isDefault: a.addressId == defaultId};
}

function seedCustomers() returns error? {
    int existing = check customersCol->countDocuments({});
    if existing > 0 {
        return;
    }
    string hash = check hashPassword("password123");
    string now = nowIso();
    Customer[] demo = [
        {
            customerId: "C-3001", name: "Demo Customer", email: "demo@fooddelivery.na", phone: "+264811234567",
            passwordHash: hash,
            addresses: [
                {addressId: "A-1", label: "Home", street: "12 Nelson Mandela Ave, Klein Windhoek", city: "Windhoek",
                    location: {lat: -22.5662, lon: 17.1050}, isDefault: true},
                {addressId: "A-2", label: "Work", street: "Independence Ave 101, CBD", city: "Windhoek",
                    location: {lat: -22.5741, lon: 17.0830}, isDefault: false}
            ],
            notificationPrefs: {email: true, sms: true, push: true}, totalOrders: 0, totalSpent: 0.0,
            createdAt: now, updatedAt: now
        },
        {
            customerId: "C-3002", name: "Ndapewa Shikongo", email: "ndapewa@fooddelivery.na", phone: "+264812345678",
            passwordHash: hash,
            addresses: [
                {addressId: "A-1", label: "Home", street: "45 Hosea Kutako Dr, Katutura", city: "Windhoek",
                    location: {lat: -22.5310, lon: 17.0590}, isDefault: true}
            ],
            notificationPrefs: {email: true, sms: false, push: true}, totalOrders: 0, totalSpent: 0.0,
            createdAt: now, updatedAt: now
        },
        {
            customerId: "C-3003", name: "Johan van Wyk", email: "johan@fooddelivery.na", phone: "+264813456789",
            passwordHash: hash,
            addresses: [
                {addressId: "A-1", label: "Home", street: "8 Schanzen Rd, Olympia", city: "Windhoek",
                    location: {lat: -22.5925, lon: 17.0915}, isDefault: true}
            ],
            notificationPrefs: {email: false, sms: true, push: true}, totalOrders: 0, totalSpent: 0.0,
            createdAt: now, updatedAt: now
        }
    ];
    check customersCol->insertMany(demo);
    log:printInfo("seeded demo customers", count = demo.length());
}
