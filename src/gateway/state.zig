const std = @import("std");
const auth = @import("protocol/auth.zig");
const schema = @import("protocol/schema.zig");

// --- Connection ---

pub const Connection = struct {
    conn_id: []const u8,
    role: auth.ClientRole,
    client_id: ?[]const u8,
    client_mode: ?schema.ClientMode,
    connected_at_ms: i64,
    last_frame_ms: i64,
    authenticated: bool,
    presence_key: ?[]const u8 = null,
};

// --- Connection Registry ---

pub const ConnectionRegistry = struct {
    connections: std.StringHashMapUnmanaged(Connection),
    allocator: std.mem.Allocator,
    mu: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) ConnectionRegistry {
        return .{
            .connections = .{},
            .allocator = allocator,
            .mu = .{},
        };
    }

    pub fn deinit(self: *ConnectionRegistry) void {
        self.mu.lock();
        defer self.mu.unlock();

        // conn_id is shared between key and Connection.conn_id, so only free once via value
        var val_iter = self.connections.valueIterator();
        while (val_iter.next()) |conn| {
            if (conn.client_id) |cid| self.allocator.free(cid);
            if (conn.presence_key) |pk| self.allocator.free(pk);
            self.allocator.free(conn.conn_id);
        }
        self.connections.deinit(self.allocator);
    }

    pub fn add(self: *ConnectionRegistry, conn_id: []const u8, role: auth.ClientRole, client_id: ?[]const u8, client_mode: ?schema.ClientMode) !void {
        self.mu.lock();
        defer self.mu.unlock();

        const now = std.time.milliTimestamp();
        const id_copy = try self.allocator.dupe(u8, conn_id);
        const cid_copy = if (client_id) |cid| try self.allocator.dupe(u8, cid) else null;

        try self.connections.put(self.allocator, id_copy, .{
            .conn_id = id_copy,
            .role = role,
            .client_id = cid_copy,
            .client_mode = client_mode,
            .connected_at_ms = now,
            .last_frame_ms = now,
            .authenticated = true,
            .presence_key = null,
        });
    }

    pub fn remove(self: *ConnectionRegistry, conn_id: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.connections.fetchRemove(conn_id)) |kv| {
            // conn_id is shared between key and value, free once
            if (kv.value.client_id) |cid| self.allocator.free(cid);
            if (kv.value.presence_key) |pk| self.allocator.free(pk);
            self.allocator.free(kv.value.conn_id);
            return true;
        }
        return false;
    }

    pub fn get(self: *ConnectionRegistry, conn_id: []const u8) ?Connection {
        self.mu.lock();
        defer self.mu.unlock();
        return self.connections.get(conn_id);
    }

    pub fn count(self: *ConnectionRegistry) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.connections.count();
    }

    pub fn updateLastFrame(self: *ConnectionRegistry, conn_id: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.connections.getPtr(conn_id)) |conn| {
            conn.last_frame_ms = std.time.milliTimestamp();
        }
    }

    pub fn isAuthenticated(self: *ConnectionRegistry, conn_id: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.connections.get(conn_id)) |conn| {
            return conn.authenticated;
        }
        return false;
    }
};

// --- Presence Tracker ---

