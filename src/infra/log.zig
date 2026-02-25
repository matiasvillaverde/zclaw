const std = @import("std");

// --- Log Level ---

pub const Level = enum(u3) {
    fatal = 0,
    err = 1,
    warn = 2,
    info = 3,
    debug = 4,
    trace = 5,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .fatal => "fatal",
            .err => "error",
            .warn => "warn",
            .info => "info",
            .debug => "debug",
            .trace => "trace",
        };
    }

    pub fn fromString(s: []const u8) ?Level {
        const map = std.StaticStringMap(Level).initComptime(.{
            .{ "fatal", .fatal },
            .{ "error", .err },
            .{ "warn", .warn },
            .{ "info", .info },
            .{ "debug", .debug },
            .{ "trace", .trace },
            .{ "silent", .fatal },
        });
        return map.get(s);
    }
};

// --- Console Style ---

pub const ConsoleStyle = enum {
    pretty,
    compact,
    json,
};

// --- Output Buffer ---

/// Thread-local scratch buffer for log formatting
var format_buf: [4096]u8 = undefined;

// --- Subsystem Logger ---

pub const SubsystemLogger = struct {
    subsystem: []const u8,
    min_level: Level,
    console_style: ConsoleStyle,
    /// Optional buffer for capturing output in tests.
    /// When null, writes to stderr.
    capture_buf: ?*std.array_list.Managed(u8) = null,

    pub fn init(subsystem: []const u8) SubsystemLogger {
        return .{
            .subsystem = subsystem,
            .min_level = .info,
            .console_style = .pretty,
        };
    }

    pub fn withLevel(self: SubsystemLogger, level: Level) SubsystemLogger {
        var copy = self;
        copy.min_level = level;
        return copy;
    }

    pub fn withStyle(self: SubsystemLogger, style: ConsoleStyle) SubsystemLogger {
        var copy = self;
        copy.console_style = style;
        return copy;
    }

    pub fn withCapture(self: SubsystemLogger, buf: *std.array_list.Managed(u8)) SubsystemLogger {
        var copy = self;
        copy.capture_buf = buf;
        return copy;
    }

    pub fn isEnabled(self: *const SubsystemLogger, level: Level) bool {
        return @intFromEnum(level) <= @intFromEnum(self.min_level);
    }

    pub fn fatal(self: *const SubsystemLogger, comptime fmt: []const u8, args: anytype) void {
        self.log(.fatal, fmt, args);
    }

    pub fn err(self: *const SubsystemLogger, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }

    pub fn warn(self: *const SubsystemLogger, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    pub fn info(self: *const SubsystemLogger, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    pub fn debug(self: *const SubsystemLogger, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }

    pub fn trace(self: *const SubsystemLogger, comptime fmt: []const u8, args: anytype) void {
        self.log(.trace, fmt, args);
    }

    fn log(self: *const SubsystemLogger, level: Level, comptime fmt: []const u8, args: anytype) void {
        if (!self.isEnabled(level)) return;

        const msg = std.fmt.bufPrint(&format_buf, fmt, args) catch "(message too long)";

        var line_buf: [8192]u8 = undefined;
        const line = switch (self.console_style) {
            .json => formatJson(level, self.subsystem, msg, &line_buf),
            .pretty => formatPretty(level, self.subsystem, msg, &line_buf),
            .compact => formatCompact(level, self.subsystem, msg, &line_buf),
        };

        if (self.capture_buf) |buf| {
            buf.appendSlice(line) catch {};
        } else {
            std.fs.File.stderr().writeAll(line) catch {};
        }
    }
};

fn formatJson(level: Level, subsystem: []const u8, msg: []const u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"level\":\"{s}\",\"subsystem\":\"{s}\",\"message\":\"{s}\"}}\n", .{
        level.label(), subsystem, msg,
    }) catch "";
}

fn formatPretty(level: Level, subsystem: []const u8, msg: []const u8, buf: []u8) []const u8 {
    const color = levelColor(level);
    const reset = "\x1b[0m";
    return std.fmt.bufPrint(buf, "{s}[{s}]{s} [{s}] {s}\n", .{
        color, level.label(), reset, subsystem, msg,
    }) catch "";
}

fn formatCompact(level: Level, subsystem: []const u8, msg: []const u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "[{s}] [{s}] {s}\n", .{
        level.label(), subsystem, msg,
    }) catch "";
}

fn levelColor(level: Level) []const u8 {
    return switch (level) {
        .fatal => "\x1b[31;1m", // bright red
        .err => "\x1b[31m", // red
        .warn => "\x1b[33m", // yellow
        .info => "\x1b[34m", // blue
        .debug => "\x1b[36m", // cyan
        .trace => "\x1b[90m", // gray
    };
}

// --- Global logger ---

var global_level: Level = .info;
var global_style: ConsoleStyle = .pretty;

pub fn setGlobalLevel(level: Level) void {
    global_level = level;
}

pub fn setGlobalStyle(style: ConsoleStyle) void {
    global_style = style;
}

pub fn scoped(subsystem: []const u8) SubsystemLogger {
    return SubsystemLogger.init(subsystem).withLevel(global_level).withStyle(global_style);
}

// --- Redaction ---

pub fn redactSensitive(input: []const u8, buf: []u8) []const u8 {
    if (input.len < 18) {
        if (input.len <= buf.len) {
            @memcpy(buf[0..input.len], input);
            return buf[0..input.len];
        }
        return input;
    }

    const prefixes = [_][]const u8{ "sk-", "ghp_", "github_pat_", "xoxb-", "xoxp-", "gsk_", "AIza", "pplx-", "npm_" };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, input, prefix)) {
            return maskToken(input, buf);
        }
    }

    if (input.len <= buf.len) {
        @memcpy(buf[0..input.len], input);
        return buf[0..input.len];
    }
    return input;
}

