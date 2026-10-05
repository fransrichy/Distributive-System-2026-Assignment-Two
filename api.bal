import ballerina/http;
import ballerina/log;
import ballerinax/mongodb;

@http:ServiceConfig {cors: CORS}
service /customers on httpListener {

    # Registers a customer account and publishes `customers.registered`.
    resource function post .(@http:Payload RegisterRequest request)
            returns http:Created|http:Conflict|error {
        string email = request.email.toLowerAscii();
        Customer? existing = check findCustomerByEmail(email);
        if existing is Customer {
            return conflictError("An account with this email already exists");
        }
        string now = nowIso();
        Address[] addresses = [];
        AddressInput? input = request.address;
        if input is AddressInput {
            addresses.push({addressId: "A-1", label: input.label, street: input.street, city: input.city,
                location: input.location, isDefault: true});
        }
        Customer customer = {
            customerId: newId("C"),
            name: request.name,
            email,
            phone: request.phone,
            passwordHash: check hashPassword(request.password),
            addresses,
            notificationPrefs: request.notificationPrefs,
            totalOrders: 0,
            totalSpent: 0.0,
            createdAt: now,
            updatedAt: now
        };
        error? inserted = customersCol->insertOne(customer);
        if inserted is error {
            return isDuplicateKey(inserted) ? conflictError("An account with this email already exists") : inserted;
        }
        emit(TOPIC_CUSTOMERS_REGISTERED, "CustomerRegistered", customer.customerId, <CustomerRegisteredEvent>{
            customerId: customer.customerId,
            name: customer.name,
            email: customer.email,
            phone: customer.phone,
            notificationPrefs: customer.notificationPrefs
        });
        incCounter("fd_customers_registered_total", "Customer registrations");
        http:Created created = {body: toView(customer), headers: {"Location": "/customers/" + customer.customerId}};
        return created;
    }

    resource function post login(@http:Payload LoginRequest request) returns CustomerView|http:Unauthorized|error {
        Customer? customer = check findCustomerByEmail(request.email);
        if customer is () || !verifyPassword(request.password, customer.passwordHash) {
            return unauthorized("Invalid email or password");
        }
        return toView(customer);
    }

    resource function get .() returns CustomerView[]|error {
        stream<Customer, error?> results = check customersCol->find({}, {sort: {"name": 1}}, NO_ID, Customer);
        CustomerView[] views = check from Customer c in results select toView(c);
        check results.close();
        return views;
    }

    resource function get [string customerId]() returns CustomerView|http:NotFound|error {
        Customer? customer = check findCustomer(customerId);
        return customer is Customer ? toView(customer) : notFound("Customer not found: " + customerId);
    }

    resource function put [string customerId](@http:Payload UpdateCustomerRequest request)
            returns CustomerView|http:NotFound|error {
        map<json> fields = {updatedAt: nowIso()};
        if request.name is string {
            fields["name"] = request.name;
        }
        if request.phone is string {
            fields["phone"] = request.phone;
        }
        NotificationPrefs? prefs = request.notificationPrefs;
        if prefs is NotificationPrefs {
            fields["notificationPrefs"] = prefs.toJson();
        }
        mongodb:UpdateResult result = check customersCol->updateOne({customerId}, {set: fields});
        if result.matchedCount == 0 {
            return notFound("Customer not found: " + customerId);
        }
        Customer? updated = check findCustomer(customerId);
        return updated is Customer ? toView(updated) : notFound("Customer not found: " + customerId);
    }

    // ---- Delivery addresses ----

    resource function get [string customerId]/addresses() returns Address[]|http:NotFound|error {
        Customer? customer = check findCustomer(customerId);
        return customer is Customer ? customer.addresses : notFound("Customer not found: " + customerId);
    }

    resource function post [string customerId]/addresses(@http:Payload AddressInput input)
            returns http:Created|http:NotFound|error {
        Customer? customer = check findCustomer(customerId);
        if customer is () {
            return notFound("Customer not found: " + customerId);
        }
        string addressId = newId("A");
        Address[] addresses = [...customer.addresses,
            {addressId, label: input.label, street: input.street, city: input.city, location: input.location,
                isDefault: input.isDefault}];
        addresses = normaliseDefault(addresses, input.isDefault ? addressId : ());
        check saveAddresses(customerId, addresses);
        http:Created created = {body: addresses};
        return created;
    }

    resource function put [string customerId]/addresses/[string addressId](@http:Payload AddressInput input)
            returns Address[]|http:NotFound|error {
        Customer? customer = check findCustomer(customerId);
        if customer is () {
            return notFound("Customer not found: " + customerId);
        }
        boolean found = false;
        Address[] addresses = [];
        foreach Address a in customer.addresses {
            if a.addressId == addressId {
                found = true;
                addresses.push({addressId, label: input.label, street: input.street, city: input.city,
                    location: input.location, isDefault: input.isDefault});
            } else {
                addresses.push(a);
            }
        }
        if !found {
            return notFound("Address not found: " + addressId);
        }
        addresses = normaliseDefault(addresses, input.isDefault ? addressId : ());
        check saveAddresses(customerId, addresses);
        return addresses;
    }

    resource function delete [string customerId]/addresses/[string addressId]()
            returns Address[]|http:NotFound|error {
        Customer? customer = check findCustomer(customerId);
        if customer is () {
            return notFound("Customer not found: " + customerId);
        }
        Address[] remaining = from Address a in customer.addresses where a.addressId != addressId select a;
        if remaining.length() == customer.addresses.length() {
            return notFound("Address not found: " + addressId);
        }
        remaining = normaliseDefault(remaining, ());
        check saveAddresses(customerId, remaining);
        return remaining;
    }

    // ---- Historical order data (event-sourced read model) ----

    resource function get [string customerId]/orders(string? status, int 'limit = 50)
            returns OrderHistoryEntry[]|error {
        map<json> filter = {customerId};
        if status is string {
            filter["status"] = status.toUpperAscii();
        }
        stream<OrderHistoryEntry, error?> results = check historyCol->find(filter,
            {sort: {"orderCreatedAtMs": -1}, 'limit}, NO_ID, OrderHistoryEntry);
        OrderHistoryEntry[] entries = check from OrderHistoryEntry e in results select e;
        check results.close();
        return entries;
    }
}

function saveAddresses(string customerId, Address[] addresses) returns error? {
    mongodb:UpdateResult _ = check customersCol->updateOne({customerId},
        {set: {addresses: addresses.toJson(), updatedAt: nowIso()}});
    log:printInfo("addresses updated", customerId = customerId, count = addresses.length());
}
