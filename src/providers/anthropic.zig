const std = @import("std");
const types = @import("types.zig");
const sse = @import("sse.zig");

// --- Anthropic API Constants ---

pub const DEFAULT_BASE_URL = "https://api.anthropic.com";
pub const MESSAGES_PATH = "/v1/messages";
pub const API_VERSION = "2023-06-01";

// --- Request Building ---

/// Build an Anthropic Messages API request body as JSON.
/// Returns the number of bytes written to buf.
pub fn buildRequestBody(
    buf: []u8,
    config: types.RequestConfig,
    messages_json: []const u8,
    tools_json: ?[]const u8,
) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    try writer.writeAll("{\"model\":\"");
    try writer.writeAll(config.model);
    try writer.writeAll("\",\"max_tokens\":");
    try std.fmt.format(writer, "{d}", .{config.max_tokens});

    if (config.stream) {
        try writer.writeAll(",\"stream\":true");
    }

    if (config.temperature) |temp| {
        try writer.writeAll(",\"temperature\":");
        try std.fmt.format(writer, "{d:.1}", .{temp});
    }

    if (config.system_prompt) |sys| {
        try writer.writeAll(",\"system\":[{\"type\":\"text\",\"text\":\"");
        try writeJsonEscaped(writer, sys);
        try writer.writeAll("\"}]");
    }

    if (tools_json) |tools| {
        try writer.writeAll(",\"tools\":");
        try writer.writeAll(tools);
    }

    try writer.writeAll(",\"messages\":");
    try writer.writeAll(messages_json);
    try writer.writeAll("}");

    return fbs.getWritten();
}

/// Build HTTP headers for Anthropic API
pub fn buildHeaders(buf: *[4][2][]const u8, api_key: []const u8) [4][2][]const u8 {
    buf[0] = .{ "content-type", "application/json" };
    buf[1] = .{ "x-api-key", api_key };
    buf[2] = .{ "anthropic-version", API_VERSION };
    buf[3] = .{ "accept", "text/event-stream" };
    return buf.*;
}

// --- Response Parsing ---

/// Parse an Anthropic SSE event into a StreamEvent
pub fn parseStreamEvent(event: *const sse.SseEvent) ?types.StreamEvent {
    if (event.isDone()) {
        return .{ .event_type = .stop, .stop_reason = .end_turn };
    }

    const event_type = event.event_type orelse return null;
    const data = event.data;

    if (std.mem.eql(u8, event_type, "content_block_start")) {
        // Check if it's a tool_use block
        if (std.mem.indexOf(u8, data, "\"type\":\"tool_use\"")) |_| {
            return .{
                .event_type = .tool_call_start,
                .tool_call_id = extractJsonString(data, "\"id\":\""),
                .tool_name = extractJsonString(data, "\"name\":\""),
            };
        }
        return .{ .event_type = .start };
    }

    if (std.mem.eql(u8, event_type, "content_block_delta")) {
        // Text delta
        if (extractJsonString(data, "\"text\":\"")) |text| {
            return .{ .event_type = .text_delta, .text = text };
        }
        // Tool input delta
        if (extractJsonString(data, "\"partial_json\":\"")) |json_delta| {
            return .{ .event_type = .tool_call_delta, .tool_input_delta = json_delta };
        }
        return null;
    }

    if (std.mem.eql(u8, event_type, "content_block_stop")) {
        // Could be tool_call_end, but we don't know without context
        return null;
    }

    if (std.mem.eql(u8, event_type, "message_delta")) {
        // Extract stop reason
        const stop_reason = if (extractJsonString(data, "\"stop_reason\":\"")) |sr|
            types.StopReason.fromString(sr)
        else
            null;

        // Extract usage
        var usage: ?types.Usage = null;
        if (extractJsonNumber(data, "\"output_tokens\":")) |out_tokens| {
            usage = .{ .output_tokens = @intCast(out_tokens) };
        }

        return .{
            .event_type = .stop,
            .stop_reason = stop_reason,
            .usage = usage,
        };
    }

    if (std.mem.eql(u8, event_type, "message_start")) {
        // Extract usage from initial message
        var usage: ?types.Usage = null;
        if (extractJsonNumber(data, "\"input_tokens\":")) |in_tokens| {
            usage = .{ .input_tokens = @intCast(in_tokens) };
        }
        return .{
            .event_type = .start,
            .usage = usage,
        };
    }

    if (std.mem.eql(u8, event_type, "message_stop")) {
        return .{ .event_type = .stop, .stop_reason = .end_turn };
    }

    if (std.mem.eql(u8, event_type, "error")) {
        return .{
            .event_type = .@"error",
            .error_message = extractJsonString(data, "\"message\":\""),
        };
    }

    return null;
}

/// Build a tool definition in Anthropic format
pub fn buildToolJson(buf: []u8, tool: types.ToolDefinition) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    try writer.writeAll("{\"name\":\"");
    try writer.writeAll(tool.name);
    try writer.writeAll("\"");

    if (tool.description.len > 0) {
        try writer.writeAll(",\"description\":\"");
        try writeJsonEscaped(writer, tool.description);
        try writer.writeAll("\"");
    }

    if (tool.parameters_json) |params| {
        try writer.writeAll(",\"input_schema\":");
        try writer.writeAll(params);
    }

    try writer.writeAll("}");
    return fbs.getWritten();
}

// --- Message Building ---

/// Build a user message in Anthropic format
pub fn buildUserMessage(buf: []u8, text: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    try writer.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"");
    try writeJsonEscaped(writer, text);
    try writer.writeAll("\"}]}");
    return fbs.getWritten();
}

