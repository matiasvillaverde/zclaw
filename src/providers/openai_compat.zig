const std = @import("std");
const openai = @import("openai.zig");
const types = @import("types.zig");
const http_client = @import("../infra/http_client.zig");

// --- OpenAI-Compatible Provider ---
//
// Wraps the OpenAI request/response format for providers that implement
// the OpenAI Chat Completions API (Groq, Ollama, OpenRouter, Together,
// DeepSeek, Mistral, xAI, etc.)

pub const CompatConfig = struct {
    provider_name: []const u8,
    base_url: []const u8,
    completions_path: []const u8 = "/v1/chat/completions",
    api_key_header: []const u8 = "authorization",
    api_key_prefix: []const u8 = "Bearer ",
    supports_streaming: bool = true,
    supports_tools: bool = true,
};

// --- Preset Configurations ---

pub const GROQ = CompatConfig{
    .provider_name = "groq",
    .base_url = "https://api.groq.com/openai",
    .supports_streaming = true,
    .supports_tools = true,
};

pub const OLLAMA = CompatConfig{
    .provider_name = "ollama",
    .base_url = "http://localhost:11434",
    .completions_path = "/v1/chat/completions",
    .api_key_prefix = "",
    .supports_streaming = true,
    .supports_tools = false,
};

pub const OPENROUTER = CompatConfig{
    .provider_name = "openrouter",
    .base_url = "https://openrouter.ai/api",
    .supports_streaming = true,
    .supports_tools = true,
};

pub const TOGETHER = CompatConfig{
    .provider_name = "together",
    .base_url = "https://api.together.xyz",
    .supports_streaming = true,
    .supports_tools = true,
};

pub const DEEPSEEK = CompatConfig{
    .provider_name = "deepseek",
    .base_url = "https://api.deepseek.com",
    .supports_streaming = true,
    .supports_tools = true,
};

pub const MISTRAL = CompatConfig{
    .provider_name = "mistral",
    .base_url = "https://api.mistral.ai",
    .supports_streaming = true,
    .supports_tools = true,
};

pub const XAI = CompatConfig{
    .provider_name = "xai",
    .base_url = "https://api.x.ai",
    .supports_streaming = true,
    .supports_tools = true,
};

/// Lookup a preset by name.
pub fn getPreset(name: []const u8) ?CompatConfig {
    const map = std.StaticStringMap(CompatConfig).initComptime(.{
        .{ "groq", GROQ },
        .{ "ollama", OLLAMA },
        .{ "openrouter", OPENROUTER },
        .{ "together", TOGETHER },
        .{ "deepseek", DEEPSEEK },
        .{ "mistral", MISTRAL },
        .{ "xai", XAI },
    });
    return map.get(name);
}

// --- Client ---

pub const Client = struct {
    http: *http_client.HttpClient,
    api_key: []const u8,
    compat_config: CompatConfig,

    pub fn init(http: *http_client.HttpClient, api_key: []const u8, config: CompatConfig) Client {
        return .{
            .http = http,
            .api_key = api_key,
            .compat_config = config,
        };
    }

    /// Send a chat completion request via the OpenAI-compatible endpoint.
    pub fn sendMessage(
        self: *Client,
        config: types.RequestConfig,
        messages_json: []const u8,
        tools_json: ?[]const u8,
    ) !openai.ProviderResponse {
        // Strip tools if provider doesn't support them
        const effective_tools = if (self.compat_config.supports_tools) tools_json else null;

        // Force streaming off if not supported
        var effective_config = config;
        if (!self.compat_config.supports_streaming) {
            effective_config.stream = false;
        }

        var body_buf: [64 * 1024]u8 = undefined;
        const body = try openai.buildRequestBody(&body_buf, effective_config, messages_json, effective_tools);

        var url_buf: [512]u8 = undefined;
        const url = try http_client.buildUrl(&url_buf, self.compat_config.base_url, self.compat_config.completions_path);

        var auth_buf: [512]u8 = undefined;
        const auth_value = try buildAuthValue(&auth_buf, self.compat_config.api_key_prefix, self.api_key);

        const auth_headers = [_]http_client.Header{
            .{ .name = self.compat_config.api_key_header, .value = auth_value },
        };

        const resp = try self.http.postSse(url, &auth_headers, body);

        return .{
            .status = resp.status,
            .body = resp.body,
            .allocator = resp.allocator,
        };
    }

    /// Get the provider name.
    pub fn providerName(self: *const Client) []const u8 {
        return self.compat_config.provider_name;
    }
};

fn buildAuthValue(buf: []u8, prefix: []const u8, key: []const u8) ![]const u8 {
    if (prefix.len == 0) return key;
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    try writer.writeAll(prefix);
    try writer.writeAll(key);
    return fbs.getWritten();
}

// --- Tests ---

