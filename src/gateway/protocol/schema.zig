const std = @import("std");

pub const PROTOCOL_VERSION: u32 = 3;
pub const MAX_PAYLOAD_BYTES: usize = 25 * 1024 * 1024; // 25 MB
pub const MAX_BUFFERED_BYTES: usize = 50 * 1024 * 1024; // 50 MB
pub const TICK_INTERVAL_MS: u32 = 30_000;
pub const HANDSHAKE_TIMEOUT_MS: u32 = 10_000;

// --- Frame Types ---

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

    pub fn fromString(s: []const u8) ?FrameType {
        const map = std.StaticStringMap(FrameType).initComptime(.{
            .{ "req", .req },
            .{ "res", .res },
            .{ "event", .event },
        });
        return map.get(s);
    }
};

// --- Error Codes ---

pub const ErrorCode = enum {
    not_linked,
    not_paired,
    agent_timeout,
    invalid_request,
    unavailable,
    method_not_found,
    unauthorized,
    internal,

    pub fn label(self: ErrorCode) []const u8 {
        return switch (self) {
            .not_linked => "NOT_LINKED",
            .not_paired => "NOT_PAIRED",
            .agent_timeout => "AGENT_TIMEOUT",
            .invalid_request => "INVALID_REQUEST",
            .unavailable => "UNAVAILABLE",
            .method_not_found => "METHOD_NOT_FOUND",
            .unauthorized => "UNAUTHORIZED",
            .internal => "INTERNAL",
        };
    }
};

// --- Request Frame ---

pub const RequestFrame = struct {
    id: []const u8,
    method: []const u8,
    params_raw: ?[]const u8 = null,
};

// --- Response Frame Builder ---

pub fn buildOkResponse(buf: []u8, id: []const u8, payload: ?[]const u8) []const u8 {
    if (payload) |p| {
        return std.fmt.bufPrint(buf, "{{\"type\":\"res\",\"id\":\"{s}\",\"ok\":true,\"payload\":{s}}}", .{ id, p }) catch "";
    } else {
        return std.fmt.bufPrint(buf, "{{\"type\":\"res\",\"id\":\"{s}\",\"ok\":true}}", .{id}) catch "";
    }
}

pub fn buildErrorResponse(buf: []u8, id: []const u8, code: ErrorCode, message: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"type\":\"res\",\"id\":\"{s}\",\"ok\":false,\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}", .{
        id, code.label(), message,
    }) catch "";
}

// --- Event Frame Builder ---

pub fn buildEvent(buf: []u8, event_name: []const u8, payload: ?[]const u8) []const u8 {
    if (payload) |p| {
        return std.fmt.bufPrint(buf, "{{\"type\":\"event\",\"event\":\"{s}\",\"payload\":{s}}}", .{ event_name, p }) catch "";
    } else {
        return std.fmt.bufPrint(buf, "{{\"type\":\"event\",\"event\":\"{s}\"}}", .{event_name}) catch "";
    }
}

pub fn buildChallengeEvent(buf: []u8, nonce: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"type\":\"event\",\"event\":\"connect.challenge\",\"payload\":{{\"nonce\":\"{s}\"}}}}", .{nonce}) catch "";
}

pub fn buildTickEvent(buf: []u8, timestamp_ms: i64) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"type\":\"event\",\"event\":\"tick\",\"payload\":{{\"ts\":{d}}}}}", .{timestamp_ms}) catch "";
}

// --- Frame Parsing ---

pub fn parseFrameType(json: []const u8) ?FrameType {
    // Quick heuristic: find "type":"xxx" in JSON
    if (indexOf(json, "\"type\":\"req\"")) |_| return .req;
    if (indexOf(json, "\"type\":\"res\"")) |_| return .res;
    if (indexOf(json, "\"type\":\"event\"")) |_| return .event;
    return null;
}

pub fn parseRequestFrame(json: []const u8) ?RequestFrame {
    // Parse "id" and "method" fields
    const id = extractJsonString(json, "\"id\":\"") orelse return null;
    const method = extractJsonString(json, "\"method\":\"") orelse return null;
    return .{
        .id = id,
        .method = method,
        .params_raw = json,
    };
}

