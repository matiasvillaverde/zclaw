const std = @import("std");
const schema = @import("protocol/schema.zig");
const auth = @import("protocol/auth.zig");
const handler = @import("protocol/handler.zig");
const state = @import("state.zig");

// --- Gateway Server Config ---

pub const GatewayConfig = struct {
    port: u16 = 18789,
    auth_mode: auth.AuthMode = .none,
    auth_config: auth.AuthConfig = .{},
    tick_interval_ms: u32 = schema.TICK_INTERVAL_MS,
    handshake_timeout_ms: u32 = schema.HANDSHAKE_TIMEOUT_MS,
};

// --- Gateway Context ---

/// Shared context available to all WebSocket connections.
/// Holds the gateway state, method registry, and configuration.
pub const GatewayContext = struct {
    state: *state.GatewayState,
    registry: *handler.MethodRegistry,
    config: GatewayConfig,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        gateway_config: GatewayConfig,
    ) !GatewayContext {
        const gw_state = try allocator.create(state.GatewayState);
        gw_state.* = state.GatewayState.init(allocator, gateway_config.auth_mode, gateway_config.auth_config);

        const registry = try allocator.create(handler.MethodRegistry);
        registry.* = handler.MethodRegistry.init(allocator);

        // Register built-in methods
        try registry.register("health", handler.handleHealth);
        try registry.register("status", handler.handleStatus);

        return .{
            .state = gw_state,
            .registry = registry,
            .config = gateway_config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GatewayContext) void {
        self.registry.deinit();
        self.allocator.destroy(self.registry);
        self.state.deinit();
        self.allocator.destroy(self.state);
    }

    pub fn registerMethod(self: *GatewayContext, method: []const u8, method_handler: handler.MethodHandler) !void {
        try self.registry.register(method, method_handler);
    }
};

// --- Connection Handshake State ---

pub const HandshakeState = enum {
    pending,
    connected,
    failed,
};

/// Per-connection state for the WebSocket protocol
pub const ConnectionState = struct {
    conn_id: [36]u8 = undefined,
    handshake: HandshakeState = .pending,
    challenge_nonce: [36]u8 = undefined,
    client_info: ?handler.ClientInfo = null,
    connected_at_ms: i64 = 0,

    pub fn init() ConnectionState {
        var cs = ConnectionState{};
        cs.connected_at_ms = std.time.milliTimestamp();
        auth.generateNonce(&cs.conn_id);
        auth.generateNonce(&cs.challenge_nonce);
        return cs;
    }

    pub fn isConnected(self: *const ConnectionState) bool {
        return self.handshake == .connected;
    }

    pub fn durationMs(self: *const ConnectionState) i64 {
        return std.time.milliTimestamp() - self.connected_at_ms;
    }
};

// --- Tests ---

test "GatewayConfig defaults" {
    const config = GatewayConfig{};
    try std.testing.expectEqual(@as(u16, 18789), config.port);
    try std.testing.expectEqual(auth.AuthMode.none, config.auth_mode);
    try std.testing.expectEqual(schema.TICK_INTERVAL_MS, config.tick_interval_ms);
    try std.testing.expectEqual(schema.HANDSHAKE_TIMEOUT_MS, config.handshake_timeout_ms);
}

test "GatewayContext init and deinit" {
    const allocator = std.testing.allocator;
    var ctx = try GatewayContext.init(allocator, .{});
    defer ctx.deinit();

    // Built-in methods should be registered
    try std.testing.expect(ctx.registry.get("health") != null);
    try std.testing.expect(ctx.registry.get("status") != null);
    try std.testing.expectEqual(@as(usize, 0), ctx.state.connectionCount());
}

test "GatewayContext with auth" {
    const allocator = std.testing.allocator;
    var ctx = try GatewayContext.init(allocator, .{
        .port = 9999,
        .auth_mode = .token,
        .auth_config = .{ .token = "secret" },
    });
    defer ctx.deinit();

    try std.testing.expectEqual(@as(u16, 9999), ctx.config.port);
    try std.testing.expectEqual(auth.AuthMode.token, ctx.state.auth_mode);
}

