const std = @import("std");
const types = @import("types.zig");
const sse = @import("sse.zig");

// --- OpenAI API Constants ---

pub const DEFAULT_BASE_URL = "https://api.openai.com";
pub const COMPLETIONS_PATH = "/v1/chat/completions";

// --- Request Building ---

/// Build an OpenAI Chat Completions API request body as JSON.
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
    try writer.writeAll("\"");

    if (config.max_tokens > 0) {
        try writer.writeAll(",\"max_tokens\":");
        try std.fmt.format(writer, "{d}", .{config.max_tokens});
    }

    if (config.stream) {
        try writer.writeAll(",\"stream\":true");
    }

    if (config.temperature) |temp| {
        try writer.writeAll(",\"temperature\":");
        try std.fmt.format(writer, "{d:.1}", .{temp});
    }

    if (tools_json) |tools| {
        try writer.writeAll(",\"tools\":");
        try writer.writeAll(tools);
        try writer.writeAll(",\"tool_choice\":\"auto\"");
    }

    try writer.writeAll(",\"messages\":");

    // Inject system prompt as first message if provided
    if (config.system_prompt) |sys| {
        try writer.writeAll("[{\"role\":\"system\",\"content\":\"");
        try writeJsonEscaped(writer, sys);
        try writer.writeAll("\"},");
        // Strip leading [ from messages_json
        if (messages_json.len > 0 and messages_json[0] == '[') {
            try writer.writeAll(messages_json[1..]);
        } else {
            try writer.writeAll(messages_json);
        }
    } else {
        try writer.writeAll(messages_json);
    }

    try writer.writeAll("}");
    return fbs.getWritten();
}

/// Build HTTP headers for OpenAI API
pub fn buildHeaders(buf: *[3][2][]const u8, api_key: []const u8) [3][2][]const u8 {
    buf[0] = .{ "content-type", "application/json" };
    buf[1] = .{ "authorization", api_key }; // Caller prepends "Bearer "
    buf[2] = .{ "accept", "text/event-stream" };
    return buf.*;
}

/// Format bearer token: "Bearer <key>"
pub fn formatBearerToken(buf: []u8, api_key: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    try writer.writeAll("Bearer ");
    try writer.writeAll(api_key);
    return fbs.getWritten();
}

// --- Response Parsing ---

/// Parse an OpenAI SSE event into a StreamEvent
pub fn parseStreamEvent(event: *const sse.SseEvent) ?types.StreamEvent {
    if (event.isDone()) {
        return .{ .event_type = .stop, .stop_reason = .end_turn };
    }

    const data = event.data;

    // Extract finish_reason if present
    const finish_reason = extractJsonString(data, "\"finish_reason\":\"");
    if (finish_reason) |fr| {
        const stop_reason = types.StopReason.fromString(fr);
        // Extract usage from the final message
        var usage: ?types.Usage = null;
        if (extractJsonNumber(data, "\"prompt_tokens\":")) |pt| {
            usage = .{ .input_tokens = @intCast(pt) };
            if (extractJsonNumber(data, "\"completion_tokens\":")) |ct| {
                usage.?.output_tokens = @intCast(ct);
            }
        }
        return .{
            .event_type = .stop,
            .stop_reason = stop_reason,
            .usage = usage,
        };
    }

    // Check for content delta
    if (extractJsonString(data, "\"content\":\"")) |content| {
        return .{ .event_type = .text_delta, .text = content };
    }

    // Check for tool calls
    if (std.mem.indexOf(u8, data, "\"tool_calls\"") != null) {
        const tool_id = extractJsonString(data, "\"id\":\"");
        const func_name = extractJsonString(data, "\"name\":\"");
        const args_delta = extractJsonString(data, "\"arguments\":\"");

        if (tool_id != null or func_name != null) {
            return .{
                .event_type = .tool_call_start,
                .tool_call_id = tool_id,
                .tool_name = func_name,
                .tool_input_delta = args_delta,
            };
        }
        if (args_delta != null) {
            return .{
                .event_type = .tool_call_delta,
                .tool_input_delta = args_delta,
            };
        }
    }

    // Check for role indicator (first chunk)
    if (extractJsonString(data, "\"role\":\"")) |_| {
        return .{ .event_type = .start };
    }

    return null;
}