fn extractJsonString(json: []const u8, prefix: []const u8) ?[]const u8 {
    const start_idx = indexOf(json, prefix) orelse return null;
    const value_start = start_idx + prefix.len;
    if (value_start >= json.len) return null;

    // Find closing quote (handle escaped quotes)
    var i = value_start;
    while (i < json.len) : (i += 1) {
        if (json[i] == '"' and (i == value_start or json[i - 1] != '\\')) {
            return json[value_start..i];
        }
    }
    return null;
}

fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, haystack, needle);
}

// --- Client Modes ---

pub const ClientMode = enum {
    webchat,
    cli,
    ui,
    backend,
    node,
    probe,
    @"test",
};

// --- Tests ---

test "FrameType.label" {
    try std.testing.expectEqualStrings("req", FrameType.req.label());
    try std.testing.expectEqualStrings("res", FrameType.res.label());
    try std.testing.expectEqualStrings("event", FrameType.event.label());
}

test "FrameType.fromString" {
    try std.testing.expectEqual(FrameType.req, FrameType.fromString("req").?);
    try std.testing.expectEqual(FrameType.res, FrameType.fromString("res").?);
    try std.testing.expectEqual(FrameType.event, FrameType.fromString("event").?);
    try std.testing.expectEqual(@as(?FrameType, null), FrameType.fromString("unknown"));
}

test "ErrorCode.label" {
    try std.testing.expectEqualStrings("NOT_LINKED", ErrorCode.not_linked.label());
    try std.testing.expectEqualStrings("INVALID_REQUEST", ErrorCode.invalid_request.label());
    try std.testing.expectEqualStrings("UNAUTHORIZED", ErrorCode.unauthorized.label());
}

test "parseFrameType" {
    try std.testing.expectEqual(FrameType.req, parseFrameType("{\"type\":\"req\",\"id\":\"1\"}").?);
    try std.testing.expectEqual(FrameType.res, parseFrameType("{\"type\":\"res\",\"id\":\"1\"}").?);
    try std.testing.expectEqual(FrameType.event, parseFrameType("{\"type\":\"event\",\"event\":\"tick\"}").?);
    try std.testing.expectEqual(@as(?FrameType, null), parseFrameType("not json"));
}

test "parseRequestFrame" {
    const frame = parseRequestFrame("{\"type\":\"req\",\"id\":\"abc-123\",\"method\":\"health\"}").?;
    try std.testing.expectEqualStrings("abc-123", frame.id);
    try std.testing.expectEqualStrings("health", frame.method);
}

test "parseRequestFrame invalid" {
    try std.testing.expectEqual(@as(?RequestFrame, null), parseRequestFrame("{}"));
    try std.testing.expectEqual(@as(?RequestFrame, null), parseRequestFrame("{\"id\":\"1\"}"));
}

test "buildOkResponse" {
    var buf: [4096]u8 = undefined;
    const resp = buildOkResponse(&buf, "req-1", "{\"status\":\"ok\"}");
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"id\":\"req-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"status\":\"ok\"") != null);
}

test "buildOkResponse without payload" {
    var buf: [4096]u8 = undefined;
    const resp = buildOkResponse(&buf, "req-2", null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "payload") == null);
}

test "buildErrorResponse" {
    var buf: [4096]u8 = undefined;
    const resp = buildErrorResponse(&buf, "req-3", .invalid_request, "bad params");
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "INVALID_REQUEST") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "bad params") != null);
}

test "buildChallengeEvent" {
    var buf: [4096]u8 = undefined;
    const evt = buildChallengeEvent(&buf, "my-nonce-123");
    try std.testing.expect(std.mem.indexOf(u8, evt, "connect.challenge") != null);
    try std.testing.expect(std.mem.indexOf(u8, evt, "my-nonce-123") != null);
}

