const std = @import("std");

// --- Output Mode ---

pub const OutputMode = enum {
    rich, // ANSI colors
    plain, // No colors
    json, // JSON output

    pub fn label(self: OutputMode) []const u8 {
        return switch (self) {
            .rich => "rich",
            .plain => "plain",
            .json => "json",
        };
    }

    pub fn fromString(s: []const u8) ?OutputMode {
        const map = std.StaticStringMap(OutputMode).initComptime(.{
            .{ "rich", .rich },
            .{ "plain", .plain },
            .{ "json", .json },
        });
        return map.get(s);
    }
};

// --- ANSI Color Codes ---

pub const Color = enum {
    reset,
    bold,
    dim,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,

    pub fn code(self: Color) []const u8 {
        return switch (self) {
            .reset => "\x1b[0m",
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .magenta => "\x1b[35m",
            .cyan => "\x1b[36m",
            .white => "\x1b[37m",
        };
    }
};

// --- Output Writer ---

pub const OutputWriter = struct {
    writer: std.io.AnyWriter,
    mode: OutputMode,

    pub fn init(writer: std.io.AnyWriter, mode: OutputMode) OutputWriter {
        return .{ .writer = writer, .mode = mode };
    }

    pub fn print(self: *const OutputWriter, comptime fmt: []const u8, args: anytype) !void {
        try self.writer.print(fmt, args);
    }

    pub fn write(self: *const OutputWriter, bytes: []const u8) !void {
        try self.writer.writeAll(bytes);
    }

    pub fn newline(self: *const OutputWriter) !void {
        try self.writer.writeAll("\n");
    }

    pub fn colored(self: *const OutputWriter, color: Color, text: []const u8) !void {
        if (self.mode == .rich) {
            try self.writer.writeAll(color.code());
            try self.writer.writeAll(text);
            try self.writer.writeAll(Color.reset.code());
        } else {
            try self.writer.writeAll(text);
        }
    }

    pub fn heading(self: *const OutputWriter, text: []const u8) !void {
        if (self.mode == .rich) {
            try self.writer.writeAll(Color.bold.code());
            try self.writer.writeAll(Color.cyan.code());
            try self.writer.writeAll(text);
            try self.writer.writeAll(Color.reset.code());
        } else {
            try self.writer.writeAll(text);
        }
        try self.writer.writeAll("\n");
    }

    pub fn success(self: *const OutputWriter, text: []const u8) !void {
        try self.colored(.green, text);
        try self.writer.writeAll("\n");
    }

    pub fn warning(self: *const OutputWriter, text: []const u8) !void {
        try self.colored(.yellow, text);
        try self.writer.writeAll("\n");
    }

    pub fn err(self: *const OutputWriter, text: []const u8) !void {
        try self.colored(.red, text);
        try self.writer.writeAll("\n");
    }

    pub fn kv(self: *const OutputWriter, key: []const u8, value: []const u8) !void {
        if (self.mode == .rich) {
            try self.writer.writeAll(Color.bold.code());
            try self.writer.writeAll(key);
            try self.writer.writeAll(Color.reset.code());
        } else {
            try self.writer.writeAll(key);
        }
        try self.writer.writeAll(": ");
        try self.writer.writeAll(value);
        try self.writer.writeAll("\n");
    }

    pub fn jsonField(self: *const OutputWriter, buf: []u8, key: []const u8, value: []const u8) !void {
        _ = buf;
        try self.writer.writeAll("\"");
        try self.writer.writeAll(key);
        try self.writer.writeAll("\": \"");
        try self.writer.writeAll(value);
        try self.writer.writeAll("\"");
    }
};

// --- Detect Output Mode ---

pub fn detectOutputMode(args: []const []const u8) OutputMode {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) return .json;
        if (std.mem.eql(u8, arg, "--plain")) return .plain;
    }
    // Check NO_COLOR env
    if (std.posix.getenv("NO_COLOR")) |_| return .plain;
    return .rich;
}

// --- Banner ---

