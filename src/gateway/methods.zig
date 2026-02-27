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

// --- Appended Tests: edge cases and deeper coverage ---

test "handleConfigSet port negative value rejected" {
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
        .request_id = "req-neg-port",
        .method = "config.set",
        .params_raw = "{\"key\":\"gateway.port\",\"value\":-1}",
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleConfigSet(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "invalid port value") != null);
    // Config should remain unchanged
    try std.testing.expectEqual(@as(u16, 18789), config.gateway.port);
}

test "handleConfigSet port 65535 accepted" {
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
        .request_id = "req-max-port",
        .method = "config.set",
        .params_raw = "{\"key\":\"gateway.port\",\"value\":65535}",
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleConfigSet(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"updated\":true") != null);
    try std.testing.expectEqual(@as(u16, 65535), config.gateway.port);
}

test "handleConfigSet port 1 accepted" {
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
        .request_id = "req-min-port",
        .method = "config.set",
        .params_raw = "{\"key\":\"gateway.port\",\"value\":1}",
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleConfigSet(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"updated\":true") != null);
    try std.testing.expectEqual(@as(u16, 1), config.gateway.port);
}

test "handleConfigSet port over 65535 rejected" {
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
        .request_id = "req-big-port",
        .method = "config.set",
        .params_raw = "{\"key\":\"gateway.port\",\"value\":70000}",
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleConfigSet(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "invalid port value") != null);
    // Config should remain unchanged
    try std.testing.expectEqual(@as(u16, 18789), config.gateway.port);
}

test "handleConfigSet port with non-integer value rejected" {
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

    // value is a string, not an integer - extractJsonInt should fail
    const ctx = handler.HandlerContext{
        .request_id = "req-str-port",
        .method = "config.set",
        .params_raw = "{\"key\":\"gateway.port\",\"value\":\"abc\"}",
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleConfigSet(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "invalid port value") != null);
}

test "handleConfigSet logging level case sensitive" {
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

    // "Debug" with capital D should be rejected (only lowercase accepted)
    const ctx = handler.HandlerContext{
        .request_id = "req-case-level",
        .method = "config.set",
        .params_raw = "{\"key\":\"logging.level\",\"value\":\"Debug\"}",
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleConfigSet(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "invalid log level") != null);
    // Config should remain at default level
    try std.testing.expectEqual(config_schema.LogLevel.info, config.logging.level);
}

test "handleConfigSet logging level empty string rejected" {
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
        .request_id = "req-empty-level",
        .method = "config.set",
        .params_raw = "{\"key\":\"logging.level\",\"value\":\"\"}",
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleConfigSet(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "invalid log level") != null);
}

test "handleConfigGet includes session mainKey" {
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
        .request_id = "req-get-session",
        .method = "config.get",
        .params_raw = null,
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleConfigGet(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"mainKey\":\"main\"") != null);
}

test "handleConfigGet reflects modified config" {
    const allocator = std.testing.allocator;
    var config = config_schema.defaultConfig();
    config.gateway.port = 4444;
    config.logging.level = .debug;

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
        .request_id = "req-get-modified",
        .method = "config.get",
        .params_raw = null,
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleConfigGet(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"port\":4444") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"level\":\"debug\"") != null);
}

test "handleStatusEnhanced reports zero connections and presence" {
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
        .request_id = "req-status-empty",
        .method = "status",
        .params_raw = null,
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleStatusEnhanced(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"connections\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"presence_online\":0") != null);
}

test "handleStatusEnhanced reports multiple connections and presence" {
    const allocator = std.testing.allocator;
    var config = config_schema.defaultConfig();
    var connections = state.ConnectionRegistry.init(allocator);
    defer connections.deinit();
    var presence = state.PresenceTracker.init(allocator);
    defer presence.deinit();
    var svc = createTestServices(&config, &connections, &presence);

    try connections.add("c1", .operator, "cl1", .cli);
    try connections.add("c2", .admin, "cl2", .ui);
    try connections.add("c3", .viewer, "cl3", .webchat);
    try presence.upsert("user:a", "c1");
    try presence.upsert("user:b", "c2");

    test_output_len = 0;
    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    const ctx = handler.HandlerContext{
        .request_id = "req-status-multi",
        .method = "status",
        .params_raw = null,
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleStatusEnhanced(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"connections\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"presence_online\":2") != null);
}

test "handlePresence uses conn_id from client info" {
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
        .conn_id = "my-conn-42",
        .role = .admin,
        .client_id = "client-x",
        .client_mode = .ui,
        .authenticated = true,
    };

    const ctx = handler.HandlerContext{
        .request_id = "req-pres-client",
        .method = "system.presence",
        .params_raw = "{\"presenceKey\":\"user:xyz\"}",
        .client = &client_info,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handlePresence(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"online\":1") != null);
    try std.testing.expect(presence.isOnline("user:xyz"));
}