pub const PresenceTracker = struct {
    online: std.StringHashMapUnmanaged(PresenceEntry),
    allocator: std.mem.Allocator,
    mu: std.Thread.Mutex,
    version: u64,

    const PresenceEntry = struct {
        conn_id: []const u8,
        updated_ms: i64,
    };

    pub fn init(allocator: std.mem.Allocator) PresenceTracker {
        return .{
            .online = .{},
            .allocator = allocator,
            .mu = .{},
            .version = 0,
        };
    }

    pub fn deinit(self: *PresenceTracker) void {
        self.mu.lock();
        defer self.mu.unlock();

        var iter = self.online.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        var val_iter = self.online.valueIterator();
        while (val_iter.next()) |entry| {
            self.allocator.free(entry.conn_id);
        }
        self.online.deinit(self.allocator);
    }

    pub fn upsert(self: *PresenceTracker, presence_key: []const u8, conn_id: []const u8) !void {
        self.mu.lock();
        defer self.mu.unlock();

        const now = std.time.milliTimestamp();
        if (self.online.getPtr(presence_key)) |entry| {
            self.allocator.free(entry.conn_id);
            entry.conn_id = try self.allocator.dupe(u8, conn_id);
            entry.updated_ms = now;
        } else {
            const key_copy = try self.allocator.dupe(u8, presence_key);
            try self.online.put(self.allocator, key_copy, .{
                .conn_id = try self.allocator.dupe(u8, conn_id),
                .updated_ms = now,
            });
        }
        self.version += 1;
    }

    pub fn removeByConnId(self: *PresenceTracker, conn_id: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();

        // Find key by conn_id (linear scan)
        var iter = self.online.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.conn_id, conn_id)) {
                self.allocator.free(entry.value_ptr.conn_id);
                const key = entry.key_ptr.*;
                self.online.removeByPtr(entry.key_ptr);
                self.allocator.free(key);
                self.version += 1;
                return true;
            }
        }
        return false;
    }

    pub fn isOnline(self: *PresenceTracker, presence_key: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.online.contains(presence_key);
    }

    pub fn onlineCount(self: *PresenceTracker) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.online.count();
    }

    pub fn getVersion(self: *PresenceTracker) u64 {
        self.mu.lock();
        defer self.mu.unlock();
        return self.version;
    }
};

// --- Gateway State ---