/// Build a tool definition in OpenAI format
pub fn buildToolJson(buf: []u8, tool: types.ToolDefinition) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"");
    try writer.writeAll(tool.name);
    try writer.writeAll("\"");

    if (tool.description.len > 0) {
        try writer.writeAll(",\"description\":\"");
        try writeJsonEscaped(writer, tool.description);
        try writer.writeAll("\"");
    }

    if (tool.parameters_json) |params| {
        try writer.writeAll(",\"parameters\":");
        try writer.writeAll(params);
    }

    try writer.writeAll("}}");
    return fbs.getWritten();
}

// --- Message Building ---

/// Build a user message in OpenAI format
pub fn buildUserMessage(buf: []u8, text: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    try writer.writeAll("{\"role\":\"user\",\"content\":\"");
    try writeJsonEscaped(writer, text);
    try writer.writeAll("\"}");
    return fbs.getWritten();
}

/// Build an assistant message in OpenAI format
pub fn buildAssistantMessage(buf: []u8, text: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    try writer.writeAll("{\"role\":\"assistant\",\"content\":\"");
    try writeJsonEscaped(writer, text);
    try writer.writeAll("\"}");
    return fbs.getWritten();
}

/// Build a tool result message in OpenAI format
pub fn buildToolResultMessage(buf: []u8, tool_call_id: []const u8, content: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    try writer.writeAll("{\"role\":\"tool\",\"tool_call_id\":\"");
    try writer.writeAll(tool_call_id);
    try writer.writeAll("\",\"content\":\"");
    try writeJsonEscaped(writer, content);
    try writer.writeAll("\"}");
    return fbs.getWritten();
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

    /// Send a chat completion request to the OpenAI API.
    pub fn sendMessage(
        self: *Client,
        config: types.RequestConfig,
        messages_json: []const u8,
        tools_json: ?[]const u8,
    ) !ProviderResponse {
        var body_buf: [64 * 1024]u8 = undefined;
        const body = try buildRequestBody(&body_buf, config, messages_json, tools_json);

        var url_buf: [512]u8 = undefined;
        const url = try http_client.buildUrl(&url_buf, self.base_url, COMPLETIONS_PATH);

        var bearer_buf: [256]u8 = undefined;
        const bearer = try formatBearerToken(&bearer_buf, self.api_key);

        const auth_headers = [_]http_client.Header{
            .{ .name = "authorization", .value = bearer },
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

    pub fn parseEvents(self: *const ProviderResponse, allocator: std.mem.Allocator) ![]sse.SseEvent {
        var parser = sse.SseParser.init(allocator);
        defer parser.deinit();
        return parser.feed(self.body);
    }
};

const http_client = @import("../infra/http_client.zig");

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

// --- Tests ---

test "buildRequestBody basic" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "gpt-4-turbo",
        .max_tokens = 2048,
        .api_key = "sk-test",
    }, "[{\"role\":\"user\",\"content\":\"hello\"}]", null);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-4-turbo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":2048") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
}

test "buildRequestBody with system prompt" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "gpt-4",
        .system_prompt = "You are helpful.",
        .api_key = "sk-test",
    }, "[{\"role\":\"user\",\"content\":\"hi\"}]", null);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "You are helpful.") != null);
    // System message should come before user messages
    const sys_pos = std.mem.indexOf(u8, body, "\"system\"").?;
    const user_pos = std.mem.indexOf(u8, body, "\"user\"").?;
    try std.testing.expect(sys_pos < user_pos);
}

test "buildRequestBody with tools" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "gpt-4",
        .api_key = "sk-test",
    }, "[]", "[{\"type\":\"function\",\"function\":{\"name\":\"bash\"}}]");

    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"auto\"") != null);
}

test "buildHeaders" {
    var buf: [3][2][]const u8 = undefined;
    const headers = buildHeaders(&buf, "Bearer sk-test");

    try std.testing.expectEqualStrings("content-type", headers[0][0]);
    try std.testing.expectEqualStrings("application/json", headers[0][1]);
    try std.testing.expectEqualStrings("authorization", headers[1][0]);
    try std.testing.expectEqualStrings("Bearer sk-test", headers[1][1]);
}