test "GatewayContext register custom method" {
    const allocator = std.testing.allocator;
    var ctx = try GatewayContext.init(allocator, .{});
    defer ctx.deinit();

    const custom_handler: handler.MethodHandler = struct {
        fn handle(hctx: *const handler.HandlerContext) void {
            hctx.respond.sendOk(hctx.request_id, "{\"custom\":true}");
        }
    }.handle;

    try ctx.registerMethod("my.custom.method", custom_handler);
    try std.testing.expect(ctx.registry.get("my.custom.method") != null);
}

test "ConnectionState init" {
    const cs = ConnectionState.init();
    try std.testing.expectEqual(HandshakeState.pending, cs.handshake);
    try std.testing.expect(!cs.isConnected());
    try std.testing.expect(cs.durationMs() >= 0);

    // Verify conn_id and nonce are UUID format (hyphens at right positions)
    try std.testing.expectEqual(@as(u8, '-'), cs.conn_id[8]);
    try std.testing.expectEqual(@as(u8, '-'), cs.conn_id[13]);
    try std.testing.expectEqual(@as(u8, '-'), cs.challenge_nonce[8]);
    try std.testing.expectEqual(@as(u8, '-'), cs.challenge_nonce[13]);
}

test "ConnectionState connected" {
    var cs = ConnectionState.init();
    cs.handshake = .connected;
    try std.testing.expect(cs.isConnected());
}

test "ConnectionState unique IDs" {
    const cs1 = ConnectionState.init();
    const cs2 = ConnectionState.init();
    try std.testing.expect(!std.mem.eql(u8, &cs1.conn_id, &cs2.conn_id));
    try std.testing.expect(!std.mem.eql(u8, &cs1.challenge_nonce, &cs2.challenge_nonce));
}

test "Full auth flow simulation" {
    const allocator = std.testing.allocator;
    var ctx = try GatewayContext.init(allocator, .{
        .auth_mode = .token,
        .auth_config = .{ .token = "test-secret" },
    });
    defer ctx.deinit();

    // Simulate connection
    var conn_state = ConnectionState.init();
    try std.testing.expectEqual(HandshakeState.pending, conn_state.handshake);

    // Client sends connect with token
    const result = auth.authenticate(
        .{ .token = "test-secret", .min_protocol = 3, .max_protocol = 3 },
        ctx.state.auth_mode,
        ctx.state.auth_config,
    );
    try std.testing.expect(result.ok);

    // Mark as connected
    conn_state.handshake = .connected;
    conn_state.client_info = .{
        .conn_id = &conn_state.conn_id,
        .role = result.role,
        .client_id = result.client_id,
        .client_mode = result.client_mode,
        .authenticated = true,
    };

    // Add to registry
    try ctx.state.connections.add(&conn_state.conn_id, result.role, result.client_id, result.client_mode);
    try std.testing.expectEqual(@as(usize, 1), ctx.state.connectionCount());

    try std.testing.expect(conn_state.isConnected());
}

// --- New Tests ---

test "GatewayConfig custom tick interval" {
    const config = GatewayConfig{
        .tick_interval_ms = 15_000,
        .handshake_timeout_ms = 5_000,
    };
    try std.testing.expectEqual(@as(u32, 15_000), config.tick_interval_ms);
    try std.testing.expectEqual(@as(u32, 5_000), config.handshake_timeout_ms);
}

test "GatewayConfig with password auth" {
    const config = GatewayConfig{
        .auth_mode = .password,
        .auth_config = .{ .password = "my-pass" },
    };
    try std.testing.expectEqual(auth.AuthMode.password, config.auth_mode);
    try std.testing.expectEqualStrings("my-pass", config.auth_config.password.?);
}

test "GatewayContext registerMethod multiple" {
    const allocator = std.testing.allocator;
    var ctx = try GatewayContext.init(allocator, .{});
    defer ctx.deinit();

    const dummy: handler.MethodHandler = struct {
        fn handle(hctx: *const handler.HandlerContext) void {
            hctx.respond.sendOk(hctx.request_id, null);
        }
    }.handle;

    try ctx.registerMethod("method.a", dummy);
    try ctx.registerMethod("method.b", dummy);
    try ctx.registerMethod("method.c", dummy);

    try std.testing.expect(ctx.registry.get("method.a") != null);
    try std.testing.expect(ctx.registry.get("method.b") != null);
    try std.testing.expect(ctx.registry.get("method.c") != null);
    // 2 built-in + 3 custom
    try std.testing.expectEqual(@as(usize, 5), ctx.registry.methodCount());
}

