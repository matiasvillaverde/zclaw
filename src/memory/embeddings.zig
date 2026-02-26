const std = @import("std");

// --- Embedding Provider ---

pub const EmbeddingProvider = enum {
    openai,
    local,

    pub fn label(self: EmbeddingProvider) []const u8 {
        return switch (self) {
            .openai => "openai",
            .local => "local",
        };
    }
};

// --- Embedding Config ---

pub const EmbeddingConfig = struct {
    provider: EmbeddingProvider = .openai,
    model: []const u8 = "text-embedding-3-small",
    dimensions: u32 = 1536,
    api_key: []const u8 = "",
    base_url: ?[]const u8 = null,
    batch_size: u32 = 100,
};

// --- Embedding Result ---

pub const EmbeddingResult = struct {
    vector: []f64,
    model: []const u8,
    tokens_used: u32,
};

// --- OpenAI Embeddings Request Builder ---

pub fn buildOpenAIEmbeddingRequest(buf: []u8, text: []const u8, config: EmbeddingConfig) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    try writer.writeAll("{\"model\":\"");
    try writer.writeAll(config.model);
    try writer.writeAll("\",\"input\":\"");
    try writeJsonEscaped(writer, text);
    try writer.writeAll("\"");

    if (config.dimensions > 0) {
        try std.fmt.format(writer, ",\"dimensions\":{d}", .{config.dimensions});
    }

    try writer.writeAll("}");
    return fbs.getWritten();
}

/// Build batch embedding request for multiple texts
pub fn buildBatchEmbeddingRequest(buf: []u8, texts: []const []const u8, config: EmbeddingConfig) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    try writer.writeAll("{\"model\":\"");
    try writer.writeAll(config.model);
    try writer.writeAll("\",\"input\":[");

    for (texts, 0..) |text, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeByte('"');
        try writeJsonEscaped(writer, text);
        try writer.writeByte('"');
    }

    try writer.writeAll("]");

    if (config.dimensions > 0) {
        try std.fmt.format(writer, ",\"dimensions\":{d}", .{config.dimensions});
    }

    try writer.writeAll("}");
    return fbs.getWritten();
}

/// Parse embedding vector from OpenAI response JSON.
/// Extracts the first embedding array from the response.
pub fn parseEmbeddingResponse(allocator: std.mem.Allocator, json: []const u8) ![]f64 {
    // Find "embedding":[...] in the response
    const prefix = "\"embedding\":[";
    const start_idx = std.mem.indexOf(u8, json, prefix) orelse return error.InvalidResponse;
    const array_start = start_idx + prefix.len;

    // Find closing bracket
    const array_end = std.mem.indexOfPos(u8, json, array_start, "]") orelse return error.InvalidResponse;
    const array_str = json[array_start..array_end];

    // Parse comma-separated floats
    var values = std.ArrayListUnmanaged(f64){};

    var iter = std.mem.splitScalar(u8, array_str, ',');
    while (iter.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t\n\r");
        if (trimmed.len == 0) continue;
        const val = std.fmt.parseFloat(f64, trimmed) catch continue;
        try values.append(allocator, val);
    }

    if (values.items.len == 0) {
        values.deinit(allocator);
        return error.InvalidResponse;
    }

    return values.toOwnedSlice(allocator);
}

/// Normalize a vector to unit length (L2 normalization).
pub fn normalizeVector(vec: []f64) void {
    var sum_sq: f64 = 0.0;
    for (vec) |v| {
        sum_sq += v * v;
    }
    const norm = @sqrt(sum_sq);
    if (norm == 0.0) return;
    for (vec) |*v| {
        v.* /= norm;
    }
}

// --- Embedding Client ---

pub const EmbeddingClient = struct {
    http: *http_client.HttpClient,
    config: EmbeddingConfig,

    pub fn init(http: *http_client.HttpClient, config: EmbeddingConfig) EmbeddingClient {
        return .{
            .http = http,
            .config = config,
        };
    }

    /// Embed a single text string.
    pub fn embed(self: *EmbeddingClient, allocator: std.mem.Allocator, text: []const u8) ![]f64 {
        var body_buf: [16 * 1024]u8 = undefined;
        const body = try buildOpenAIEmbeddingRequest(&body_buf, text, self.config);

        const base = self.config.base_url orelse "https://api.openai.com";
        var url_buf: [512]u8 = undefined;
        const url = try http_client.buildUrl(&url_buf, base, "/v1/embeddings");

        var bearer_buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&bearer_buf);
        try fbs.writer().writeAll("Bearer ");
        try fbs.writer().writeAll(self.config.api_key);
        const bearer = fbs.getWritten();

        const auth_headers = [_]http_client.Header{
            .{ .name = "authorization", .value = bearer },
        };

        var resp = self.http.postJson(url, &auth_headers, body) catch return error.EmbeddingFailed;
        defer resp.deinit();

        if (resp.status < 200 or resp.status >= 300) {
            return error.EmbeddingFailed;
        }

        return parseEmbeddingResponse(allocator, resp.body);
    }
};

