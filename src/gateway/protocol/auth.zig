const std = @import("std");
const schema = @import("schema.zig");

// --- Auth Modes ---

pub const AuthMode = enum {
    none,
    token,
    password,

    pub fn label(self: AuthMode) []const u8 {
        return switch (self) {
            .none => "none",
            .token => "token",
            .password => "password",
        };
    }

    pub fn fromString(s: []const u8) ?AuthMode {
        const map = std.StaticStringMap(AuthMode).initComptime(.{
            .{ "none", .none },
            .{ "token", .token },
            .{ "password", .password },
        });
        return map.get(s);
    }
};

// --- Client Role ---

pub const ClientRole = enum {
    viewer,
    operator,
    admin,

    pub fn label(self: ClientRole) []const u8 {
        return switch (self) {
            .viewer => "viewer",
            .operator => "operator",
            .admin => "admin",
        };
    }

    pub fn fromString(s: []const u8) ?ClientRole {
        const map = std.StaticStringMap(ClientRole).initComptime(.{
            .{ "viewer", .viewer },
            .{ "operator", .operator },
            .{ "admin", .admin },
        });
        return map.get(s);
    }

    pub fn canAccessMethod(self: ClientRole, method: []const u8) bool {
        // Viewers can only access read-only methods
        if (self == .viewer) {
            return isReadOnlyMethod(method);
        }
        // Admin-only methods
        if (isAdminMethod(method)) {
            return self == .admin;
        }
        // Operators and admins can access everything else
        return true;
    }
};

fn isReadOnlyMethod(method: []const u8) bool {
    const read_methods = std.StaticStringMap(void).initComptime(.{
        .{ "health", {} },
        .{ "status", {} },
        .{ "config.get", {} },
        .{ "sessions.list", {} },
        .{ "sessions.preview", {} },
        .{ "channels.status", {} },
        .{ "models.list", {} },
        .{ "tools.catalog", {} },
        .{ "cron.list", {} },
        .{ "cron.status", {} },
        .{ "usage.status", {} },
        .{ "usage.cost", {} },
        .{ "agent", {} },
        .{ "agents.list", {} },
        .{ "chat.history", {} },
    });
    return read_methods.has(method);
}

fn isAdminMethod(method: []const u8) bool {
    const admin_methods = std.StaticStringMap(void).initComptime(.{
        .{ "config.set", {} },
        .{ "config.apply", {} },
        .{ "config.patch", {} },
        .{ "agents.create", {} },
        .{ "agents.update", {} },
        .{ "agents.delete", {} },
        .{ "device.pair.approve", {} },
        .{ "device.pair.reject", {} },
        .{ "device.pair.remove", {} },
        .{ "device.token.rotate", {} },
        .{ "device.token.revoke", {} },
    });
    return admin_methods.has(method);
}

// --- Auth Rate Limiter ---

pub const RateLimiter = struct {
    attempts: std.StringHashMapUnmanaged(AttemptEntry),
    allocator: std.mem.Allocator,
    max_attempts: u32,
    window_ms: i64,

    const AttemptEntry = struct {
        count: u32,
        first_attempt_ms: i64,
    };

    pub fn init(allocator: std.mem.Allocator, max_attempts: u32, window_ms: i64) RateLimiter {
        return .{
            .attempts = .{},
            .allocator = allocator,
            .max_attempts = max_attempts,
            .window_ms = window_ms,
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        var iter = self.attempts.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.attempts.deinit(self.allocator);
    }

    pub fn check(self: *RateLimiter, key: []const u8) bool {
        const now = std.time.milliTimestamp();
        if (self.attempts.get(key)) |entry| {
            // Reset if outside window
            if (now - entry.first_attempt_ms > self.window_ms) {
                return true;
            }
            return entry.count < self.max_attempts;
        }
        return true;
    }

    pub fn recordFailure(self: *RateLimiter, key: []const u8) !void {
        const now = std.time.milliTimestamp();
        if (self.attempts.getPtr(key)) |entry| {
            if (now - entry.first_attempt_ms > self.window_ms) {
                entry.* = .{ .count = 1, .first_attempt_ms = now };
            } else {
                entry.count += 1;
            }
        } else {
            const key_copy = try self.allocator.dupe(u8, key);
            try self.attempts.put(self.allocator, key_copy, .{
                .count = 1,
                .first_attempt_ms = now,
            });
        }
    }

    pub fn reset(self: *RateLimiter, key: []const u8) void {
        if (self.attempts.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
        }
    }
};

// --- Challenge-Response Auth ---

pub const ChallengeState = struct {
    nonce: [36]u8,
    created_ms: i64,
    timeout_ms: u32,

    pub fn isExpired(self: *const ChallengeState) bool {
        const now = std.time.milliTimestamp();
        return (now - self.created_ms) > @as(i64, self.timeout_ms);
    }
};

/// Generate a random nonce (UUID v4 format)
pub fn generateNonce(buf: *[36]u8) void {
    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    // UUID v4 format
    random_bytes[6] = (random_bytes[6] & 0x0f) | 0x40; // version 4
    random_bytes[8] = (random_bytes[8] & 0x3f) | 0x80; // variant 1

    _ = std.fmt.bufPrint(buf, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        random_bytes[0],  random_bytes[1],  random_bytes[2],  random_bytes[3],
        random_bytes[4],  random_bytes[5],
        random_bytes[6],  random_bytes[7],
        random_bytes[8],  random_bytes[9],
        random_bytes[10], random_bytes[11], random_bytes[12], random_bytes[13], random_bytes[14], random_bytes[15],
    }) catch {};
}