test "formatBearerToken" {
    var buf: [256]u8 = undefined;
    const token = try formatBearerToken(&buf, "sk-abc123");
    try std.testing.expectEqualStrings("Bearer sk-abc123", token);
}

test "parseStreamEvent text delta" {
    const event = sse.SseEvent{
        .event_type = null,
        .data = "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello\"}}]}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.text_delta, result.event_type);
    try std.testing.expectEqualStrings("Hello", result.text.?);
}

test "parseStreamEvent role indicator" {
    const event = sse.SseEvent{
        .event_type = null,
        .data = "{\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"}}]}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.start, result.event_type);
}

test "parseStreamEvent finish reason stop" {
    const event = sse.SseEvent{
        .event_type = null,
        .data = "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.stop, result.event_type);
    try std.testing.expectEqual(types.StopReason.end_turn, result.stop_reason.?);
}

test "parseStreamEvent finish reason tool_calls" {
    const event = sse.SseEvent{
        .event_type = null,
        .data = "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.stop, result.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, result.stop_reason.?);
}

test "parseStreamEvent tool call" {
    const event = sse.SseEvent{
        .event_type = null,
        .data = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_abc\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"\"}}]}}]}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.tool_call_start, result.event_type);
    try std.testing.expectEqualStrings("call_abc", result.tool_call_id.?);
    try std.testing.expectEqualStrings("bash", result.tool_name.?);
}

test "parseStreamEvent done" {
    const event = sse.SseEvent{ .event_type = null, .data = "[DONE]" };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.stop, result.event_type);
}

test "buildToolJson" {
    var buf: [1024]u8 = undefined;
    const json = try buildToolJson(&buf, .{
        .name = "bash",
        .description = "Execute commands",
        .parameters_json = "{\"type\":\"object\"}",
    });

    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"function\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"bash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"parameters\":{") != null);
}

test "buildUserMessage" {
    var buf: [1024]u8 = undefined;
    const msg = try buildUserMessage(&buf, "Hello");
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"content\":\"Hello\"") != null);
}

test "buildAssistantMessage" {
    var buf: [1024]u8 = undefined;
    const msg = try buildAssistantMessage(&buf, "Hi there");
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"role\":\"assistant\"") != null);
}

test "buildToolResultMessage" {
    var buf: [1024]u8 = undefined;
    const msg = try buildToolResultMessage(&buf, "call_123", "output data");
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"role\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"tool_call_id\":\"call_123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"content\":\"output data\"") != null);
}

test "writeJsonEscaped special chars" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeJsonEscaped(fbs.writer(), "line1\nline2\ttab\"quote\\slash");
    const result = fbs.getWritten();
    try std.testing.expectEqualStrings("line1\\nline2\\ttab\\\"quote\\\\slash", result);
}

test "buildRequestBody with temperature" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "gpt-4",
        .temperature = 0.5,
        .api_key = "sk-test",
    }, "[]", null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.5") != null);
}

test "Client.sendMessage mock success" {
    const mock_sse =
        "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hello!\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";

    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = mock_sse },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = Client.init(&http, "sk-openai-test", null);

    var resp = try client.sendMessage(.{
        .model = "gpt-4-turbo",
        .system_prompt = "You are helpful.",
        .api_key = "sk-openai-test",
    }, "[{\"role\":\"user\",\"content\":\"Hi\"}]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);

    // Parse SSE events
    const events = try resp.parseEvents(std.testing.allocator);
    defer sse.freeEvents(std.testing.allocator, events);
    try std.testing.expectEqual(@as(usize, 4), events.len);

    // Verify stream events
    const delta = parseStreamEvent(&events[1]);
    try std.testing.expect(delta != null);
    try std.testing.expectEqualStrings("Hello!", delta.?.text.?);

    const done = parseStreamEvent(&events[3]);
    try std.testing.expect(done != null);
    try std.testing.expectEqual(types.StreamEventType.stop, done.?.event_type);
}

