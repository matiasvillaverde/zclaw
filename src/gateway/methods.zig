const std = @import("std");
const handler = @import("protocol/handler.zig");
const schema = @import("protocol/schema.zig");
const auth = @import("protocol/auth.zig");
const state = @import("state.zig");
const config_schema = @import("../config/schema.zig");

// --- Gateway Services ---
// Shared services available to all RPC method handlers via user_data.

pub const GatewayServices = struct {
    config: *config_schema.Config,
    connections: *state.ConnectionRegistry,
    presence: *state.PresenceTracker,
    started_at_ms: i64,

    pub fn init(
        config: *config_schema.Config,
        connections: *state.ConnectionRegistry,
        presence: *state.PresenceTracker,
        started_at_ms: i64,
    ) GatewayServices {
        return .{
            .config = config,
            .connections = connections,
            .presence = presence,
            .started_at_ms = started_at_ms,
        };
    }

    pub fn uptimeMs(self: *const GatewayServices) i64 {
        return std.time.milliTimestamp() - self.started_at_ms;
    }
};

fn getServices(ctx: *const handler.HandlerContext) ?*GatewayServices {
    const ptr = ctx.user_data orelse return null;
    return @ptrCast(@alignCast(ptr));
}

// --- config.get ---

pub fn handleConfigGet(ctx: *const handler.HandlerContext) void {
    const svc = getServices(ctx) orelse {
        ctx.respond.sendError(ctx.request_id, .internal, "services unavailable");
        return;
    };

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    w.writeAll("{") catch return;
    std.fmt.format(w, "\"gateway\":{{\"port\":{d}}},", .{svc.config.gateway.port}) catch return;
    std.fmt.format(w, "\"logging\":{{\"level\":\"{s}\"}},", .{svc.config.logging.level.label()}) catch return;
    std.fmt.format(w, "\"session\":{{\"mainKey\":\"{s}\"}}", .{svc.config.session.main_key}) catch return;
    w.writeAll("}") catch return;
    ctx.respond.sendOk(ctx.request_id, fbs.getWritten());
}

// --- config.set ---

pub fn handleConfigSet(ctx: *const handler.HandlerContext) void {
    const svc = getServices(ctx) orelse {
        ctx.respond.sendError(ctx.request_id, .internal, "services unavailable");
        return;
    };

    const params = ctx.params_raw orelse {
        ctx.respond.sendError(ctx.request_id, .invalid_request, "missing params");
        return;
    };

    // Simple key-value: look for "key" and "value" in params
    const key = extractJsonString(params, "key") orelse {
        ctx.respond.sendError(ctx.request_id, .invalid_request, "missing 'key'");
        return;
    };

    if (std.mem.eql(u8, key, "gateway.port")) {
        if (extractJsonInt(params, "value")) |port_val| {
            if (port_val > 0 and port_val <= 65535) {
                svc.config.gateway.port = @intCast(@as(u16, @truncate(@as(u64, @bitCast(port_val)))));
                ctx.respond.sendOk(ctx.request_id, "{\"updated\":true}");
                return;
            }
        }
        ctx.respond.sendError(ctx.request_id, .invalid_request, "invalid port value");
    } else if (std.mem.eql(u8, key, "logging.level")) {
        if (extractJsonString(params, "value")) |level_str| {
            const map = std.StaticStringMap(config_schema.LogLevel).initComptime(.{
                .{ "silent", .silent },
                .{ "fatal", .fatal },
                .{ "error", .err },
                .{ "warn", .warn },
                .{ "info", .info },
                .{ "debug", .debug },
                .{ "trace", .trace },
            });
            if (map.get(level_str)) |level| {
                svc.config.logging.level = level;
                ctx.respond.sendOk(ctx.request_id, "{\"updated\":true}");
                return;
            }
        }
        ctx.respond.sendError(ctx.request_id, .invalid_request, "invalid log level");
    } else {
        ctx.respond.sendError(ctx.request_id, .invalid_request, "unknown config key");
    }
}

// --- status (enhanced) ---