pub const GatewayState = struct {
    connections: ConnectionRegistry,
    presence: PresenceTracker,
    rate_limiter: auth.RateLimiter,
    auth_mode: auth.AuthMode,
    auth_config: auth.AuthConfig,
    started_at_ms: i64,

    pub fn init(allocator: std.mem.Allocator, auth_mode: auth.AuthMode, auth_config: auth.AuthConfig) GatewayState {
        return .{
            .connections = ConnectionRegistry.init(allocator),
            .presence = PresenceTracker.init(allocator),
            .rate_limiter = auth.RateLimiter.init(allocator, 5, 60_000),
            .auth_mode = auth_mode,
            .auth_config = auth_config,
            .started_at_ms = std.time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *GatewayState) void {
        self.connections.deinit();
        self.presence.deinit();
        self.rate_limiter.deinit();
    }

    pub fn connectionCount(self: *GatewayState) usize {
        return self.connections.count();
    }

    pub fn uptimeMs(self: *const GatewayState) i64 {
        return std.time.milliTimestamp() - self.started_at_ms;
    }
};

// --- Tests ---

test "ConnectionRegistry add and get" {
    const allocator = std.testing.allocator;
    var registry = ConnectionRegistry.init(allocator);
    defer registry.deinit();

    try registry.add("conn-1", .operator, "client-1", .cli);
    try std.testing.expectEqual(@as(usize, 1), registry.count());

    const conn = registry.get("conn-1").?;
    try std.testing.expectEqualStrings("conn-1", conn.conn_id);
    try std.testing.expectEqual(auth.ClientRole.operator, conn.role);
    try std.testing.expect(conn.authenticated);
}

test "ConnectionRegistry remove" {
    const allocator = std.testing.allocator;
    var registry = ConnectionRegistry.init(allocator);
    defer registry.deinit();

    try registry.add("conn-1", .operator, "client-1", .cli);
    try std.testing.expectEqual(@as(usize, 1), registry.count());

    try std.testing.expect(registry.remove("conn-1"));
    try std.testing.expectEqual(@as(usize, 0), registry.count());

    // Remove non-existent
    try std.testing.expect(!registry.remove("conn-999"));
}

test "ConnectionRegistry isAuthenticated" {
    const allocator = std.testing.allocator;
    var registry = ConnectionRegistry.init(allocator);
    defer registry.deinit();

    try registry.add("conn-1", .admin, null, null);
    try std.testing.expect(registry.isAuthenticated("conn-1"));
    try std.testing.expect(!registry.isAuthenticated("conn-unknown"));
}

test "ConnectionRegistry updateLastFrame" {
    const allocator = std.testing.allocator;
    var registry = ConnectionRegistry.init(allocator);
    defer registry.deinit();

    try registry.add("conn-1", .operator, null, null);
    const before = registry.get("conn-1").?.last_frame_ms;

    // Small delay to ensure timestamp changes
    std.Thread.sleep(1_000_000); // 1ms

    registry.updateLastFrame("conn-1");
    const after = registry.get("conn-1").?.last_frame_ms;
    try std.testing.expect(after >= before);
}

test "ConnectionRegistry multiple connections" {
    const allocator = std.testing.allocator;
    var registry = ConnectionRegistry.init(allocator);
    defer registry.deinit();

    try registry.add("conn-1", .operator, "c1", .cli);
    try registry.add("conn-2", .admin, "c2", .ui);
    try registry.add("conn-3", .viewer, "c3", .webchat);

    try std.testing.expectEqual(@as(usize, 3), registry.count());
    try std.testing.expectEqual(auth.ClientRole.operator, registry.get("conn-1").?.role);
    try std.testing.expectEqual(auth.ClientRole.admin, registry.get("conn-2").?.role);
    try std.testing.expectEqual(auth.ClientRole.viewer, registry.get("conn-3").?.role);
}

test "PresenceTracker upsert and isOnline" {
    const allocator = std.testing.allocator;
    var tracker = PresenceTracker.init(allocator);
    defer tracker.deinit();

    try std.testing.expect(!tracker.isOnline("user:123"));

    try tracker.upsert("user:123", "conn-1");
    try std.testing.expect(tracker.isOnline("user:123"));
    try std.testing.expectEqual(@as(usize, 1), tracker.onlineCount());
}

test "PresenceTracker upsert updates connection" {
    const allocator = std.testing.allocator;
    var tracker = PresenceTracker.init(allocator);
    defer tracker.deinit();

    try tracker.upsert("user:123", "conn-1");
    try std.testing.expectEqual(@as(u64, 1), tracker.getVersion());

    try tracker.upsert("user:123", "conn-2");
    try std.testing.expectEqual(@as(u64, 2), tracker.getVersion());
    try std.testing.expectEqual(@as(usize, 1), tracker.onlineCount());
}

test "PresenceTracker removeByConnId" {
    const allocator = std.testing.allocator;
    var tracker = PresenceTracker.init(allocator);
    defer tracker.deinit();

    try tracker.upsert("user:123", "conn-1");
    try tracker.upsert("user:456", "conn-2");

    try std.testing.expect(tracker.removeByConnId("conn-1"));
    try std.testing.expect(!tracker.isOnline("user:123"));
    try std.testing.expect(tracker.isOnline("user:456"));
    try std.testing.expectEqual(@as(usize, 1), tracker.onlineCount());

    // Remove non-existent
    try std.testing.expect(!tracker.removeByConnId("conn-999"));
}

test "PresenceTracker version increments" {
    const allocator = std.testing.allocator;
    var tracker = PresenceTracker.init(allocator);
    defer tracker.deinit();

    try std.testing.expectEqual(@as(u64, 0), tracker.getVersion());

    try tracker.upsert("user:1", "conn-1");
    try std.testing.expectEqual(@as(u64, 1), tracker.getVersion());

    try tracker.upsert("user:2", "conn-2");
    try std.testing.expectEqual(@as(u64, 2), tracker.getVersion());

    _ = tracker.removeByConnId("conn-1");
    try std.testing.expectEqual(@as(u64, 3), tracker.getVersion());
}

test "GatewayState init and deinit" {
    const allocator = std.testing.allocator;
    var state = GatewayState.init(allocator, .token, .{ .token = "test-token" });
    defer state.deinit();

    try std.testing.expectEqual(@as(usize, 0), state.connectionCount());
    try std.testing.expect(state.uptimeMs() >= 0);
    try std.testing.expectEqual(auth.AuthMode.token, state.auth_mode);
}

test "GatewayState with connections" {
    const allocator = std.testing.allocator;
    var state = GatewayState.init(allocator, .none, .{});
    defer state.deinit();

    try state.connections.add("conn-1", .operator, "c1", .cli);
    try state.connections.add("conn-2", .admin, "c2", .ui);

    try std.testing.expectEqual(@as(usize, 2), state.connectionCount());
}

test "GatewayState with presence" {
    const allocator = std.testing.allocator;
    var state = GatewayState.init(allocator, .none, .{});
    defer state.deinit();

    try state.presence.upsert("user:abc", "conn-1");
    try std.testing.expect(state.presence.isOnline("user:abc"));
}

test "GatewayState rate limiter" {
    const allocator = std.testing.allocator;
    var state = GatewayState.init(allocator, .token, .{ .token = "tok" });
    defer state.deinit();

    try std.testing.expect(state.rate_limiter.check("192.168.1.1"));
    // 5 failures should block
    for (0..5) |_| {
        try state.rate_limiter.recordFailure("192.168.1.1");
    }
    try std.testing.expect(!state.rate_limiter.check("192.168.1.1"));
}

// --- Additional Tests ---

test "Connection struct defaults" {
    const conn = Connection{
        .conn_id = "c1",
        .role = .operator,
        .client_id = null,
        .client_mode = null,
        .connected_at_ms = 1000,
        .last_frame_ms = 1000,
        .authenticated = true,
    };
    try std.testing.expect(conn.presence_key == null);
    try std.testing.expect(conn.authenticated);
}

test "ConnectionRegistry get nonexistent" {
    const allocator = std.testing.allocator;
    var registry = ConnectionRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expect(registry.get("missing") == null);
}

test "ConnectionRegistry isAuthenticated returns false for missing" {
    const allocator = std.testing.allocator;
    var registry = ConnectionRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expect(!registry.isAuthenticated("missing"));
}

test "ConnectionRegistry updateLastFrame nonexistent is safe" {
    const allocator = std.testing.allocator;
    var registry = ConnectionRegistry.init(allocator);
    defer registry.deinit();

    // Should not crash
    registry.updateLastFrame("missing");
}

test "ConnectionRegistry add with null client_id and mode" {
    const allocator = std.testing.allocator;
    var registry = ConnectionRegistry.init(allocator);
    defer registry.deinit();

    try registry.add("conn-1", .viewer, null, null);
    const conn = registry.get("conn-1").?;
    try std.testing.expect(conn.client_id == null);
    try std.testing.expect(conn.client_mode == null);
    try std.testing.expectEqual(auth.ClientRole.viewer, conn.role);
}

test "PresenceTracker init empty" {
    const allocator = std.testing.allocator;
    var tracker = PresenceTracker.init(allocator);
    defer tracker.deinit();

    try std.testing.expectEqual(@as(usize, 0), tracker.onlineCount());
    try std.testing.expectEqual(@as(u64, 0), tracker.getVersion());
}

test "PresenceTracker removeByConnId nonexistent" {
    const allocator = std.testing.allocator;
    var tracker = PresenceTracker.init(allocator);
    defer tracker.deinit();

    try std.testing.expect(!tracker.removeByConnId("missing"));
}

test "PresenceTracker isOnline nonexistent" {
    const allocator = std.testing.allocator;
    var tracker = PresenceTracker.init(allocator);
    defer tracker.deinit();

    try std.testing.expect(!tracker.isOnline("user:missing"));
}

test "PresenceTracker multiple users" {
    const allocator = std.testing.allocator;
    var tracker = PresenceTracker.init(allocator);
    defer tracker.deinit();

    try tracker.upsert("user:1", "conn-a");
    try tracker.upsert("user:2", "conn-b");
    try tracker.upsert("user:3", "conn-c");

    try std.testing.expectEqual(@as(usize, 3), tracker.onlineCount());
    try std.testing.expect(tracker.isOnline("user:1"));
    try std.testing.expect(tracker.isOnline("user:2"));
    try std.testing.expect(tracker.isOnline("user:3"));
}

test "GatewayState uptimeMs positive" {
    const allocator = std.testing.allocator;
    var state = GatewayState.init(allocator, .none, .{});
    defer state.deinit();

    try std.testing.expect(state.uptimeMs() >= 0);
}

test "GatewayState password auth mode" {
    const allocator = std.testing.allocator;
    var state = GatewayState.init(allocator, .password, .{ .password = "secret" });
    defer state.deinit();

    try std.testing.expectEqual(auth.AuthMode.password, state.auth_mode);
    try std.testing.expectEqualStrings("secret", state.auth_config.password.?);
}

test "GatewayState none auth mode" {
    const allocator = std.testing.allocator;
    var state = GatewayState.init(allocator, .none, .{});
    defer state.deinit();

    try std.testing.expectEqual(auth.AuthMode.none, state.auth_mode);
    try std.testing.expect(state.auth_config.token == null);
}

// --- New Tests ---

test "ConnectionRegistry add and remove multiple" {
    const allocator = std.testing.allocator;
    var registry = ConnectionRegistry.init(allocator);
    defer registry.deinit();

    try registry.add("c1", .operator, "client1", .cli);
    try registry.add("c2", .admin, "client2", .ui);
    try registry.add("c3", .viewer, null, .webchat);

    try std.testing.expectEqual(@as(usize, 3), registry.count());

    try std.testing.expect(registry.remove("c2"));
    try std.testing.expectEqual(@as(usize, 2), registry.count());
    try std.testing.expect(registry.get("c2") == null);
    try std.testing.expect(registry.get("c1") != null);
    try std.testing.expect(registry.get("c3") != null);
}

test "ConnectionRegistry count starts at zero" {
    const allocator = std.testing.allocator;
    var registry = ConnectionRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 0), registry.count());
}

