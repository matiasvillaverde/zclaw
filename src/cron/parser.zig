const std = @import("std");

// --- Cron Expression Parser ---
//
// Standard 5-field cron: minute hour day-of-month month day-of-week
// Supports: * (any), specific values, ranges (1-5), steps (*/5)

/// A field set using a u64 bitfield (supports values 0-63).
pub const FieldSet = struct {
    bits: u64 = 0,

    pub fn set(self: *FieldSet, val: u6) void {
        self.bits |= @as(u64, 1) << val;
    }

    pub fn isSet(self: *const FieldSet, val: u6) bool {
        return (self.bits & (@as(u64, 1) << val)) != 0;
    }

    pub fn setAll(self: *FieldSet, min: u6, max: u6) void {
        var i: u6 = min;
        while (i <= max) : (i += 1) {
            self.set(i);
            if (i == max) break;
        }
    }

    pub fn setStep(self: *FieldSet, min: u6, max: u6, step: u6) void {
        if (step == 0) return;
        var i: u6 = min;
        while (i <= max) {
            self.set(i);
            const next = @as(u7, i) + step;
            if (next > max) break;
            i = @intCast(next);
        }
    }

    pub fn count(self: *const FieldSet) u32 {
        return @popCount(self.bits);
    }
};

/// Parsed cron expression with 5 fields.
pub const CronExpr = struct {
    minute: FieldSet = .{},
    hour: FieldSet = .{},
    day_of_month: FieldSet = .{},
    month: FieldSet = .{},
    day_of_week: FieldSet = .{},

    /// Check if a timestamp matches this expression.
    /// Takes broken-down time components.
    pub fn matches(self: *const CronExpr, minute: u6, hour: u5, mday: u5, month: u4, wday: u3) bool {
        if (!self.minute.isSet(minute)) return false;
        if (!self.hour.isSet(@intCast(hour))) return false;
        if (!self.day_of_month.isSet(@intCast(mday))) return false;
        if (!self.month.isSet(@intCast(month))) return false;
        if (!self.day_of_week.isSet(@intCast(wday))) return false;
        return true;
    }
};

/// Parse a single cron field.
fn parseField(field: []const u8, min: u6, max: u6) !FieldSet {
    var fs = FieldSet{};

    if (field.len == 0) return error.InvalidField;

    // Wildcard
    if (std.mem.eql(u8, field, "*")) {
        fs.setAll(min, max);
        return fs;
    }

    // Step: */N or M-N/S
    if (std.mem.indexOf(u8, field, "/")) |slash_pos| {
        const step = std.fmt.parseInt(u6, field[slash_pos + 1 ..], 10) catch return error.InvalidField;
        if (step == 0) return error.InvalidField;

        if (std.mem.eql(u8, field[0..slash_pos], "*")) {
            fs.setStep(min, max, step);
        } else if (std.mem.indexOf(u8, field[0..slash_pos], "-")) |dash_pos| {
            const range_min = std.fmt.parseInt(u6, field[0..dash_pos], 10) catch return error.InvalidField;
            const range_max = std.fmt.parseInt(u6, field[dash_pos + 1 .. slash_pos], 10) catch return error.InvalidField;
            fs.setStep(range_min, range_max, step);
        }
        return fs;
    }

    // Range: M-N
    if (std.mem.indexOf(u8, field, "-")) |dash_pos| {
        const range_min = std.fmt.parseInt(u6, field[0..dash_pos], 10) catch return error.InvalidField;
        const range_max = std.fmt.parseInt(u6, field[dash_pos + 1 ..], 10) catch return error.InvalidField;
        if (range_min > range_max) return error.InvalidField;
        fs.setAll(range_min, range_max);
        return fs;
    }

    // Specific value
    const val = std.fmt.parseInt(u6, field, 10) catch return error.InvalidField;
    if (val < min or val > max) return error.InvalidField;
    fs.set(val);
    return fs;
}