/// Build an assistant message in Anthropic format
pub fn buildAssistantMessage(buf: []u8, text: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    try writer.writeAll("{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"");
    try writeJsonEscaped(writer, text);
    try writer.writeAll("\"}]}");
    return fbs.getWritten();
}

/// Build a tool result message in Anthropic format
pub fn buildToolResultMessage(buf: []u8, tool_use_id: []const u8, content: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    try writer.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"");
    try writer.writeAll(tool_use_id);
    try writer.writeAll("\",\"content\":\"");
    try writeJsonEscaped(writer, content);
    try writer.writeAll("\"}]}");
    return fbs.getWritten();
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
            else => {
                if (c < 0x20) {
                    try std.fmt.format(writer, "\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
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

fn extractJsonNumber(json: []const u8, prefix: []const u8) ?i64 {
    const start_idx = std.mem.indexOf(u8, json, prefix) orelse return null;
    const value_start = start_idx + prefix.len;
    if (value_start >= json.len) return null;

    var end = value_start;
    while (end < json.len and (json[end] >= '0' and json[end] <= '9')) : (end += 1) {}
    if (end == value_start) return null;

    return std.fmt.parseInt(i64, json[value_start..end], 10) catch null;
}

// --- Provider Client ---

pub const Client = struct {
    http: *http_client.HttpClient,
    api_key: []const u8,
    base_url: []const u8,

    pub fn init(http: *http_client.HttpClient, api_key: []const u8, base_url: ?[]const u8) Client {
        return .{
            .http = http,
            .api_key = api_key,
            .base_url = base_url orelse DEFAULT_BASE_URL,
        };
    }

    /// Send a message to the Anthropic Messages API.
    /// Returns the raw SSE response body for streaming, or JSON for non-streaming.
    pub fn sendMessage(
        self: *Client,
        config: types.RequestConfig,
        messages_json: []const u8,
        tools_json: ?[]const u8,
    ) !ProviderResponse {
        // Build request body
        var body_buf: [64 * 1024]u8 = undefined;
        const body = try buildRequestBody(&body_buf, config, messages_json, tools_json);

        // Build URL
        var url_buf: [512]u8 = undefined;
        const url = try http_client.buildUrl(&url_buf, self.base_url, MESSAGES_PATH);

        // Build auth headers
        const auth_headers = [_]http_client.Header{
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = API_VERSION },
        };

        const resp = try self.http.postSse(url, &auth_headers, body);

        return .{
            .status = resp.status,
            .body = resp.body,
            .allocator = resp.allocator,
        };
    }
};

pub const ProviderResponse = struct {
    status: u16,
    body: []const u8,
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *ProviderResponse) void {
        if (self.allocator) |alloc| {
            alloc.free(self.body);
        }
    }

    pub fn isSuccess(self: *const ProviderResponse) bool {
        return self.status >= 200 and self.status < 300;
    }

    /// Parse SSE events from the response body
    pub fn parseEvents(self: *const ProviderResponse, allocator: std.mem.Allocator) ![]sse.SseEvent {
        var parser = sse.SseParser.init(allocator);
        defer parser.deinit();
        return parser.feed(self.body);
    }
};

const http_client = @import("../infra/http_client.zig");

// --- Tests ---

test "buildRequestBody basic" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "claude-3-5-sonnet-20241022",
        .max_tokens = 1024,
        .system_prompt = "You are helpful.",
        .api_key = "sk-test",
    }, "[{\"role\":\"user\",\"content\":\"hello\"}]", null);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"claude-3-5-sonnet-20241022\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":1024") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\":[{\"type\":\"text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "You are helpful.") != null);
}

test "buildRequestBody with tools" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "claude-3-5-sonnet",
        .api_key = "sk-test",
    }, "[]", "[{\"name\":\"bash\"}]");

    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"name\":\"bash\"}]") != null);
}

test "buildRequestBody no stream" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "claude-3-5-sonnet",
        .stream = false,
        .api_key = "sk-test",
    }, "[]", null);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\"") == null);
}

test "buildHeaders" {
    var buf: [4][2][]const u8 = undefined;
    const headers = buildHeaders(&buf, "sk-ant-test");

    try std.testing.expectEqualStrings("content-type", headers[0][0]);
    try std.testing.expectEqualStrings("application/json", headers[0][1]);
    try std.testing.expectEqualStrings("x-api-key", headers[1][0]);
    try std.testing.expectEqualStrings("sk-ant-test", headers[1][1]);
    try std.testing.expectEqualStrings("anthropic-version", headers[2][0]);
    try std.testing.expectEqualStrings(API_VERSION, headers[2][1]);
}

test "parseStreamEvent text delta" {
    const event = sse.SseEvent{
        .event_type = "content_block_delta",
        .data = "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.text_delta, result.event_type);
    try std.testing.expectEqualStrings("Hello", result.text.?);
}

test "parseStreamEvent tool call start" {
    const event = sse.SseEvent{
        .event_type = "content_block_start",
        .data = "{\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_123\",\"name\":\"bash\"}}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.tool_call_start, result.event_type);
    try std.testing.expectEqualStrings("call_123", result.tool_call_id.?);
    try std.testing.expectEqualStrings("bash", result.tool_name.?);
}

test "parseStreamEvent message delta with stop reason" {
    const event = sse.SseEvent{
        .event_type = "message_delta",
        .data = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":42}}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.stop, result.event_type);
    try std.testing.expectEqual(types.StopReason.end_turn, result.stop_reason.?);
    try std.testing.expectEqual(@as(u64, 42), result.usage.?.output_tokens);
}

test "parseStreamEvent message start with usage" {
    const event = sse.SseEvent{
        .event_type = "message_start",
        .data = "{\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":100}}}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.start, result.event_type);
    try std.testing.expectEqual(@as(u64, 100), result.usage.?.input_tokens);
}

test "parseStreamEvent message stop" {
    const event = sse.SseEvent{
        .event_type = "message_stop",
        .data = "{\"type\":\"message_stop\"}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.stop, result.event_type);
}

test "parseStreamEvent error" {
    const event = sse.SseEvent{
        .event_type = "error",
        .data = "{\"type\":\"error\",\"error\":{\"message\":\"rate limited\"}}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.@"error", result.event_type);
    try std.testing.expectEqualStrings("rate limited", result.error_message.?);
}

test "parseStreamEvent done sentinel" {
    const event = sse.SseEvent{ .event_type = null, .data = "[DONE]" };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.stop, result.event_type);
}

test "parseStreamEvent unknown type" {
    const event = sse.SseEvent{
        .event_type = "unknown_event_type",
        .data = "{}",
    };
    try std.testing.expect(parseStreamEvent(&event) == null);
}

test "buildToolJson" {
    var buf: [1024]u8 = undefined;
    const json = try buildToolJson(&buf, .{
        .name = "bash",
        .description = "Execute commands",
        .parameters_json = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}}}",
    });

    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"bash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"description\":\"Execute commands\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"input_schema\":{") != null);
}

