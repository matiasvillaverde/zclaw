const std = @import("std");
const schema = @import("schema.zig");
const auth = @import("auth.zig");

// --- Method Handler Type ---

pub const HandlerContext = struct {
    request_id: []const u8,
    method: []const u8,
    params_raw: ?[]const u8,
    client: ?*const ClientInfo,
    respond: *const ResponseWriter,
    user_data: ?*anyopaque = null,
};

pub const ClientInfo = struct {
    conn_id: []const u8,
    role: auth.ClientRole,
    client_id: ?[]const u8,
    client_mode: ?schema.ClientMode,
    authenticated: bool,
};

pub const ResponseWriter = struct {
    buf: []u8,
    write_fn: *const fn (ctx: *anyopaque, data: []const u8) void,
    ctx: *anyopaque,

    pub fn sendOk(self: *const ResponseWriter, id: []const u8, payload: ?[]const u8) void {
        const msg = schema.buildOkResponse(self.buf, id, payload);
        self.write_fn(self.ctx, msg);
    }

    pub fn sendError(self: *const ResponseWriter, id: []const u8, code: schema.ErrorCode, message: []const u8) void {
        const msg = schema.buildErrorResponse(self.buf, id, code, message);
        self.write_fn(self.ctx, msg);
    }

    pub fn sendEvent(self: *const ResponseWriter, event_name: []const u8, payload: ?[]const u8) void {
        const msg = schema.buildEvent(self.buf, event_name, payload);
        self.write_fn(self.ctx, msg);
    }
};

// --- Method Handler Function ---

pub const MethodHandler = *const fn (ctx: *const HandlerContext) void;

// --- Method Registry ---

pub const MethodRegistry = struct {
    handlers: std.StringHashMapUnmanaged(MethodHandler),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MethodRegistry {
        return .{
            .handlers = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MethodRegistry) void {
        self.handlers.deinit(self.allocator);
    }

    pub fn register(self: *MethodRegistry, method: []const u8, handler: MethodHandler) !void {
        try self.handlers.put(self.allocator, method, handler);
    }

    pub fn get(self: *const MethodRegistry, method: []const u8) ?MethodHandler {
        return self.handlers.get(method);
    }

    pub fn methodCount(self: *const MethodRegistry) usize {
        return self.handlers.count();
    }
};

// --- Frame Dispatcher ---

pub const DispatchResult = enum {
    ok,
    not_authenticated,
    method_not_found,
    unauthorized,
    invalid_frame,
    frame_too_large,
};

pub fn dispatch(
    json: []const u8,
    registry: *const MethodRegistry,
    client: ?*const ClientInfo,
    respond: *const ResponseWriter,
) DispatchResult {
    return dispatchWithData(json, registry, client, respond, null);
}

pub fn dispatchWithData(
    json: []const u8,
    registry: *const MethodRegistry,
    client: ?*const ClientInfo,
    respond: *const ResponseWriter,
    user_data: ?*anyopaque,
) DispatchResult {
    // Check payload size
    if (json.len > schema.MAX_PAYLOAD_BYTES) {
        return .frame_too_large;
    }

    // Parse frame type
    const frame_type = schema.parseFrameType(json) orelse return .invalid_frame;

    // Only handle request frames
    if (frame_type != .req) return .invalid_frame;

    // Parse request frame
    const frame = schema.parseRequestFrame(json) orelse return .invalid_frame;

    // Check authentication (first frame must be "connect")
    if (client == null and !std.mem.eql(u8, frame.method, "connect")) {
        respond.sendError(frame.id, .unauthorized, "not authenticated");
        return .not_authenticated;
    }

    // Health is always allowed without auth
    const is_health = std.mem.eql(u8, frame.method, "health");

    // Check role authorization
    if (client) |c| {
        if (!is_health and !c.role.canAccessMethod(frame.method)) {
            respond.sendError(frame.id, .unauthorized, "insufficient permissions");
            return .unauthorized;
        }
    }

    // Lookup handler
    const method_handler = registry.get(frame.method) orelse {
        respond.sendError(frame.id, .method_not_found, "unknown method");
        return .method_not_found;
    };

    // Execute handler
    const ctx = HandlerContext{
        .request_id = frame.id,
        .method = frame.method,
        .params_raw = frame.params_raw,
        .client = client,
        .respond = respond,
        .user_data = user_data,
    };
    method_handler(&ctx);

    return .ok;
}

// --- Built-in Handlers ---

pub fn handleHealth(ctx: *const HandlerContext) void {
    ctx.respond.sendOk(ctx.request_id, "{\"status\":\"ok\",\"version\":\"0.1.0\"}");
}

pub fn handleStatus(ctx: *const HandlerContext) void {
    ctx.respond.sendOk(ctx.request_id, "{\"gateway\":\"running\",\"protocol\":3}");
}

// --- Tests ---

// Test helpers
var test_output_buf: [8192]u8 = undefined;
var test_output_len: usize = 0;

fn testWriteFn(ctx: *anyopaque, data: []const u8) void {
    _ = ctx;
    @memcpy(test_output_buf[0..data.len], data);
    test_output_len = data.len;
}

fn getTestOutput() []const u8 {
    return test_output_buf[0..test_output_len];
}

fn createTestWriter() ResponseWriter {
    return .{
        .buf = &test_output_buf,
        .write_fn = testWriteFn,
        .ctx = @ptrFromInt(1), // dummy context
    };
}

test "MethodRegistry register and get" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("health", handleHealth);
    try registry.register("status", handleStatus);

    try std.testing.expectEqual(@as(usize, 2), registry.methodCount());
    try std.testing.expect(registry.get("health") != null);
    try std.testing.expect(registry.get("status") != null);
    try std.testing.expect(registry.get("nonexistent") == null);
}

