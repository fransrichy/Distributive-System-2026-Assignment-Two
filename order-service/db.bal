import ballerinax/mongodb;

final mongodb:Collection ordersCol = check getCollection("orders");

function findOrder(string orderId) returns Order|error? {
    return ordersCol->findOne({orderId}, {}, NO_ID, Order);
}

function findOrders(map<json> filter, int 'limit) returns Order[]|error {
    stream<Order, error?> results = check ordersCol->find(filter, {sort: {"createdAtMs": -1}, 'limit}, NO_ID, Order);
    Order[] orders = check from Order o in results select o;
    check results.close();
    return orders;
}