/// Parse a 5-field cron expression.
pub fn parse(expr: []const u8) !CronExpr {
    var fields: [5][]const u8 = undefined;
    var field_count: usize = 0;
    var iter = std.mem.splitScalar(u8, expr, ' ');

    while (iter.next()) |field| {
        if (field.len == 0) continue;
        if (field_count >= 5) return error.InvalidField;
        fields[field_count] = field;
        field_count += 1;
    }

    if (field_count != 5) return error.InvalidField;

    return .{
        .minute = try parseField(fields[0], 0, 59),
        .hour = try parseField(fields[1], 0, 23),
        .day_of_month = try parseField(fields[2], 1, 31),
        .month = try parseField(fields[3], 1, 12),
        .day_of_week = try parseField(fields[4], 0, 6),
    };
}

// --- Tests ---

test "FieldSet basic operations" {
    var fs = FieldSet{};
    try std.testing.expect(!fs.isSet(0));

    fs.set(5);
    try std.testing.expect(fs.isSet(5));
    try std.testing.expect(!fs.isSet(6));
    try std.testing.expectEqual(@as(u32, 1), fs.count());
}

test "FieldSet setAll" {
    var fs = FieldSet{};
    fs.setAll(1, 5);
    try std.testing.expect(fs.isSet(1));
    try std.testing.expect(fs.isSet(3));
    try std.testing.expect(fs.isSet(5));
    try std.testing.expect(!fs.isSet(0));
    try std.testing.expect(!fs.isSet(6));
    try std.testing.expectEqual(@as(u32, 5), fs.count());
}

test "FieldSet setStep" {
    var fs = FieldSet{};
    fs.setStep(0, 59, 15);
    try std.testing.expect(fs.isSet(0));
    try std.testing.expect(fs.isSet(15));
    try std.testing.expect(fs.isSet(30));
    try std.testing.expect(fs.isSet(45));
    try std.testing.expect(!fs.isSet(1));
}

test "parse every minute" {
    const cron = try parse("* * * * *");
    try std.testing.expectEqual(@as(u32, 60), cron.minute.count());
    try std.testing.expectEqual(@as(u32, 24), cron.hour.count());
}

test "parse specific time" {
    const cron = try parse("30 9 * * *");
    try std.testing.expect(cron.minute.isSet(30));
    try std.testing.expect(!cron.minute.isSet(0));
    try std.testing.expect(cron.hour.isSet(9));
    try std.testing.expect(!cron.hour.isSet(10));
}

test "parse step" {
    const cron = try parse("*/15 * * * *");
    try std.testing.expect(cron.minute.isSet(0));
    try std.testing.expect(cron.minute.isSet(15));
    try std.testing.expect(cron.minute.isSet(30));
    try std.testing.expect(cron.minute.isSet(45));
    try std.testing.expect(!cron.minute.isSet(1));
}

test "parse range" {
    const cron = try parse("* 9-17 * * *");
    try std.testing.expect(cron.hour.isSet(9));
    try std.testing.expect(cron.hour.isSet(12));
    try std.testing.expect(cron.hour.isSet(17));
    try std.testing.expect(!cron.hour.isSet(8));
    try std.testing.expect(!cron.hour.isSet(18));
}

test "parse weekday range" {
    const cron = try parse("0 0 * * 1-5");
    try std.testing.expect(cron.day_of_week.isSet(1));
    try std.testing.expect(cron.day_of_week.isSet(5));
    try std.testing.expect(!cron.day_of_week.isSet(0));
    try std.testing.expect(!cron.day_of_week.isSet(6));
}

test "CronExpr matches" {
    const cron = try parse("30 9 * * *");
    try std.testing.expect(cron.matches(30, 9, 15, 6, 1));
    try std.testing.expect(!cron.matches(0, 9, 15, 6, 1));
    try std.testing.expect(!cron.matches(30, 10, 15, 6, 1));
}

test "parse invalid too few fields" {
    try std.testing.expectError(error.InvalidField, parse("* * *"));
}

test "parse invalid too many fields" {
    try std.testing.expectError(error.InvalidField, parse("* * * * * *"));
}

test "parse invalid value" {
    try std.testing.expectError(error.InvalidField, parse("60 * * * *"));
}

test "parse invalid range" {
    try std.testing.expectError(error.InvalidField, parse("* 25 * * *"));
}

test "parseField specific value" {
    const fs = try parseField("42", 0, 59);
    try std.testing.expect(fs.isSet(42));
    try std.testing.expectEqual(@as(u32, 1), fs.count());
}