const http_client = @import("../infra/http_client.zig");

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

// --- Tests ---

test "EmbeddingProvider labels" {
    try std.testing.expectEqualStrings("openai", EmbeddingProvider.openai.label());
    try std.testing.expectEqualStrings("local", EmbeddingProvider.local.label());
}

test "EmbeddingConfig defaults" {
    const config = EmbeddingConfig{};
    try std.testing.expectEqual(EmbeddingProvider.openai, config.provider);
    try std.testing.expectEqualStrings("text-embedding-3-small", config.model);
    try std.testing.expectEqual(@as(u32, 1536), config.dimensions);
}

test "buildOpenAIEmbeddingRequest" {
    var buf: [4096]u8 = undefined;
    const json = try buildOpenAIEmbeddingRequest(&buf, "Hello world", .{});

    try std.testing.expect(std.mem.indexOf(u8, json, "\"model\":\"text-embedding-3-small\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"input\":\"Hello world\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dimensions\":1536") != null);
}

test "buildOpenAIEmbeddingRequest with escaping" {
    var buf: [4096]u8 = undefined;
    const json = try buildOpenAIEmbeddingRequest(&buf, "Hello \"world\"\nnewline", .{});

    try std.testing.expect(std.mem.indexOf(u8, json, "Hello \\\"world\\\"\\nnewline") != null);
}

test "buildBatchEmbeddingRequest" {
    var buf: [4096]u8 = undefined;
    const texts = [_][]const u8{ "first", "second", "third" };
    const json = try buildBatchEmbeddingRequest(&buf, &texts, .{});

    try std.testing.expect(std.mem.indexOf(u8, json, "\"input\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"first\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"second\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"third\"") != null);
}

test "parseEmbeddingResponse" {
    const allocator = std.testing.allocator;
    const json = "{\"data\":[{\"embedding\":[0.1,0.2,0.3],\"index\":0}]}";
    const vec = try parseEmbeddingResponse(allocator, json);
    defer allocator.free(vec);

    try std.testing.expectEqual(@as(usize, 3), vec.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), vec[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), vec[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), vec[2], 0.001);
}

test "parseEmbeddingResponse invalid" {
    const allocator = std.testing.allocator;
    const result = parseEmbeddingResponse(allocator, "{}");
    try std.testing.expectError(error.InvalidResponse, result);
}

test "normalizeVector" {
    var vec = [_]f64{ 3.0, 4.0 };
    normalizeVector(&vec);

    // 3/5 = 0.6, 4/5 = 0.8
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), vec[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), vec[1], 0.001);

    // Verify unit length
    var sum_sq: f64 = 0.0;
    for (vec) |v| sum_sq += v * v;
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), sum_sq, 0.001);
}

test "normalizeVector zero" {
    var vec = [_]f64{ 0.0, 0.0 };
    normalizeVector(&vec);
    // Should not divide by zero
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), vec[0], 0.001);
}

test "EmbeddingClient.embed mock success" {
    const mock_response = "{\"data\":[{\"embedding\":[0.1,0.2,0.3],\"index\":0}],\"usage\":{\"total_tokens\":5}}";
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = mock_response },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = EmbeddingClient.init(&http, .{ .api_key = "sk-test" });

    const vec = try client.embed(std.testing.allocator, "Hello world");
    defer std.testing.allocator.free(vec);

    try std.testing.expectEqual(@as(usize, 3), vec.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), vec[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), vec[1], 0.001);

    // Verify URL
    try std.testing.expect(std.mem.endsWith(u8, mock.last_url.?, "/v1/embeddings"));
}

test "EmbeddingClient.embed mock error" {
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 401, .body = "{\"error\":\"invalid key\"}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = EmbeddingClient.init(&http, .{ .api_key = "bad" });

    const result = client.embed(std.testing.allocator, "test");
    try std.testing.expectError(error.EmbeddingFailed, result);
}

test "EmbeddingClient.embed custom base_url" {
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "{\"data\":[{\"embedding\":[1.0],\"index\":0}]}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var client = EmbeddingClient.init(&http, .{
        .api_key = "key",
        .base_url = "https://custom.ai",
    });

    const vec = try client.embed(std.testing.allocator, "test");
    defer std.testing.allocator.free(vec);

    try std.testing.expect(std.mem.startsWith(u8, mock.last_url.?, "https://custom.ai"));
}