test "buildUserMessage" {
    var buf: [1024]u8 = undefined;
    const msg = try buildUserMessage(&buf, "Hello world");
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"text\":\"Hello world\"") != null);
}

test "buildAssistantMessage" {
    var buf: [1024]u8 = undefined;
    const msg = try buildAssistantMessage(&buf, "I can help");
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"role\":\"assistant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"text\":\"I can help\"") != null);
}

test "buildToolResultMessage" {
    var buf: [1024]u8 = undefined;
    const msg = try buildToolResultMessage(&buf, "call_123", "success");
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"tool_result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"tool_use_id\":\"call_123\"") != null);
}

test "writeJsonEscaped" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeJsonEscaped(fbs.writer(), "hello \"world\"\ntest\\path");
    const result = fbs.getWritten();
    try std.testing.expectEqualStrings("hello \\\"world\\\"\\ntest\\\\path", result);
}

test "extractJsonString" {
    const json = "{\"id\":\"abc-123\",\"name\":\"test\"}";
    try std.testing.expectEqualStrings("abc-123", extractJsonString(json, "\"id\":\"").?);
    try std.testing.expectEqualStrings("test", extractJsonString(json, "\"name\":\"").?);
    try std.testing.expect(extractJsonString(json, "\"missing\":\"") == null);
}

test "extractJsonNumber" {
    const json = "{\"input_tokens\":150,\"output_tokens\":42}";
    try std.testing.expectEqual(@as(i64, 150), extractJsonNumber(json, "\"input_tokens\":").?);
    try std.testing.expectEqual(@as(i64, 42), extractJsonNumber(json, "\"output_tokens\":").?);
    try std.testing.expect(extractJsonNumber(json, "\"missing\":") == null);
}

test "buildRequestBody with temperature" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "claude-3-5-sonnet",
        .temperature = 0.7,
        .api_key = "sk-test",
    }, "[]", null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.7") != null);
}

test "Client.sendMessage mock success" {
    const mock_sse =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":25}}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello!\"}}\n\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";

    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = mock_sse },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = Client.init(&http, "sk-ant-test-key", null);

    var resp = try client.sendMessage(.{
        .model = "claude-3-5-sonnet-20241022",
        .system_prompt = "You are helpful.",
        .api_key = "sk-ant-test-key",
    }, "[{\"role\":\"user\",\"content\":\"Hi\"}]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);

    // Parse SSE events from response
    const events = try resp.parseEvents(std.testing.allocator);
    defer sse.freeEvents(std.testing.allocator, events);
    try std.testing.expectEqual(@as(usize, 3), events.len);

    // Verify we can parse stream events
    const start = parseStreamEvent(&events[0]);
    try std.testing.expect(start != null);
    try std.testing.expectEqual(types.StreamEventType.start, start.?.event_type);

    const delta = parseStreamEvent(&events[1]);
    try std.testing.expect(delta != null);
    try std.testing.expectEqualStrings("Hello!", delta.?.text.?);
}