/// Validate token auth: constant-time comparison
pub fn validateToken(provided: []const u8, expected: []const u8) bool {
    if (provided.len != expected.len) return false;
    return safeEqual(provided, expected);
}

/// Validate password auth: constant-time comparison
pub fn validatePassword(provided: []const u8, expected: []const u8) bool {
    if (provided.len != expected.len) return false;
    return safeEqual(provided, expected);
}

/// Constant-time string comparison (prevents timing attacks)
fn safeEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var result: u8 = 0;
    for (a, b) |ca, cb| {
        result |= ca ^ cb;
    }
    return result == 0;
}

/// Validate protocol version from connect params
pub fn validateProtocolVersion(min_protocol: ?u32, max_protocol: ?u32) bool {
    const version = schema.PROTOCOL_VERSION;
    if (min_protocol) |min| {
        if (min > version) return false;
    }
    if (max_protocol) |max| {
        if (max < version) return false;
    }
    return true;
}

// --- Connect Parameters ---

pub const ConnectParams = struct {
    protocol_version: ?u32 = null,
    min_protocol: ?u32 = null,
    max_protocol: ?u32 = null,
    client_id: ?[]const u8 = null,
    client_mode: ?schema.ClientMode = null,
    role: ?ClientRole = null,
    token: ?[]const u8 = null,
    password: ?[]const u8 = null,
    nonce: ?[]const u8 = null,
};

pub const AuthResult = struct {
    ok: bool,
    error_code: ?schema.ErrorCode = null,
    error_message: ?[]const u8 = null,
    role: ClientRole = .operator,
    client_id: ?[]const u8 = null,
    client_mode: ?schema.ClientMode = null,
};

/// Authenticate a connect request
pub fn authenticate(params: ConnectParams, auth_mode: AuthMode, config: AuthConfig) AuthResult {
    // Validate protocol version
    if (!validateProtocolVersion(params.min_protocol, params.max_protocol)) {
        return .{
            .ok = false,
            .error_code = .invalid_request,
            .error_message = "protocol version mismatch",
        };
    }

    // Check auth based on mode
    switch (auth_mode) {
        .none => {},
        .token => {
            const provided = params.token orelse return .{
                .ok = false,
                .error_code = .unauthorized,
                .error_message = "token required",
            };
            const expected = config.token orelse return .{
                .ok = false,
                .error_code = .internal,
                .error_message = "token not configured",
            };
            if (!validateToken(provided, expected)) {
                return .{
                    .ok = false,
                    .error_code = .unauthorized,
                    .error_message = "invalid token",
                };
            }
        },
        .password => {
            const provided = params.password orelse return .{
                .ok = false,
                .error_code = .unauthorized,
                .error_message = "password required",
            };
            const expected = config.password orelse return .{
                .ok = false,
                .error_code = .internal,
                .error_message = "password not configured",
            };
            if (!validatePassword(provided, expected)) {
                return .{
                    .ok = false,
                    .error_code = .unauthorized,
                    .error_message = "invalid password",
                };
            }
        },
    }

    return .{
        .ok = true,
        .role = params.role orelse .operator,
        .client_id = params.client_id,
        .client_mode = params.client_mode,
    };
}

