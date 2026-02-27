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

// --- Additional Tests ---

test "MethodRegistry empty" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 0), registry.methodCount());
    try std.testing.expect(registry.get("anything") == null);
}

test "MethodRegistry overwrite handler" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("health", handleHealth);
    try registry.register("health", handleStatus);

    try std.testing.expectEqual(@as(usize, 1), registry.methodCount());
}

test "ClientInfo struct fields" {
    const info = ClientInfo{
        .conn_id = "conn-123",
        .role = .admin,
        .client_id = "client-abc",
        .client_mode = .ui,
        .authenticated = true,
    };
    try std.testing.expectEqualStrings("conn-123", info.conn_id);
    try std.testing.expectEqual(auth.ClientRole.admin, info.role);
    try std.testing.expect(info.authenticated);
}

test "ClientInfo with null optionals" {
    const info = ClientInfo{
        .conn_id = "c1",
        .role = .viewer,
        .client_id = null,
        .client_mode = null,
        .authenticated = false,
    };
    try std.testing.expect(info.client_id == null);
    try std.testing.expect(info.client_mode == null);
    try std.testing.expect(!info.authenticated);
}

test "HandlerContext fields" {
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const ctx = HandlerContext{
        .request_id = "req-1",
        .method = "health",
        .params_raw = null,
        .client = null,
        .respond = &writer,
    };
    try std.testing.expectEqualStrings("req-1", ctx.request_id);
    try std.testing.expectEqualStrings("health", ctx.method);
    try std.testing.expect(ctx.params_raw == null);
    try std.testing.expect(ctx.user_data == null);
}

test "DispatchResult enum values" {
    try std.testing.expect(DispatchResult.ok != DispatchResult.not_authenticated);
    try std.testing.expect(DispatchResult.method_not_found != DispatchResult.unauthorized);
    try std.testing.expect(DispatchResult.invalid_frame != DispatchResult.frame_too_large);
}

test "handleHealth outputs ok status" {
    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const ctx = HandlerContext{
        .request_id = "test-id",
        .method = "health",
        .params_raw = null,
        .client = null,
        .respond = &writer,
    };
    handleHealth(&ctx);
    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "version") != null);
}

test "handleStatus outputs gateway running" {
    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const ctx = HandlerContext{
        .request_id = "status-id",
        .method = "status",
        .params_raw = null,
        .client = null,
        .respond = &writer,
    };
    handleStatus(&ctx);
    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"gateway\":\"running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"protocol\":3") != null);
}

test "ResponseWriter sendEvent without payload" {
    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;
    writer.sendEvent("tick", null);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"event\":\"tick\"") != null);
}

test "dispatch response frame ignored" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const json = "{\"type\":\"res\",\"id\":\"1\",\"ok\":true}";
    const result = dispatch(json, &registry, null, &writer);
    try std.testing.expectEqual(DispatchResult.invalid_frame, result);
}

// --- New Tests ---

test "MethodRegistry register single and get" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("my.method", handleHealth);
    try std.testing.expectEqual(@as(usize, 1), registry.methodCount());
    try std.testing.expect(registry.get("my.method") != null);
}

test "MethodRegistry get returns null for unknown" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expect(registry.get("unknown") == null);
}

test "dispatch empty JSON returns invalid_frame" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const result = dispatch("", &registry, null, &writer);
    try std.testing.expectEqual(DispatchResult.invalid_frame, result);
}

test "dispatch well-formed request to registered method" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("status", handleStatus);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const client_info = ClientInfo{
        .conn_id = "c1",
        .role = .admin,
        .client_id = null,
        .client_mode = null,
        .authenticated = true,
    };

    const json = "{\"type\":\"req\",\"id\":\"s1\",\"method\":\"status\"}";
    const result = dispatch(json, &registry, &client_info, &writer);
    try std.testing.expectEqual(DispatchResult.ok, result);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"gateway\":\"running\"") != null);
}

test "dispatch health always allowed for viewer" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("health", handleHealth);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const viewer = ClientInfo{
        .conn_id = "v1",
        .role = .viewer,
        .client_id = null,
        .client_mode = null,
        .authenticated = true,
    };

    const json = "{\"type\":\"req\",\"id\":\"h1\",\"method\":\"health\"}";
    const result = dispatch(json, &registry, &viewer, &writer);
    try std.testing.expectEqual(DispatchResult.ok, result);
}

test "dispatchWithData passes user_data correctly" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    const check_handler: MethodHandler = struct {
        fn handle(ctx: *const HandlerContext) void {
            if (ctx.user_data != null) {
                ctx.respond.sendOk(ctx.request_id, "{\"has_data\":true}");
            } else {
                ctx.respond.sendOk(ctx.request_id, "{\"has_data\":false}");
            }
        }
    }.handle;

    try registry.register("check", check_handler);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const client_info = ClientInfo{
        .conn_id = "c1",
        .role = .admin,
        .client_id = null,
        .client_mode = null,
        .authenticated = true,
    };

    var dummy_data: u32 = 42;
    const json = "{\"type\":\"req\",\"id\":\"d1\",\"method\":\"check\"}";
    _ = dispatchWithData(json, &registry, &client_info, &writer, @ptrCast(&dummy_data));

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"has_data\":true") != null);
}

