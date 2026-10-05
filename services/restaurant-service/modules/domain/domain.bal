// Pure domain logic of the Restaurant service: kitchen opening hours.

public type OpeningHours record {|
    # MON, TUE, WED, THU, FRI, SAT or SUN
    string day;
    # 24h local time, `HH:MM`
    string open;
    # 24h local time, `HH:MM`. A close earlier than open means the kitchen closes after midnight.
    string close;
|};

final readonly & string[] DAYS = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"];

# Day code (MON..SUN) for a local epoch timestamp.
#
# + localEpochSeconds - seconds since 1970-01-01 shifted to local time
# + return - three letter day code
public isolated function dayCode(int localEpochSeconds) returns string {
    // 1970-01-01 was a Thursday (index 4 when Sunday = 0)
    int days = localEpochSeconds / 86400;
    return DAYS[(days + 4) % 7];
}

# Parses `HH:MM` into minutes after midnight.
#
# + value - time of day
# + return - minutes after midnight or an error for malformed input
public isolated function parseTime(string value) returns int|error {
    string[] parts = re `:`.split(value.trim());
    if parts.length() != 2 {
        return error(string `invalid time '${value}', expected HH:MM`);
    }
    int hours = check int:fromString(parts[0]);
    int minutes = check int:fromString(parts[1]);
    if hours < 0 || hours > 23 || minutes < 0 || minutes > 59 {
        return error(string `invalid time '${value}'`);
    }
    return hours * 60 + minutes;
}

# Validates an opening-hours schedule.
#
# + hours - schedule to validate
# + return - an error message, or `()` when the schedule is valid
public isolated function validateHours(OpeningHours[] hours) returns string? {
    foreach OpeningHours h in hours {
        if DAYS.indexOf(h.day.toUpperAscii()) is () {
            return "invalid day '" + h.day + "', use MON..SUN";
        }
        int|error open = parseTime(h.open);
        int|error close = parseTime(h.close);
        if open is error {
            return open.message();
        }
        if close is error {
            return close.message();
        }
        if open == close {
            return "open and close times must differ on " + h.day;
        }
    }
    return ();
}

# Whether the kitchen is open at a local moment in time. Supports schedules that run past
# midnight (e.g. FRI 18:00-02:00 keeps the kitchen open until 02:00 on Saturday).
#
# + hours - weekly schedule
# + localEpochSeconds - seconds since epoch shifted to local time
# + return - true when open
public isolated function isOpenAt(OpeningHours[] hours, int localEpochSeconds) returns boolean {
    string today = dayCode(localEpochSeconds);
    string yesterday = dayCode(localEpochSeconds - 86400);
    int minuteOfDay = (localEpochSeconds % 86400) / 60;
    foreach OpeningHours h in hours {
        int|error open = parseTime(h.open);
        int|error close = parseTime(h.close);
        if open is error || close is error {
            continue;
        }
        // 23:59 is treated as "until the end of the day"
        int effectiveClose = close == 23 * 60 + 59 ? 24 * 60 : close;
        string day = h.day.toUpperAscii();
        if open < effectiveClose {
            if day == today && minuteOfDay >= open && minuteOfDay < effectiveClose {
                return true;
            }
        } else {
            if day == today && minuteOfDay >= open {
                return true;
            }
            if day == yesterday && minuteOfDay < effectiveClose {
                return true;
            }
        }
    }
    return false;
}

# Convenience schedule: the same hours every day of the week.
#
# + open - opening time
# + close - closing time
# + return - a seven day schedule
public isolated function everyDay(string open, string close) returns OpeningHours[] =>
    from string day in DAYS select {day, open, close};
