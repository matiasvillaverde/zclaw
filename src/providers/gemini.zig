const std = @import("std");
const types = @import("types.zig");
const sse = @import("sse.zig");
const http_client = @import("../infra/http_client.zig");

// --- Google Gemini API Constants ---

pub const DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com";
pub const API_VERSION = "v1beta";

// --- URL Building ---

/// Build Gemini API URL: {base}/v1beta/models/{model}:generateContent?key={api_key}
pub fn buildApiUrl(buf: []u8, base_url: []const u8, model: []const u8, api_key: []const u8, stream: bool) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    try writer.writeAll(base_url);
    try writer.writeByte('/');
    try writer.writeAll(API_VERSION);
    try writer.writeAll("/models/");
    try writer.writeAll(model);
    if (stream) {
        try writer.writeAll(":streamGenerateContent?alt=sse&key=");
    } else {
        try writer.writeAll(":generateContent?key=");
    }
    try writer.writeAll(api_key);
    return fbs.getWritten();
}

// --- Request Building ---

/// Build a Gemini generateContent request body.
/// Gemini uses { "contents": [{ "role": "user", "parts": [{ "text": "..." }] }] }
pub fn buildRequestBody(
    buf: []u8,
    config: types.RequestConfig,
    messages_json: []const u8,
) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    try writer.writeAll("{\"contents\":");
    try writer.writeAll(messages_json);

    // Generation config
    try writer.writeAll(",\"generationConfig\":{");

    var has_field = false;

    if (config.max_tokens > 0) {
        try writer.writeAll("\"maxOutputTokens\":");
        try std.fmt.format(writer, "{d}", .{config.max_tokens});
        has_field = true;
    }

    if (config.temperature) |temp| {
        if (has_field) try writer.writeByte(',');
        try writer.writeAll("\"temperature\":");
        try std.fmt.format(writer, "{d:.1}", .{temp});
    }

    try writer.writeByte('}');

    // System instruction
    if (config.system_prompt) |sys| {
        try writer.writeAll(",\"systemInstruction\":{\"parts\":[{\"text\":\"");
        try writeJsonEscaped(writer, sys);
        try writer.writeAll("\"}]}");
    }

    try writer.writeByte('}');
    return fbs.getWritten();
}

/// Build a Gemini-format message JSON array from a simple user message.
/// Returns: [{"role":"user","parts":[{"text":"..."}]}]
pub fn buildUserMessage(buf: []u8, text: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    try writer.writeAll("[{\"role\":\"user\",\"parts\":[{\"text\":\"");
    try writeJsonEscaped(writer, text);
    try writer.writeAll("\"}]}]");
    return fbs.getWritten();
}

/// Build a Gemini-format model (assistant) message.
pub fn buildModelMessage(buf: []u8, text: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    try writer.writeAll("{\"role\":\"model\",\"parts\":[{\"text\":\"");
    try writeJsonEscaped(writer, text);
    try writer.writeAll("\"}]}");
    return fbs.getWritten();
}

// --- Response Parsing ---

/// Extract text from a Gemini generateContent response.
/// Looks for "text":"..." in candidates[0].content.parts[0].
pub fn extractResponseText(json: []const u8) ?[]const u8 {
    // Look for "candidates" then find "text" field
    if (std.mem.indexOf(u8, json, "\"candidates\"")) |_| {
        return extractJsonString(json, "\"text\":\"");
    }
    return null;
}

/// Extract usage info from Gemini response.
pub fn extractUsage(json: []const u8) types.Usage {
    var usage = types.Usage{};
    if (extractJsonNumber(json, "\"promptTokenCount\":")) |n| {
        usage.input_tokens = @intCast(n);
    }
    if (extractJsonNumber(json, "\"candidatesTokenCount\":")) |n| {
        usage.output_tokens = @intCast(n);
    }
    return usage;
}

/// Extract finish reason from Gemini response.
pub fn extractFinishReason(json: []const u8) ?types.StopReason {
    if (extractJsonString(json, "\"finishReason\":\"")) |reason| {
        if (std.mem.eql(u8, reason, "STOP")) return .end_turn;
        if (std.mem.eql(u8, reason, "MAX_TOKENS")) return .max_tokens;
        if (std.mem.eql(u8, reason, "SAFETY")) return .content_filter;
    }
    return null;
}

