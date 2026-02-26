const std = @import("std");

// --- RPC Frame Types ---

pub const FrameType = enum {
    req,
    res,
    event,

    pub fn label(self: FrameType) []const u8 {
        return switch (self) {
            .req => "req",
            .res => "res",
            .event => "event",
        };
    }
};

// --- Request Builder ---

/// Build a JSON RPC request frame.
/// Format: {"type":"req","id":"<id>","method":"<method>","params":{<params>}}
pub fn buildRequest(buf: []u8, id: []const u8, method: []const u8, params: ?[]const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("{\"type\":\"req\",\"id\":\"");
    try w.writeAll(id);
    try w.writeAll("\",\"method\":\"");
    try w.writeAll(method);
    try w.writeAll("\"");
    if (params) |p| {
        try w.writeAll(",\"params\":");
        try w.writeAll(p);
    }
    try w.writeAll("}");
    return fbs.getWritten();
}

// --- Connect Request ---

pub fn buildConnectRequest(buf: []u8, id: []const u8, token: ?[]const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("{\"type\":\"req\",\"id\":\"");
    try w.writeAll(id);
    try w.writeAll("\",\"method\":\"connect\",\"params\":{\"protocol\":3");
    if (token) |t| {
        try w.writeAll(",\"auth\":{\"type\":\"token\",\"token\":\"");
        try w.writeAll(t);
        try w.writeAll("\"}");
    }
    try w.writeAll("}}");
    return fbs.getWritten();
}

// --- Chat Message Request ---

pub fn buildChatRequest(buf: []u8, id: []const u8, message: []const u8, agent: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("{\"type\":\"req\",\"id\":\"");
    try w.writeAll(id);
    try w.writeAll("\",\"method\":\"agent\",\"params\":{\"message\":\"");
    try writeJsonEscaped(w, message);
    try w.writeAll("\",\"agent\":\"");
    try w.writeAll(agent);
    try w.writeAll("\"}}");
    return fbs.getWritten();
}

// --- Response Parsing ---

pub const ParsedFrame = struct {
    frame_type: FrameType,
    id: ?[]const u8 = null,
    method: ?[]const u8 = null,
    ok: bool = true,
    event_name: ?[]const u8 = null,
    payload_start: ?usize = null,
};

pub fn parseFrame(json: []const u8) ?ParsedFrame {
    // Determine frame type
    var result = ParsedFrame{ .frame_type = .req };

    if (extractJsonString(json, "\"type\":\"")) |t| {
        if (std.mem.eql(u8, t, "req")) {
            result.frame_type = .req;
        } else if (std.mem.eql(u8, t, "res")) {
            result.frame_type = .res;
        } else if (std.mem.eql(u8, t, "event")) {
            result.frame_type = .event;
        } else {
            return null;
        }
    } else {
        return null;
    }

    // Extract common fields
    result.id = extractJsonString(json, "\"id\":\"");
    result.method = extractJsonString(json, "\"method\":\"");
    result.event_name = extractJsonString(json, "\"event\":\"");

    // Check ok field for responses
    if (result.frame_type == .res) {
        if (std.mem.indexOf(u8, json, "\"ok\":false")) |_| {
            result.ok = false;
        }
    }

    // Find payload start
    if (std.mem.indexOf(u8, json, "\"payload\":")) |idx| {
        result.payload_start = idx + "\"payload\":".len;
    }

    return result;
}

/// Extract a streaming delta from an agent.stream event.
/// Returns the content delta text if present.
pub fn extractStreamDelta(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"delta\":\"");
}

/// Extract error message from a response frame.
pub fn extractErrorMessage(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"message\":\"");
}

/// Extract error code from a response frame.
pub fn extractErrorCode(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"code\":\"");
}

// --- Request ID Generation ---

var request_counter: u32 = 0;

pub fn nextRequestId(buf: []u8) []const u8 {
    request_counter += 1;
    var fbs = std.io.fixedBufferStream(buf);
    std.fmt.format(fbs.writer(), "ui-{d}", .{request_counter}) catch return "ui-0";
    return fbs.getWritten();
}

pub fn resetRequestCounter() void {
    request_counter = 0;
}

// --- Helpers ---

fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}

fn extractJsonString(json: []const u8, prefix: []const u8) ?[]const u8 {
    const start_idx = std.mem.indexOf(u8, json, prefix) orelse return null;
    const value_start = start_idx + prefix.len;
    if (value_start >= json.len) return null;
    var i = value_start;
    while (i < json.len) : (i += 1) {
        if (json[i] == '"' and (i == value_start or json[i - 1] != '\\')) {
            return json[value_start..i];
        }
    }
    return null;
}

