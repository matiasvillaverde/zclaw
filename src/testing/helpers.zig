const std = @import("std");

/// Test infrastructure: mock responses, assertion helpers, fixtures.

pub const MockResponse = struct {
    status: u16,
    body: []const u8,
    content_type: []const u8,

    pub fn ok(body: []const u8) MockResponse { return .{ .status = 200, .body = body, .content_type = "application/json" }; }
    pub fn okHtml(body: []const u8) MockResponse { return .{ .status = 200, .body = body, .content_type = "text/html" }; }
    pub fn created(body: []const u8) MockResponse { return .{ .status = 201, .body = body, .content_type = "application/json" }; }
    pub fn badRequest(body: []const u8) MockResponse { return .{ .status = 400, .body = body, .content_type = "application/json" }; }
    pub fn unauthorized() MockResponse { return .{ .status = 401, .body = "{\"error\":\"unauthorized\"}", .content_type = "application/json" }; }
    pub fn forbidden() MockResponse { return .{ .status = 403, .body = "{\"error\":\"forbidden\"}", .content_type = "application/json" }; }
    pub fn notFound() MockResponse { return .{ .status = 404, .body = "{\"error\":\"not_found\"}", .content_type = "application/json" }; }
    pub fn tooManyRequests() MockResponse { return .{ .status = 429, .body = "{\"error\":\"rate_limit_exceeded\"}", .content_type = "application/json" }; }
    pub fn serverError() MockResponse { return .{ .status = 500, .body = "{\"error\":\"internal_error\"}", .content_type = "application/json" }; }
    pub fn overloaded() MockResponse { return .{ .status = 529, .body = "{\"error\":\"overloaded\"}", .content_type = "application/json" }; }
};

// ── Fixtures ──

