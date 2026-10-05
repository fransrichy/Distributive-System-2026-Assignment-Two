import notification_service.domain;

import ballerina/http;
import ballerina/log;
import ballerinax/mongodb;

# Persisted in `notification_db.notifications` - the notification inbox / audit log.
public type Notification record {|
    # Deterministic id (eventId + recipient + channel) => duplicates are rejected by a unique index
    string notificationId;
    string eventId;
    string eventType;
    string topic;
    string? orderId;
    domain:Recipient recipientType;
    string recipientId;
    domain:Channel channel;
    string destination;
    string title;
    string body;
    string status;
    boolean read;
    string createdAt;
    int createdAtMs;
|};

# Cached customer contact details (`notification_db.contacts`), fed by events.
type ContactDoc record {|
    string customerId;
    string? email;
    string? phone;
    boolean emailOn;
    boolean smsOn;
    boolean pushOn;
|};

type Prefs record {
    boolean email;
    boolean sms;
    boolean push;
};

type NotificationSent record {|
    string notificationId;
    string orderId;
    string recipientType;
    string recipientId;
    string channel;
|};

final mongodb:Collection notificationsCol = check getCollection("notifications");
final mongodb:Collection contactsCol = check getCollection("contacts");

function handleEvent(string topic, EventEnvelope envelope) returns error? {
    map<json> data = check envelope.data.cloneWithType();
    check rememberContact(data);
    string customerId = data["customerId"] is string ? <string>data["customerId"] : "";
    ContactDoc? contactDoc = check contactsCol->findOne({customerId}, {}, NO_ID, ContactDoc);
    domain:Contact contact = contactDoc is ContactDoc
        ? {email: contactDoc.email, phone: contactDoc.phone, emailOn: contactDoc.emailOn, smsOn: contactDoc.smsOn,
            pushOn: contactDoc.pushOn}
        : domain:UNKNOWN_CONTACT;

    foreach domain:Message message in domain:messagesFor(topic, data, contact) {
        string? orderId = data["orderId"] is string ? <string>data["orderId"] : ();
        Notification notification = {
            notificationId: string `${envelope.eventId}-${message.recipientType}-${message.channel}`,
            eventId: envelope.eventId,
            eventType: envelope.eventType,
            topic,
            orderId,
            recipientType: message.recipientType,
            recipientId: message.recipientId,
            channel: message.channel,
            destination: domain:destinationOf(message, contact),
            title: message.title,
            body: message.body,
            status: "SENT",
            read: false,
            createdAt: nowIso(),
            createdAtMs: nowMs()
        };
        error? stored = notificationsCol->insertOne(notification);
        if stored is error {
            if isDuplicateKey(stored) {
                continue; // event redelivered - this notification was already sent
            }
            return stored;
        }
        dispatch(notification);
        emit(TOPIC_NOTIFICATIONS_SENT, "NotificationSent", orderId ?: message.recipientId, <NotificationSent>{
            notificationId: notification.notificationId,
            orderId: orderId ?: "",
            recipientType: message.recipientType,
            recipientId: message.recipientId,
            channel: message.channel
        });
    }
}

# Simulated channel gateways (SMTP / SMS aggregator / push service).
function dispatch(Notification n) {
    incCounter("fd_notifications_sent_total", "Notifications dispatched", {channel: n.channel, recipient: n.recipientType});
    log:printInfo(string `[${n.channel}] -> ${n.recipientType} ${n.recipientId} (${n.destination}): ${n.title}`,
            orderId = n.orderId);
}

# Keeps the contact cache up to date from registration and order events.
function rememberContact(map<json> data) returns error? {
    json customerId = data["customerId"];
    json email = data["customerEmail"] ?: data["email"];
    json phone = data["customerPhone"] ?: data["phone"];
    json prefs = data["notificationPrefs"];
    if customerId !is string || (email is () && phone is ()) {
        return;
    }
    Prefs p = prefs is map<json> ? check prefs.cloneWithType() : {email: true, sms: true, push: true};
    ContactDoc contact = {
        customerId,
        email: email is string ? email : (),
        phone: phone is string ? phone : (),
        emailOn: p.email,
        smsOn: p.sms,
        pushOn: p.push
    };
    mongodb:UpdateResult _ = check contactsCol->updateOne({customerId}, {set: <map<json>>contact.toJson()},
        {upsert: true});
}

@http:ServiceConfig {cors: CORS}
service /notifications on httpListener {

    resource function get .(string? recipientType, string? recipientId, string? orderId, string? channel,
            int 'limit = 50) returns Notification[]|error {
        map<json> filter = {};
        if recipientType is string {
            filter["recipientType"] = recipientType.toUpperAscii();
        }
        if recipientId is string {
            filter["recipientId"] = recipientId;
        }
        if orderId is string {
            filter["orderId"] = orderId;
        }
        if channel is string {
            filter["channel"] = channel.toUpperAscii();
        }
        stream<Notification, error?> results = check notificationsCol->find(filter,
            {sort: {"createdAtMs": -1}, 'limit}, NO_ID, Notification);
        Notification[] notifications = check from Notification n in results select n;
        check results.close();
        return notifications;
    }

    resource function get stats() returns map<int>|error {
        map<int> stats = {};
        foreach string channel in ["EMAIL", "SMS", "PUSH"] {
            stats[channel] = check countIn(notificationsCol, {channel});
        }
        foreach string recipient in ["CUSTOMER", "RESTAURANT", "DRIVER"] {
            stats[recipient] = check countIn(notificationsCol, {recipientType: recipient});
        }
        stats["UNREAD"] = check countIn(notificationsCol, {read: false});
        return stats;
    }

    resource function put [string notificationId]/read() returns http:Ok|http:NotFound|error {
        mongodb:UpdateResult result = check notificationsCol->updateOne({notificationId}, {set: {read: true}});
        return result.matchedCount == 0 ? notFound("Notification not found: " + notificationId) : http:OK;
    }
}