test "buildTickEvent" {
    var buf: [4096]u8 = undefined;
    const evt = buildTickEvent(&buf, 1700000000000);
    try std.testing.expect(std.mem.indexOf(u8, evt, "\"event\":\"tick\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, evt, "1700000000000") != null);
}

test "PROTOCOL_VERSION is 3" {
    try std.testing.expectEqual(@as(u32, 3), PROTOCOL_VERSION);
}

test "constants" {
    try std.testing.expectEqual(@as(usize, 25 * 1024 * 1024), MAX_PAYLOAD_BYTES);
    try std.testing.expectEqual(@as(u32, 30_000), TICK_INTERVAL_MS);
    try std.testing.expectEqual(@as(u32, 10_000), HANDSHAKE_TIMEOUT_MS);
}

// --- Additional Tests ---

test "ErrorCode all labels non-empty" {
    for (std.meta.tags(ErrorCode)) |code| {
        try std.testing.expect(code.label().len > 0);
    }
}

test "ErrorCode not_paired label" {
    try std.testing.expectEqualStrings("NOT_PAIRED", ErrorCode.not_paired.label());
}

test "ErrorCode agent_timeout label" {
    try std.testing.expectEqualStrings("AGENT_TIMEOUT", ErrorCode.agent_timeout.label());
}

test "ErrorCode unavailable label" {
    try std.testing.expectEqualStrings("UNAVAILABLE", ErrorCode.unavailable.label());
}

test "ErrorCode method_not_found label" {
    try std.testing.expectEqualStrings("METHOD_NOT_FOUND", ErrorCode.method_not_found.label());
}

test "ErrorCode internal label" {
    try std.testing.expectEqualStrings("INTERNAL", ErrorCode.internal.label());
}

test "FrameType.fromString all valid" {
    try std.testing.expectEqual(FrameType.req, FrameType.fromString("req").?);
    try std.testing.expectEqual(FrameType.res, FrameType.fromString("res").?);
    try std.testing.expectEqual(FrameType.event, FrameType.fromString("event").?);
}

test "FrameType.fromString empty" {
    try std.testing.expect(FrameType.fromString("") == null);
}

test "parseFrameType empty string" {
    try std.testing.expect(parseFrameType("") == null);
}

test "parseRequestFrame with params" {
    const json = "{\"type\":\"req\",\"id\":\"abc\",\"method\":\"chat.send\",\"params\":{\"msg\":\"hi\"}}";
    const frame = parseRequestFrame(json).?;
    try std.testing.expectEqualStrings("abc", frame.id);
    try std.testing.expectEqualStrings("chat.send", frame.method);
    try std.testing.expect(frame.params_raw != null);
}

test "RequestFrame struct fields" {
    const frame = RequestFrame{
        .id = "req-1",
        .method = "health",
    };
    try std.testing.expectEqualStrings("req-1", frame.id);
    try std.testing.expectEqualStrings("health", frame.method);
    try std.testing.expect(frame.params_raw == null);
}

test "buildOkResponse contains type res" {
    var buf: [4096]u8 = undefined;
    const resp = buildOkResponse(&buf, "id-1", null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"type\":\"res\"") != null);
}

test "buildErrorResponse contains type res" {
    var buf: [4096]u8 = undefined;
    const resp = buildErrorResponse(&buf, "id-1", .internal, "server error");
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"type\":\"res\"") != null);
}

test "buildEvent with payload" {
    var buf: [4096]u8 = undefined;
    const evt = buildEvent(&buf, "agent.delta", "{\"text\":\"hi\"}");
    try std.testing.expect(std.mem.indexOf(u8, evt, "\"type\":\"event\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, evt, "\"event\":\"agent.delta\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, evt, "\"text\":\"hi\"") != null);
}

test "buildEvent without payload" {
    var buf: [4096]u8 = undefined;
    const evt = buildEvent(&buf, "tick", null);
    try std.testing.expect(std.mem.indexOf(u8, evt, "\"event\":\"tick\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, evt, "payload") == null);
}

test "MAX_BUFFERED_BYTES" {
    try std.testing.expectEqual(@as(usize, 50 * 1024 * 1024), MAX_BUFFERED_BYTES);
}

// --- New Tests ---

test "FrameType.label all variants return non-empty" {
    for (std.meta.tags(FrameType)) |ft| {
        try std.testing.expect(ft.label().len > 0);
    }
}

test "FrameType round-trip via label and fromString" {
    for (std.meta.tags(FrameType)) |ft| {
        const parsed = FrameType.fromString(ft.label());
        try std.testing.expectEqual(ft, parsed.?);
    }
}

test "FrameType.fromString case sensitive" {
    try std.testing.expect(FrameType.fromString("REQ") == null);
    try std.testing.expect(FrameType.fromString("Req") == null);
    try std.testing.expect(FrameType.fromString("RES") == null);
    try std.testing.expect(FrameType.fromString("EVENT") == null);
}

test "ErrorCode all variants unique labels" {
    const codes = std.meta.tags(ErrorCode);
    for (codes, 0..) |c1, i| {
        for (codes, 0..) |c2, j| {
            if (i != j) {
                try std.testing.expect(!std.mem.eql(u8, c1.label(), c2.label()));
            }
        }
    }
}

test "buildOkResponse with complex payload" {
    var buf: [4096]u8 = undefined;
    const resp = buildOkResponse(&buf, "req-complex", "{\"data\":{\"nested\":true},\"count\":42}");
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"nested\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"count\":42") != null);
}