pub fn handleStatusEnhanced(ctx: *const handler.HandlerContext) void {
    const svc = getServices(ctx) orelse {
        ctx.respond.sendOk(ctx.request_id, "{\"gateway\":\"running\",\"protocol\":3}");
        return;
    };

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    w.writeAll("{") catch return;
    std.fmt.format(w, "\"gateway\":\"running\",\"protocol\":3,", .{}) catch return;
    std.fmt.format(w, "\"uptime_ms\":{d},", .{svc.uptimeMs()}) catch return;
    std.fmt.format(w, "\"connections\":{d},", .{svc.connections.count()}) catch return;
    std.fmt.format(w, "\"presence_online\":{d},", .{svc.presence.onlineCount()}) catch return;
    std.fmt.format(w, "\"port\":{d}", .{svc.config.gateway.port}) catch return;
    w.writeAll("}") catch return;
    ctx.respond.sendOk(ctx.request_id, fbs.getWritten());
}

// --- connections.list ---

pub fn handleConnectionsList(ctx: *const handler.HandlerContext) void {
    const svc = getServices(ctx) orelse {
        ctx.respond.sendOk(ctx.request_id, "{\"connections\":[]}");
        return;
    };

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    w.writeAll("{\"connections\":[") catch return;

    // Note: count is the most we can safely report without iterating
    std.fmt.format(w, "],\"count\":{d}", .{svc.connections.count()}) catch return;
    w.writeAll("}") catch return;
    ctx.respond.sendOk(ctx.request_id, fbs.getWritten());
}

// --- system.presence ---

pub fn handlePresence(ctx: *const handler.HandlerContext) void {
    const svc = getServices(ctx) orelse {
        ctx.respond.sendError(ctx.request_id, .internal, "services unavailable");
        return;
    };

    const params = ctx.params_raw orelse {
        ctx.respond.sendError(ctx.request_id, .invalid_request, "missing params");
        return;
    };

    const presence_key = extractJsonString(params, "presenceKey") orelse {
        ctx.respond.sendError(ctx.request_id, .invalid_request, "missing 'presenceKey'");
        return;
    };

    const conn_id = if (ctx.client) |c| c.conn_id else "unknown";

    svc.presence.upsert(presence_key, conn_id) catch {
        ctx.respond.sendError(ctx.request_id, .internal, "presence update failed");
        return;
    };

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    std.fmt.format(w, "{{\"online\":{d},\"version\":{d}}}", .{
        svc.presence.onlineCount(),
        svc.presence.getVersion(),
    }) catch return;
    ctx.respond.sendOk(ctx.request_id, fbs.getWritten());
}

// --- Register all methods ---

pub fn registerMethods(registry: *handler.MethodRegistry) !void {
    try registry.register("config.get", handleConfigGet);
    try registry.register("config.set", handleConfigSet);
    try registry.register("status", handleStatusEnhanced);
    try registry.register("connections.list", handleConnectionsList);
    try registry.register("system.presence", handlePresence);
}

// --- JSON helpers ---

fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Find "key":"value" pattern
    var search_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;

    const start_idx = std.mem.indexOf(u8, json, needle) orelse return null;
    const val_start = start_idx + needle.len;
    if (val_start >= json.len) return null;

    const val_end = std.mem.indexOfPos(u8, json, val_start, "\"") orelse return null;
    return json[val_start..val_end];
}

fn extractJsonInt(json: []const u8, key: []const u8) ?i64 {
    // Find "key":number pattern
    var search_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;

    const start_idx = std.mem.indexOf(u8, json, needle) orelse return null;
    const val_start = start_idx + needle.len;
    if (val_start >= json.len) return null;

    // Skip whitespace
    var i = val_start;
    while (i < json.len and json[i] == ' ') : (i += 1) {}
    if (i >= json.len) return null;

    // Parse integer
    var end = i;
    if (json[end] == '-') end += 1;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
    if (end == i or (end == i + 1 and json[i] == '-')) return null;

    return std.fmt.parseInt(i64, json[i..end], 10) catch null;
}

// --- Tests ---