test "Client.sendMessage mock rate limited" {
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 429, .body = "{\"error\":{\"message\":\"Rate limit exceeded\"}}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = Client.init(&http, "sk-test", null);

    var resp = try client.sendMessage(.{
        .model = "gpt-4",
        .api_key = "sk-test",
    }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(!resp.isSuccess());
    try std.testing.expectEqual(@as(u16, 429), resp.status);
}

test "Client.sendMessage custom base_url" {
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "data: [DONE]\n\n" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = Client.init(&http, "key", "https://openrouter.ai/api");

    var resp = try client.sendMessage(.{
        .model = "meta-llama/llama-3-70b",
        .api_key = "key",
    }, "[]", null);
    defer resp.deinit();

    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
    try std.testing.expect(resp.isSuccess());
}

test "Client.sendMessage with tools" {
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"\"}}]}}]}\n\ndata: [DONE]\n\n" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = Client.init(&http, "key", null);

    var resp = try client.sendMessage(.{
        .model = "gpt-4",
        .api_key = "key",
    }, "[]", "[{\"type\":\"function\",\"function\":{\"name\":\"bash\"}}]");
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
}

test "Client.init custom base_url" {
    const responses = [_]http_client.MockTransport.MockResponse{};
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    const client = Client.init(&http, "key", "https://openrouter.ai/api");
    try std.testing.expectEqualStrings("https://openrouter.ai/api", client.base_url);
}

test "ProviderResponse.isSuccess" {
    const r200 = ProviderResponse{ .status = 200, .body = "" };
    try std.testing.expect(r200.isSuccess());

    const r429 = ProviderResponse{ .status = 429, .body = "" };
    try std.testing.expect(!r429.isSuccess());
}

// =====================================================
// Additional comprehensive tests
// =====================================================

// --- finish_reason parsing for all OpenAI values ---

test "parseStreamEvent finish_reason length maps to max_tokens" {
    const event = sse.SseEvent{
        .event_type = null,
        .data = "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"length\"}]}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.stop, result.event_type);
    try std.testing.expectEqual(types.StopReason.max_tokens, result.stop_reason.?);
}

test "parseStreamEvent finish_reason content_filter" {
    const event = sse.SseEvent{
        .event_type = null,
        .data = "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"content_filter\"}]}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.stop, result.event_type);
    try std.testing.expectEqual(types.StopReason.content_filter, result.stop_reason.?);
}

test "parseStreamEvent finish_reason with usage data" {
    const event = sse.SseEvent{
        .event_type = null,
        .data = "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":50,\"total_tokens\":150}}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.stop, result.event_type);
    try std.testing.expectEqual(types.StopReason.end_turn, result.stop_reason.?);
    try std.testing.expectEqual(@as(u64, 100), result.usage.?.input_tokens);
    try std.testing.expectEqual(@as(u64, 50), result.usage.?.output_tokens);
}

test "parseStreamEvent finish_reason without usage" {
    const event = sse.SseEvent{
        .event_type = null,
        .data = "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.stop, result.event_type);
    try std.testing.expect(result.usage == null);
}

// --- Streaming chunks ---

test "parseStreamEvent content delta with long text" {
    const event = sse.SseEvent{
        .event_type = null,
        .data = "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"This is a longer piece of text that spans multiple words and sentences.\"}}]}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.text_delta, result.event_type);
    try std.testing.expectEqualStrings("This is a longer piece of text that spans multiple words and sentences.", result.text.?);
}

test "parseStreamEvent content delta with empty string" {
    const event = sse.SseEvent{
        .event_type = null,
        .data = "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\"}}]}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.text_delta, result.event_type);
    try std.testing.expectEqualStrings("", result.text.?);
}

test "parseStreamEvent empty delta no content no role" {
    const event = sse.SseEvent{
        .event_type = null,
        .data = "{\"choices\":[{\"index\":0,\"delta\":{}}]}",
    };
    const result = parseStreamEvent(&event);
    // Empty delta without content, role, or tool_calls should return null
    try std.testing.expect(result == null);
}

// --- Tool call parsing ---

test "parseStreamEvent tool call with arguments delta" {
    const event = sse.SseEvent{
        .event_type = null,
        .data = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"query\\\"\"}}]}}]}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.tool_call_delta, result.event_type);
    try std.testing.expect(result.tool_input_delta != null);
}

test "parseStreamEvent tool call start with function name and id" {
    const event = sse.SseEvent{
        .event_type = null,
        .data = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_xyz789\",\"type\":\"function\",\"function\":{\"name\":\"web_search\",\"arguments\":\"\"}}]}}]}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.tool_call_start, result.event_type);
    try std.testing.expectEqualStrings("call_xyz789", result.tool_call_id.?);
    try std.testing.expectEqualStrings("web_search", result.tool_name.?);
}

test "parseStreamEvent tool_calls without id or name is delta" {
    const event = sse.SseEvent{
        .event_type = null,
        .data = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\": \\\"hello\\\"\"}}]}}]}",
    };
    const result = parseStreamEvent(&event).?;
    try std.testing.expectEqual(types.StreamEventType.tool_call_delta, result.event_type);
}

// --- Request body building ---

test "buildRequestBody no stream" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "gpt-4",
        .stream = false,
        .api_key = "sk-test",
    }, "[]", null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\"") == null);
}

test "buildRequestBody with system prompt injects system message" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "gpt-4",
        .system_prompt = "You are a coding assistant.",
        .api_key = "sk-test",
    }, "[{\"role\":\"user\",\"content\":\"help\"}]", null);

    // System message should come first
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "You are a coding assistant.") != null);
}

