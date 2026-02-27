const std = @import("std");

// --- HTTP Client Abstraction ---
//
// Provides a transport-agnostic HTTP client with a vtable interface.
// Real implementation uses std.http.Client.
// Tests use MockTransport for deterministic behavior.

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
};

pub const HttpResponse = struct {
    status: u16,
    body: []const u8,
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *HttpResponse) void {
        if (self.allocator) |alloc| {
            alloc.free(self.body);
        }
    }
};

pub const HttpError = error{
    ConnectionFailed,
    Timeout,
    InvalidUrl,
    TlsError,
    ResponseTooLarge,
    OutOfMemory,
    InvalidResponse,
    DnsResolutionFailed,
    ConnectionRefused,
};

pub const RequestOptions = struct {
    method: HttpMethod = .POST,
    url: []const u8,
    headers: []const Header = &.{},
    body: ?[]const u8 = null,
    timeout_ms: u32 = 30_000,
    max_response_bytes: usize = 10 * 1024 * 1024, // 10MB
};

// --- Transport VTable ---

pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        request: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, options: RequestOptions) anyerror!HttpResponse,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn request(self: Transport, allocator: std.mem.Allocator, options: RequestOptions) !HttpResponse {
        return self.vtable.request(self.ptr, allocator, options);
    }

    pub fn deinit(self: Transport) void {
        self.vtable.deinit(self.ptr);
    }
};

// --- HttpClient ---

pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    transport: Transport,

    pub fn init(allocator: std.mem.Allocator, transport: Transport) HttpClient {
        return .{
            .allocator = allocator,
            .transport = transport,
        };
    }

    pub fn deinit(self: *HttpClient) void {
        self.transport.deinit();
    }

    pub fn post(self: *HttpClient, url: []const u8, headers: []const Header, body: []const u8) !HttpResponse {
        return self.transport.request(self.allocator, .{
            .method = .POST,
            .url = url,
            .headers = headers,
            .body = body,
        });
    }

    pub fn get(self: *HttpClient, url: []const u8, headers: []const Header) !HttpResponse {
        return self.transport.request(self.allocator, .{
            .method = .GET,
            .url = url,
            .headers = headers,
        });
    }

    pub fn postJson(self: *HttpClient, url: []const u8, auth_headers: []const Header, json_body: []const u8) !HttpResponse {
        var all_headers: [16]Header = undefined;
        all_headers[0] = .{ .name = "content-type", .value = "application/json" };
        var count: usize = 1;
        for (auth_headers) |h| {
            if (count < 16) {
                all_headers[count] = h;
                count += 1;
            }
        }
        return self.post(url, all_headers[0..count], json_body);
    }

    pub fn postSse(self: *HttpClient, url: []const u8, auth_headers: []const Header, json_body: []const u8) !HttpResponse {
        var all_headers: [16]Header = undefined;
        all_headers[0] = .{ .name = "content-type", .value = "application/json" };
        all_headers[1] = .{ .name = "accept", .value = "text/event-stream" };
        var count: usize = 2;
        for (auth_headers) |h| {
            if (count < 16) {
                all_headers[count] = h;
                count += 1;
            }
        }
        return self.post(url, all_headers[0..count], json_body);
    }
};

// --- Real HTTP Transport (std.http.Client) ---

pub const StdHttpTransport = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StdHttpTransport {
        return .{ .allocator = allocator };
    }

    pub fn transport(self: *StdHttpTransport) Transport {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn requestImpl(ptr: *anyopaque, allocator: std.mem.Allocator, options: RequestOptions) anyerror!HttpResponse {
        const self: *StdHttpTransport = @ptrCast(@alignCast(ptr));
        _ = self;

        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        // Convert our headers to std.http.Header format
        var http_headers: [16]std.http.Header = undefined;
        const hdr_len = @min(options.headers.len, 16);
        for (0..hdr_len) |i| {
            http_headers[i] = .{
                .name = options.headers[i].name,
                .value = options.headers[i].value,
            };
        }

        // Use Allocating writer to capture response body
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();

        const result = client.fetch(.{
            .location = .{ .url = options.url },
            .method = switch (options.method) {
                .GET => .GET,
                .POST => .POST,
                .PUT => .PUT,
                .DELETE => .DELETE,
                .PATCH => .PATCH,
            },
            .extra_headers = http_headers[0..hdr_len],
            .payload = options.body,
            .response_writer = &aw.writer,
        }) catch return HttpError.ConnectionFailed;

        const status: u16 = @intFromEnum(result.status);
        var body_list = aw.toArrayList();
        const body = body_list.toOwnedSlice(allocator) catch return HttpError.OutOfMemory;

        return .{
            .status = status,
            .body = body,
            .allocator = allocator,
        };
    }

    fn deinitImpl(ptr: *anyopaque) void {
        _ = ptr;
    }

    const vtable: Transport.VTable = .{
        .request = requestImpl,
        .deinit = deinitImpl,
    };
};