test "dispatchWithData null user_data" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    const check_handler: MethodHandler = struct {
        fn handle(ctx: *const HandlerContext) void {
            if (ctx.user_data != null) {
                ctx.respond.sendOk(ctx.request_id, "{\"has_data\":true}");
            } else {
                ctx.respond.sendOk(ctx.request_id, "{\"has_data\":false}");
            }
        }
    }.handle;

    try registry.register("check", check_handler);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const client_info = ClientInfo{
        .conn_id = "c1",
        .role = .admin,
        .client_id = null,
        .client_mode = null,
        .authenticated = true,
    };

    const json = "{\"type\":\"req\",\"id\":\"d2\",\"method\":\"check\"}";
    _ = dispatchWithData(json, &registry, &client_info, &writer, null);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"has_data\":false") != null);
}

test "ResponseWriter sendOk null payload" {
    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;
    writer.sendOk("null-test", null);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "payload") == null);
}

test "ResponseWriter sendError different codes" {
    const codes = [_]schema.ErrorCode{ .not_linked, .not_paired, .agent_timeout, .unavailable, .method_not_found, .unauthorized, .internal, .invalid_request };
    for (codes) |code| {
        test_output_len = 0;
        var resp_buf: [4096]u8 = undefined;
        var writer = createTestWriter();
        writer.buf = &resp_buf;
        writer.sendError("err-id", code, "msg");

        const output = getTestOutput();
        try std.testing.expect(std.mem.indexOf(u8, output, code.label()) != null);
    }
}

test "DispatchResult all variants distinct" {
    const variants = [_]DispatchResult{ .ok, .not_authenticated, .method_not_found, .unauthorized, .invalid_frame, .frame_too_large };
    for (variants, 0..) |v1, i| {
        for (variants, 0..) |v2, j| {
            if (i != j) {
                try std.testing.expect(v1 != v2);
            }
        }
    }
}

test "HandlerContext with all fields populated" {
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const client_info = ClientInfo{
        .conn_id = "conn-full",
        .role = .operator,
        .client_id = "client-full",
        .client_mode = .backend,
        .authenticated = true,
    };

    var data: u8 = 1;
    const ctx = HandlerContext{
        .request_id = "req-full",
        .method = "test.full",
        .params_raw = "{\"key\":\"val\"}",
        .client = &client_info,
        .respond = &writer,
        .user_data = @ptrCast(&data),
    };
    try std.testing.expectEqualStrings("req-full", ctx.request_id);
    try std.testing.expectEqualStrings("test.full", ctx.method);
    try std.testing.expectEqualStrings("{\"key\":\"val\"}", ctx.params_raw.?);
    try std.testing.expect(ctx.client != null);
    try std.testing.expect(ctx.user_data != null);
}

test "dispatch operator can call non-admin methods" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    const dummy: MethodHandler = struct {
        fn handle(ctx: *const HandlerContext) void {
            ctx.respond.sendOk(ctx.request_id, null);
        }
    }.handle;

    try registry.register("chat.send", dummy);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const operator = ClientInfo{
        .conn_id = "op1",
        .role = .operator,
        .client_id = null,
        .client_mode = null,
        .authenticated = true,
    };

    const json = "{\"type\":\"req\",\"id\":\"op-1\",\"method\":\"chat.send\"}";
    const result = dispatch(json, &registry, &operator, &writer);
    try std.testing.expectEqual(DispatchResult.ok, result);
}

test "dispatch admin can call admin methods" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    const dummy: MethodHandler = struct {
        fn handle(ctx: *const HandlerContext) void {
            ctx.respond.sendOk(ctx.request_id, null);
        }
    }.handle;

    try registry.register("config.set", dummy);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const admin = ClientInfo{
        .conn_id = "a1",
        .role = .admin,
        .client_id = null,
        .client_mode = null,
        .authenticated = true,
    };

    const json = "{\"type\":\"req\",\"id\":\"a-1\",\"method\":\"config.set\"}";
    const result = dispatch(json, &registry, &admin, &writer);
    try std.testing.expectEqual(DispatchResult.ok, result);
}

test "dispatch calls dispatch with null user_data" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("health", handleHealth);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const client_info = ClientInfo{
        .conn_id = "c1",
        .role = .admin,
        .client_id = null,
        .client_mode = null,
        .authenticated = true,
    };

    const json = "{\"type\":\"req\",\"id\":\"d-1\",\"method\":\"health\"}";
    const result = dispatch(json, &registry, &client_info, &writer);
    try std.testing.expectEqual(DispatchResult.ok, result);
    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"status\":\"ok\"") != null);
}

test "MethodRegistry register many methods" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    const dummy: MethodHandler = struct {
        fn handle(_: *const HandlerContext) void {}
    }.handle;

    try registry.register("method.1", dummy);
    try registry.register("method.2", dummy);
    try registry.register("method.3", dummy);
    try registry.register("method.4", dummy);
    try registry.register("method.5", dummy);

    try std.testing.expectEqual(@as(usize, 5), registry.methodCount());
    for ([_][]const u8{ "method.1", "method.2", "method.3", "method.4", "method.5" }) |name| {
        try std.testing.expect(registry.get(name) != null);
    }
}

test "handleHealth includes version field" {
    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const ctx = HandlerContext{
        .request_id = "ver-id",
        .method = "health",
        .params_raw = null,
        .client = null,
        .respond = &writer,
    };
    handleHealth(&ctx);
    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"version\":\"0.1.0\"") != null);
}

test "handleStatus includes protocol version 3" {
    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const ctx = HandlerContext{
        .request_id = "proto-id",
        .method = "status",
        .params_raw = null,
        .client = null,
        .respond = &writer,
    };
    handleStatus(&ctx);
    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"protocol\":3") != null);
}
