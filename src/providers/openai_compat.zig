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

// =====================================================
// Additional comprehensive tests
// =====================================================

// --- CompatConfig defaults and custom ---

test "CompatConfig custom completions path" {
    const config = CompatConfig{
        .provider_name = "custom",
        .base_url = "https://my-api.com",
        .completions_path = "/api/v2/chat",
    };
    try std.testing.expectEqualStrings("/api/v2/chat", config.completions_path);
}

test "CompatConfig custom api_key_header" {
    const config = CompatConfig{
        .provider_name = "custom",
        .base_url = "https://my-api.com",
        .api_key_header = "x-api-key",
        .api_key_prefix = "",
    };
    try std.testing.expectEqualStrings("x-api-key", config.api_key_header);
    try std.testing.expectEqualStrings("", config.api_key_prefix);
}

test "CompatConfig no streaming support" {
    const config = CompatConfig{
        .provider_name = "batch-only",
        .base_url = "https://batch.api.com",
        .supports_streaming = false,
    };
    try std.testing.expect(!config.supports_streaming);
    try std.testing.expect(config.supports_tools);
}

test "CompatConfig no tools support" {
    const config = CompatConfig{
        .provider_name = "no-tools",
        .base_url = "https://simple.api.com",
        .supports_tools = false,
    };
    try std.testing.expect(!config.supports_tools);
    try std.testing.expect(config.supports_streaming);
}

test "CompatConfig both streaming and tools disabled" {
    const config = CompatConfig{
        .provider_name = "minimal",
        .base_url = "https://minimal.api.com",
        .supports_streaming = false,
        .supports_tools = false,
    };
    try std.testing.expect(!config.supports_streaming);
    try std.testing.expect(!config.supports_tools);
}

// --- Preset URL and config validation ---

test "GROQ preset uses openai path" {
    try std.testing.expectEqualStrings("/v1/chat/completions", GROQ.completions_path);
    try std.testing.expectEqualStrings("authorization", GROQ.api_key_header);
    try std.testing.expectEqualStrings("Bearer ", GROQ.api_key_prefix);
}

test "OLLAMA preset uses empty auth prefix" {
    try std.testing.expectEqualStrings("Bearer ", OPENROUTER.api_key_prefix);
    try std.testing.expectEqualStrings("", OLLAMA.api_key_prefix);
}

test "DEEPSEEK preset supports tools" {
    try std.testing.expect(DEEPSEEK.supports_tools);
    try std.testing.expect(DEEPSEEK.supports_streaming);
}

test "MISTRAL preset supports tools" {
    try std.testing.expect(MISTRAL.supports_tools);
    try std.testing.expect(MISTRAL.supports_streaming);
}

test "XAI preset supports tools" {
    try std.testing.expect(XAI.supports_tools);
    try std.testing.expect(XAI.supports_streaming);
}

test "TOGETHER preset config" {
    try std.testing.expectEqualStrings("together", TOGETHER.provider_name);
    try std.testing.expect(TOGETHER.supports_streaming);
    try std.testing.expect(TOGETHER.supports_tools);
    try std.testing.expectEqualStrings("/v1/chat/completions", TOGETHER.completions_path);
}

// --- getPreset exhaustive ---

test "getPreset returns correct provider_name for each" {
    const groq = getPreset("groq").?;
    try std.testing.expectEqualStrings("groq", groq.provider_name);

    const ollama = getPreset("ollama").?;
    try std.testing.expectEqualStrings("ollama", ollama.provider_name);

    const openrouter = getPreset("openrouter").?;
    try std.testing.expectEqualStrings("openrouter", openrouter.provider_name);

    const together = getPreset("together").?;
    try std.testing.expectEqualStrings("together", together.provider_name);

    const deepseek = getPreset("deepseek").?;
    try std.testing.expectEqualStrings("deepseek", deepseek.provider_name);

    const mistral = getPreset("mistral").?;
    try std.testing.expectEqualStrings("mistral", mistral.provider_name);

    const xai = getPreset("xai").?;
    try std.testing.expectEqualStrings("xai", xai.provider_name);
}

test "getPreset returns null for case variations" {
    try std.testing.expect(getPreset("Groq") == null);
    try std.testing.expect(getPreset("GROQ") == null);
    try std.testing.expect(getPreset("Ollama") == null);
    try std.testing.expect(getPreset("OpenRouter") == null);
}

test "getPreset returns null for empty string" {
    try std.testing.expect(getPreset("") == null);
}

test "getPreset returns null for similar names" {
    try std.testing.expect(getPreset("openai") == null);
    try std.testing.expect(getPreset("anthropic") == null);
    try std.testing.expect(getPreset("claude") == null);
    try std.testing.expect(getPreset("gpt") == null);
}

// --- Client providerName ---

test "Client.providerName for different presets" {
    const responses = [_]http_client.MockTransport.MockResponse{};
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());

    const groq_client = Client.init(&http, "key", GROQ);
    try std.testing.expectEqualStrings("groq", groq_client.providerName());

    const ollama_client = Client.init(&http, "key", OLLAMA);
    try std.testing.expectEqualStrings("ollama", ollama_client.providerName());

    const deepseek_client = Client.init(&http, "key", DEEPSEEK);
    try std.testing.expectEqualStrings("deepseek", deepseek_client.providerName());
}

// --- Client.sendMessage disables streaming when unsupported ---

