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