test "Client.sendMessage mock error" {
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 401, .body = "{\"error\":{\"message\":\"invalid api key\"}}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = Client.init(&http, "bad-key", null);

    var resp = try client.sendMessage(.{
        .model = "claude-3-5-sonnet",
        .api_key = "bad-key",
    }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(!resp.isSuccess());
    try std.testing.expectEqual(@as(u16, 401), resp.status);
}

test "Client.sendMessage with custom base_url" {
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "data: [DONE]\n\n" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = Client.init(&http, "key", "https://custom-proxy.example.com");

    var resp = try client.sendMessage(.{
        .model = "claude-3-5-sonnet",
        .api_key = "key",
    }, "[]", null);
    defer resp.deinit();

    // Verify call was made and succeeded
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
    try std.testing.expect(resp.isSuccess());
}

test "Client.sendMessage with tools" {
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_1\",\"name\":\"bash\"}}\n\n" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = Client.init(&http, "key", null);

    var resp = try client.sendMessage(.{
        .model = "claude-3-5-sonnet",
        .api_key = "key",
    }, "[{\"role\":\"user\",\"content\":\"run ls\"}]", "[{\"name\":\"bash\"}]");
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
}

test "Client.init defaults" {
    const responses = [_]http_client.MockTransport.MockResponse{};
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    const client = Client.init(&http, "sk-key", null);
    try std.testing.expectEqualStrings(DEFAULT_BASE_URL, client.base_url);
    try std.testing.expectEqualStrings("sk-key", client.api_key);
}

test "Client.init custom base_url" {
    const responses = [_]http_client.MockTransport.MockResponse{};
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    const client = Client.init(&http, "key", "https://proxy.example.com");
    try std.testing.expectEqualStrings("https://proxy.example.com", client.base_url);
}

test "ProviderResponse.isSuccess" {
    const r200 = ProviderResponse{ .status = 200, .body = "" };
    try std.testing.expect(r200.isSuccess());

    const r201 = ProviderResponse{ .status = 201, .body = "" };
    try std.testing.expect(r201.isSuccess());

    const r400 = ProviderResponse{ .status = 400, .body = "" };
    try std.testing.expect(!r400.isSuccess());

    const r500 = ProviderResponse{ .status = 500, .body = "" };
    try std.testing.expect(!r500.isSuccess());
}

// =====================================================
// Additional comprehensive tests
// =====================================================

// --- Content block type parsing in stream events ---

test "parseStreamEvent content_block_start text type" {
    const event = sse.SseEvent{
        .event_type = "content_block_start",
        .data = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.start, result.event_type);
    // Not a tool_use block, so no tool fields
    try std.testing.expect(result.tool_call_id == null);
    try std.testing.expect(result.tool_name == null);
}

test "parseStreamEvent content_block_start thinking type" {
    const event = sse.SseEvent{
        .event_type = "content_block_start",
        .data = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.start, result.event_type);
}

test "parseStreamEvent content_block_start tool_use with complex id" {
    const event = sse.SseEvent{
        .event_type = "content_block_start",
        .data = "{\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_01A109YZZXB1pZD74XjFVsJd\",\"name\":\"web_search\",\"input\":{}}}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.tool_call_start, result.event_type);
    try std.testing.expectEqualStrings("toolu_01A109YZZXB1pZD74XjFVsJd", result.tool_call_id.?);
    try std.testing.expectEqualStrings("web_search", result.tool_name.?);
}

// --- Tool input delta parsing ---

test "parseStreamEvent tool_call_delta with partial_json" {
    const event = sse.SseEvent{
        .event_type = "content_block_delta",
        .data = "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"query\\\"\"}}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.tool_call_delta, result.event_type);
    try std.testing.expect(result.tool_input_delta != null);
}

test "parseStreamEvent content_block_delta with empty text" {
    const event = sse.SseEvent{
        .event_type = "content_block_delta",
        .data = "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"\"}}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.text_delta, result.event_type);
    try std.testing.expectEqualStrings("", result.text.?);
}

// --- Message delta with various stop reasons ---

test "parseStreamEvent message_delta stop_reason tool_use" {
    const event = sse.SseEvent{
        .event_type = "message_delta",
        .data = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":15}}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.stop, result.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, result.stop_reason.?);
    try std.testing.expectEqual(@as(u64, 15), result.usage.?.output_tokens);
}

test "parseStreamEvent message_delta stop_reason max_tokens" {
    const event = sse.SseEvent{
        .event_type = "message_delta",
        .data = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"},\"usage\":{\"output_tokens\":4096}}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StopReason.max_tokens, result.stop_reason.?);
    try std.testing.expectEqual(@as(u64, 4096), result.usage.?.output_tokens);
}

test "parseStreamEvent message_delta stop_reason stop_sequence" {
    const event = sse.SseEvent{
        .event_type = "message_delta",
        .data = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"stop_sequence\"},\"usage\":{\"output_tokens\":10}}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StopReason.stop_sequence, result.stop_reason.?);
}

test "parseStreamEvent message_delta without usage" {
    const event = sse.SseEvent{
        .event_type = "message_delta",
        .data = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.stop, result.event_type);
    try std.testing.expectEqual(types.StopReason.end_turn, result.stop_reason.?);
    try std.testing.expect(result.usage == null);
}

// --- Message start with usage tracking ---

test "parseStreamEvent message_start with large usage" {
    const event = sse.SseEvent{
        .event_type = "message_start",
        .data = "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_abc\",\"model\":\"claude-3-5-sonnet\",\"usage\":{\"input_tokens\":12500}}}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.start, result.event_type);
    try std.testing.expectEqual(@as(u64, 12500), result.usage.?.input_tokens);
}

test "parseStreamEvent message_start without usage" {
    const event = sse.SseEvent{
        .event_type = "message_start",
        .data = "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_abc\"}}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.start, result.event_type);
    try std.testing.expect(result.usage == null);
}

// --- Error event parsing ---

test "parseStreamEvent error with overloaded message" {
    const event = sse.SseEvent{
        .event_type = "error",
        .data = "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.@"error", result.event_type);
    try std.testing.expectEqualStrings("Overloaded", result.error_message.?);
}

test "parseStreamEvent error with invalid_request_error" {
    const event = sse.SseEvent{
        .event_type = "error",
        .data = "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"max_tokens must be positive\"}}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.@"error", result.event_type);
    try std.testing.expectEqualStrings("max_tokens must be positive", result.error_message.?);
}

test "parseStreamEvent error without message field" {
    const event = sse.SseEvent{
        .event_type = "error",
        .data = "{\"type\":\"error\",\"error\":{\"type\":\"api_error\"}}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.@"error", result.event_type);
    try std.testing.expect(result.error_message == null);
}

// --- content_block_stop ---

test "parseStreamEvent content_block_stop returns null" {
    const event = sse.SseEvent{
        .event_type = "content_block_stop",
        .data = "{\"type\":\"content_block_stop\",\"index\":0}",
    };
    const result = parseStreamEvent(&event);
    try std.testing.expect(result == null);
}

// --- Null/missing event_type ---

test "parseStreamEvent null event_type with non-DONE data returns null" {
    const event = sse.SseEvent{
        .event_type = null,
        .data = "{\"some\":\"data\"}",
    };
    const result = parseStreamEvent(&event);
    try std.testing.expect(result == null);
}

// --- Request body building edge cases ---

test "buildRequestBody with no system prompt" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "claude-3-haiku",
        .api_key = "sk-test",
    }, "[]", null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\"") == null);
}

test "buildRequestBody with all fields" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "claude-3-5-sonnet-20241022",
        .max_tokens = 8192,
        .stream = true,
        .temperature = 0.3,
        .system_prompt = "Be concise.",
        .api_key = "sk-ant-key",
    }, "[{\"role\":\"user\",\"content\":\"hi\"}]", "[{\"name\":\"bash\"}]");

    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"claude-3-5-sonnet-20241022\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":8192") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Be concise.") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"name\":\"bash\"}]") != null);
}

test "buildRequestBody temperature zero" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "claude-3-5-sonnet",
        .temperature = 0.0,
        .api_key = "sk-test",
    }, "[]", null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.0") != null);
}

test "buildRequestBody temperature max" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "claude-3-5-sonnet",
        .temperature = 1.0,
        .api_key = "sk-test",
    }, "[]", null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":1.0") != null);
}

test "buildRequestBody system prompt with special characters" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "claude-3-5-sonnet",
        .system_prompt = "Handle \"quotes\" and \\backslashes\\ and\nnewlines",
        .api_key = "sk-test",
    }, "[]", null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"quotes\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\\backslashes\\\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\n") != null);
}

test "buildRequestBody with empty messages array" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "claude-3-5-sonnet",
        .api_key = "sk-test",
    }, "[]", null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"messages\":[]") != null);
}

// --- Tool JSON building ---

test "buildToolJson with no description" {
    var buf: [1024]u8 = undefined;
    const json = try buildToolJson(&buf, .{
        .name = "simple_tool",
    });
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"simple_tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"description\"") == null);
}

test "buildToolJson with no parameters" {
    var buf: [1024]u8 = undefined;
    const json = try buildToolJson(&buf, .{
        .name = "no_params",
        .description = "A tool without parameters",
    });
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"no_params\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"description\":\"A tool without parameters\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"input_schema\"") == null);
}

test "buildToolJson with complex parameters" {
    var buf: [2048]u8 = undefined;
    const params = "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\"},\"method\":{\"type\":\"string\",\"enum\":[\"GET\",\"POST\"]}},\"required\":[\"url\"]}";
    const json = try buildToolJson(&buf, .{
        .name = "http_request",
        .description = "Make HTTP request",
        .parameters_json = params,
    });
    try std.testing.expect(std.mem.indexOf(u8, json, "\"input_schema\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"required\"") != null);
}