test "ConnectionRegistry remove returns false for unknown" {
    const allocator = std.testing.allocator;
    var registry = ConnectionRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expect(!registry.remove("does-not-exist"));
}

test "ConnectionRegistry connection fields preserved" {
    const allocator = std.testing.allocator;
    var registry = ConnectionRegistry.init(allocator);
    defer registry.deinit();

    try registry.add("conn-test", .admin, "my-client", .ui);
    const conn = registry.get("conn-test").?;
    try std.testing.expectEqualStrings("conn-test", conn.conn_id);
    try std.testing.expectEqual(auth.ClientRole.admin, conn.role);
    try std.testing.expectEqualStrings("my-client", conn.client_id.?);
    try std.testing.expectEqual(schema.ClientMode.ui, conn.client_mode.?);
    try std.testing.expect(conn.authenticated);
    try std.testing.expect(conn.connected_at_ms > 0);
    try std.testing.expect(conn.last_frame_ms > 0);
}

test "Connection with presence_key" {
    const conn = Connection{
        .conn_id = "c1",
        .role = .operator,
        .client_id = null,
        .client_mode = null,
        .connected_at_ms = 1000,
        .last_frame_ms = 2000,
        .authenticated = false,
        .presence_key = "user:abc",
    };
    try std.testing.expectEqualStrings("user:abc", conn.presence_key.?);
    try std.testing.expect(!conn.authenticated);
}