test "GatewayContext state is accessible" {
    const allocator = std.testing.allocator;
    var ctx = try GatewayContext.init(allocator, .{ .port = 8080 });
    defer ctx.deinit();

    try std.testing.expectEqual(@as(u16, 8080), ctx.config.port);
    try std.testing.expect(ctx.state.uptimeMs() >= 0);
}

test "ConnectionState failed state" {
    var cs = ConnectionState.init();
    cs.handshake = .failed;
    try std.testing.expect(!cs.isConnected());
    try std.testing.expectEqual(HandshakeState.failed, cs.handshake);
}

test "ConnectionState durationMs increases" {
    const cs = ConnectionState.init();
    const d1 = cs.durationMs();
    std.Thread.sleep(1_000_000); // 1ms
    const d2 = cs.durationMs();
    try std.testing.expect(d2 >= d1);
}

test "HandshakeState all variants" {
    try std.testing.expect(HandshakeState.pending != HandshakeState.connected);
    try std.testing.expect(HandshakeState.connected != HandshakeState.failed);
    try std.testing.expect(HandshakeState.pending != HandshakeState.failed);
}

test "ConnectionState connected_at_ms is reasonable" {
    const cs = ConnectionState.init();
    try std.testing.expect(cs.connected_at_ms > 0);
    // Should be close to now
    const now = std.time.milliTimestamp();
    try std.testing.expect(now - cs.connected_at_ms < 1000);
}

test "GatewayContext no auth has none mode" {
    const allocator = std.testing.allocator;
    var ctx = try GatewayContext.init(allocator, .{});
    defer ctx.deinit();

    try std.testing.expectEqual(auth.AuthMode.none, ctx.state.auth_mode);
}

test "GatewayContext built-in health works" {
    const allocator = std.testing.allocator;
    var ctx = try GatewayContext.init(allocator, .{});
    defer ctx.deinit();

    const h = ctx.registry.get("health");
    try std.testing.expect(h != null);
}

test "GatewayContext built-in status works" {
    const allocator = std.testing.allocator;
    var ctx = try GatewayContext.init(allocator, .{});
    defer ctx.deinit();

    const s = ctx.registry.get("status");
    try std.testing.expect(s != null);
}

test "ConnectionState unique nonces per instance" {
    const cs1 = ConnectionState.init();
    const cs2 = ConnectionState.init();
    const cs3 = ConnectionState.init();
    try std.testing.expect(!std.mem.eql(u8, &cs1.challenge_nonce, &cs2.challenge_nonce));
    try std.testing.expect(!std.mem.eql(u8, &cs2.challenge_nonce, &cs3.challenge_nonce));
}

test "GatewayConfig all defaults" {
    const config = GatewayConfig{};
    try std.testing.expectEqual(@as(u16, 18789), config.port);
    try std.testing.expectEqual(auth.AuthMode.none, config.auth_mode);
    try std.testing.expect(config.auth_config.token == null);
    try std.testing.expect(config.auth_config.password == null);
}

test "ConnectionState default handshake is pending" {
    const cs = ConnectionState{};
    try std.testing.expectEqual(HandshakeState.pending, cs.handshake);
}

test "GatewayContext state has zero connections after init" {
    const allocator = std.testing.allocator;
    var ctx = try GatewayContext.init(allocator, .{});
    defer ctx.deinit();

    try std.testing.expectEqual(@as(usize, 0), ctx.state.connectionCount());
    try std.testing.expectEqual(@as(usize, 0), ctx.state.presence.onlineCount());
}

test "GatewayContext token auth stores config in state" {
    const allocator = std.testing.allocator;
    var ctx = try GatewayContext.init(allocator, .{
        .auth_mode = .token,
        .auth_config = .{ .token = "secure-token-123" },
    });
    defer ctx.deinit();

    try std.testing.expectEqual(auth.AuthMode.token, ctx.state.auth_mode);
    try std.testing.expectEqualStrings("secure-token-123", ctx.state.auth_config.token.?);
}
