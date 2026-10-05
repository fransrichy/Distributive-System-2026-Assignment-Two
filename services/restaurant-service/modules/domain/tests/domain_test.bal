import ballerina/test;

// 2026-10-05 is a Monday. Seconds since epoch at 00:00 (already in local time).
const int MONDAY_MIDNIGHT = 1791158400;

function at(int dayOffset, int hour, int minute) returns int =>
    MONDAY_MIDNIGHT + dayOffset * 86400 + hour * 3600 + minute * 60;

@test:Config {}
function dayCodeIsCorrect() {
    test:assertEquals(dayCode(0), "THU"); // 1970-01-01
    test:assertEquals(dayCode(MONDAY_MIDNIGHT), "MON");
    test:assertEquals(dayCode(at(6, 12, 0)), "SUN");
}

@test:Config {}
function regularHours() {
    OpeningHours[] hours = [{day: "MON", open: "10:00", close: "21:00"}];
    test:assertTrue(isOpenAt(hours, at(0, 10, 0)));
    test:assertTrue(isOpenAt(hours, at(0, 20, 59)));
    test:assertFalse(isOpenAt(hours, at(0, 21, 0)));
    test:assertFalse(isOpenAt(hours, at(0, 9, 59)));
    test:assertFalse(isOpenAt(hours, at(1, 12, 0)), "closed on Tuesday");
}

@test:Config {}
function overnightHoursSpillIntoNextDay() {
    OpeningHours[] hours = [{day: "FRI", open: "18:00", close: "02:00"}];
    test:assertTrue(isOpenAt(hours, at(4, 23, 30)), "Friday night");
    test:assertTrue(isOpenAt(hours, at(5, 1, 30)), "early Saturday");
    test:assertFalse(isOpenAt(hours, at(5, 2, 30)));
    test:assertFalse(isOpenAt(hours, at(4, 17, 0)));
}

@test:Config {}
function allDaySchedule() {
    OpeningHours[] hours = everyDay("00:00", "23:59");
    test:assertEquals(hours.length(), 7);
    test:assertTrue(isOpenAt(hours, at(2, 23, 59)));
    test:assertTrue(isOpenAt(hours, at(3, 0, 0)));
}

@test:Config {}
function scheduleValidation() {
    test:assertEquals(validateHours([{day: "MON", open: "08:00", close: "17:00"}]), ());
    test:assertTrue(validateHours([{day: "XYZ", open: "08:00", close: "17:00"}]) is string);
    test:assertTrue(validateHours([{day: "MON", open: "25:00", close: "17:00"}]) is string);
    test:assertTrue(validateHours([{day: "MON", open: "08:00", close: "08:00"}]) is string);
    test:assertTrue(parseTime("7") is error);
}
