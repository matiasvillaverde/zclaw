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