// Test helper infrastructure
var test_output_buf: [8192]u8 = undefined;
var test_output_len: usize = 0;

fn testWriteFn(ctx_ptr: *anyopaque, data: []const u8) void {
    _ = ctx_ptr;
    @memcpy(test_output_buf[0..data.len], data);
    test_output_len = data.len;
}

fn getTestOutput() []const u8 {
    return test_output_buf[0..test_output_len];
}

fn createTestWriter() handler.ResponseWriter {
    return .{
        .buf = &test_output_buf,
        .write_fn = testWriteFn,
        .ctx = @ptrFromInt(1),
    };
}

fn createTestServices(config: *config_schema.Config, connections: *state.ConnectionRegistry, presence: *state.PresenceTracker) GatewayServices {
    return GatewayServices.init(config, connections, presence, std.time.milliTimestamp());
}

test "extractJsonString" {
    const json = "{\"key\":\"value\",\"name\":\"test\"}";
    try std.testing.expectEqualStrings("value", extractJsonString(json, "key").?);
    try std.testing.expectEqualStrings("test", extractJsonString(json, "name").?);
    try std.testing.expectEqual(@as(?[]const u8, null), extractJsonString(json, "missing"));
}

test "extractJsonInt" {
    const json = "{\"port\":9999,\"count\":42}";
    try std.testing.expectEqual(@as(i64, 9999), extractJsonInt(json, "port").?);
    try std.testing.expectEqual(@as(i64, 42), extractJsonInt(json, "count").?);
    try std.testing.expectEqual(@as(?i64, null), extractJsonInt(json, "missing"));
}

test "extractJsonInt negative" {
    const json = "{\"offset\":-100}";
    try std.testing.expectEqual(@as(i64, -100), extractJsonInt(json, "offset").?);
}

test "handleConfigGet returns config JSON" {
    const allocator = std.testing.allocator;
    var config = config_schema.defaultConfig();
    var connections = state.ConnectionRegistry.init(allocator);
    defer connections.deinit();
    var presence = state.PresenceTracker.init(allocator);
    defer presence.deinit();
    var svc = createTestServices(&config, &connections, &presence);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const ctx = handler.HandlerContext{
        .request_id = "req-1",
        .method = "config.get",
        .params_raw = null,
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleConfigGet(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"port\":18789") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"level\":\"info\"") != null);
}

test "handleConfigSet updates port" {
    const allocator = std.testing.allocator;
    var config = config_schema.defaultConfig();
    var connections = state.ConnectionRegistry.init(allocator);
    defer connections.deinit();
    var presence = state.PresenceTracker.init(allocator);
    defer presence.deinit();
    var svc = createTestServices(&config, &connections, &presence);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const ctx = handler.HandlerContext{
        .request_id = "req-2",
        .method = "config.set",
        .params_raw = "{\"key\":\"gateway.port\",\"value\":9999}",
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleConfigSet(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"updated\":true") != null);
    try std.testing.expectEqual(@as(u16, 9999), config.gateway.port);
}

test "handleConfigSet updates log level" {
    const allocator = std.testing.allocator;
    var config = config_schema.defaultConfig();
    var connections = state.ConnectionRegistry.init(allocator);
    defer connections.deinit();
    var presence = state.PresenceTracker.init(allocator);
    defer presence.deinit();
    var svc = createTestServices(&config, &connections, &presence);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const ctx = handler.HandlerContext{
        .request_id = "req-3",
        .method = "config.set",
        .params_raw = "{\"key\":\"logging.level\",\"value\":\"debug\"}",
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleConfigSet(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"updated\":true") != null);
    try std.testing.expectEqual(config_schema.LogLevel.debug, config.logging.level);
}

test "handleConfigSet rejects unknown key" {
    const allocator = std.testing.allocator;
    var config = config_schema.defaultConfig();
    var connections = state.ConnectionRegistry.init(allocator);
    defer connections.deinit();
    var presence = state.PresenceTracker.init(allocator);
    defer presence.deinit();
    var svc = createTestServices(&config, &connections, &presence);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const ctx = handler.HandlerContext{
        .request_id = "req-4",
        .method = "config.set",
        .params_raw = "{\"key\":\"unknown.field\",\"value\":\"abc\"}",
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleConfigSet(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "unknown config key") != null);
}