pub const AuthConfig = struct {
    token: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

// --- Tests ---

test "AuthMode.label" {
    try std.testing.expectEqualStrings("none", AuthMode.none.label());
    try std.testing.expectEqualStrings("token", AuthMode.token.label());
    try std.testing.expectEqualStrings("password", AuthMode.password.label());
}

test "AuthMode.fromString" {
    try std.testing.expectEqual(AuthMode.none, AuthMode.fromString("none").?);
    try std.testing.expectEqual(AuthMode.token, AuthMode.fromString("token").?);
    try std.testing.expectEqual(AuthMode.password, AuthMode.fromString("password").?);
    try std.testing.expectEqual(@as(?AuthMode, null), AuthMode.fromString("unknown"));
}

test "ClientRole.label" {
    try std.testing.expectEqualStrings("viewer", ClientRole.viewer.label());
    try std.testing.expectEqualStrings("operator", ClientRole.operator.label());
    try std.testing.expectEqualStrings("admin", ClientRole.admin.label());
}

test "ClientRole.fromString" {
    try std.testing.expectEqual(ClientRole.viewer, ClientRole.fromString("viewer").?);
    try std.testing.expectEqual(ClientRole.operator, ClientRole.fromString("operator").?);
    try std.testing.expectEqual(ClientRole.admin, ClientRole.fromString("admin").?);
    try std.testing.expectEqual(@as(?ClientRole, null), ClientRole.fromString("unknown"));
}

test "ClientRole authorization" {
    // Viewer can only access read-only methods
    try std.testing.expect(ClientRole.viewer.canAccessMethod("health"));
    try std.testing.expect(ClientRole.viewer.canAccessMethod("status"));
    try std.testing.expect(ClientRole.viewer.canAccessMethod("config.get"));
    try std.testing.expect(!ClientRole.viewer.canAccessMethod("config.set"));
    try std.testing.expect(!ClientRole.viewer.canAccessMethod("chat.send"));

    // Operator can access non-admin methods
    try std.testing.expect(ClientRole.operator.canAccessMethod("health"));
    try std.testing.expect(ClientRole.operator.canAccessMethod("chat.send"));
    try std.testing.expect(!ClientRole.operator.canAccessMethod("config.set"));
    try std.testing.expect(!ClientRole.operator.canAccessMethod("agents.delete"));

    // Admin can access everything
    try std.testing.expect(ClientRole.admin.canAccessMethod("health"));
    try std.testing.expect(ClientRole.admin.canAccessMethod("chat.send"));
    try std.testing.expect(ClientRole.admin.canAccessMethod("config.set"));
    try std.testing.expect(ClientRole.admin.canAccessMethod("agents.delete"));
}

test "safeEqual" {
    try std.testing.expect(safeEqual("abc", "abc"));
    try std.testing.expect(!safeEqual("abc", "abd"));
    try std.testing.expect(!safeEqual("abc", "ab"));
    try std.testing.expect(safeEqual("", ""));
}

test "validateToken" {
    try std.testing.expect(validateToken("my-secret-token", "my-secret-token"));
    try std.testing.expect(!validateToken("wrong-token", "my-secret-token"));
    try std.testing.expect(!validateToken("short", "my-secret-token"));
}

test "validatePassword" {
    try std.testing.expect(validatePassword("correct-pass", "correct-pass"));
    try std.testing.expect(!validatePassword("wrong-pass!!", "correct-pass"));
}

test "validateProtocolVersion" {
    // No constraints
    try std.testing.expect(validateProtocolVersion(null, null));

    // Matching version
    try std.testing.expect(validateProtocolVersion(3, 3));

    // Range includes version
    try std.testing.expect(validateProtocolVersion(1, 5));
    try std.testing.expect(validateProtocolVersion(3, 3));

    // Version too low for min
    try std.testing.expect(!validateProtocolVersion(4, 5));

    // Version too high for max
    try std.testing.expect(!validateProtocolVersion(1, 2));
}

test "generateNonce produces UUID format" {
    var nonce: [36]u8 = undefined;
    generateNonce(&nonce);

    // UUID format: 8-4-4-4-12 with hyphens at positions 8, 13, 18, 23
    try std.testing.expectEqual(@as(u8, '-'), nonce[8]);
    try std.testing.expectEqual(@as(u8, '-'), nonce[13]);
    try std.testing.expectEqual(@as(u8, '-'), nonce[18]);
    try std.testing.expectEqual(@as(u8, '-'), nonce[23]);

    // Verify it's all hex characters + hyphens
    for (nonce, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            try std.testing.expectEqual(@as(u8, '-'), c);
        } else {
            try std.testing.expect(std.ascii.isHex(c));
        }
    }
}