pub const anthropic_chat_response =
    \\{"id":"msg_123","type":"message","role":"assistant","content":[{"type":"text","text":"Hello!"}],"model":"claude-sonnet-4-20250514","stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5}}
;
pub const anthropic_tool_response =
    \\{"id":"msg_456","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"web_search","input":{"query":"test"}}],"model":"claude-sonnet-4-20250514","stop_reason":"tool_use","usage":{"input_tokens":20,"output_tokens":15}}
;
pub const openai_chat_response =
    \\{"id":"chatcmpl-123","object":"chat.completion","model":"gpt-4","choices":[{"index":0,"message":{"role":"assistant","content":"Hello!"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
;
pub const telegram_update =
    \\{"update_id":123456,"message":{"message_id":1,"from":{"id":12345,"is_bot":false,"first_name":"Test"},"chat":{"id":12345,"type":"private"},"date":1700000000,"text":"/start"}}
;
pub const discord_message =
    \\{"t":"MESSAGE_CREATE","s":1,"op":0,"d":{"id":"123","channel_id":"456","author":{"id":"789","username":"test"},"content":"hello"}}
;
pub const slack_event =
    \\{"type":"event_callback","event":{"type":"message","text":"hello","user":"U123","channel":"C456","ts":"1700000000.000000"}}
;

// ── Assertion helpers ──

pub fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("Expected to contain: \"{s}\"\nActual: \"{s}\"\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

pub fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("Expected NOT to contain: \"{s}\"\nActual: \"{s}\"\n", .{ needle, haystack });
        return error.TestExpectedNotContains;
    }
}

pub fn expectStartsWith(str: []const u8, prefix: []const u8) !void {
    if (!std.mem.startsWith(u8, str, prefix)) {
        std.debug.print("Expected to start with: \"{s}\"\nActual: \"{s}\"\n", .{ prefix, str });
        return error.TestExpectedStartsWith;
    }
}

pub fn expectEndsWith(str: []const u8, suffix: []const u8) !void {
    if (!std.mem.endsWith(u8, str, suffix)) {
        std.debug.print("Expected to end with: \"{s}\"\nActual: \"{s}\"\n", .{ suffix, str });
        return error.TestExpectedEndsWith;
    }
}

pub fn expectInRange(comptime T: type, value: T, min: T, max: T) !void {
    if (value < min or value > max) return error.TestExpectedInRange;
}

pub fn extractJsonField(allocator: std.mem.Allocator, json: []const u8, field: []const u8) !?[]u8 {
    var search_buf: [256]u8 = undefined;
    const pattern = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{field}) catch return null;
    const idx = std.mem.indexOf(u8, json, pattern) orelse return null;
    const after = json[idx + pattern.len ..];
    var start: usize = 0;
    while (start < after.len and (after[start] == ' ' or after[start] == '\t')) start += 1;
    if (start >= after.len) return null;
    if (after[start] == '"') {
        const str_start = start + 1;
        var end = str_start;
        while (end < after.len and after[end] != '"') end += 1;
        return try allocator.dupe(u8, after[str_start..end]);
    } else {
        var end = start;
        while (end < after.len and after[end] != ',' and after[end] != '}' and after[end] != ']') end += 1;
        return try allocator.dupe(u8, after[start..end]);
    }
}

// ── Tests ──

test "MockResponse.ok" { try std.testing.expectEqual(@as(u16, 200), MockResponse.ok("{}").status); }
test "MockResponse.unauthorized" { try std.testing.expectEqual(@as(u16, 401), MockResponse.unauthorized().status); }
test "MockResponse.tooManyRequests" { try std.testing.expectEqual(@as(u16, 429), MockResponse.tooManyRequests().status); }
test "MockResponse.serverError" { try std.testing.expectEqual(@as(u16, 500), MockResponse.serverError().status); }
test "MockResponse.overloaded" { try std.testing.expectEqual(@as(u16, 529), MockResponse.overloaded().status); }
test "MockResponse.notFound" { try std.testing.expectEqual(@as(u16, 404), MockResponse.notFound().status); }
test "MockResponse.forbidden" { try std.testing.expectEqual(@as(u16, 403), MockResponse.forbidden().status); }
test "MockResponse.badRequest" { try std.testing.expectEqual(@as(u16, 400), MockResponse.badRequest("{}").status); }
test "MockResponse.created" { try std.testing.expectEqual(@as(u16, 201), MockResponse.created("{}").status); }
test "MockResponse.okHtml" { try std.testing.expectEqualStrings("text/html", MockResponse.okHtml("<h1>hi</h1>").content_type); }

test "extractJsonField - string" {
    const a = std.testing.allocator;
    const r = try extractJsonField(a, "{\"name\":\"hello\"}", "name");
    defer if (r) |v| a.free(v);
    try std.testing.expectEqualStrings("hello", r.?);
}
test "extractJsonField - number" {
    const a = std.testing.allocator;
    const r = try extractJsonField(a, "{\"count\":42}", "count");
    defer if (r) |v| a.free(v);
    try std.testing.expectEqualStrings("42", r.?);
}
test "extractJsonField - missing" {
    const r = try extractJsonField(std.testing.allocator, "{\"name\":\"hello\"}", "missing");
    try std.testing.expect(r == null);
}

test "expectContains - found" { try expectContains("hello world", "world"); }
test "expectContains - not found" { try std.testing.expectError(error.TestExpectedContains, expectContains("hello world", "xyz")); }
test "expectNotContains - not found" { try expectNotContains("hello world", "xyz"); }
test "expectNotContains - found" { try std.testing.expectError(error.TestExpectedNotContains, expectNotContains("hello world", "world")); }
test "expectStartsWith - matches" { try expectStartsWith("hello world", "hello"); }
test "expectStartsWith - no match" { try std.testing.expectError(error.TestExpectedStartsWith, expectStartsWith("hello world", "world")); }
test "expectEndsWith - matches" { try expectEndsWith("hello world", "world"); }
test "expectEndsWith - no match" { try std.testing.expectError(error.TestExpectedEndsWith, expectEndsWith("hello world", "hello")); }
test "expectInRange - in range" { try expectInRange(u32, 5, 1, 10); }
test "expectInRange - below" { try std.testing.expectError(error.TestExpectedInRange, expectInRange(u32, 0, 1, 10)); }
test "expectInRange - above" { try std.testing.expectError(error.TestExpectedInRange, expectInRange(u32, 11, 1, 10)); }

test "fixtures are non-empty" {
    try std.testing.expect(anthropic_chat_response.len > 0);
    try std.testing.expect(openai_chat_response.len > 0);
    try std.testing.expect(telegram_update.len > 0);
    try std.testing.expect(discord_message.len > 0);
    try std.testing.expect(slack_event.len > 0);
}
