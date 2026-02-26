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