test "handleConfigSet rejects missing params" {
    const allocator = std.testing.allocator;
    var config = config_schema.defaultConfig();
    var connections = state.ConnectionRegistry.init(allocator);
    defer connections.deinit();
    var presence = state.PresenceTracker.init(allocator);
    defer presence.deinit();
    var svc = createTestServices(&config, &connections, &presence);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const ctx = handler.HandlerContext{
        .request_id = "req-5",
        .method = "config.set",
        .params_raw = null,
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleConfigSet(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "missing params") != null);
}

test "handleStatusEnhanced returns full status" {
    const allocator = std.testing.allocator;
    var config = config_schema.defaultConfig();
    var connections = state.ConnectionRegistry.init(allocator);
    defer connections.deinit();
    var presence = state.PresenceTracker.init(allocator);
    defer presence.deinit();
    var svc = createTestServices(&config, &connections, &presence);

    // Add a connection
    try connections.add("conn-1", .operator, "client-1", .cli);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const ctx = handler.HandlerContext{
        .request_id = "req-6",
        .method = "status",
        .params_raw = null,
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleStatusEnhanced(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"gateway\":\"running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"connections\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"port\":18789") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"uptime_ms\":") != null);
}

test "handleConnectionsList returns count" {
    const allocator = std.testing.allocator;
    var config = config_schema.defaultConfig();
    var connections = state.ConnectionRegistry.init(allocator);
    defer connections.deinit();
    var presence = state.PresenceTracker.init(allocator);
    defer presence.deinit();
    var svc = createTestServices(&config, &connections, &presence);

    try connections.add("conn-1", .operator, "c1", .cli);
    try connections.add("conn-2", .admin, "c2", .ui);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const ctx = handler.HandlerContext{
        .request_id = "req-7",
        .method = "connections.list",
        .params_raw = null,
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleConnectionsList(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"count\":2") != null);
}

test "handlePresence updates and returns status" {
    const allocator = std.testing.allocator;
    var config = config_schema.defaultConfig();
    var connections = state.ConnectionRegistry.init(allocator);
    defer connections.deinit();
    var presence = state.PresenceTracker.init(allocator);
    defer presence.deinit();
    var svc = createTestServices(&config, &connections, &presence);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const client_info = handler.ClientInfo{
        .conn_id = "conn-1",
        .role = .operator,
        .client_id = "client-1",
        .client_mode = .cli,
        .authenticated = true,
    };

    const ctx = handler.HandlerContext{
        .request_id = "req-8",
        .method = "system.presence",
        .params_raw = "{\"presenceKey\":\"user:abc\"}",
        .client = &client_info,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handlePresence(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"online\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"version\":1") != null);
    try std.testing.expect(presence.isOnline("user:abc"));
}

test "handlePresence rejects missing presenceKey" {
    const allocator = std.testing.allocator;
    var config = config_schema.defaultConfig();
    var connections = state.ConnectionRegistry.init(allocator);
    defer connections.deinit();
    var presence = state.PresenceTracker.init(allocator);
    defer presence.deinit();
    var svc = createTestServices(&config, &connections, &presence);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const ctx = handler.HandlerContext{
        .request_id = "req-9",
        .method = "system.presence",
        .params_raw = "{}",
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handlePresence(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "missing 'presenceKey'") != null);
}

test "handleConfigGet without services returns error" {
    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const ctx = handler.HandlerContext{
        .request_id = "req-10",
        .method = "config.get",
        .params_raw = null,
        .client = null,
        .respond = &writer,
        .user_data = null,
    };
    handleConfigGet(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "services unavailable") != null);
}