test "buildToolJson description with special characters" {
    var buf: [1024]u8 = undefined;
    const json = try buildToolJson(&buf, .{
        .name = "test",
        .description = "Handles \"special\" chars\nand newlines",
    });
    try std.testing.expect(std.mem.indexOf(u8, json, "\\\"special\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\n") != null);
}

// --- Message building ---

test "buildUserMessage with special characters" {
    var buf: [1024]u8 = undefined;
    const msg = try buildUserMessage(&buf, "Say \"hello\" and use \\path\\to\\file");
    try std.testing.expect(std.mem.indexOf(u8, msg, "\\\"hello\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\\\\path\\\\to\\\\file") != null);
}

test "buildUserMessage empty text" {
    var buf: [1024]u8 = undefined;
    const msg = try buildUserMessage(&buf, "");
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"text\":\"\"") != null);
}

test "buildAssistantMessage with special characters" {
    var buf: [1024]u8 = undefined;
    const msg = try buildAssistantMessage(&buf, "Line 1\nLine 2\tTabbed");
    try std.testing.expect(std.mem.indexOf(u8, msg, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\\t") != null);
}

test "buildToolResultMessage with JSON content" {
    var buf: [1024]u8 = undefined;
    const msg = try buildToolResultMessage(&buf, "call_abc", "{\"result\":\"ok\"}");
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"tool_use_id\":\"call_abc\"") != null);
}

// --- writeJsonEscaped edge cases ---

test "writeJsonEscaped empty string" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeJsonEscaped(fbs.writer(), "");
    try std.testing.expectEqualStrings("", fbs.getWritten());
}

test "writeJsonEscaped no special characters" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeJsonEscaped(fbs.writer(), "plain text");
    try std.testing.expectEqualStrings("plain text", fbs.getWritten());
}

test "writeJsonEscaped control characters" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const input = [_]u8{ 0x00, 0x01, 0x1F };
    try writeJsonEscaped(fbs.writer(), &input);
    const result = fbs.getWritten();
    // Control characters should be escaped as \uXXXX
    try std.testing.expect(result.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result, "\\u") != null);
}

test "writeJsonEscaped carriage return" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeJsonEscaped(fbs.writer(), "line1\rline2");
    try std.testing.expectEqualStrings("line1\\rline2", fbs.getWritten());
}

// --- extractJsonString edge cases ---

test "extractJsonString at end of string" {
    const json = "{\"key\":\"value\"}";
    try std.testing.expectEqualStrings("value", extractJsonString(json, "\"key\":\"").?);
}

test "extractJsonString empty value" {
    const json = "{\"key\":\"\"}";
    try std.testing.expectEqualStrings("", extractJsonString(json, "\"key\":\"").?);
}

test "extractJsonString with escaped quotes in value" {
    const json = "{\"text\":\"say \\\"hello\\\"\"}";
    // The extractor should stop at the first unescaped quote
    const result = extractJsonString(json, "\"text\":\"");
    try std.testing.expect(result != null);
}

test "extractJsonString multiple matches returns first" {
    const json = "{\"a\":\"first\",\"b\":\"second\",\"a\":\"third\"}";
    try std.testing.expectEqualStrings("first", extractJsonString(json, "\"a\":\"").?);
}

test "extractJsonString with prefix at very end" {
    // Prefix found but no content after
    try std.testing.expect(extractJsonString("\"key\":\"", "\"key\":\"") == null);
}

// --- extractJsonNumber edge cases ---

test "extractJsonNumber zero value" {
    const json = "{\"count\":0}";
    try std.testing.expectEqual(@as(i64, 0), extractJsonNumber(json, "\"count\":").?);
}

test "extractJsonNumber large value" {
    const json = "{\"tokens\":999999999}";
    try std.testing.expectEqual(@as(i64, 999999999), extractJsonNumber(json, "\"tokens\":").?);
}

test "extractJsonNumber with trailing comma" {
    const json = "{\"a\":42,\"b\":7}";
    try std.testing.expectEqual(@as(i64, 42), extractJsonNumber(json, "\"a\":").?);
    try std.testing.expectEqual(@as(i64, 7), extractJsonNumber(json, "\"b\":").?);
}

test "extractJsonNumber with non-digit after prefix" {
    const json = "{\"val\":null}";
    try std.testing.expect(extractJsonNumber(json, "\"val\":") == null);
}

// --- Headers ---

test "buildHeaders contains all required Anthropic headers" {
    var buf: [4][2][]const u8 = undefined;
    const headers = buildHeaders(&buf, "sk-ant-api03-test");
    try std.testing.expectEqual(@as(usize, 4), headers.len);
    try std.testing.expectEqualStrings("content-type", headers[0][0]);
    try std.testing.expectEqualStrings("x-api-key", headers[1][0]);
    try std.testing.expectEqualStrings("anthropic-version", headers[2][0]);
    try std.testing.expectEqualStrings("accept", headers[3][0]);
    try std.testing.expectEqualStrings("text/event-stream", headers[3][1]);
}

// --- ProviderResponse edge cases ---

test "ProviderResponse.isSuccess boundary values" {
    const r199 = ProviderResponse{ .status = 199, .body = "" };
    try std.testing.expect(!r199.isSuccess());

    const r299 = ProviderResponse{ .status = 299, .body = "" };
    try std.testing.expect(r299.isSuccess());

    const r300 = ProviderResponse{ .status = 300, .body = "" };
    try std.testing.expect(!r300.isSuccess());
}

test "ProviderResponse.isSuccess common error codes" {
    const codes = [_]u16{ 400, 401, 403, 404, 408, 429, 500, 502, 503, 504 };
    for (codes) |code| {
        const r = ProviderResponse{ .status = code, .body = "" };
        try std.testing.expect(!r.isSuccess());
    }
}

test "ProviderResponse.deinit with allocator frees body" {
    const allocator = std.testing.allocator;
    const body = try allocator.dupe(u8, "test response body");
    var resp = ProviderResponse{
        .status = 200,
        .body = body,
        .allocator = allocator,
    };
    resp.deinit();
    // If we get here without crash, the deallocation was successful
}