test "Client.sendMessage disables streaming for non-streaming provider" {
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());

    const no_stream_config = CompatConfig{
        .provider_name = "no-stream",
        .base_url = "https://batch.api.com",
        .supports_streaming = false,
    };
    var client = Client.init(&http, "key", no_stream_config);

    var resp = try client.sendMessage(.{
        .model = "model",
        .stream = true, // This should be overridden
        .api_key = "key",
    }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
    // The body sent should not contain "stream":true since provider doesn't support it
    if (mock.last_body) |body| {
        try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") == null);
    }
}

// --- Client.sendMessage with various providers ---

test "Client.sendMessage openrouter" {
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "data: [DONE]\n\n" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = Client.init(&http, "or-key", OPENROUTER);

    var resp = try client.sendMessage(.{
        .model = "meta-llama/llama-3.1-70b-instruct",
        .api_key = "or-key",
    }, "[{\"role\":\"user\",\"content\":\"hi\"}]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
}

test "Client.sendMessage together" {
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "data: [DONE]\n\n" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = Client.init(&http, "together-key", TOGETHER);

    var resp = try client.sendMessage(.{
        .model = "mistralai/Mixtral-8x7B-Instruct-v0.1",
        .api_key = "together-key",
    }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
}

test "Client.sendMessage mistral" {
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "data: [DONE]\n\n" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = Client.init(&http, "mistral-key", MISTRAL);

    var resp = try client.sendMessage(.{
        .model = "mistral-large-latest",
        .api_key = "mistral-key",
    }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
}

test "Client.sendMessage xai" {
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "data: [DONE]\n\n" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = Client.init(&http, "xai-key", XAI);

    var resp = try client.sendMessage(.{
        .model = "grok-2",
        .api_key = "xai-key",
    }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
}

// --- Client.sendMessage with tools that are supported ---

test "Client.sendMessage passes tools when supported" {
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "data: [DONE]\n\n" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = Client.init(&http, "key", GROQ);

    var resp = try client.sendMessage(.{
        .model = "llama-3.1-70b",
        .api_key = "key",
    }, "[]", "[{\"type\":\"function\"}]");
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
    if (mock.last_body) |body| {
        try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") != null);
    }
}

// --- buildAuthValue edge cases ---

test "buildAuthValue with custom prefix" {
    var buf: [256]u8 = undefined;
    const val = try buildAuthValue(&buf, "Token ", "my-secret-key");
    try std.testing.expectEqualStrings("Token my-secret-key", val);
}

test "buildAuthValue with long key" {
    var buf: [512]u8 = undefined;
    const val = try buildAuthValue(&buf, "Bearer ", "sk-proj-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ");
    try std.testing.expect(std.mem.startsWith(u8, val, "Bearer sk-proj-"));
}

test "buildAuthValue empty key with prefix" {
    var buf: [256]u8 = undefined;
    const val = try buildAuthValue(&buf, "Bearer ", "");
    try std.testing.expectEqualStrings("Bearer ", val);
}

test "buildAuthValue empty key without prefix" {
    var buf: [256]u8 = undefined;
    const val = try buildAuthValue(&buf, "", "");
    try std.testing.expectEqualStrings("", val);
}

// --- Client.sendMessage error responses ---

test "Client.sendMessage 500 server error" {
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 500, .body = "{\"error\":\"internal server error\"}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = Client.init(&http, "key", GROQ);

    var resp = try client.sendMessage(.{
        .model = "llama-3",
        .api_key = "key",
    }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(!resp.isSuccess());
    try std.testing.expectEqual(@as(u16, 500), resp.status);
}

test "Client.sendMessage 401 unauthorized" {
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 401, .body = "{\"error\":\"invalid api key\"}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = Client.init(&http, "bad-key", DEEPSEEK);

    var resp = try client.sendMessage(.{
        .model = "deepseek-chat",
        .api_key = "bad-key",
    }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(!resp.isSuccess());
    try std.testing.expectEqual(@as(u16, 401), resp.status);
}

// --- Custom endpoint with non-standard path ---

test "Client.sendMessage with non-standard completions path" {
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "data: [DONE]\n\n" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());

    const custom = CompatConfig{
        .provider_name = "vllm",
        .base_url = "http://localhost:8000",
        .completions_path = "/v1/completions",
        .api_key_prefix = "",
    };
    var client = Client.init(&http, "no-auth", custom);

    var resp = try client.sendMessage(.{
        .model = "meta-llama/Meta-Llama-3-8B",
        .api_key = "no-auth",
    }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
}

test "Client.sendMessage with api_key_header x-api-key" {
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "data: [DONE]\n\n" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());

    const custom = CompatConfig{
        .provider_name = "fireworks",
        .base_url = "https://api.fireworks.ai/inference",
        .api_key_header = "x-api-key",
        .api_key_prefix = "",
    };
    var client = Client.init(&http, "fw-key", custom);

    var resp = try client.sendMessage(.{
        .model = "accounts/fireworks/models/llama-v3p1-70b-instruct",
        .api_key = "fw-key",
    }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
}

// --- Preset base_url values ---

test "All presets have non-empty base_url" {
    const presets = [_]CompatConfig{ GROQ, OLLAMA, OPENROUTER, TOGETHER, DEEPSEEK, MISTRAL, XAI };
    for (presets) |p| {
        try std.testing.expect(p.base_url.len > 0);
    }
}

test "All presets have non-empty provider_name" {
    const presets = [_]CompatConfig{ GROQ, OLLAMA, OPENROUTER, TOGETHER, DEEPSEEK, MISTRAL, XAI };
    for (presets) |p| {
        try std.testing.expect(p.provider_name.len > 0);
    }
}