/// Parse a Gemini SSE event into a StreamEvent.
pub fn parseStreamEvent(raw: *const sse.SseEvent) ?types.StreamEvent {
    // Gemini SSE data contains JSON chunks
    const data = raw.data;
    if (data.len == 0) return null;

    // Check for text content
    if (extractResponseText(data)) |text| {
        return .{
            .event_type = .text_delta,
            .text = text,
            .usage = extractUsage(data),
        };
    }

    // Check for finish reason
    if (extractFinishReason(data)) |reason| {
        return .{
            .event_type = .stop,
            .stop_reason = reason,
            .usage = extractUsage(data),
        };
    }

    return null;
}

// --- Client ---

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
};

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

    /// Send a chat message through the Gemini API.
    pub fn sendMessage(
        self: *Client,
        config: types.RequestConfig,
        messages_json: []const u8,
        _: ?[]const u8, // tools_json — not yet wired for Gemini
    ) !ProviderResponse {
        var body_buf: [64 * 1024]u8 = undefined;
        const body = try buildRequestBody(&body_buf, config, messages_json);

        var url_buf: [1024]u8 = undefined;
        const url = try buildApiUrl(&url_buf, self.base_url, config.model, self.api_key, config.stream);

        const headers = [_]http_client.Header{
            .{ .name = "content-type", .value = "application/json" },
        };

        if (config.stream) {
            const resp = try self.http.postSse(url, &headers, body);
            return .{
                .status = resp.status,
                .body = resp.body,
                .allocator = resp.allocator,
            };
        } else {
            const resp = try self.http.post(url, &headers, body);
            return .{
                .status = resp.status,
                .body = resp.body,
                .allocator = resp.allocator,
            };
        }
    }

    pub fn providerName(_: *const Client) []const u8 {
        return "gemini";
    }
};

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

test "buildApiUrl non-streaming" {
    var buf: [1024]u8 = undefined;
    const url = try buildApiUrl(&buf, DEFAULT_BASE_URL, "gemini-2.0-flash", "AIzaSyTest", false);
    try std.testing.expectEqualStrings(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=AIzaSyTest",
        url,
    );
}

test "buildApiUrl streaming" {
    var buf: [1024]u8 = undefined;
    const url = try buildApiUrl(&buf, DEFAULT_BASE_URL, "gemini-2.0-flash", "key123", true);
    try std.testing.expect(std.mem.indexOf(u8, url, ":streamGenerateContent?alt=sse&key=key123") != null);
}

test "buildApiUrl custom base URL" {
    var buf: [1024]u8 = undefined;
    const url = try buildApiUrl(&buf, "https://custom.googleapis.com", "gemini-pro", "key", false);
    try std.testing.expect(std.mem.startsWith(u8, url, "https://custom.googleapis.com/"));
}

test "buildApiUrl buffer too small" {
    var buf: [10]u8 = undefined;
    const result = buildApiUrl(&buf, DEFAULT_BASE_URL, "gemini-2.0-flash", "key", false);
    try std.testing.expectError(error.NoSpaceLeft, result);
}

test "buildRequestBody basic" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "gemini-2.0-flash",
        .max_tokens = 1024,
        .api_key = "test",
    }, "[{\"role\":\"user\",\"parts\":[{\"text\":\"Hello\"}]}]");

    try std.testing.expect(std.mem.indexOf(u8, body, "\"contents\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"maxOutputTokens\":1024") != null);
}

test "buildRequestBody with system prompt" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "gemini-2.0-flash",
        .system_prompt = "You are helpful",
        .api_key = "test",
    }, "[]");

    try std.testing.expect(std.mem.indexOf(u8, body, "\"systemInstruction\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "You are helpful") != null);
}

test "buildRequestBody with temperature" {
    var buf: [4096]u8 = undefined;
    const body = try buildRequestBody(&buf, .{
        .model = "gemini-2.0-flash",
        .temperature = 0.7,
        .api_key = "test",
    }, "[]");

    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":") != null);
}

test "buildUserMessage" {
    var buf: [1024]u8 = undefined;
    const msg = try buildUserMessage(&buf, "Hello Gemini");
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"text\":\"Hello Gemini\"") != null);
}

test "buildUserMessage with special characters" {
    var buf: [1024]u8 = undefined;
    const msg = try buildUserMessage(&buf, "He said \"hi\"\nNew line");
    try std.testing.expect(std.mem.indexOf(u8, msg, "\\\"hi\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\\n") != null);
}

test "buildModelMessage" {
    var buf: [1024]u8 = undefined;
    const msg = try buildModelMessage(&buf, "I can help!");
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"role\":\"model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"text\":\"I can help!\"") != null);
}