test "PresenceTracker version starts at 0" {
    const allocator = std.testing.allocator;
    var tracker = PresenceTracker.init(allocator);
    defer tracker.deinit();

    try std.testing.expectEqual(@as(u64, 0), tracker.getVersion());
}

test "PresenceTracker upsert same key increments version each time" {
    const allocator = std.testing.allocator;
    var tracker = PresenceTracker.init(allocator);
    defer tracker.deinit();

    try tracker.upsert("user:1", "conn-a");
    try std.testing.expectEqual(@as(u64, 1), tracker.getVersion());
    try tracker.upsert("user:1", "conn-b");
    try std.testing.expectEqual(@as(u64, 2), tracker.getVersion());
    try tracker.upsert("user:1", "conn-c");
    try std.testing.expectEqual(@as(u64, 3), tracker.getVersion());
    // Only 1 user online despite 3 upserts
    try std.testing.expectEqual(@as(usize, 1), tracker.onlineCount());
}

test "PresenceTracker removeByConnId reduces count" {
    const allocator = std.testing.allocator;
    var tracker = PresenceTracker.init(allocator);
    defer tracker.deinit();

    try tracker.upsert("user:a", "conn-1");
    try tracker.upsert("user:b", "conn-2");
    try tracker.upsert("user:c", "conn-3");
    try std.testing.expectEqual(@as(usize, 3), tracker.onlineCount());

    try std.testing.expect(tracker.removeByConnId("conn-2"));
    try std.testing.expectEqual(@as(usize, 2), tracker.onlineCount());
    try std.testing.expect(!tracker.isOnline("user:b"));
}