test "handlePresence without client uses unknown conn_id" {
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

    // client is null, so conn_id defaults to "unknown"
    const ctx = handler.HandlerContext{
        .request_id = "req-pres-no-client",
        .method = "system.presence",
        .params_raw = "{\"presenceKey\":\"user:anon\"}",
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handlePresence(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"online\":1") != null);
    try std.testing.expect(presence.isOnline("user:anon"));
}

test "handlePresence increments version on successive calls" {
    const allocator = std.testing.allocator;
    var config = config_schema.defaultConfig();
    var connections = state.ConnectionRegistry.init(allocator);
    defer connections.deinit();
    var presence = state.PresenceTracker.init(allocator);
    defer presence.deinit();
    var svc = createTestServices(&config, &connections, &presence);

    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    // First presence call
    test_output_len = 0;
    const ctx1 = handler.HandlerContext{
        .request_id = "req-pres-v1",
        .method = "system.presence",
        .params_raw = "{\"presenceKey\":\"user:one\"}",
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handlePresence(&ctx1);

    const output1 = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output1, "\"version\":1") != null);

    // Second presence call with different key
    test_output_len = 0;
    const ctx2 = handler.HandlerContext{
        .request_id = "req-pres-v2",
        .method = "system.presence",
        .params_raw = "{\"presenceKey\":\"user:two\"}",
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handlePresence(&ctx2);

    const output2 = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output2, "\"version\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output2, "\"online\":2") != null);
}

test "extractJsonString first key among many" {
    const json = "{\"a\":\"alpha\",\"b\":\"beta\",\"c\":\"gamma\"}";
    try std.testing.expectEqualStrings("alpha", extractJsonString(json, "a").?);
    try std.testing.expectEqualStrings("beta", extractJsonString(json, "b").?);
    try std.testing.expectEqualStrings("gamma", extractJsonString(json, "c").?);
}

test "extractJsonString with numeric-like string value" {
    const json = "{\"port\":\"8080\"}";
    // This is a string value "8080", not an integer
    try std.testing.expectEqualStrings("8080", extractJsonString(json, "port").?);
}

test "extractJsonInt with whitespace after colon" {
    const json = "{\"count\":   123}";
    try std.testing.expectEqual(@as(i64, 123), extractJsonInt(json, "count").?);
}

test "extractJsonInt only digits after key" {
    // Value followed by comma
    const json = "{\"x\":55,\"y\":66}";
    try std.testing.expectEqual(@as(i64, 55), extractJsonInt(json, "x").?);
    try std.testing.expectEqual(@as(i64, 66), extractJsonInt(json, "y").?);
}

test "extractJsonInt with value at end of json" {
    const json = "{\"val\":999}";
    try std.testing.expectEqual(@as(i64, 999), extractJsonInt(json, "val").?);
}

test "extractJsonString returns null for partial key match" {
    const json = "{\"keyname\":\"val\"}";
    // "key" should NOT match "keyname"
    try std.testing.expect(extractJsonString(json, "key") == null);
}

test "handleConfigGet response is valid JSON structure" {
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
        .request_id = "req-json-check",
        .method = "config.get",
        .params_raw = null,
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleConfigGet(&ctx);

    const output = getTestOutput();
    // Verify the output contains the response envelope with ok:true
    try std.testing.expect(std.mem.indexOf(u8, output, "\"ok\":true") != null);
    // Verify the JSON payload has all three config sections
    try std.testing.expect(std.mem.indexOf(u8, output, "\"gateway\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"logging\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"session\"") != null);
}

test "handleConfigSet port then verify via handleConfigGet" {
    const allocator = std.testing.allocator;
    var config = config_schema.defaultConfig();
    var connections = state.ConnectionRegistry.init(allocator);
    defer connections.deinit();
    var presence = state.PresenceTracker.init(allocator);
    defer presence.deinit();
    var svc = createTestServices(&config, &connections, &presence);

    var resp_buf: [4096]u8 = undefined;
    var writer = createTestWriter();
    writer.buf = &resp_buf;

    // Set port to 3000
    test_output_len = 0;
    const set_ctx = handler.HandlerContext{
        .request_id = "req-set-then-get",
        .method = "config.set",
        .params_raw = "{\"key\":\"gateway.port\",\"value\":3000}",
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleConfigSet(&set_ctx);
    try std.testing.expectEqual(@as(u16, 3000), config.gateway.port);

    // Now get config and verify it reflects the new port
    test_output_len = 0;
    const get_ctx = handler.HandlerContext{
        .request_id = "req-get-after-set",
        .method = "config.get",
        .params_raw = null,
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleConfigGet(&get_ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"port\":3000") != null);
}

test "handleConnectionsList with zero connections" {
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
        .request_id = "req-conn-zero",
        .method = "connections.list",
        .params_raw = null,
        .client = null,
        .respond = &writer,
        .user_data = @ptrCast(&svc),
    };
    handleConnectionsList(&ctx);

    const output = getTestOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"count\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"connections\":[]") != null);
}