test "ProviderResponse.deinit without allocator is no-op" {
    var resp = ProviderResponse{
        .status = 200,
        .body = "static body",
    };
    resp.deinit();
}

// --- Full stream simulation ---

test "parseStreamEvent full conversation stream" {
    // Simulate a complete Anthropic stream
    const events_data = [_]struct { event_type: []const u8, data: []const u8 }{
        .{ .event_type = "message_start", .data = "{\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":50}}}" },
        .{ .event_type = "content_block_start", .data = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\"}}" },
        .{ .event_type = "content_block_delta", .data = "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}" },
        .{ .event_type = "content_block_delta", .data = "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" world\"}}" },
        .{ .event_type = "content_block_stop", .data = "{\"type\":\"content_block_stop\",\"index\":0}" },
        .{ .event_type = "message_delta", .data = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":10}}" },
        .{ .event_type = "message_stop", .data = "{\"type\":\"message_stop\"}" },
    };

    var total_usage = types.Usage{};
    var text_parts: [10][]const u8 = undefined;
    var text_count: usize = 0;

    for (events_data) |ed| {
        const sse_event = sse.SseEvent{ .event_type = ed.event_type, .data = ed.data };
        if (parseStreamEvent(&sse_event)) |stream_event| {
            switch (stream_event.event_type) {
                .start => {
                    if (stream_event.usage) |u| total_usage.add(u);
                },
                .text_delta => {
                    if (stream_event.text) |t| {
                        text_parts[text_count] = t;
                        text_count += 1;
                    }
                },
                .stop => {
                    if (stream_event.usage) |u| total_usage.add(u);
                },
                else => {},
            }
        }
    }

    try std.testing.expectEqual(@as(usize, 2), text_count);
    try std.testing.expectEqualStrings("Hello", text_parts[0]);
    try std.testing.expectEqualStrings(" world", text_parts[1]);
    try std.testing.expectEqual(@as(u64, 50), total_usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 10), total_usage.output_tokens);
}

// --- API Constants ---

test "API constants are correct" {
    try std.testing.expectEqualStrings("https://api.anthropic.com", DEFAULT_BASE_URL);
    try std.testing.expectEqualStrings("/v1/messages", MESSAGES_PATH);
    try std.testing.expectEqualStrings("2023-06-01", API_VERSION);
}

// =====================================================
// Targeted scenario tests
// =====================================================

// --- 1. writeJsonEscaped with control characters ---

test "writeJsonEscaped with tab newline carriage return" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeJsonEscaped(fbs.writer(), "before\tand\nand\rafter");
    try std.testing.expectEqualStrings("before\\tand\\nand\\rafter", fbs.getWritten());
}

test "writeJsonEscaped with null byte" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const input = "before\x00after";
    try writeJsonEscaped(fbs.writer(), input);
    const result = fbs.getWritten();
    // Null byte (0x00) should be escaped as \u0000
    try std.testing.expectEqualStrings("before\\u0000after", result);
}

test "writeJsonEscaped with backspace" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const input = "before\x08after";
    try writeJsonEscaped(fbs.writer(), input);
    const result = fbs.getWritten();
    // Backspace (0x08) is a control char < 0x20, should be \u0008
    try std.testing.expectEqualStrings("before\\u0008after", result);
}

test "writeJsonEscaped with multiple control characters in sequence" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    // Mix of named escapes (\t, \n, \r) and generic control chars (\x01, \x1f)
    const input = "\x01\t\n\r\x1f";
    try writeJsonEscaped(fbs.writer(), input);
    const result = fbs.getWritten();
    try std.testing.expectEqualStrings("\\u0001\\t\\n\\r\\u001f", result);
}

// --- 2. writeJsonEscaped with unicode ---

test "writeJsonEscaped with non-ASCII latin characters" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    // UTF-8 encoded: e with accent (e-acute = 0xC3 0xA9)
    try writeJsonEscaped(fbs.writer(), "caf\xc3\xa9");
    const result = fbs.getWritten();
    // Multi-byte UTF-8 characters have bytes >= 0x80, so they pass through as-is
    try std.testing.expectEqualStrings("caf\xc3\xa9", result);
}

test "writeJsonEscaped with emoji" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    // Rocket emoji U+1F680 = 0xF0 0x9F 0x9A 0x80 in UTF-8
    const rocket = "\xf0\x9f\x9a\x80";
    try writeJsonEscaped(fbs.writer(), rocket);
    const result = fbs.getWritten();
    // All bytes are >= 0x80, so they pass through unchanged
    try std.testing.expectEqualStrings(rocket, result);
}

test "writeJsonEscaped with CJK characters" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    // Japanese: "hello" in hiragana
    const input = "\xe3\x81\x93\xe3\x82\x93\xe3\x81\xab\xe3\x81\xa1\xe3\x81\xaf";
    try writeJsonEscaped(fbs.writer(), input);
    const result = fbs.getWritten();
    try std.testing.expectEqualStrings(input, result);
}

test "writeJsonEscaped with mixed unicode and escapes" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    // "caf\xc3\xa9" with a newline and a quote
    try writeJsonEscaped(fbs.writer(), "caf\xc3\xa9\n\"bon\"");
    const result = fbs.getWritten();
    try std.testing.expectEqualStrings("caf\xc3\xa9\\n\\\"bon\\\"", result);
}

// --- 3. writeJsonEscaped with deeply nested escaping ---

test "writeJsonEscaped with escaped quotes in source" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    // Input literally contains backslash-quote: value is  He said \"hi\"
    try writeJsonEscaped(fbs.writer(), "He said \\\"hi\\\"");
    const result = fbs.getWritten();
    // Each \ becomes \\, each " becomes \"
    // So \" in input becomes \\\"
    try std.testing.expectEqualStrings("He said \\\\\\\"hi\\\\\\\"", result);
}

test "writeJsonEscaped with double backslashes" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeJsonEscaped(fbs.writer(), "C:\\\\Users\\\\path");
    const result = fbs.getWritten();
    // Each \\ in input becomes \\\\ in output
    try std.testing.expectEqualStrings("C:\\\\\\\\Users\\\\\\\\path", result);
}

test "writeJsonEscaped with backslash before newline" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeJsonEscaped(fbs.writer(), "line\\\n");
    const result = fbs.getWritten();
    // \ becomes \\, \n becomes \n
    try std.testing.expectEqualStrings("line\\\\\\n", result);
}