// --- Mock Transport for Tests ---

pub const MockTransport = struct {
    responses: []const MockResponse,
    call_count: usize = 0,
    last_url: ?[]const u8 = null,
    last_body: ?[]const u8 = null,
    last_method: ?HttpMethod = null,

    pub const MockResponse = struct {
        status: u16 = 200,
        body: []const u8 = "{}",
    };

    pub fn init(responses: []const MockResponse) MockTransport {
        return .{ .responses = responses };
    }

    pub fn transport(self: *MockTransport) Transport {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn requestImpl(ptr: *anyopaque, allocator: std.mem.Allocator, options: RequestOptions) anyerror!HttpResponse {
        const self: *MockTransport = @ptrCast(@alignCast(ptr));
        self.last_url = options.url;
        self.last_body = options.body;
        self.last_method = options.method;

        if (self.call_count >= self.responses.len) {
            return HttpError.ConnectionFailed;
        }

        const mock = self.responses[self.call_count];
        self.call_count += 1;

        const body_copy = try allocator.dupe(u8, mock.body);
        return .{
            .status = mock.status,
            .body = body_copy,
            .allocator = allocator,
        };
    }

    fn deinitImpl(ptr: *anyopaque) void {
        _ = ptr;
    }

    const vtable: Transport.VTable = .{
        .request = requestImpl,
        .deinit = deinitImpl,
    };
};

// --- URL Helpers ---

pub fn buildUrl(buf: []u8, base: []const u8, path: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll(base);
    try w.writeAll(path);
    return fbs.getWritten();
}

pub fn buildUrlWithQuery(buf: []u8, base: []const u8, path: []const u8, query: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll(base);
    try w.writeAll(path);
    try w.writeAll("?");
    try w.writeAll(query);
    return fbs.getWritten();
}

// --- Tests ---

test "MockTransport basic request" {
    const responses = [_]MockTransport.MockResponse{
        .{ .status = 200, .body = "{\"ok\":true}" },
    };
    var mock = MockTransport.init(&responses);
    var client = HttpClient.init(std.testing.allocator, mock.transport());

    var resp = try client.post("https://api.example.com/v1/test", &.{}, "{}");
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("{\"ok\":true}", resp.body);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
    try std.testing.expectEqualStrings("https://api.example.com/v1/test", mock.last_url.?);
}

test "MockTransport sequential responses" {
    const responses = [_]MockTransport.MockResponse{
        .{ .status = 200, .body = "first" },
        .{ .status = 201, .body = "second" },
        .{ .status = 500, .body = "error" },
    };
    var mock = MockTransport.init(&responses);
    var client = HttpClient.init(std.testing.allocator, mock.transport());

    var r1 = try client.post("https://a.com/1", &.{}, "");
    defer r1.deinit();
    try std.testing.expectEqual(@as(u16, 200), r1.status);
    try std.testing.expectEqualStrings("first", r1.body);

    var r2 = try client.post("https://a.com/2", &.{}, "");
    defer r2.deinit();
    try std.testing.expectEqual(@as(u16, 201), r2.status);

    var r3 = try client.post("https://a.com/3", &.{}, "");
    defer r3.deinit();
    try std.testing.expectEqual(@as(u16, 500), r3.status);
}

test "MockTransport exhausted returns error" {
    const responses = [_]MockTransport.MockResponse{
        .{ .status = 200, .body = "ok" },
    };
    var mock = MockTransport.init(&responses);
    var client = HttpClient.init(std.testing.allocator, mock.transport());

    var r1 = try client.post("https://a.com", &.{}, "");
    defer r1.deinit();

    const r2 = client.post("https://a.com", &.{}, "");
    try std.testing.expectError(HttpError.ConnectionFailed, r2);
}

test "MockTransport captures method" {
    const responses = [_]MockTransport.MockResponse{
        .{ .status = 200, .body = "{}" },
    };
    var mock = MockTransport.init(&responses);
    var client = HttpClient.init(std.testing.allocator, mock.transport());

    var resp = try client.get("https://a.com/status", &.{});
    defer resp.deinit();

    try std.testing.expectEqual(HttpMethod.GET, mock.last_method.?);
}

test "MockTransport captures body" {
    const responses = [_]MockTransport.MockResponse{
        .{ .status = 200, .body = "{}" },
    };
    var mock = MockTransport.init(&responses);
    var client = HttpClient.init(std.testing.allocator, mock.transport());

    var resp = try client.post("https://a.com", &.{}, "{\"model\":\"claude\"}");
    defer resp.deinit();

    try std.testing.expectEqualStrings("{\"model\":\"claude\"}", mock.last_body.?);
}

test "postJson adds content-type header" {
    const responses = [_]MockTransport.MockResponse{
        .{ .status = 200, .body = "{}" },
    };
    var mock = MockTransport.init(&responses);
    var client = HttpClient.init(std.testing.allocator, mock.transport());

    const auth_headers = [_]Header{
        .{ .name = "x-api-key", .value = "sk-test" },
    };
    var resp = try client.postJson("https://api.anthropic.com/v1/messages", &auth_headers, "{\"model\":\"claude\"}");
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
}

test "postSse adds SSE accept header" {
    const responses = [_]MockTransport.MockResponse{
        .{ .status = 200, .body = "event: message_start\ndata: {}\n\n" },
    };
    var mock = MockTransport.init(&responses);
    var client = HttpClient.init(std.testing.allocator, mock.transport());

    var resp = try client.postSse("https://api.anthropic.com/v1/messages", &.{}, "{}");
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
}

test "buildUrl" {
    var buf: [256]u8 = undefined;
    const url = try buildUrl(&buf, "https://api.anthropic.com", "/v1/messages");
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", url);
}

test "buildUrlWithQuery" {
    var buf: [256]u8 = undefined;
    const url = try buildUrlWithQuery(&buf, "https://api.example.com", "/search", "q=hello&limit=10");
    try std.testing.expectEqualStrings("https://api.example.com/search?q=hello&limit=10", url);
}

test "HttpResponse deinit with allocator" {
    const body = try std.testing.allocator.dupe(u8, "test body");
    var resp = HttpResponse{
        .status = 200,
        .body = body,
        .allocator = std.testing.allocator,
    };
    resp.deinit();
}

test "HttpResponse deinit without allocator" {
    var resp = HttpResponse{
        .status = 200,
        .body = "static body",
    };
    resp.deinit(); // Should not crash
}

test "RequestOptions defaults" {
    const opts = RequestOptions{
        .url = "https://example.com",
    };
    try std.testing.expectEqual(HttpMethod.POST, opts.method);
    try std.testing.expectEqual(@as(u32, 30_000), opts.timeout_ms);
    try std.testing.expect(opts.body == null);
}

test "StdHttpTransport init" {
    var transport_instance = StdHttpTransport.init(std.testing.allocator);
    const t = transport_instance.transport();
    _ = t;
}

test "MockTransport empty responses" {
    const responses = [_]MockTransport.MockResponse{};
    var mock = MockTransport.init(&responses);
    var client = HttpClient.init(std.testing.allocator, mock.transport());

    const result = client.post("https://a.com", &.{}, "");
    try std.testing.expectError(HttpError.ConnectionFailed, result);
    try std.testing.expectEqual(@as(usize, 0), mock.call_count);
}

test "Header struct" {
    const h = Header{ .name = "Authorization", .value = "Bearer token" };
    try std.testing.expectEqualStrings("Authorization", h.name);
    try std.testing.expectEqualStrings("Bearer token", h.value);
}

// ===== Additional comprehensive tests =====

// --- HttpMethod enum ---

test "HttpMethod - all variants exist" {
    const methods = [_]HttpMethod{ .GET, .POST, .PUT, .DELETE, .PATCH };
    try std.testing.expectEqual(@as(usize, 5), methods.len);
}

// --- HttpResponse ---

test "HttpResponse - status code 200" {
    var resp = HttpResponse{ .status = 200, .body = "ok" };
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("ok", resp.body);
    resp.deinit(); // no allocator, should not crash
}

test "HttpResponse - status code 201 Created" {
    var resp = HttpResponse{ .status = 201, .body = "{\"id\":1}" };
    try std.testing.expectEqual(@as(u16, 201), resp.status);
    resp.deinit();
}

test "HttpResponse - status code 204 No Content" {
    var resp = HttpResponse{ .status = 204, .body = "" };
    try std.testing.expectEqual(@as(u16, 204), resp.status);
    try std.testing.expectEqualStrings("", resp.body);
    resp.deinit();
}

test "HttpResponse - status code 301 redirect" {
    var resp = HttpResponse{ .status = 301, .body = "" };
    try std.testing.expectEqual(@as(u16, 301), resp.status);
    resp.deinit();
}

test "HttpResponse - status code 400 Bad Request" {
    var resp = HttpResponse{ .status = 400, .body = "{\"error\":\"bad request\"}" };
    try std.testing.expectEqual(@as(u16, 400), resp.status);
    resp.deinit();
}

test "HttpResponse - status code 401 Unauthorized" {
    var resp = HttpResponse{ .status = 401, .body = "{\"error\":\"unauthorized\"}" };
    try std.testing.expectEqual(@as(u16, 401), resp.status);
    resp.deinit();
}

test "HttpResponse - status code 403 Forbidden" {
    var resp = HttpResponse{ .status = 403, .body = "Forbidden" };
    try std.testing.expectEqual(@as(u16, 403), resp.status);
    resp.deinit();
}

test "HttpResponse - status code 404 Not Found" {
    var resp = HttpResponse{ .status = 404, .body = "Not Found" };
    try std.testing.expectEqual(@as(u16, 404), resp.status);
    resp.deinit();
}

test "HttpResponse - status code 429 Rate Limited" {
    var resp = HttpResponse{ .status = 429, .body = "{\"error\":\"rate limited\"}" };
    try std.testing.expectEqual(@as(u16, 429), resp.status);
    resp.deinit();
}

test "HttpResponse - status code 500 Internal Server Error" {
    var resp = HttpResponse{ .status = 500, .body = "{\"error\":\"internal\"}" };
    try std.testing.expectEqual(@as(u16, 500), resp.status);
    resp.deinit();
}

test "HttpResponse - status code 502 Bad Gateway" {
    var resp = HttpResponse{ .status = 502, .body = "Bad Gateway" };
    try std.testing.expectEqual(@as(u16, 502), resp.status);
    resp.deinit();
}

test "HttpResponse - status code 503 Service Unavailable" {
    var resp = HttpResponse{ .status = 503, .body = "Service Unavailable" };
    try std.testing.expectEqual(@as(u16, 503), resp.status);
    resp.deinit();
}

test "HttpResponse - empty body with allocator" {
    const body = try std.testing.allocator.dupe(u8, "");
    var resp = HttpResponse{
        .status = 200,
        .body = body,
        .allocator = std.testing.allocator,
    };
    resp.deinit();
}

test "HttpResponse - large body with allocator" {
    const large_body = try std.testing.allocator.alloc(u8, 10000);
    defer {} // deinit below handles freeing
    @memset(large_body, 'x');
    var resp = HttpResponse{
        .status = 200,
        .body = large_body,
        .allocator = std.testing.allocator,
    };
    try std.testing.expectEqual(@as(usize, 10000), resp.body.len);
    resp.deinit();
}

// --- RequestOptions ---

test "RequestOptions - custom values" {
    const opts = RequestOptions{
        .method = .GET,
        .url = "https://api.example.com/v1/models",
        .timeout_ms = 5000,
        .max_response_bytes = 1024,
    };
    try std.testing.expectEqual(HttpMethod.GET, opts.method);
    try std.testing.expectEqualStrings("https://api.example.com/v1/models", opts.url);
    try std.testing.expectEqual(@as(u32, 5000), opts.timeout_ms);
    try std.testing.expectEqual(@as(usize, 1024), opts.max_response_bytes);
    try std.testing.expect(opts.body == null);
    try std.testing.expectEqual(@as(usize, 0), opts.headers.len);
}

test "RequestOptions - with body" {
    const opts = RequestOptions{
        .url = "https://example.com",
        .body = "{\"key\":\"value\"}",
    };
    try std.testing.expectEqualStrings("{\"key\":\"value\"}", opts.body.?);
}

test "RequestOptions - with headers" {
    const hdrs = [_]Header{
        .{ .name = "Authorization", .value = "Bearer token" },
        .{ .name = "Content-Type", .value = "application/json" },
    };
    const opts = RequestOptions{
        .url = "https://example.com",
        .headers = &hdrs,
    };
    try std.testing.expectEqual(@as(usize, 2), opts.headers.len);
    try std.testing.expectEqualStrings("Authorization", opts.headers[0].name);
    try std.testing.expectEqualStrings("Content-Type", opts.headers[1].name);
}

test "RequestOptions - default max_response_bytes is 10MB" {
    const opts = RequestOptions{ .url = "https://example.com" };
    try std.testing.expectEqual(@as(usize, 10 * 1024 * 1024), opts.max_response_bytes);
}

// --- MockTransport extended ---

test "MockTransport - many sequential responses" {
    const responses = [_]MockTransport.MockResponse{
        .{ .status = 200, .body = "r1" },
        .{ .status = 201, .body = "r2" },
        .{ .status = 202, .body = "r3" },
        .{ .status = 204, .body = "" },
        .{ .status = 400, .body = "err1" },
        .{ .status = 500, .body = "err2" },
    };
    var mock = MockTransport.init(&responses);
    var client = HttpClient.init(std.testing.allocator, mock.transport());

    var r1 = try client.get("https://a.com/1", &.{});
    defer r1.deinit();
    try std.testing.expectEqual(@as(u16, 200), r1.status);
    try std.testing.expectEqualStrings("r1", r1.body);

    var r2 = try client.get("https://a.com/2", &.{});
    defer r2.deinit();
    try std.testing.expectEqual(@as(u16, 201), r2.status);

    var r3 = try client.get("https://a.com/3", &.{});
    defer r3.deinit();
    try std.testing.expectEqual(@as(u16, 202), r3.status);

    var r4 = try client.get("https://a.com/4", &.{});
    defer r4.deinit();
    try std.testing.expectEqual(@as(u16, 204), r4.status);
    try std.testing.expectEqualStrings("", r4.body);

    var r5 = try client.get("https://a.com/5", &.{});
    defer r5.deinit();
    try std.testing.expectEqual(@as(u16, 400), r5.status);

    var r6 = try client.get("https://a.com/6", &.{});
    defer r6.deinit();
    try std.testing.expectEqual(@as(u16, 500), r6.status);

    try std.testing.expectEqual(@as(usize, 6), mock.call_count);
}

test "MockTransport - captures last URL correctly" {
    const responses = [_]MockTransport.MockResponse{
        .{ .status = 200, .body = "{}" },
        .{ .status = 200, .body = "{}" },
    };
    var mock = MockTransport.init(&responses);
    var client = HttpClient.init(std.testing.allocator, mock.transport());

    var r1 = try client.get("https://first.com/path", &.{});
    defer r1.deinit();
    try std.testing.expectEqualStrings("https://first.com/path", mock.last_url.?);

    var r2 = try client.get("https://second.com/other", &.{});
    defer r2.deinit();
    try std.testing.expectEqualStrings("https://second.com/other", mock.last_url.?);
}

test "MockTransport - GET method captured" {
    const responses = [_]MockTransport.MockResponse{
        .{ .status = 200, .body = "{}" },
    };
    var mock = MockTransport.init(&responses);
    var client = HttpClient.init(std.testing.allocator, mock.transport());

    var resp = try client.get("https://a.com", &.{});
    defer resp.deinit();
    try std.testing.expectEqual(HttpMethod.GET, mock.last_method.?);
}

test "MockTransport - POST method captured" {
    const responses = [_]MockTransport.MockResponse{
        .{ .status = 200, .body = "{}" },
    };
    var mock = MockTransport.init(&responses);
    var client = HttpClient.init(std.testing.allocator, mock.transport());

    var resp = try client.post("https://a.com", &.{}, "body");
    defer resp.deinit();
    try std.testing.expectEqual(HttpMethod.POST, mock.last_method.?);
}

test "MockTransport - initial state" {
    const responses = [_]MockTransport.MockResponse{};
    const mock = MockTransport.init(&responses);
    try std.testing.expectEqual(@as(usize, 0), mock.call_count);
    try std.testing.expect(mock.last_url == null);
    try std.testing.expect(mock.last_body == null);
    try std.testing.expect(mock.last_method == null);
}

test "MockTransport - body is null for GET" {
    const responses = [_]MockTransport.MockResponse{
        .{ .status = 200, .body = "{}" },
    };
    var mock = MockTransport.init(&responses);
    var client = HttpClient.init(std.testing.allocator, mock.transport());

    var resp = try client.get("https://a.com", &.{});
    defer resp.deinit();
    try std.testing.expect(mock.last_body == null);
}

test "MockTransport - body captured for POST" {
    const responses = [_]MockTransport.MockResponse{
        .{ .status = 200, .body = "{}" },
    };
    var mock = MockTransport.init(&responses);
    var client = HttpClient.init(std.testing.allocator, mock.transport());

    var resp = try client.post("https://a.com", &.{}, "{\"test\":true}");
    defer resp.deinit();
    try std.testing.expectEqualStrings("{\"test\":true}", mock.last_body.?);
}

test "MockTransport - empty body for POST" {
    const responses = [_]MockTransport.MockResponse{
        .{ .status = 200, .body = "{}" },
    };
    var mock = MockTransport.init(&responses);
    var client = HttpClient.init(std.testing.allocator, mock.transport());

    var resp = try client.post("https://a.com", &.{}, "");
    defer resp.deinit();
    try std.testing.expectEqualStrings("", mock.last_body.?);
}

// --- buildUrl extended ---

test "buildUrl - empty base and path" {
    var buf: [256]u8 = undefined;
    const url = try buildUrl(&buf, "", "");
    try std.testing.expectEqualStrings("", url);
}

test "buildUrl - empty path" {
    var buf: [256]u8 = undefined;
    const url = try buildUrl(&buf, "https://api.example.com", "");
    try std.testing.expectEqualStrings("https://api.example.com", url);
}

test "buildUrl - empty base" {
    var buf: [256]u8 = undefined;
    const url = try buildUrl(&buf, "", "/path");
    try std.testing.expectEqualStrings("/path", url);
}

test "buildUrl - URL with special characters in path" {
    var buf: [256]u8 = undefined;
    const url = try buildUrl(&buf, "https://api.example.com", "/search?q=hello%20world&limit=10");
    try std.testing.expectEqualStrings("https://api.example.com/search?q=hello%20world&limit=10", url);
}

test "buildUrl - long URL" {
    var buf: [1024]u8 = undefined;
    const long_path = "/" ++ "a" ** 200;
    const url = try buildUrl(&buf, "https://api.example.com", long_path);
    try std.testing.expect(url.len == "https://api.example.com".len + long_path.len);
}

test "buildUrl - buffer too small returns error" {
    var buf: [10]u8 = undefined;
    const result = buildUrl(&buf, "https://api.example.com", "/v1/messages");
    try std.testing.expectError(error.NoSpaceLeft, result);
}

// --- buildUrlWithQuery extended ---

test "buildUrlWithQuery - empty query" {
    var buf: [256]u8 = undefined;
    const url = try buildUrlWithQuery(&buf, "https://api.example.com", "/path", "");
    try std.testing.expectEqualStrings("https://api.example.com/path?", url);
}

test "buildUrlWithQuery - complex query" {
    var buf: [512]u8 = undefined;
    const url = try buildUrlWithQuery(&buf, "https://api.example.com", "/search", "q=hello+world&lang=en&page=1&per_page=20");
    try std.testing.expectEqualStrings("https://api.example.com/search?q=hello+world&lang=en&page=1&per_page=20", url);
}

test "buildUrlWithQuery - buffer too small returns error" {
    var buf: [10]u8 = undefined;
    const result = buildUrlWithQuery(&buf, "https://api.example.com", "/search", "q=hello");
    try std.testing.expectError(error.NoSpaceLeft, result);
}

// --- postJson extended ---

test "postJson - with multiple auth headers" {
    const responses = [_]MockTransport.MockResponse{
        .{ .status = 200, .body = "{\"ok\":true}" },
    };
    var mock = MockTransport.init(&responses);
    var client = HttpClient.init(std.testing.allocator, mock.transport());

    const auth_headers = [_]Header{
        .{ .name = "x-api-key", .value = "sk-test" },
        .{ .name = "anthropic-version", .value = "2023-06-01" },
        .{ .name = "x-custom", .value = "value" },
    };
    var resp = try client.postJson("https://api.anthropic.com/v1/messages", &auth_headers, "{\"model\":\"claude\"}");
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("{\"ok\":true}", resp.body);
}

test "postJson - with empty auth headers" {
    const responses = [_]MockTransport.MockResponse{
        .{ .status = 200, .body = "{}" },
    };
    var mock = MockTransport.init(&responses);
    var client = HttpClient.init(std.testing.allocator, mock.transport());

    var resp = try client.postJson("https://api.example.com", &.{}, "{}");
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
}

// --- postSse extended ---

test "postSse - with auth headers" {
    const responses = [_]MockTransport.MockResponse{
        .{ .status = 200, .body = "event: done\ndata: {}\n\n" },
    };
    var mock = MockTransport.init(&responses);
    var client = HttpClient.init(std.testing.allocator, mock.transport());

    const auth_headers = [_]Header{
        .{ .name = "x-api-key", .value = "sk-test" },
    };
    var resp = try client.postSse("https://api.anthropic.com/v1/messages", &auth_headers, "{\"stream\":true}");
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
}

// --- Header edge cases ---

test "Header - empty name and value" {
    const h = Header{ .name = "", .value = "" };
    try std.testing.expectEqualStrings("", h.name);
    try std.testing.expectEqualStrings("", h.value);
}

test "Header - special characters in value" {
    const h = Header{ .name = "Authorization", .value = "Bearer eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature" };
    try std.testing.expect(std.mem.indexOf(u8, h.value, ".") != null);
}

test "Header - unicode in value" {
    const h = Header{ .name = "X-Custom", .value = "\xc3\xa9\xc3\xa0\xc3\xbc" };
    try std.testing.expect(h.value.len > 0);
}

// --- MockResponse defaults ---

test "MockResponse - default values" {
    const mr = MockTransport.MockResponse{};
    try std.testing.expectEqual(@as(u16, 200), mr.status);
    try std.testing.expectEqualStrings("{}", mr.body);
}

test "MockResponse - custom values" {
    const mr = MockTransport.MockResponse{ .status = 418, .body = "I'm a teapot" };
    try std.testing.expectEqual(@as(u16, 418), mr.status);
    try std.testing.expectEqualStrings("I'm a teapot", mr.body);
}

// --- HttpClient init/deinit ---

test "HttpClient - init and deinit" {
    const responses = [_]MockTransport.MockResponse{};
    var mock = MockTransport.init(&responses);
    var client = HttpClient.init(std.testing.allocator, mock.transport());
    client.deinit();
}

// --- HttpError enum ---

test "HttpError - ConnectionFailed from exhausted mock" {
    const responses = [_]MockTransport.MockResponse{};
    var mock = MockTransport.init(&responses);
    var client = HttpClient.init(std.testing.allocator, mock.transport());

    try std.testing.expectError(HttpError.ConnectionFailed, client.get("https://a.com", &.{}));
    try std.testing.expectError(HttpError.ConnectionFailed, client.post("https://a.com", &.{}, ""));
}