test "buildRequestBody with tools adds tool_choice auto" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "gpt-4",
        .api_key = "sk-test",
    }, "[]", "[{\"type\":\"function\",\"function\":{\"name\":\"bash\"}}]");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"auto\"") != null);
}

test "buildRequestBody without tools has no tool_choice" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "gpt-4",
        .api_key = "sk-test",
    }, "[]", null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\"") == null);
}

test "buildRequestBody system prompt with special chars" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "gpt-4",
        .system_prompt = "Use \"quotes\" and\nnewlines",
        .api_key = "sk-test",
    }, "[{\"role\":\"user\",\"content\":\"hi\"}]", null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"quotes\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\n") != null);
}

test "buildRequestBody temperature 0.0" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "gpt-4",
        .temperature = 0.0,
        .api_key = "sk-test",
    }, "[]", null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.0") != null);
}

test "buildRequestBody temperature 2.0" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "gpt-4",
        .temperature = 2.0,
        .api_key = "sk-test",
    }, "[]", null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":2.0") != null);
}

test "buildRequestBody max_tokens 0 omits field" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "gpt-4",
        .max_tokens = 0,
        .api_key = "sk-test",
    }, "[]", null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\"") == null);
}

// --- Tool JSON building ---

test "buildToolJson wraps in function type" {
    var buf: [1024]u8 = undefined;
    const json = try buildToolJson(&buf, .{
        .name = "calculator",
        .description = "Do math",
        .parameters_json = "{\"type\":\"object\"}",
    });
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"function\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"function\":{") != null);
}

test "buildToolJson no description" {
    var buf: [1024]u8 = undefined;
    const json = try buildToolJson(&buf, .{
        .name = "tool",
    });
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"description\"") == null);
}

test "buildToolJson no parameters" {
    var buf: [1024]u8 = undefined;
    const json = try buildToolJson(&buf, .{
        .name = "no_params_tool",
        .description = "Does nothing",
    });
    try std.testing.expect(std.mem.indexOf(u8, json, "\"parameters\"") == null);
}

// --- Message building ---

test "buildUserMessage with newlines and tabs" {
    var buf: [1024]u8 = undefined;
    const msg = try buildUserMessage(&buf, "line1\nline2\ttab");
    try std.testing.expect(std.mem.indexOf(u8, msg, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\\t") != null);
}

test "buildAssistantMessage empty" {
    var buf: [1024]u8 = undefined;
    const msg = try buildAssistantMessage(&buf, "");
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"role\":\"assistant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"content\":\"\"") != null);
}

test "buildToolResultMessage with empty content" {
    var buf: [1024]u8 = undefined;
    const msg = try buildToolResultMessage(&buf, "call_id", "");
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"role\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"content\":\"\"") != null);
}

test "buildToolResultMessage uses tool role not user" {
    var buf: [1024]u8 = undefined;
    const msg = try buildToolResultMessage(&buf, "c1", "result");
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"role\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"role\":\"user\"") == null);
}

// --- formatBearerToken ---