test "GatewayState started_at_ms is recent" {
    const allocator = std.testing.allocator;
    const before = std.time.milliTimestamp();
    var gw_state = GatewayState.init(allocator, .none, .{});
    defer gw_state.deinit();
    const after = std.time.milliTimestamp();

    try std.testing.expect(gw_state.started_at_ms >= before);
    try std.testing.expect(gw_state.started_at_ms <= after);
}

test "GatewayState connectionCount reflects registry" {
    const allocator = std.testing.allocator;
    var gw_state = GatewayState.init(allocator, .none, .{});
    defer gw_state.deinit();

    try gw_state.connections.add("c1", .operator, null, null);
    try std.testing.expectEqual(@as(usize, 1), gw_state.connectionCount());
    try gw_state.connections.add("c2", .admin, null, null);
    try std.testing.expectEqual(@as(usize, 2), gw_state.connectionCount());
    _ = gw_state.connections.remove("c1");
    try std.testing.expectEqual(@as(usize, 1), gw_state.connectionCount());
}

test "GatewayState token auth config preserved" {
    const allocator = std.testing.allocator;
    var gw_state = GatewayState.init(allocator, .token, .{ .token = "my-secret-token" });
    defer gw_state.deinit();

    try std.testing.expectEqual(auth.AuthMode.token, gw_state.auth_mode);
    try std.testing.expectEqualStrings("my-secret-token", gw_state.auth_config.token.?);
}

test "ConnectionRegistry add then remove then re-add same conn_id" {
    const allocator = std.testing.allocator;
    var registry = ConnectionRegistry.init(allocator);
    defer registry.deinit();

    try registry.add("conn-1", .operator, "client-a", .cli);
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expectEqual(auth.ClientRole.operator, registry.get("conn-1").?.role);

    // Remove first, then re-add
    try std.testing.expect(registry.remove("conn-1"));
    try std.testing.expectEqual(@as(usize, 0), registry.count());

    try registry.add("conn-1", .admin, "client-b", .ui);
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expectEqual(auth.ClientRole.admin, registry.get("conn-1").?.role);
}

test "PresenceTracker remove all and readd" {
    const allocator = std.testing.allocator;
    var tracker = PresenceTracker.init(allocator);
    defer tracker.deinit();

    try tracker.upsert("u1", "c1");
    try tracker.upsert("u2", "c2");
    _ = tracker.removeByConnId("c1");
    _ = tracker.removeByConnId("c2");
    try std.testing.expectEqual(@as(usize, 0), tracker.onlineCount());

    try tracker.upsert("u3", "c3");
    try std.testing.expectEqual(@as(usize, 1), tracker.onlineCount());
    try std.testing.expect(tracker.isOnline("u3"));
}

test "ConnectionRegistry empty deinit is safe" {
    const allocator = std.testing.allocator;
    var registry = ConnectionRegistry.init(allocator);
    registry.deinit();
}

test "PresenceTracker empty deinit is safe" {
    const allocator = std.testing.allocator;
    var tracker = PresenceTracker.init(allocator);
    tracker.deinit();
}

test "GatewayState deinit after adding connections" {
    const allocator = std.testing.allocator;
    var gw_state = GatewayState.init(allocator, .none, .{});
    try gw_state.connections.add("c1", .operator, "client1", .cli);
    try gw_state.presence.upsert("user:1", "c1");
    gw_state.deinit();
}