test "CompatConfig defaults" {
    const config = CompatConfig{
        .provider_name = "test",
        .base_url = "https://test.api.com",
    };
    try std.testing.expectEqualStrings("/v1/chat/completions", config.completions_path);
    try std.testing.expectEqualStrings("authorization", config.api_key_header);
    try std.testing.expectEqualStrings("Bearer ", config.api_key_prefix);
    try std.testing.expect(config.supports_streaming);
    try std.testing.expect(config.supports_tools);
}

test "GROQ preset" {
    try std.testing.expectEqualStrings("groq", GROQ.provider_name);
    try std.testing.expectEqualStrings("https://api.groq.com/openai", GROQ.base_url);
    try std.testing.expect(GROQ.supports_streaming);
    try std.testing.expect(GROQ.supports_tools);
}

test "OLLAMA preset" {
    try std.testing.expectEqualStrings("ollama", OLLAMA.provider_name);
    try std.testing.expectEqualStrings("http://localhost:11434", OLLAMA.base_url);
    try std.testing.expectEqualStrings("", OLLAMA.api_key_prefix);
    try std.testing.expect(!OLLAMA.supports_tools);
}

test "OPENROUTER preset" {
    try std.testing.expectEqualStrings("openrouter", OPENROUTER.provider_name);
    try std.testing.expectEqualStrings("https://openrouter.ai/api", OPENROUTER.base_url);
}

test "TOGETHER preset" {
    try std.testing.expectEqualStrings("together", TOGETHER.provider_name);
    try std.testing.expectEqualStrings("https://api.together.xyz", TOGETHER.base_url);
}

test "DEEPSEEK preset" {
    try std.testing.expectEqualStrings("deepseek", DEEPSEEK.provider_name);
    try std.testing.expectEqualStrings("https://api.deepseek.com", DEEPSEEK.base_url);
}

test "MISTRAL preset" {
    try std.testing.expectEqualStrings("mistral", MISTRAL.provider_name);
    try std.testing.expectEqualStrings("https://api.mistral.ai", MISTRAL.base_url);
}

test "XAI preset" {
    try std.testing.expectEqualStrings("xai", XAI.provider_name);
    try std.testing.expectEqualStrings("https://api.x.ai", XAI.base_url);
}

test "getPreset known providers" {
    try std.testing.expect(getPreset("groq") != null);
    try std.testing.expect(getPreset("ollama") != null);
    try std.testing.expect(getPreset("openrouter") != null);
    try std.testing.expect(getPreset("together") != null);
    try std.testing.expect(getPreset("deepseek") != null);
    try std.testing.expect(getPreset("mistral") != null);
    try std.testing.expect(getPreset("xai") != null);
    try std.testing.expect(getPreset("unknown") == null);
}

test "Client.init" {
    const responses = [_]http_client.MockTransport.MockResponse{};
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    const client = Client.init(&http, "gsk_test_key", GROQ);
    try std.testing.expectEqualStrings("groq", client.providerName());
    try std.testing.expectEqualStrings("gsk_test_key", client.api_key);
}

test "Client.sendMessage mock success" {
    const mock_sse =
        "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hi from Groq!\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";

    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = mock_sse },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = Client.init(&http, "gsk_test", GROQ);

    var resp = try client.sendMessage(.{
        .model = "llama-3.1-70b-versatile",
        .api_key = "gsk_test",
    }, "[{\"role\":\"user\",\"content\":\"Hello\"}]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
}

test "Client.sendMessage strips tools when unsupported" {
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "data: [DONE]\n\n" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = Client.init(&http, "key", OLLAMA);

    var resp = try client.sendMessage(.{
        .model = "llama3",
        .api_key = "key",
    }, "[]", "[{\"type\":\"function\"}]");
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
    // Body should not contain tools since Ollama doesn't support them
    if (mock.last_body) |body| {
        try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") == null);
    }
}

test "Client.sendMessage custom endpoint" {
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "data: [DONE]\n\n" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());

    const custom = CompatConfig{
        .provider_name = "custom",
        .base_url = "https://my-llm.internal",
        .completions_path = "/api/generate",
    };
    var client = Client.init(&http, "custom-key", custom);

    var resp = try client.sendMessage(.{
        .model = "my-model",
        .api_key = "custom-key",
    }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
}

test "Client.sendMessage rate limited" {
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 429, .body = "{\"error\":{\"message\":\"Rate limit\"}}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = Client.init(&http, "key", DEEPSEEK);

    var resp = try client.sendMessage(.{
        .model = "deepseek-chat",
        .api_key = "key",
    }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(!resp.isSuccess());
    try std.testing.expectEqual(@as(u16, 429), resp.status);
}

test "buildAuthValue with prefix" {
    var buf: [256]u8 = undefined;
    const val = try buildAuthValue(&buf, "Bearer ", "sk-abc");
    try std.testing.expectEqualStrings("Bearer sk-abc", val);
}

test "buildAuthValue without prefix" {
    var buf: [256]u8 = undefined;
    const val = try buildAuthValue(&buf, "", "raw-key");
    try std.testing.expectEqualStrings("raw-key", val);
}