test "extractResponseText" {
    const json = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hello from Gemini!\"}],\"role\":\"model\"}}]}";
    const text = extractResponseText(json);
    try std.testing.expectEqualStrings("Hello from Gemini!", text.?);
}

test "extractResponseText no candidates" {
    const json = "{\"error\":{\"message\":\"bad request\"}}";
    try std.testing.expect(extractResponseText(json) == null);
}

test "extractResponseText empty text" {
    const json = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"\"}],\"role\":\"model\"}}]}";
    const text = extractResponseText(json);
    try std.testing.expectEqualStrings("", text.?);
}

test "extractUsage" {
    const json = "{\"usageMetadata\":{\"promptTokenCount\":100,\"candidatesTokenCount\":50,\"totalTokenCount\":150}}";
    const usage = extractUsage(json);
    try std.testing.expectEqual(@as(u64, 100), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 50), usage.output_tokens);
}

test "extractUsage missing" {
    const json = "{\"candidates\":[]}";
    const usage = extractUsage(json);
    try std.testing.expectEqual(@as(u64, 0), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 0), usage.output_tokens);
}

test "extractFinishReason STOP" {
    const json = "{\"candidates\":[{\"finishReason\":\"STOP\"}]}";
    try std.testing.expectEqual(types.StopReason.end_turn, extractFinishReason(json).?);
}

test "extractFinishReason MAX_TOKENS" {
    const json = "{\"candidates\":[{\"finishReason\":\"MAX_TOKENS\"}]}";
    try std.testing.expectEqual(types.StopReason.max_tokens, extractFinishReason(json).?);
}

test "extractFinishReason SAFETY" {
    const json = "{\"candidates\":[{\"finishReason\":\"SAFETY\"}]}";
    try std.testing.expectEqual(types.StopReason.content_filter, extractFinishReason(json).?);
}

test "extractFinishReason missing" {
    const json = "{\"candidates\":[{\"content\":{}}]}";
    try std.testing.expect(extractFinishReason(json) == null);
}

test "parseStreamEvent text delta" {
    const raw = sse.SseEvent{
        .event_type = null,
        .data = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hi!\"}],\"role\":\"model\"}}]}",
    };
    const evt = parseStreamEvent(&raw).?;
    try std.testing.expectEqual(types.StreamEventType.text_delta, evt.event_type);
    try std.testing.expectEqualStrings("Hi!", evt.text.?);
}

test "parseStreamEvent stop" {
    const raw = sse.SseEvent{
        .event_type = null,
        .data = "{\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"parts\":[]}}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":5}}",
    };
    const evt = parseStreamEvent(&raw);
    // This will match text first since parts is empty, should still parse
    try std.testing.expect(evt != null);
}

test "parseStreamEvent empty data" {
    const raw = sse.SseEvent{
        .event_type = null,
        .data = "",
    };
    try std.testing.expect(parseStreamEvent(&raw) == null);
}

test "Client.init" {
    const responses = [_]http_client.MockTransport.MockResponse{};
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    const client = Client.init(&http, "AIzaSyTest", null);
    try std.testing.expectEqualStrings("gemini", client.providerName());
    try std.testing.expectEqualStrings(DEFAULT_BASE_URL, client.base_url);
}

test "Client.init custom base URL" {
    const responses = [_]http_client.MockTransport.MockResponse{};
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    const client = Client.init(&http, "key", "https://custom.google.com");
    try std.testing.expectEqualStrings("https://custom.google.com", client.base_url);
}

test "Client.sendMessage mock success" {
    const mock_response = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hello!\"}],\"role\":\"model\"},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":5,\"candidatesTokenCount\":3}}";
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = mock_response },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = Client.init(&http, "AIzaSyTest", null);

    var resp = try client.sendMessage(.{
        .model = "gemini-2.0-flash",
        .api_key = "AIzaSyTest",
        .stream = false,
    }, "[{\"role\":\"user\",\"parts\":[{\"text\":\"Hi\"}]}]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
}

test "Client.sendMessage error response" {
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 400, .body = "{\"error\":{\"message\":\"bad request\"}}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = Client.init(&http, "bad-key", null);

    var resp = try client.sendMessage(.{
        .model = "gemini-2.0-flash",
        .api_key = "bad-key",
        .stream = false,
    }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(!resp.isSuccess());
    try std.testing.expectEqual(@as(u16, 400), resp.status);
}

test "DEFAULT_BASE_URL is correct" {
    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com", DEFAULT_BASE_URL);
}

test "API_VERSION is v1beta" {
    try std.testing.expectEqualStrings("v1beta", API_VERSION);
}