// --- Tests ---

test "FrameType labels" {
    try std.testing.expectEqualStrings("req", FrameType.req.label());
    try std.testing.expectEqualStrings("res", FrameType.res.label());
    try std.testing.expectEqualStrings("event", FrameType.event.label());
}

test "buildRequest basic" {
    var buf: [512]u8 = undefined;
    const frame = try buildRequest(&buf, "1", "health", null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"type\":\"req\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"id\":\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"method\":\"health\"") != null);
}

test "buildRequest with params" {
    var buf: [512]u8 = undefined;
    const frame = try buildRequest(&buf, "2", "config.get", "{\"key\":\"port\"}");
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"params\":{\"key\":\"port\"}") != null);
}

test "buildConnectRequest no auth" {
    var buf: [512]u8 = undefined;
    const frame = try buildConnectRequest(&buf, "0", null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"method\":\"connect\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"protocol\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "auth") == null);
}

test "buildConnectRequest with token" {
    var buf: [512]u8 = undefined;
    const frame = try buildConnectRequest(&buf, "0", "my-secret-token");
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"token\":\"my-secret-token\"") != null);
}

test "buildChatRequest" {
    var buf: [1024]u8 = undefined;
    const frame = try buildChatRequest(&buf, "3", "Hello bot!", "default");
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"method\":\"agent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"message\":\"Hello bot!\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"agent\":\"default\"") != null);
}

test "buildChatRequest with escaping" {
    var buf: [1024]u8 = undefined;
    const frame = try buildChatRequest(&buf, "4", "say \"hello\"", "default");
    try std.testing.expect(std.mem.indexOf(u8, frame, "\\\"hello\\\"") != null);
}

test "parseFrame request" {
    const json = "{\"type\":\"req\",\"id\":\"1\",\"method\":\"health\"}";
    const frame = parseFrame(json).?;
    try std.testing.expectEqual(FrameType.req, frame.frame_type);
    try std.testing.expectEqualStrings("1", frame.id.?);
    try std.testing.expectEqualStrings("health", frame.method.?);
}

test "parseFrame response ok" {
    const json = "{\"type\":\"res\",\"id\":\"1\",\"ok\":true,\"payload\":{\"status\":\"ok\"}}";
    const frame = parseFrame(json).?;
    try std.testing.expectEqual(FrameType.res, frame.frame_type);
    try std.testing.expect(frame.ok);
    try std.testing.expect(frame.payload_start != null);
}

test "parseFrame response error" {
    const json = "{\"type\":\"res\",\"id\":\"1\",\"ok\":false,\"error\":{\"code\":\"auth_failed\",\"message\":\"Bad token\"}}";
    const frame = parseFrame(json).?;
    try std.testing.expectEqual(FrameType.res, frame.frame_type);
    try std.testing.expect(!frame.ok);
    try std.testing.expectEqualStrings("auth_failed", extractErrorCode(json).?);
    try std.testing.expectEqualStrings("Bad token", extractErrorMessage(json).?);
}

test "parseFrame event" {
    const json = "{\"type\":\"event\",\"event\":\"agent.stream\",\"payload\":{\"delta\":\"Hello\"}}";
    const frame = parseFrame(json).?;
    try std.testing.expectEqual(FrameType.event, frame.frame_type);
    try std.testing.expectEqualStrings("agent.stream", frame.event_name.?);
}

test "parseFrame invalid type" {
    const json = "{\"type\":\"invalid\"}";
    try std.testing.expect(parseFrame(json) == null);
}

test "parseFrame no type" {
    const json = "{\"id\":\"1\"}";
    try std.testing.expect(parseFrame(json) == null);
}

test "extractStreamDelta" {
    const json = "{\"delta\":\"Hello world\"}";
    try std.testing.expectEqualStrings("Hello world", extractStreamDelta(json).?);
}

test "extractStreamDelta missing" {
    const json = "{\"content\":\"test\"}";
    try std.testing.expect(extractStreamDelta(json) == null);
}

test "nextRequestId" {
    resetRequestCounter();
    var buf: [32]u8 = undefined;
    const id1 = nextRequestId(&buf);
    try std.testing.expectEqualStrings("ui-1", id1);

    var buf2: [32]u8 = undefined;
    const id2 = nextRequestId(&buf2);
    try std.testing.expectEqualStrings("ui-2", id2);
}

test "writeJsonEscaped" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeJsonEscaped(fbs.writer(), "hello \"world\"\nnewline");
    const written = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "\\\"world\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\\n") != null);
}