test "generateNonce produces different values" {
    var nonce1: [36]u8 = undefined;
    var nonce2: [36]u8 = undefined;
    generateNonce(&nonce1);
    generateNonce(&nonce2);
    try std.testing.expect(!std.mem.eql(u8, &nonce1, &nonce2));
}

test "ChallengeState.isExpired" {
    const state = ChallengeState{
        .nonce = [_]u8{0} ** 36,
        .created_ms = std.time.milliTimestamp() - 20_000,
        .timeout_ms = 10_000,
    };
    try std.testing.expect(state.isExpired());

    const fresh = ChallengeState{
        .nonce = [_]u8{0} ** 36,
        .created_ms = std.time.milliTimestamp(),
        .timeout_ms = 10_000,
    };
    try std.testing.expect(!fresh.isExpired());
}

test "authenticate with no auth" {
    const result = authenticate(.{}, .none, .{});
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(ClientRole.operator, result.role);
}

test "authenticate with token - success" {
    const result = authenticate(
        .{ .token = "my-token", .role = .admin },
        .token,
        .{ .token = "my-token" },
    );
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(ClientRole.admin, result.role);
}

test "authenticate with token - failure" {
    const result = authenticate(
        .{ .token = "wrong!!!" },
        .token,
        .{ .token = "my-token" },
    );
    try std.testing.expect(!result.ok);
    try std.testing.expectEqual(schema.ErrorCode.unauthorized, result.error_code.?);
}

test "authenticate with token - missing" {
    const result = authenticate(
        .{},
        .token,
        .{ .token = "my-token" },
    );
    try std.testing.expect(!result.ok);
    try std.testing.expectEqual(schema.ErrorCode.unauthorized, result.error_code.?);
}

test "authenticate with password - success" {
    const result = authenticate(
        .{ .password = "secret123" },
        .password,
        .{ .password = "secret123" },
    );
    try std.testing.expect(result.ok);
}

test "authenticate with password - failure" {
    const result = authenticate(
        .{ .password = "wrong1234" },
        .password,
        .{ .password = "secret123" },
    );
    try std.testing.expect(!result.ok);
    try std.testing.expectEqual(schema.ErrorCode.unauthorized, result.error_code.?);
}

test "authenticate protocol version mismatch" {
    const result = authenticate(
        .{ .min_protocol = 5, .max_protocol = 6 },
        .none,
        .{},
    );
    try std.testing.expect(!result.ok);
    try std.testing.expectEqual(schema.ErrorCode.invalid_request, result.error_code.?);
}

test "authenticate token not configured" {
    const result = authenticate(
        .{ .token = "some-token" },
        .token,
        .{},
    );
    try std.testing.expect(!result.ok);
    try std.testing.expectEqual(schema.ErrorCode.internal, result.error_code.?);
}

test "RateLimiter basic flow" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator, 3, 60_000);
    defer limiter.deinit();

    const key = "192.168.1.1";

    // Should be allowed initially
    try std.testing.expect(limiter.check(key));

    // Record failures
    try limiter.recordFailure(key);
    try std.testing.expect(limiter.check(key));
    try limiter.recordFailure(key);
    try std.testing.expect(limiter.check(key));
    try limiter.recordFailure(key);

    // Should be blocked after max attempts
    try std.testing.expect(!limiter.check(key));

    // Reset should clear
    limiter.reset(key);
    try std.testing.expect(limiter.check(key));
}

test "RateLimiter different keys" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator, 1, 60_000);
    defer limiter.deinit();

    try limiter.recordFailure("ip-1");
    try std.testing.expect(!limiter.check("ip-1"));
    try std.testing.expect(limiter.check("ip-2")); // Different key still allowed
}