fn maskToken(token: []const u8, buf: []u8) []const u8 {
    if (token.len < 10 or buf.len < 13) return "***";
    const prefix_len = 6;
    const suffix_len = 4;
    const dots = "...";
    const total = prefix_len + dots.len + suffix_len;
    if (total > buf.len) return "***";

    @memcpy(buf[0..prefix_len], token[0..prefix_len]);
    @memcpy(buf[prefix_len .. prefix_len + dots.len], dots);
    @memcpy(buf[prefix_len + dots.len .. total], token[token.len - suffix_len ..]);
    return buf[0..total];
}

// --- Tests ---

test "Level.label" {
    try std.testing.expectEqualStrings("fatal", Level.fatal.label());
    try std.testing.expectEqualStrings("error", Level.err.label());
    try std.testing.expectEqualStrings("warn", Level.warn.label());
    try std.testing.expectEqualStrings("info", Level.info.label());
    try std.testing.expectEqualStrings("debug", Level.debug.label());
    try std.testing.expectEqualStrings("trace", Level.trace.label());
}

test "Level.fromString" {
    try std.testing.expectEqual(Level.fatal, Level.fromString("fatal").?);
    try std.testing.expectEqual(Level.err, Level.fromString("error").?);
    try std.testing.expectEqual(Level.warn, Level.fromString("warn").?);
    try std.testing.expectEqual(Level.info, Level.fromString("info").?);
    try std.testing.expectEqual(Level.debug, Level.fromString("debug").?);
    try std.testing.expectEqual(Level.trace, Level.fromString("trace").?);
    try std.testing.expectEqual(Level.fatal, Level.fromString("silent").?);
    try std.testing.expectEqual(@as(?Level, null), Level.fromString("unknown"));
}

test "SubsystemLogger.isEnabled" {
    const logger = SubsystemLogger.init("test").withLevel(.warn);
    try std.testing.expect(logger.isEnabled(.fatal));
    try std.testing.expect(logger.isEnabled(.err));
    try std.testing.expect(logger.isEnabled(.warn));
    try std.testing.expect(!logger.isEnabled(.info));
    try std.testing.expect(!logger.isEnabled(.debug));
    try std.testing.expect(!logger.isEnabled(.trace));
}

test "SubsystemLogger.isEnabled all levels" {
    const logger_trace = SubsystemLogger.init("test").withLevel(.trace);
    try std.testing.expect(logger_trace.isEnabled(.trace));
    try std.testing.expect(logger_trace.isEnabled(.fatal));

    const logger_fatal = SubsystemLogger.init("test").withLevel(.fatal);
    try std.testing.expect(logger_fatal.isEnabled(.fatal));
    try std.testing.expect(!logger_fatal.isEnabled(.err));
}

test "SubsystemLogger outputs json format" {
    var output = std.array_list.Managed(u8).init(std.testing.allocator);
    defer output.deinit();

    const logger = SubsystemLogger.init("test-sub").withStyle(.json).withCapture(&output);
    logger.info("hello {s}", .{"world"});

    const written = output.items;
    try std.testing.expect(std.mem.indexOf(u8, written, "\"level\":\"info\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"subsystem\":\"test-sub\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "hello world") != null);
}

test "SubsystemLogger outputs compact format" {
    var output = std.array_list.Managed(u8).init(std.testing.allocator);
    defer output.deinit();

    const logger = SubsystemLogger.init("mymod").withStyle(.compact).withCapture(&output);
    logger.warn("test warning {d}", .{42});

    const written = output.items;
    try std.testing.expect(std.mem.indexOf(u8, written, "[warn]") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "[mymod]") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "test warning 42") != null);
}

test "SubsystemLogger respects level filter" {
    var output = std.array_list.Managed(u8).init(std.testing.allocator);
    defer output.deinit();

    const logger = SubsystemLogger.init("test").withLevel(.err).withStyle(.compact).withCapture(&output);
    logger.info("should not appear", .{});
    logger.debug("also hidden", .{});

    try std.testing.expectEqual(@as(usize, 0), output.items.len);

    logger.err("should appear", .{});
    try std.testing.expect(output.items.len > 0);
}

test "redactSensitive masks API keys" {
    var buf: [256]u8 = undefined;
    const result = redactSensitive("sk-1234567890abcdefghij", &buf);
    try std.testing.expectEqualStrings("sk-123...ghij", result);
}

test "redactSensitive passes through normal text" {
    var buf: [256]u8 = undefined;
    const result = redactSensitive("hello world", &buf);
    try std.testing.expectEqualStrings("hello world", result);
}

test "redactSensitive masks github tokens" {
    var buf: [256]u8 = undefined;
    const result = redactSensitive("ghp_1234567890abcdefghij", &buf);
    try std.testing.expectEqualStrings("ghp_12...ghij", result);
}

test "scoped logger uses global settings" {
    setGlobalLevel(.debug);
    setGlobalStyle(.compact);
    defer {
        setGlobalLevel(.info);
        setGlobalStyle(.pretty);
    }

    const logger = scoped("test");
    try std.testing.expectEqual(Level.debug, logger.min_level);
    try std.testing.expectEqual(ConsoleStyle.compact, logger.console_style);
}