// --- 4. buildRequestBody near buffer capacity ---

test "buildRequestBody near buffer capacity" {
    // Create a buffer that is just barely large enough for the output
    // A minimal request: {"model":"X","max_tokens":4096,"stream":true,"system":[{"type":"text","text":"Y"}],"messages":[]}
    // Use a very long model name and system prompt to nearly fill the buffer
    const model_name = "a" ** 200;
    const system_prompt = "b" ** 300;
    // Calculate approximate size: overhead + model + system + messages
    // overhead ~ 120 bytes for JSON structure
    var big_buf: [1024]u8 = undefined;
    const body = try buildRequestBody(&big_buf, .{
        .model = model_name,
        .system_prompt = system_prompt,
        .api_key = "sk-test",
    }, "[]", null);

    try std.testing.expect(std.mem.indexOf(u8, body, model_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, system_prompt) != null);
    try std.testing.expect(body.len > 500); // Should be substantial
}

test "buildRequestBody buffer too small returns error" {
    // Buffer that is way too small
    var tiny_buf: [10]u8 = undefined;
    const result = buildRequestBody(&tiny_buf, .{
        .model = "claude-3-5-sonnet-20241022",
        .api_key = "sk-test",
    }, "[]", null);
    try std.testing.expectError(error.NoSpaceLeft, result);
}

// --- 5. buildRequestBody with tools_json ---

test "buildRequestBody with tools_json includes tools in output" {
    var buf: [4096]u8 = undefined;
    const tools = "[{\"name\":\"bash\",\"description\":\"Run shell commands\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}}}}]";
    const body = try buildRequestBody(&buf, .{
        .model = "claude-3-5-sonnet",
        .system_prompt = "You are a coding assistant.",
        .api_key = "sk-test",
    }, "[{\"role\":\"user\",\"content\":\"list files\"}]", tools);

    // Verify tools are present in the output
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"name\":\"bash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input_schema\"") != null);
    // Verify it also has system and messages
    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"messages\"") != null);
}

test "buildRequestBody tools_json null means no tools key" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "claude-3-5-sonnet",
        .api_key = "sk-test",
    }, "[]", null);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") == null);
}

// --- 6. parseStreamEvent with unknown event type ---

test "parseStreamEvent with completely unknown event type returns null" {
    const event = sse.SseEvent{
        .event_type = "ping",
        .data = "{\"type\":\"ping\"}",
    };
    try std.testing.expect(parseStreamEvent(&event) == null);
}

test "parseStreamEvent with empty event type string returns null" {
    const event = sse.SseEvent{
        .event_type = "",
        .data = "{}",
    };
    try std.testing.expect(parseStreamEvent(&event) == null);
}

test "parseStreamEvent with similar but wrong event type" {
    const event = sse.SseEvent{
        .event_type = "content_block_deltas", // extra 's'
        .data = "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}",
    };
    try std.testing.expect(parseStreamEvent(&event) == null);
}

// --- 7. parseStreamEvent with malformed JSON ---

test "parseStreamEvent with malformed JSON in content_block_delta" {
    const event = sse.SseEvent{
        .event_type = "content_block_delta",
        .data = "this is not json at all",
    };
    // No extractable text or partial_json, should return null
    try std.testing.expect(parseStreamEvent(&event) == null);
}

test "parseStreamEvent with truncated JSON" {
    const event = sse.SseEvent{
        .event_type = "content_block_delta",
        .data = "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":",
    };
    // extractJsonString for "text" won't find a properly quoted string
    try std.testing.expect(parseStreamEvent(&event) == null);
}

test "parseStreamEvent with empty JSON object" {
    const event = sse.SseEvent{
        .event_type = "content_block_delta",
        .data = "{}",
    };
    // No text or partial_json fields found
    try std.testing.expect(parseStreamEvent(&event) == null);
}

// --- 8. parseStreamEvent with empty data field ---

test "parseStreamEvent with empty data string" {
    const event = sse.SseEvent{
        .event_type = "content_block_delta",
        .data = "",
    };
    try std.testing.expect(parseStreamEvent(&event) == null);
}

test "parseStreamEvent message_start with empty data" {
    const event = sse.SseEvent{
        .event_type = "message_start",
        .data = "",
    };
    const result = parseStreamEvent(&event).?;
    // message_start always returns a start event, but usage will be null
    try std.testing.expectEqual(types.StreamEventType.start, result.event_type);
    try std.testing.expect(result.usage == null);
}

test "parseStreamEvent message_delta with empty data" {
    const event = sse.SseEvent{
        .event_type = "message_delta",
        .data = "",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.stop, result.event_type);
    try std.testing.expect(result.stop_reason == null);
    try std.testing.expect(result.usage == null);
}

// --- 9. extractJsonString with escaped quotes ---

test "extractJsonString with escaped quote in value" {
    const json = "{\"text\":\"say \\\"hello\\\" world\"}";
    const result = extractJsonString(json, "\"text\":\"");
    try std.testing.expect(result != null);
    // The extractor finds from start to first unescaped quote
    // Input: say \"hello\" world
    // The \" are escaped, so extractor should skip them
    try std.testing.expectEqualStrings("say \\\"hello\\\" world", result.?);
}

test "extractJsonString with single escaped quote" {
    const json = "{\"msg\":\"it's \\\"fine\\\"\"}";
    const result = extractJsonString(json, "\"msg\":\"");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("it's \\\"fine\\\"", result.?);
}

test "extractJsonString with escaped backslash before quote" {
    // JSON: {"val":"test\\"}  - value is test\ (escaped backslash then closing quote)
    // The simple extractor sees \ before " and thinks it's escaped — known limitation.
    // It returns null because it can't find the unescaped closing quote.
    const json = "{\"val\":\"test\\\\\"}";
    const result = extractJsonString(json, "\"val\":\"");
    try std.testing.expect(result == null);
}

// --- 10. buildHeaders with custom base_url ---