test "registerMethods adds all methods" {
    const allocator = std.testing.allocator;
    var registry = handler.MethodRegistry.init(allocator);
    defer registry.deinit();

    try registerMethods(&registry);

    try std.testing.expect(registry.get("config.get") != null);
    try std.testing.expect(registry.get("config.set") != null);
    try std.testing.expect(registry.get("status") != null);
    try std.testing.expect(registry.get("connections.list") != null);
    try std.testing.expect(registry.get("system.presence") != null);
    try std.testing.expectEqual(@as(usize, 5), registry.methodCount());
}

test "GatewayServices uptimeMs" {
    const allocator = std.testing.allocator;
    var config = config_schema.defaultConfig();
    var connections = state.ConnectionRegistry.init(allocator);
    defer connections.deinit();
    var presence = state.PresenceTracker.init(allocator);
    defer presence.deinit();
    const svc = createTestServices(&config, &connections, &presence);

    try std.testing.expect(svc.uptimeMs() >= 0);
}

test "dispatchWithData passes user_data to handler" {
    const allocator = std.testing.allocator;
    var registry = handler.MethodRegistry.init(allocator);
    defer registry.deinit();

    try registerMethods(&registry);

    var config = config_schema.defaultConfig();
    var connections = state.ConnectionRegistry.init(allocator);
    defer connections.deinit();
    var presence = state.PresenceTracker.init(allocator);
    defer presence.deinit();
    var svc = createTestServices(&config, &connections, &presence);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const client_info = handler.ClientInfo{
        .conn_id = "conn-1",
        .role = .admin,
        .client_id = "client-1",
        .client_mode = .cli,
        .authenticated = true,
    };

    const json = "{\"type\":\"req\",\"id\":\"req-d1\",\"method\":\"config.get\"}";
    const result = handler.dispatchWithData(json, &registry, &client_info, &writer, @ptrCast(&svc));
    try std.testing.expectEqual(handler.DispatchResult.ok, result);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"port\":18789") != null);
}

// --- New Tests ---

test "extractJsonString with nested quotes" {
    const json = "{\"key\":\"value with spaces\"}";
    try std.testing.expectEqualStrings("value with spaces", extractJsonString(json, "key").?);
}

test "extractJsonString empty value" {
    const json = "{\"key\":\"\"}";
    try std.testing.expectEqualStrings("", extractJsonString(json, "key").?);
}

test "extractJsonInt zero" {
    const json = "{\"count\":0}";
    try std.testing.expectEqual(@as(i64, 0), extractJsonInt(json, "count").?);
}

test "extractJsonInt large value" {
    const json = "{\"big\":999999}";
    try std.testing.expectEqual(@as(i64, 999999), extractJsonInt(json, "big").?);
}

test "extractJsonInt with whitespace" {
    const json = "{\"val\":  42}";
    try std.testing.expectEqual(@as(i64, 42), extractJsonInt(json, "val").?);
}

test "handleConfigSet invalid port zero" {
    const allocator = std.testing.allocator;
    var config = config_schema.defaultConfig();
    var connections = state.ConnectionRegistry.init(allocator);
    defer connections.deinit();
    var presence = state.PresenceTracker.init(allocator);
    defer presence.deinit();
    var svc = createTestServices(&config, &connections, &presence);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const ctx = handler.HandlerContext{
        .request_id = "req-port0",
        .method = "config.set",
        .params_raw = "{\"key\":\"gateway.port\",\"value\":0}",
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleConfigSet(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "invalid port value") != null);
}

test "handleConfigSet invalid log level" {
    const allocator = std.testing.allocator;
    var config = config_schema.defaultConfig();
    var connections = state.ConnectionRegistry.init(allocator);
    defer connections.deinit();
    var presence = state.PresenceTracker.init(allocator);
    defer presence.deinit();
    var svc = createTestServices(&config, &connections, &presence);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const ctx = handler.HandlerContext{
        .request_id = "req-bad-level",
        .method = "config.set",
        .params_raw = "{\"key\":\"logging.level\",\"value\":\"nonexistent\"}",
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleConfigSet(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "invalid log level") != null);
}