pub const BANNER =
    \\  _______ _
    \\ |___  / | |
    \\    / /__| | __ ___      __
    \\   / / __| |/ _` \ \ /\ / /
    \\  / / (__| | (_| |\ V  V /
    \\ /____\___|_|\__,_| \_/\_/
    \\
;

pub fn printBanner(out: *const OutputWriter) !void {
    if (out.mode == .rich) {
        try out.writer.writeAll(Color.cyan.code());
        try out.writer.writeAll(BANNER);
        try out.writer.writeAll(Color.reset.code());
    } else if (out.mode == .plain) {
        try out.writer.writeAll(BANNER);
    }
    // No banner in JSON mode
}

// --- Version ---

pub const VERSION = "0.1.0";
pub const DESCRIPTION = "Multi-channel AI gateway";

pub fn printVersion(out: *const OutputWriter) !void {
    if (out.mode == .json) {
        try out.print("{{\"version\":\"{s}\"}}\n", .{VERSION});
    } else {
        try out.print("zclaw {s}\n", .{VERSION});
    }
}

// --- Tests ---

test "OutputMode labels and fromString" {
    try std.testing.expectEqualStrings("rich", OutputMode.rich.label());
    try std.testing.expectEqualStrings("json", OutputMode.json.label());
    try std.testing.expectEqual(OutputMode.plain, OutputMode.fromString("plain").?);
    try std.testing.expectEqual(@as(?OutputMode, null), OutputMode.fromString("xml"));
}

test "Color codes" {
    try std.testing.expectEqualStrings("\x1b[0m", Color.reset.code());
    try std.testing.expectEqualStrings("\x1b[31m", Color.red.code());
    try std.testing.expectEqualStrings("\x1b[32m", Color.green.code());
    try std.testing.expectEqualStrings("\x1b[1m", Color.bold.code());
}

test "detectOutputMode" {
    const json_args = [_][]const u8{ "zclaw", "--json", "status" };
    try std.testing.expectEqual(OutputMode.json, detectOutputMode(&json_args));

    const plain_args = [_][]const u8{ "zclaw", "--plain", "status" };
    try std.testing.expectEqual(OutputMode.plain, detectOutputMode(&plain_args));

    const default_args = [_][]const u8{ "zclaw", "status" };
    // Without NO_COLOR env, should default to rich
    const mode = detectOutputMode(&default_args);
    try std.testing.expect(mode == .rich or mode == .plain);
}

test "OutputWriter plain print" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const out = OutputWriter.init(fbs.writer().any(), .plain);

    try out.print("{s} {d}", .{ "hello", 42 });
    try std.testing.expectEqualStrings("hello 42", fbs.getWritten());
}

test "OutputWriter colored in plain mode" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const out = OutputWriter.init(fbs.writer().any(), .plain);

    try out.colored(.red, "error text");
    try std.testing.expectEqualStrings("error text", fbs.getWritten());
}

test "OutputWriter colored in rich mode" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const out = OutputWriter.init(fbs.writer().any(), .rich);

    try out.colored(.green, "ok");
    const written = fbs.getWritten();
    try std.testing.expect(std.mem.startsWith(u8, written, "\x1b[32m"));
    try std.testing.expect(std.mem.endsWith(u8, written, "\x1b[0m"));
    try std.testing.expect(std.mem.indexOf(u8, written, "ok") != null);
}

test "OutputWriter heading" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const out = OutputWriter.init(fbs.writer().any(), .plain);

    try out.heading("Status");
    try std.testing.expectEqualStrings("Status\n", fbs.getWritten());
}

test "OutputWriter kv" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const out = OutputWriter.init(fbs.writer().any(), .plain);

    try out.kv("Version", "0.1.0");
    try std.testing.expectEqualStrings("Version: 0.1.0\n", fbs.getWritten());
}

test "OutputWriter kv rich" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const out = OutputWriter.init(fbs.writer().any(), .rich);

    try out.kv("Key", "val");
    const written = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "Key") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, ": val\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b[1m") != null);
}

test "OutputWriter success warning err" {
    var buf: [1024]u8 = undefined;

    {
        var fbs = std.io.fixedBufferStream(&buf);
        const out = OutputWriter.init(fbs.writer().any(), .plain);
        try out.success("ok");
        try std.testing.expectEqualStrings("ok\n", fbs.getWritten());
    }
    {
        var fbs = std.io.fixedBufferStream(&buf);
        const out = OutputWriter.init(fbs.writer().any(), .plain);
        try out.warning("warn");
        try std.testing.expectEqualStrings("warn\n", fbs.getWritten());
    }
    {
        var fbs = std.io.fixedBufferStream(&buf);
        const out = OutputWriter.init(fbs.writer().any(), .plain);
        try out.err("fail");
        try std.testing.expectEqualStrings("fail\n", fbs.getWritten());
    }
}

test "printVersion plain" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const out = OutputWriter.init(fbs.writer().any(), .plain);
    try printVersion(&out);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), VERSION) != null);
}

test "printVersion json" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const out = OutputWriter.init(fbs.writer().any(), .json);
    try printVersion(&out);
    const written = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, VERSION) != null);
}

test "printBanner modes" {
    var buf: [2048]u8 = undefined;

    // Rich mode prints colored banner
    {
        var fbs = std.io.fixedBufferStream(&buf);
        const out = OutputWriter.init(fbs.writer().any(), .rich);
        try printBanner(&out);
        try std.testing.expect(fbs.getWritten().len > 0);
        // Contains ANSI color codes
        try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\x1b[") != null);
    }

    // Plain mode prints uncolored banner
    {
        var fbs = std.io.fixedBufferStream(&buf);
        const out = OutputWriter.init(fbs.writer().any(), .plain);
        try printBanner(&out);
        try std.testing.expect(fbs.getWritten().len > 0);
        try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\x1b[") == null);
    }

    // JSON mode prints nothing
    {
        var fbs = std.io.fixedBufferStream(&buf);
        const out = OutputWriter.init(fbs.writer().any(), .json);
        try printBanner(&out);
        try std.testing.expectEqual(@as(usize, 0), fbs.getWritten().len);
    }
}

test "OutputWriter newline" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const out = OutputWriter.init(fbs.writer().any(), .plain);
    try out.newline();
    try std.testing.expectEqualStrings("\n", fbs.getWritten());
}