test "buildHeaders always includes api-key and version regardless of usage context" {
    // Even when client uses a custom base_url, buildHeaders itself just takes an api key
    var buf: [4][2][]const u8 = undefined;
    const custom_key = "sk-ant-custom-proxy-key-12345";
    const headers = buildHeaders(&buf, custom_key);

    // Verify x-api-key header contains the custom key
    try std.testing.expectEqualStrings("x-api-key", headers[1][0]);
    try std.testing.expectEqualStrings(custom_key, headers[1][1]);

    // Verify anthropic-version header is always present with correct value
    try std.testing.expectEqualStrings("anthropic-version", headers[2][0]);
    try std.testing.expectEqualStrings("2023-06-01", headers[2][1]);

    // Verify content-type is application/json
    try std.testing.expectEqualStrings("content-type", headers[0][0]);
    try std.testing.expectEqualStrings("application/json", headers[0][1]);

    // Verify accept is text/event-stream
    try std.testing.expectEqualStrings("accept", headers[3][0]);
    try std.testing.expectEqualStrings("text/event-stream", headers[3][1]);
}

test "buildHeaders with empty api key" {
    var buf: [4][2][]const u8 = undefined;
    const headers = buildHeaders(&buf, "");
    try std.testing.expectEqualStrings("x-api-key", headers[1][0]);
    try std.testing.expectEqualStrings("", headers[1][1]);
    // Version header is still present
    try std.testing.expectEqualStrings("anthropic-version", headers[2][0]);
    try std.testing.expectEqualStrings(API_VERSION, headers[2][1]);
}

// --- 11. Client.sendMessage with 429 rate limit ---

test "Client.sendMessage with 429 rate limit response" {
    const error_body = "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"Rate limit exceeded. Please retry after 30 seconds.\"}}";
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 429, .body = error_body },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = Client.init(&http, "sk-ant-key", null);

    var resp = try client.sendMessage(.{
        .model = "claude-3-5-sonnet-20241022",
        .api_key = "sk-ant-key",
    }, "[{\"role\":\"user\",\"content\":\"hello\"}]", null);
    defer resp.deinit();

    try std.testing.expect(!resp.isSuccess());
    try std.testing.expectEqual(@as(u16, 429), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "rate_limit_error") != null);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
}

// --- 12. Client.sendMessage with 401 auth error ---

test "Client.sendMessage with 401 authentication error" {
    const error_body = "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"Invalid API key provided.\"}}";
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 401, .body = error_body },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = Client.init(&http, "sk-ant-INVALID", null);

    var resp = try client.sendMessage(.{
        .model = "claude-3-5-sonnet",
        .api_key = "sk-ant-INVALID",
    }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(!resp.isSuccess());
    try std.testing.expectEqual(@as(u16, 401), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "authentication_error") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Invalid API key") != null);
}

// --- 13. parseStreamEvent error event ---

test "parseStreamEvent error event with rate_limit_error type" {
    const event = sse.SseEvent{
        .event_type = "error",
        .data = "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"Number of request tokens has exceeded your per-minute rate limit\"}}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.@"error", result.event_type);
    try std.testing.expectEqualStrings("Number of request tokens has exceeded your per-minute rate limit", result.error_message.?);
}

test "parseStreamEvent error event with api_error type" {
    const event = sse.SseEvent{
        .event_type = "error",
        .data = "{\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":\"Internal server error\"}}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.@"error", result.event_type);
    try std.testing.expectEqualStrings("Internal server error", result.error_message.?);
}

test "parseStreamEvent error event with empty message" {
    const event = sse.SseEvent{
        .event_type = "error",
        .data = "{\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":\"\"}}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.@"error", result.event_type);
    try std.testing.expectEqualStrings("", result.error_message.?);
}

// --- 14. buildUserMessage with very long content ---

test "buildUserMessage with near 32KB content" {
    // Generate content that is close to 32KB (the sendMessage body_buf is 64KB)
    const long_text = "x" ** (30 * 1024);
    var buf: [32 * 1024]u8 = undefined;
    const msg = try buildUserMessage(&buf, long_text);

    // Verify structure is correct
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"type\":\"text\"") != null);
    // Verify the long content is present
    try std.testing.expect(msg.len > 30 * 1024);
    // Verify it starts and ends correctly
    try std.testing.expect(std.mem.startsWith(u8, msg, "{\"role\":\"user\""));
    try std.testing.expect(std.mem.endsWith(u8, msg, "\"}]}"));
}

test "buildUserMessage buffer too small for long content" {
    const long_text = "y" ** 2000;
    var small_buf: [100]u8 = undefined;
    const result = buildUserMessage(&small_buf, long_text);
    try std.testing.expectError(error.NoSpaceLeft, result);
}

// --- 15. buildAssistantMessage content verification ---

test "buildAssistantMessage JSON structure verification" {
    var buf: [1024]u8 = undefined;
    const msg = try buildAssistantMessage(&buf, "I can help you with that.");

    // Verify exact JSON structure
    try std.testing.expect(std.mem.startsWith(u8, msg, "{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\""));
    try std.testing.expect(std.mem.endsWith(u8, msg, "\"}]}"));

    // Verify the role is assistant (not user)
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"role\":\"assistant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"role\":\"user\"") == null);

    // Verify content array structure
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"content\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"type\":\"text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"text\":\"I can help you with that.\"") != null);
}

test "buildAssistantMessage with content requiring escaping" {
    var buf: [1024]u8 = undefined;
    const msg = try buildAssistantMessage(&buf, "Here is code:\n```\nfn main() {}\n```\nWith \"quotes\" and \\backslash");

    // Verify escaping happened
    try std.testing.expect(std.mem.indexOf(u8, msg, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\\\"quotes\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\\\\backslash") != null);

    // Verify structure is maintained
    try std.testing.expect(std.mem.startsWith(u8, msg, "{\"role\":\"assistant\""));
    try std.testing.expect(std.mem.endsWith(u8, msg, "\"}]}"));
}

test "buildAssistantMessage vs buildUserMessage role difference" {
    var buf1: [1024]u8 = undefined;
    var buf2: [1024]u8 = undefined;
    const assistant_msg = try buildAssistantMessage(&buf1, "same content");
    const user_msg = try buildUserMessage(&buf2, "same content");

    // Both should have the same content but different roles
    try std.testing.expect(std.mem.indexOf(u8, assistant_msg, "\"role\":\"assistant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, user_msg, "\"role\":\"user\"") != null);

    // Both should have the same text content
    try std.testing.expect(std.mem.indexOf(u8, assistant_msg, "\"text\":\"same content\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, user_msg, "\"text\":\"same content\"") != null);
}