test "formatBearerToken with long key" {
    var buf: [256]u8 = undefined;
    const token = try formatBearerToken(&buf, "sk-proj-abcdefghijklmnopqrstuvwxyz0123456789");
    try std.testing.expect(std.mem.startsWith(u8, token, "Bearer "));
    try std.testing.expect(std.mem.endsWith(u8, token, "0123456789"));
}

test "formatBearerToken with empty key" {
    var buf: [256]u8 = undefined;
    const token = try formatBearerToken(&buf, "");
    try std.testing.expectEqualStrings("Bearer ", token);
}

// --- Headers ---

test "buildHeaders structure" {
    var buf: [3][2][]const u8 = undefined;
    const headers = buildHeaders(&buf, "Bearer test-key");
    try std.testing.expectEqual(@as(usize, 3), headers.len);
    try std.testing.expectEqualStrings("content-type", headers[0][0]);
    try std.testing.expectEqualStrings("application/json", headers[0][1]);
    try std.testing.expectEqualStrings("authorization", headers[1][0]);
    try std.testing.expectEqualStrings("accept", headers[2][0]);
    try std.testing.expectEqualStrings("text/event-stream", headers[2][1]);
}

// --- extractJsonString ---

test "extractJsonString from OpenAI response" {
    const json = "{\"choices\":[{\"delta\":{\"content\":\"Hello world\"}}]}";
    try std.testing.expectEqualStrings("Hello world", extractJsonString(json, "\"content\":\"").?);
}

test "extractJsonString finish_reason" {
    const json = "{\"choices\":[{\"finish_reason\":\"stop\"}]}";
    try std.testing.expectEqualStrings("stop", extractJsonString(json, "\"finish_reason\":\"").?);
}

test "extractJsonString returns null for missing" {
    try std.testing.expect(extractJsonString("{}", "\"missing\":\"") == null);
}

test "extractJsonString empty json" {
    try std.testing.expect(extractJsonString("", "\"key\":\"") == null);
}

// --- extractJsonNumber ---

test "extractJsonNumber prompt_tokens" {
    const json = "{\"usage\":{\"prompt_tokens\":42,\"completion_tokens\":10}}";
    try std.testing.expectEqual(@as(i64, 42), extractJsonNumber(json, "\"prompt_tokens\":").?);
    try std.testing.expectEqual(@as(i64, 10), extractJsonNumber(json, "\"completion_tokens\":").?);
}

test "extractJsonNumber missing field" {
    try std.testing.expect(extractJsonNumber("{}", "\"tokens\":") == null);
}

// --- ProviderResponse ---

test "ProviderResponse.isSuccess boundary 200" {
    const r = ProviderResponse{ .status = 200, .body = "" };
    try std.testing.expect(r.isSuccess());
}

test "ProviderResponse.isSuccess boundary 299" {
    const r = ProviderResponse{ .status = 299, .body = "" };
    try std.testing.expect(r.isSuccess());
}

test "ProviderResponse.isSuccess boundary 300 fails" {
    const r = ProviderResponse{ .status = 300, .body = "" };
    try std.testing.expect(!r.isSuccess());
}

test "ProviderResponse.isSuccess boundary 199 fails" {
    const r = ProviderResponse{ .status = 199, .body = "" };
    try std.testing.expect(!r.isSuccess());
}

test "ProviderResponse deinit frees allocated body" {
    const allocator = std.testing.allocator;
    const body = try allocator.dupe(u8, "response body to free");
    var resp = ProviderResponse{
        .status = 200,
        .body = body,
        .allocator = allocator,
    };
    resp.deinit();
}

// --- API Constants ---

test "OpenAI API constants" {
    try std.testing.expectEqualStrings("https://api.openai.com", DEFAULT_BASE_URL);
    try std.testing.expectEqualStrings("/v1/chat/completions", COMPLETIONS_PATH);
}

// --- writeJsonEscaped ---

test "writeJsonEscaped all special chars" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeJsonEscaped(fbs.writer(), "\"\\\n\r\t");
    try std.testing.expectEqualStrings("\\\"\\\\\\n\\r\\t", fbs.getWritten());
}

test "writeJsonEscaped plain ascii" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeJsonEscaped(fbs.writer(), "abcABC123!@#$%^&*()");
    try std.testing.expectEqualStrings("abcABC123!@#$%^&*()", fbs.getWritten());
}