test "buildErrorResponse all error codes" {
    var buf: [4096]u8 = undefined;
    for (std.meta.tags(ErrorCode)) |code| {
        const resp = buildErrorResponse(&buf, "err-all", code, "test message");
        try std.testing.expect(std.mem.indexOf(u8, resp, code.label()) != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":false") != null);
    }
}

test "buildEvent type is event" {
    var buf: [4096]u8 = undefined;
    const evt = buildEvent(&buf, "custom.event", null);
    try std.testing.expect(std.mem.indexOf(u8, evt, "\"type\":\"event\"") != null);
}

test "buildChallengeEvent has correct structure" {
    var buf: [4096]u8 = undefined;
    const evt = buildChallengeEvent(&buf, "test-nonce-value");
    try std.testing.expect(std.mem.indexOf(u8, evt, "\"type\":\"event\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, evt, "\"event\":\"connect.challenge\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, evt, "\"nonce\":\"test-nonce-value\"") != null);
}

test "buildTickEvent has correct structure" {
    var buf: [4096]u8 = undefined;
    const evt = buildTickEvent(&buf, 0);
    try std.testing.expect(std.mem.indexOf(u8, evt, "\"event\":\"tick\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, evt, "\"ts\":0") != null);
}

test "buildTickEvent negative timestamp" {
    var buf: [4096]u8 = undefined;
    const evt = buildTickEvent(&buf, -1);
    try std.testing.expect(std.mem.indexOf(u8, evt, "\"ts\":-1") != null);
}

test "parseFrameType with extra whitespace" {
    // Not JSON-aware parser, looks for exact substring
    try std.testing.expect(parseFrameType("{  \"type\":\"req\"  }") != null);
}

test "parseRequestFrame missing method" {
    const result = parseRequestFrame("{\"type\":\"req\",\"id\":\"123\"}");
    try std.testing.expect(result == null);
}

test "parseRequestFrame missing id" {
    const result = parseRequestFrame("{\"type\":\"req\",\"method\":\"health\"}");
    try std.testing.expect(result == null);
}

test "parseRequestFrame params_raw is full JSON" {
    const json = "{\"type\":\"req\",\"id\":\"r1\",\"method\":\"test\",\"params\":{\"a\":1}}";
    const frame = parseRequestFrame(json).?;
    try std.testing.expectEqualStrings(json, frame.params_raw.?);
}

test "ClientMode all variants" {
    const modes = [_]ClientMode{ .webchat, .cli, .ui, .backend, .node, .probe, .@"test" };
    for (modes, 0..) |m1, i| {
        for (modes, 0..) |m2, j| {
            if (i != j) {
                try std.testing.expect(m1 != m2);
            }
        }
    }
}

test "RequestFrame with params_raw" {
    const frame = RequestFrame{
        .id = "req-42",
        .method = "chat.send",
        .params_raw = "{\"text\":\"hi\"}",
    };
    try std.testing.expectEqualStrings("req-42", frame.id);
    try std.testing.expectEqualStrings("chat.send", frame.method);
    try std.testing.expectEqualStrings("{\"text\":\"hi\"}", frame.params_raw.?);
}

test "parseFrameType only matches first type found" {
    // Contains req before res
    const json = "{\"type\":\"req\",\"data\":\"type\":\"res\"}";
    try std.testing.expectEqual(FrameType.req, parseFrameType(json).?);
}

test "buildOkResponse with empty payload" {
    var buf: [4096]u8 = undefined;
    const resp = buildOkResponse(&buf, "req-empty", "{}");
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"payload\":{}") != null);
}

test "buildErrorResponse with long message" {
    var buf: [4096]u8 = undefined;
    const resp = buildErrorResponse(&buf, "req-long", .internal, "this is a longer error message for testing");
    try std.testing.expect(std.mem.indexOf(u8, resp, "this is a longer error message for testing") != null);
}