test "dispatch health request" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();
    try registry.register("health", handleHealth);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const client_info = ClientInfo{
        .conn_id = "test-conn",
        .role = .operator,
        .client_id = "test-client",
        .client_mode = .cli,
        .authenticated = true,
    };

    const json = "{\"type\":\"req\",\"id\":\"req-1\",\"method\":\"health\"}";
    const result = dispatch(json, &registry, &client_info, &writer);
    try std.testing.expectEqual(DispatchResult.ok, result);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"status\":\"ok\"") != null);
}

test "dispatch unknown method" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const client_info = ClientInfo{
        .conn_id = "test-conn",
        .role = .admin,
        .client_id = "test-client",
        .client_mode = .cli,
        .authenticated = true,
    };

    const json = "{\"type\":\"req\",\"id\":\"req-2\",\"method\":\"unknown.method\"}";
    const result = dispatch(json, &registry, &client_info, &writer);
    try std.testing.expectEqual(DispatchResult.method_not_found, result);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "METHOD_NOT_FOUND") != null);
}

test "dispatch unauthenticated non-connect request" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();
    try registry.register("health", handleHealth);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const json = "{\"type\":\"req\",\"id\":\"req-3\",\"method\":\"health\"}";
    const result = dispatch(json, &registry, null, &writer);
    try std.testing.expectEqual(DispatchResult.not_authenticated, result);
}

test "dispatch invalid frame" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const result = dispatch("not json at all", &registry, null, &writer);
    try std.testing.expectEqual(DispatchResult.invalid_frame, result);
}

test "dispatch event frame ignored" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const json = "{\"type\":\"event\",\"event\":\"tick\"}";
    const result = dispatch(json, &registry, null, &writer);
    try std.testing.expectEqual(DispatchResult.invalid_frame, result);
}

test "dispatch viewer unauthorized for write method" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    const dummy_handler: MethodHandler = struct {
        fn handle(_: *const HandlerContext) void {}
    }.handle;
    try registry.register("chat.send", dummy_handler);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const viewer = ClientInfo{
        .conn_id = "test-conn",
        .role = .viewer,
        .client_id = "viewer-1",
        .client_mode = .webchat,
        .authenticated = true,
    };

    const json = "{\"type\":\"req\",\"id\":\"req-4\",\"method\":\"chat.send\"}";
    const result = dispatch(json, &registry, &viewer, &writer);
    try std.testing.expectEqual(DispatchResult.unauthorized, result);
}

test "dispatch connect allowed without auth" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    const connect_handler: MethodHandler = struct {
        fn handle(ctx: *const HandlerContext) void {
            ctx.respond.sendOk(ctx.request_id, null);
        }
    }.handle;
    try registry.register("connect", connect_handler);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const json = "{\"type\":\"req\",\"id\":\"req-5\",\"method\":\"connect\"}";
    const result = dispatch(json, &registry, null, &writer);
    try std.testing.expectEqual(DispatchResult.ok, result);
}

test "ResponseWriter.sendOk" {
    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;
    writer.sendOk("test-id", "{\"data\":1}");

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"id\":\"test-id\"") != null);
}

test "ResponseWriter.sendError" {
    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;
    writer.sendError("err-id", .invalid_request, "bad input");

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "INVALID_REQUEST") != null);
}

test "ResponseWriter.sendEvent" {
    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;
    writer.sendEvent("agent.delta", "{\"text\":\"hello\"}");

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"event\":\"agent.delta\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"text\":\"hello\"") != null);
}

test "frame too large rejected" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    // Create a "frame" that exceeds MAX_PAYLOAD_BYTES
    const big = [_]u8{'x'} ** (schema.MAX_PAYLOAD_BYTES + 1);
    const result = dispatch(&big, &registry, null, &writer);
    try std.testing.expectEqual(DispatchResult.frame_too_large, result);
}