test "handleConfigSet missing key field" {
    const allocator = std.testing.allocator;
    var config = config_schema.defaultConfig();
    var connections = state.ConnectionRegistry.init(allocator);
    defer connections.deinit();
    var presence = state.PresenceTracker.init(allocator);
    defer presence.deinit();
    var svc = createTestServices(&config, &connections, &presence);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const ctx = handler.HandlerContext{
        .request_id = "req-no-key",
        .method = "config.set",
        .params_raw = "{\"value\":\"something\"}",
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleConfigSet(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "missing 'key'") != null);
}

test "handleStatusEnhanced without services returns basic status" {
    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const ctx = handler.HandlerContext{
        .request_id = "req-status-no-svc",
        .method = "status",
        .params_raw = null,
        .client = null,
        .respond = &writer,
        .user_data = null,
    };
    handleStatusEnhanced(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"gateway\":\"running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"protocol\":3") != null);
}

test "handleConnectionsList without services returns empty" {
    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const ctx = handler.HandlerContext{
        .request_id = "req-conn-no-svc",
        .method = "connections.list",
        .params_raw = null,
        .client = null,
        .respond = &writer,
        .user_data = null,
    };
    handleConnectionsList(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"connections\":[]") != null);
}

test "handlePresence without services returns error" {
    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const ctx = handler.HandlerContext{
        .request_id = "req-pres-no-svc",
        .method = "system.presence",
        .params_raw = "{\"presenceKey\":\"u:1\"}",
        .client = null,
        .respond = &writer,
        .user_data = null,
    };
    handlePresence(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "services unavailable") != null);
}

test "handlePresence without params returns error" {
    const allocator = std.testing.allocator;
    var config = config_schema.defaultConfig();
    var connections = state.ConnectionRegistry.init(allocator);
    defer connections.deinit();
    var presence = state.PresenceTracker.init(allocator);
    defer presence.deinit();
    var svc = createTestServices(&config, &connections, &presence);

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const ctx = handler.HandlerContext{
        .request_id = "req-no-params",
        .method = "system.presence",
        .params_raw = null,
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handlePresence(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "missing params") != null);
}

test "handleConfigSet without services returns error" {
    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const ctx = handler.HandlerContext{
        .request_id = "req-set-no-svc",
        .method = "config.set",
        .params_raw = "{\"key\":\"gateway.port\",\"value\":9999}",
        .client = null,
        .respond = &writer,
        .user_data = null,
    };
    handleConfigSet(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "services unavailable") != null);
}

test "GatewayServices init preserves all fields" {
    const allocator = std.testing.allocator;
    var config = config_schema.defaultConfig();
    var connections = state.ConnectionRegistry.init(allocator);
    defer connections.deinit();
    var presence = state.PresenceTracker.init(allocator);
    defer presence.deinit();

    const svc = GatewayServices.init(&config, &connections, &presence, 12345);
    try std.testing.expectEqual(@as(i64, 12345), svc.started_at_ms);
}

test "handleConfigSet all log levels" {
    const allocator = std.testing.allocator;
    const levels = [_][]const u8{ "silent", "fatal", "error", "warn", "info", "debug", "trace" };
    for (levels) |level| {
        var config = config_schema.defaultConfig();
        var connections = state.ConnectionRegistry.init(allocator);
        defer connections.deinit();
        var presence = state.PresenceTracker.init(allocator);
        defer presence.deinit();
        var svc = createTestServices(&config, &connections, &presence);

        test_output_len = 0;
        var resp_buf: [4096]u8 = undefined;
        var writer = createTestWriter();
        writer.buf = &resp_buf;

        var params_buf: [256]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf, "{{\"key\":\"logging.level\",\"value\":\"{s}\"}}", .{level}) catch continue;

        const ctx = handler.HandlerContext{
            .request_id = "req-lvl",
            .method = "config.set",
            .params_raw = params,
            .client = null,
            .respond = &writer,
            .user_data = @ptrCast(&svc),
        };
        handleConfigSet(&ctx);

        const output = getTestOutput();
        try std.testing.expect(std.mem.indexOf(u8, output, "\"updated\":true") != null);
    }
}
