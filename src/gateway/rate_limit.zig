const std = @import("std");

// --- Sliding Window Rate Limiter ---
//
// In-memory sliding-window rate limiter for gateway authentication attempts.
// Tracks failed auth attempts by {scope, clientIp}. Supports configurable
// quotas, lockout durations, burst allowance, and loopback exemption.

pub const Scope = enum {
    default,
    shared_secret,
    device_token,
    hook_auth,

    pub fn label(self: Scope) []const u8 {
        return switch (self) {
            .default => "default",
            .shared_secret => "shared-secret",
            .device_token => "device-token",
            .hook_auth => "hook-auth",
        };
    }

    pub fn fromString(s: []const u8) ?Scope {
        const map = std.StaticStringMap(Scope).initComptime(.{
            .{ "default", .default },
            .{ "shared-secret", .shared_secret },
            .{ "device-token", .device_token },
            .{ "hook-auth", .hook_auth },
        });
        return map.get(s);
    }
};

pub const Config = struct {
    /// Maximum failed attempts before blocking.
    max_attempts: u32 = 10,
    /// Sliding window duration in milliseconds.
    window_ms: i64 = 60_000,
    /// Lockout duration in milliseconds after the limit is exceeded.
    lockout_ms: i64 = 300_000,
    /// Exempt loopback (localhost) addresses from rate limiting.
    exempt_loopback: bool = true,
    /// Burst allowance: extra attempts allowed in a short burst window.
    burst_allowance: u32 = 0,
    /// Burst window in milliseconds (subset of window_ms).
    burst_window_ms: i64 = 5_000,
};

pub const CheckResult = struct {
    /// Whether the request is allowed to proceed.
    allowed: bool,
    /// Number of remaining attempts before the limit is reached.
    remaining: u32,
    /// Milliseconds until the lockout expires (0 when not locked).
    retry_after_ms: i64,
};

const Entry = struct {
    /// Timestamps (epoch ms) of recent failed attempts inside the window.
    attempts: std.ArrayListUnmanaged(i64),
    /// If set (> 0), requests are blocked until this epoch-ms instant.
    locked_until: i64,

    fn init() Entry {
        return .{
            .attempts = .empty,
            .locked_until = 0,
        };
    }

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        self.attempts.deinit(allocator);
    }

    /// Remove attempts that fell outside the window.
    fn slideWindow(self: *Entry, now: i64, window_ms: i64) void {
        const cutoff = now - window_ms;
        var write_idx: usize = 0;
        for (self.attempts.items) |ts| {
            if (ts > cutoff) {
                self.attempts.items[write_idx] = ts;
                write_idx += 1;
            }
        }
        self.attempts.items.len = write_idx;
    }

    /// Count attempts within a recent sub-window (for burst detection).
    fn countInWindow(self: *const Entry, now: i64, window_ms: i64) u32 {
        const cutoff = now - window_ms;
        var count: u32 = 0;
        for (self.attempts.items) |ts| {
            if (ts > cutoff) {
                count += 1;
            }
        }
        return count;
    }
};

pub const SlidingWindowLimiter = struct {
    entries: std.StringHashMapUnmanaged(Entry),
    allocator: std.mem.Allocator,
    config: Config,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) SlidingWindowLimiter {
        return .{
            .entries = .empty,
            .allocator = allocator,
            .config = cfg,
        };
    }

    pub fn deinit(self: *SlidingWindowLimiter) void {
        var iter = self.entries.iterator();
        while (iter.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            kv.value_ptr.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
    }

    /// Build a composite key from scope + IP.
    fn resolveKey(self: *SlidingWindowLimiter, ip: []const u8, scope: Scope) ![]u8 {
        const scope_label = scope.label();
        const key = try self.allocator.alloc(u8, scope_label.len + 1 + ip.len);
        @memcpy(key[0..scope_label.len], scope_label);
        key[scope_label.len] = ':';
        @memcpy(key[scope_label.len + 1 ..], ip);
        return key;
    }

    /// Check if an IP is a loopback address.
    fn isLoopback(ip: []const u8) bool {
        if (std.mem.eql(u8, ip, "127.0.0.1")) return true;
        if (std.mem.eql(u8, ip, "::1")) return true;
        if (std.mem.eql(u8, ip, "localhost")) return true;
        // IPv4-mapped IPv6 loopback
        if (std.mem.eql(u8, ip, "::ffff:127.0.0.1")) return true;
        return false;
    }

    /// Effective max attempts including burst allowance.
    fn effectiveMax(self: *const SlidingWindowLimiter) u32 {
        return self.config.max_attempts + self.config.burst_allowance;
    }

    /// Check whether an IP is currently allowed to attempt authentication.
    pub fn check(self: *SlidingWindowLimiter, ip: []const u8, scope: Scope) CheckResult {
        return self.checkAt(ip, scope, std.time.milliTimestamp());
    }

    /// Check at a specific timestamp (for testing).
    pub fn checkAt(self: *SlidingWindowLimiter, ip: []const u8, scope: Scope, now: i64) CheckResult {
        if (self.config.exempt_loopback and isLoopback(ip)) {
            return .{ .allowed = true, .remaining = self.effectiveMax(), .retry_after_ms = 0 };
        }

        // Build lookup key on the stack (not allocated)
        const scope_label = scope.label();
        var key_buf: [256]u8 = undefined;
        if (scope_label.len + 1 + ip.len > key_buf.len) {
            return .{ .allowed = true, .remaining = self.effectiveMax(), .retry_after_ms = 0 };
        }
        @memcpy(key_buf[0..scope_label.len], scope_label);
        key_buf[scope_label.len] = ':';
        @memcpy(key_buf[scope_label.len + 1 .. scope_label.len + 1 + ip.len], ip);
        const lookup_key = key_buf[0 .. scope_label.len + 1 + ip.len];

        const entry_ptr = self.entries.getPtr(lookup_key) orelse {
            return .{ .allowed = true, .remaining = self.effectiveMax(), .retry_after_ms = 0 };
        };

        // Still locked out?
        if (entry_ptr.locked_until > 0 and now < entry_ptr.locked_until) {
            return .{
                .allowed = false,
                .remaining = 0,
                .retry_after_ms = entry_ptr.locked_until - now,
            };
        }

        // Lockout expired -- clear it.
        if (entry_ptr.locked_until > 0 and now >= entry_ptr.locked_until) {
            entry_ptr.locked_until = 0;
            entry_ptr.attempts.items.len = 0;
        }

        entry_ptr.slideWindow(now, self.config.window_ms);
        const max = self.effectiveMax();
        const count: u32 = @intCast(entry_ptr.attempts.items.len);
        const remaining = if (count >= max) 0 else max - count;
        return .{
            .allowed = remaining > 0,
            .remaining = remaining,
            .retry_after_ms = 0,
        };
    }

    /// Record a failed authentication attempt.
    pub fn recordFailure(self: *SlidingWindowLimiter, ip: []const u8, scope: Scope) !void {
        return self.recordFailureAt(ip, scope, std.time.milliTimestamp());
    }

    /// Record a failure at a specific timestamp (for testing).
    pub fn recordFailureAt(self: *SlidingWindowLimiter, ip: []const u8, scope: Scope, now: i64) !void {
        if (self.config.exempt_loopback and isLoopback(ip)) {
            return;
        }

        const scope_label = scope.label();
        var key_buf: [256]u8 = undefined;
        if (scope_label.len + 1 + ip.len > key_buf.len) return;
        @memcpy(key_buf[0..scope_label.len], scope_label);
        key_buf[scope_label.len] = ':';
        @memcpy(key_buf[scope_label.len + 1 .. scope_label.len + 1 + ip.len], ip);
        const lookup_key = key_buf[0 .. scope_label.len + 1 + ip.len];

        if (self.entries.getPtr(lookup_key)) |entry_ptr| {
            // If currently locked, do nothing (already blocked).
            if (entry_ptr.locked_until > 0 and now < entry_ptr.locked_until) {
                return;
            }

            entry_ptr.slideWindow(now, self.config.window_ms);
            try entry_ptr.attempts.append(self.allocator, now);

            if (entry_ptr.attempts.items.len >= self.effectiveMax()) {
                entry_ptr.locked_until = now + self.config.lockout_ms;
            }
        } else {
            const key_copy = try self.resolveKey(ip, scope);
            var entry = Entry.init();
            try entry.attempts.append(self.allocator, now);

            if (entry.attempts.items.len >= self.effectiveMax()) {
                entry.locked_until = now + self.config.lockout_ms;
            }

            try self.entries.put(self.allocator, key_copy, entry);
        }
    }

    /// Reset the rate-limit state for an IP.
    pub fn reset(self: *SlidingWindowLimiter, ip: []const u8, scope: Scope) void {
        const scope_label = scope.label();
        var key_buf: [256]u8 = undefined;
        if (scope_label.len + 1 + ip.len > key_buf.len) return;
        @memcpy(key_buf[0..scope_label.len], scope_label);
        key_buf[scope_label.len] = ':';
        @memcpy(key_buf[scope_label.len + 1 .. scope_label.len + 1 + ip.len], ip);
        const lookup_key = key_buf[0 .. scope_label.len + 1 + ip.len];

        if (self.entries.fetchRemove(lookup_key)) |kv| {
            self.allocator.free(kv.key);
            var entry = kv.value;
            entry.deinit(self.allocator);
        }
    }

    /// Return the current number of tracked entries.
    pub fn size(self: *const SlidingWindowLimiter) u32 {
        return self.entries.count();
    }

    /// Remove expired entries and release memory.
    pub fn prune(self: *SlidingWindowLimiter) void {
        self.pruneAt(std.time.milliTimestamp());
    }

    /// Prune at a specific timestamp (for testing).
    pub fn pruneAt(self: *SlidingWindowLimiter, now: i64) void {
        // Collect keys to remove (can't modify during iteration)
        var to_remove: [64][]const u8 = undefined;
        var remove_count: usize = 0;

        var iter = self.entries.iterator();
        while (iter.next()) |kv| {
            // If locked out, keep until lockout expires.
            if (kv.value_ptr.locked_until > 0 and now < kv.value_ptr.locked_until) {
                continue;
            }
            kv.value_ptr.slideWindow(now, self.config.window_ms);
            if (kv.value_ptr.attempts.items.len == 0) {
                if (remove_count < to_remove.len) {
                    to_remove[remove_count] = kv.key_ptr.*;
                    remove_count += 1;
                }
            }
        }

        for (to_remove[0..remove_count]) |key| {
            if (self.entries.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                var entry = kv.value;
                entry.deinit(self.allocator);
            }
        }
    }

    /// Clear all entries.
    pub fn clear(self: *SlidingWindowLimiter) void {
        var iter = self.entries.iterator();
        while (iter.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            kv.value_ptr.deinit(self.allocator);
        }
        self.entries.clearAndFree(self.allocator);
    }
};

// --- Fixed Window Rate Limiter ---

pub const FixedWindowLimiter = struct {
    max_requests: u32,
    window_ms: i64,
    count: u32,
    window_start_ms: i64,

    pub fn init(max_requests: u32, window_ms: i64) FixedWindowLimiter {
        return .{
            .max_requests = @max(1, max_requests),
            .window_ms = @max(1, window_ms),
            .count = 0,
            .window_start_ms = 0,
        };
    }

    pub fn consume(self: *FixedWindowLimiter) CheckResult {
        return self.consumeAt(std.time.milliTimestamp());
    }

    pub fn consumeAt(self: *FixedWindowLimiter, now: i64) CheckResult {
        if (now - self.window_start_ms >= self.window_ms) {
            self.window_start_ms = now;
            self.count = 0;
        }
        if (self.count >= self.max_requests) {
            return .{
                .allowed = false,
                .retry_after_ms = @max(0, self.window_start_ms + self.window_ms - now),
                .remaining = 0,
            };
        }
        self.count += 1;
        const remaining = if (self.count >= self.max_requests) 0 else self.max_requests - self.count;
        return .{
            .allowed = true,
            .retry_after_ms = 0,
            .remaining = remaining,
        };
    }

    pub fn resetWindow(self: *FixedWindowLimiter) void {
        self.count = 0;
        self.window_start_ms = 0;
    }
};

// --- Control Plane Rate Limiter ---

pub const ControlPlaneLimiter = struct {
    const max_requests: u32 = 3;
    const window_ms: i64 = 60_000;

    buckets: std.StringHashMapUnmanaged(Bucket),
    allocator: std.mem.Allocator,

    const Bucket = struct {
        count: u32,
        window_start_ms: i64,
    };

    pub fn init(allocator: std.mem.Allocator) ControlPlaneLimiter {
        return .{
            .buckets = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ControlPlaneLimiter) void {
        var iter = self.buckets.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.buckets.deinit(self.allocator);
    }

    pub fn consume(self: *ControlPlaneLimiter, key: []const u8) !CheckResult {
        return self.consumeAt(key, std.time.milliTimestamp());
    }

    pub fn consumeAt(self: *ControlPlaneLimiter, key: []const u8, now: i64) !CheckResult {
        if (self.buckets.getPtr(key)) |bucket| {
            if (now - bucket.window_start_ms >= window_ms) {
                bucket.count = 1;
                bucket.window_start_ms = now;
                return .{
                    .allowed = true,
                    .retry_after_ms = 0,
                    .remaining = max_requests - 1,
                };
            }

            if (bucket.count >= max_requests) {
                return .{
                    .allowed = false,
                    .retry_after_ms = @max(0, bucket.window_start_ms + window_ms - now),
                    .remaining = 0,
                };
            }

            bucket.count += 1;
            const remaining = if (bucket.count >= max_requests) 0 else max_requests - bucket.count;
            return .{
                .allowed = true,
                .retry_after_ms = 0,
                .remaining = remaining,
            };
        }

        // New key
        const key_copy = try self.allocator.dupe(u8, key);
        try self.buckets.put(self.allocator, key_copy, .{
            .count = 1,
            .window_start_ms = now,
        });
        return .{
            .allowed = true,
            .retry_after_ms = 0,
            .remaining = max_requests - 1,
        };
    }

    pub fn clear(self: *ControlPlaneLimiter) void {
        var iter = self.buckets.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.buckets.clearAndFree(self.allocator);
    }

    pub fn resolveKey(device_id: ?[]const u8, client_ip: ?[]const u8, conn_id: ?[]const u8, buf: []u8) []const u8 {
        const dev = device_id orelse "unknown-device";
        const ip = client_ip orelse "unknown-ip";

        if (std.mem.eql(u8, dev, "unknown-device") and std.mem.eql(u8, ip, "unknown-ip")) {
            if (conn_id) |cid| {
                if (cid.len > 0) {
                    return std.fmt.bufPrint(buf, "{s}|{s}|conn={s}", .{ dev, ip, cid }) catch buf[0..0];
                }
            }
        }
        return std.fmt.bufPrint(buf, "{s}|{s}", .{ dev, ip }) catch buf[0..0];
    }
};

// --- Tests ---

test "Scope label" {
    try std.testing.expectEqualStrings("default", Scope.default.label());
    try std.testing.expectEqualStrings("shared-secret", Scope.shared_secret.label());
    try std.testing.expectEqualStrings("device-token", Scope.device_token.label());
    try std.testing.expectEqualStrings("hook-auth", Scope.hook_auth.label());
}

test "Scope fromString" {
    try std.testing.expectEqual(Scope.default, Scope.fromString("default").?);
    try std.testing.expectEqual(Scope.shared_secret, Scope.fromString("shared-secret").?);
    try std.testing.expectEqual(Scope.device_token, Scope.fromString("device-token").?);
    try std.testing.expectEqual(Scope.hook_auth, Scope.fromString("hook-auth").?);
    try std.testing.expectEqual(@as(?Scope, null), Scope.fromString("unknown"));
}

test "SlidingWindowLimiter basic flow" {
    const allocator = std.testing.allocator;
    var limiter = SlidingWindowLimiter.init(allocator, .{ .max_attempts = 3, .window_ms = 60_000, .lockout_ms = 300_000 });
    defer limiter.deinit();

    const ip = "192.168.1.1";

    // Should be allowed initially
    const r1 = limiter.check(ip, .default);
    try std.testing.expect(r1.allowed);
    try std.testing.expectEqual(@as(u32, 3), r1.remaining);

    // Record failures
    try limiter.recordFailure(ip, .default);
    const r2 = limiter.check(ip, .default);
    try std.testing.expect(r2.allowed);
    try std.testing.expectEqual(@as(u32, 2), r2.remaining);

    try limiter.recordFailure(ip, .default);
    const r3 = limiter.check(ip, .default);
    try std.testing.expect(r3.allowed);
    try std.testing.expectEqual(@as(u32, 1), r3.remaining);

    try limiter.recordFailure(ip, .default);

    // Should be blocked after max attempts
    const r4 = limiter.check(ip, .default);
    try std.testing.expect(!r4.allowed);
    try std.testing.expectEqual(@as(u32, 0), r4.remaining);

    // Reset should clear
    limiter.reset(ip, .default);
    const r5 = limiter.check(ip, .default);
    try std.testing.expect(r5.allowed);
}

test "SlidingWindowLimiter different keys" {
    const allocator = std.testing.allocator;
    var limiter = SlidingWindowLimiter.init(allocator, .{ .max_attempts = 1, .window_ms = 60_000, .lockout_ms = 300_000 });
    defer limiter.deinit();

    try limiter.recordFailure("ip-1", .default);
    try std.testing.expect(!limiter.check("ip-1", .default).allowed);
    try std.testing.expect(limiter.check("ip-2", .default).allowed);
}

test "SlidingWindowLimiter different scopes" {
    const allocator = std.testing.allocator;
    var limiter = SlidingWindowLimiter.init(allocator, .{ .max_attempts = 1, .window_ms = 60_000, .lockout_ms = 300_000 });
    defer limiter.deinit();

    try limiter.recordFailure("10.0.0.1", .shared_secret);
    try std.testing.expect(!limiter.check("10.0.0.1", .shared_secret).allowed);
    // Same IP, different scope should still be allowed
    try std.testing.expect(limiter.check("10.0.0.1", .device_token).allowed);
}

test "SlidingWindowLimiter loopback exempt" {
    const allocator = std.testing.allocator;
    var limiter = SlidingWindowLimiter.init(allocator, .{ .max_attempts = 1, .window_ms = 60_000, .lockout_ms = 300_000, .exempt_loopback = true });
    defer limiter.deinit();

    // Loopback addresses should always be allowed
    try limiter.recordFailure("127.0.0.1", .default);
    try limiter.recordFailure("127.0.0.1", .default);
    try limiter.recordFailure("127.0.0.1", .default);
    try std.testing.expect(limiter.check("127.0.0.1", .default).allowed);

    try limiter.recordFailure("::1", .default);
    try std.testing.expect(limiter.check("::1", .default).allowed);

    try limiter.recordFailure("localhost", .default);
    try std.testing.expect(limiter.check("localhost", .default).allowed);
}

test "SlidingWindowLimiter loopback not exempt" {
    const allocator = std.testing.allocator;
    var limiter = SlidingWindowLimiter.init(allocator, .{ .max_attempts = 1, .window_ms = 60_000, .lockout_ms = 300_000, .exempt_loopback = false });
    defer limiter.deinit();

    try limiter.recordFailure("127.0.0.1", .default);
    try std.testing.expect(!limiter.check("127.0.0.1", .default).allowed);
}

test "SlidingWindowLimiter lockout" {
    const allocator = std.testing.allocator;
    var limiter = SlidingWindowLimiter.init(allocator, .{ .max_attempts = 2, .window_ms = 60_000, .lockout_ms = 10_000 });
    defer limiter.deinit();

    const base_time: i64 = 1_000_000;

    try limiter.recordFailureAt("10.0.0.1", .default, base_time);
    try limiter.recordFailureAt("10.0.0.1", .default, base_time + 100);

    // Should be locked out
    const r1 = limiter.checkAt("10.0.0.1", .default, base_time + 200);
    try std.testing.expect(!r1.allowed);
    try std.testing.expect(r1.retry_after_ms > 0);

    // Still locked after 5 seconds
    const r2 = limiter.checkAt("10.0.0.1", .default, base_time + 5_100);
    try std.testing.expect(!r2.allowed);

    // Lockout expires after 10 seconds
    const r3 = limiter.checkAt("10.0.0.1", .default, base_time + 10_200);
    try std.testing.expect(r3.allowed);
    try std.testing.expectEqual(@as(u32, 2), r3.remaining);
}

test "SlidingWindowLimiter sliding window expiry" {
    const allocator = std.testing.allocator;
    var limiter = SlidingWindowLimiter.init(allocator, .{ .max_attempts = 2, .window_ms = 10_000, .lockout_ms = 5_000 });
    defer limiter.deinit();

    const base_time: i64 = 1_000_000;

    // Record one failure
    try limiter.recordFailureAt("10.0.0.1", .default, base_time);

    // After window passes, the old attempt should slide out
    const r1 = limiter.checkAt("10.0.0.1", .default, base_time + 11_000);
    try std.testing.expect(r1.allowed);
    try std.testing.expectEqual(@as(u32, 2), r1.remaining);
}

test "SlidingWindowLimiter burst allowance" {
    const allocator = std.testing.allocator;
    var limiter = SlidingWindowLimiter.init(allocator, .{
        .max_attempts = 2,
        .window_ms = 60_000,
        .lockout_ms = 300_000,
        .burst_allowance = 3,
    });
    defer limiter.deinit();

    const ip = "10.0.0.5";
    const base_time: i64 = 1_000_000;

    // Should allow max_attempts + burst_allowance = 5 total
    try limiter.recordFailureAt(ip, .default, base_time);
    try limiter.recordFailureAt(ip, .default, base_time + 1);
    try limiter.recordFailureAt(ip, .default, base_time + 2);
    try limiter.recordFailureAt(ip, .default, base_time + 3);

    const r1 = limiter.checkAt(ip, .default, base_time + 4);
    try std.testing.expect(r1.allowed);
    try std.testing.expectEqual(@as(u32, 1), r1.remaining);

    try limiter.recordFailureAt(ip, .default, base_time + 5);

    // Now should be blocked
    const r2 = limiter.checkAt(ip, .default, base_time + 6);
    try std.testing.expect(!r2.allowed);
}

test "SlidingWindowLimiter size and prune" {
    const allocator = std.testing.allocator;
    var limiter = SlidingWindowLimiter.init(allocator, .{ .max_attempts = 5, .window_ms = 10_000, .lockout_ms = 5_000 });
    defer limiter.deinit();

    const base_time: i64 = 1_000_000;

    try limiter.recordFailureAt("ip-1", .default, base_time);
    try limiter.recordFailureAt("ip-2", .default, base_time);
    try limiter.recordFailureAt("ip-3", .default, base_time);

    try std.testing.expectEqual(@as(u32, 3), limiter.size());

    // Prune after window -- all entries should be removed
    limiter.pruneAt(base_time + 20_000);
    try std.testing.expectEqual(@as(u32, 0), limiter.size());
}

test "SlidingWindowLimiter prune keeps locked entries" {
    const allocator = std.testing.allocator;
    var limiter = SlidingWindowLimiter.init(allocator, .{ .max_attempts = 2, .window_ms = 5_000, .lockout_ms = 60_000 });
    defer limiter.deinit();

    const base_time: i64 = 1_000_000;

    // Record 2 failures to trigger lockout (max_attempts = 2)
    try limiter.recordFailureAt("ip-locked", .default, base_time);
    try limiter.recordFailureAt("ip-locked", .default, base_time + 1);

    // Add a non-locked entry (only 1 failure, below max_attempts)
    try limiter.recordFailureAt("ip-free", .shared_secret, base_time);

    try std.testing.expectEqual(@as(u32, 2), limiter.size());

    // Prune after window but before lockout expires
    limiter.pruneAt(base_time + 10_000);

    // ip-free should be pruned (window expired, not locked), ip-locked should remain (locked)
    try std.testing.expectEqual(@as(u32, 1), limiter.size());
}

test "SlidingWindowLimiter clear" {
    const allocator = std.testing.allocator;
    var limiter = SlidingWindowLimiter.init(allocator, .{ .max_attempts = 5, .window_ms = 60_000, .lockout_ms = 300_000 });
    defer limiter.deinit();

    try limiter.recordFailure("ip-1", .default);
    try limiter.recordFailure("ip-2", .shared_secret);
    try std.testing.expectEqual(@as(u32, 2), limiter.size());

    limiter.clear();
    try std.testing.expectEqual(@as(u32, 0), limiter.size());
}

test "SlidingWindowLimiter reset non-existent key" {
    const allocator = std.testing.allocator;
    var limiter = SlidingWindowLimiter.init(allocator, .{ .max_attempts = 5, .window_ms = 60_000, .lockout_ms = 300_000 });
    defer limiter.deinit();

    // Should not crash
    limiter.reset("non-existent", .default);
}

test "SlidingWindowLimiter check non-existent key" {
    const allocator = std.testing.allocator;
    var limiter = SlidingWindowLimiter.init(allocator, .{ .max_attempts = 5, .window_ms = 60_000, .lockout_ms = 300_000 });
    defer limiter.deinit();

    const r = limiter.check("non-existent", .default);
    try std.testing.expect(r.allowed);
    try std.testing.expectEqual(@as(u32, 5), r.remaining);
    try std.testing.expectEqual(@as(i64, 0), r.retry_after_ms);
}

test "SlidingWindowLimiter default config" {
    const allocator = std.testing.allocator;
    var limiter = SlidingWindowLimiter.init(allocator, .{});
    defer limiter.deinit();

    // Default: 10 max attempts
    const r = limiter.check("test-ip", .default);
    try std.testing.expect(r.allowed);
    try std.testing.expectEqual(@as(u32, 10), r.remaining);
}

test "SlidingWindowLimiter record while locked does nothing" {
    const allocator = std.testing.allocator;
    var limiter = SlidingWindowLimiter.init(allocator, .{ .max_attempts = 1, .window_ms = 60_000, .lockout_ms = 300_000 });
    defer limiter.deinit();

    const base_time: i64 = 1_000_000;

    // Trigger lockout
    try limiter.recordFailureAt("ip-1", .default, base_time);

    // Recording while locked should not change state
    try limiter.recordFailureAt("ip-1", .default, base_time + 100);
    try limiter.recordFailureAt("ip-1", .default, base_time + 200);

    // Still locked
    const r = limiter.checkAt("ip-1", .default, base_time + 300);
    try std.testing.expect(!r.allowed);
}

test "SlidingWindowLimiter IPv4-mapped IPv6 loopback exempt" {
    const allocator = std.testing.allocator;
    var limiter = SlidingWindowLimiter.init(allocator, .{ .max_attempts = 1, .window_ms = 60_000, .lockout_ms = 300_000, .exempt_loopback = true });
    defer limiter.deinit();

    try limiter.recordFailure("::ffff:127.0.0.1", .default);
    try std.testing.expect(limiter.check("::ffff:127.0.0.1", .default).allowed);
}

test "SlidingWindowLimiter multiple scopes independent" {
    const allocator = std.testing.allocator;
    var limiter = SlidingWindowLimiter.init(allocator, .{ .max_attempts = 2, .window_ms = 60_000, .lockout_ms = 300_000 });
    defer limiter.deinit();

    // Max out shared_secret scope
    try limiter.recordFailure("10.0.0.1", .shared_secret);
    try limiter.recordFailure("10.0.0.1", .shared_secret);
    try std.testing.expect(!limiter.check("10.0.0.1", .shared_secret).allowed);

    // Other scopes should still work
    try std.testing.expect(limiter.check("10.0.0.1", .default).allowed);
    try std.testing.expect(limiter.check("10.0.0.1", .device_token).allowed);
    try std.testing.expect(limiter.check("10.0.0.1", .hook_auth).allowed);
}

test "SlidingWindowLimiter retry_after decreases" {
    const allocator = std.testing.allocator;
    var limiter = SlidingWindowLimiter.init(allocator, .{ .max_attempts = 1, .window_ms = 60_000, .lockout_ms = 10_000 });
    defer limiter.deinit();

    const base_time: i64 = 1_000_000;

    try limiter.recordFailureAt("ip-1", .default, base_time);

    const r1 = limiter.checkAt("ip-1", .default, base_time + 1_000);
    try std.testing.expect(!r1.allowed);
    try std.testing.expect(r1.retry_after_ms <= 10_000);
    try std.testing.expect(r1.retry_after_ms > 0);

    const r2 = limiter.checkAt("ip-1", .default, base_time + 5_000);
    try std.testing.expect(!r2.allowed);
    try std.testing.expect(r2.retry_after_ms < r1.retry_after_ms);
}

// --- Fixed Window Limiter Tests ---

test "FixedWindowLimiter basic flow" {
    var limiter = FixedWindowLimiter.init(3, 60_000);

    const base_time: i64 = 1_000_000;

    const r1 = limiter.consumeAt(base_time);
    try std.testing.expect(r1.allowed);
    try std.testing.expectEqual(@as(u32, 2), r1.remaining);

    const r2 = limiter.consumeAt(base_time + 100);
    try std.testing.expect(r2.allowed);
    try std.testing.expectEqual(@as(u32, 1), r2.remaining);

    const r3 = limiter.consumeAt(base_time + 200);
    try std.testing.expect(r3.allowed);
    try std.testing.expectEqual(@as(u32, 0), r3.remaining);

    // Exhausted
    const r4 = limiter.consumeAt(base_time + 300);
    try std.testing.expect(!r4.allowed);
    try std.testing.expectEqual(@as(u32, 0), r4.remaining);
    try std.testing.expect(r4.retry_after_ms > 0);
}

test "FixedWindowLimiter window reset" {
    var limiter = FixedWindowLimiter.init(2, 10_000);

    const base_time: i64 = 1_000_000;

    _ = limiter.consumeAt(base_time);
    _ = limiter.consumeAt(base_time + 100);

    // Exhausted
    const r1 = limiter.consumeAt(base_time + 200);
    try std.testing.expect(!r1.allowed);

    // Window resets
    const r2 = limiter.consumeAt(base_time + 11_000);
    try std.testing.expect(r2.allowed);
    try std.testing.expectEqual(@as(u32, 1), r2.remaining);
}

test "FixedWindowLimiter reset" {
    var limiter = FixedWindowLimiter.init(1, 60_000);

    const base_time: i64 = 1_000_000;

    _ = limiter.consumeAt(base_time);
    try std.testing.expect(!limiter.consumeAt(base_time + 100).allowed);

    limiter.resetWindow();
    const r = limiter.consumeAt(base_time + 200);
    try std.testing.expect(r.allowed);
}

test "FixedWindowLimiter min values" {
    // Zero max_requests should be clamped to 1
    const limiter = FixedWindowLimiter.init(0, 0);
    try std.testing.expectEqual(@as(u32, 1), limiter.max_requests);
    try std.testing.expectEqual(@as(i64, 1), limiter.window_ms);
}

// --- Control Plane Limiter Tests ---

test "ControlPlaneLimiter basic flow" {
    const allocator = std.testing.allocator;
    var limiter = ControlPlaneLimiter.init(allocator);
    defer limiter.deinit();

    const base_time: i64 = 1_000_000;

    const r1 = try limiter.consumeAt("device-1|10.0.0.1", base_time);
    try std.testing.expect(r1.allowed);
    try std.testing.expectEqual(@as(u32, 2), r1.remaining);

    const r2 = try limiter.consumeAt("device-1|10.0.0.1", base_time + 100);
    try std.testing.expect(r2.allowed);
    try std.testing.expectEqual(@as(u32, 1), r2.remaining);

    const r3 = try limiter.consumeAt("device-1|10.0.0.1", base_time + 200);
    try std.testing.expect(r3.allowed);
    try std.testing.expectEqual(@as(u32, 0), r3.remaining);

    // Exhausted
    const r4 = try limiter.consumeAt("device-1|10.0.0.1", base_time + 300);
    try std.testing.expect(!r4.allowed);
    try std.testing.expect(r4.retry_after_ms > 0);
}

test "ControlPlaneLimiter window reset" {
    const allocator = std.testing.allocator;
    var limiter = ControlPlaneLimiter.init(allocator);
    defer limiter.deinit();

    const base_time: i64 = 1_000_000;

    _ = try limiter.consumeAt("key-1", base_time);
    _ = try limiter.consumeAt("key-1", base_time + 100);
    _ = try limiter.consumeAt("key-1", base_time + 200);

    const r1 = try limiter.consumeAt("key-1", base_time + 300);
    try std.testing.expect(!r1.allowed);

    // After window, should be allowed again
    const r2 = try limiter.consumeAt("key-1", base_time + 61_000);
    try std.testing.expect(r2.allowed);
}

test "ControlPlaneLimiter different keys independent" {
    const allocator = std.testing.allocator;
    var limiter = ControlPlaneLimiter.init(allocator);
    defer limiter.deinit();

    const base_time: i64 = 1_000_000;

    _ = try limiter.consumeAt("key-1", base_time);
    _ = try limiter.consumeAt("key-1", base_time + 1);
    _ = try limiter.consumeAt("key-1", base_time + 2);

    // key-1 exhausted
    try std.testing.expect(!(try limiter.consumeAt("key-1", base_time + 3)).allowed);

    // key-2 should still work
    const r = try limiter.consumeAt("key-2", base_time + 4);
    try std.testing.expect(r.allowed);
}

test "ControlPlaneLimiter clear" {
    const allocator = std.testing.allocator;
    var limiter = ControlPlaneLimiter.init(allocator);
    defer limiter.deinit();

    _ = try limiter.consumeAt("key-1", 1_000_000);
    limiter.clear();

    // After clear, should allow again
    const r = try limiter.consumeAt("key-1", 1_000_001);
    try std.testing.expect(r.allowed);
    try std.testing.expectEqual(@as(u32, 2), r.remaining);
}

test "ControlPlaneLimiter resolveKey basic" {
    var buf: [256]u8 = undefined;

    const key1 = ControlPlaneLimiter.resolveKey("dev-1", "10.0.0.1", null, &buf);
    try std.testing.expectEqualStrings("dev-1|10.0.0.1", key1);
}

test "ControlPlaneLimiter resolveKey fallback" {
    var buf: [256]u8 = undefined;

    const key = ControlPlaneLimiter.resolveKey(null, null, null, &buf);
    try std.testing.expectEqualStrings("unknown-device|unknown-ip", key);
}

test "ControlPlaneLimiter resolveKey with conn_id fallback" {
    var buf: [256]u8 = undefined;

    const key = ControlPlaneLimiter.resolveKey(null, null, "conn-123", &buf);
    try std.testing.expectEqualStrings("unknown-device|unknown-ip|conn=conn-123", key);
}

test "ControlPlaneLimiter resolveKey does not use conn_id when identity present" {
    var buf: [256]u8 = undefined;

    const key = ControlPlaneLimiter.resolveKey("dev-1", null, "conn-123", &buf);
    try std.testing.expectEqualStrings("dev-1|unknown-ip", key);
}

test "isLoopback" {
    try std.testing.expect(SlidingWindowLimiter.isLoopback("127.0.0.1"));
    try std.testing.expect(SlidingWindowLimiter.isLoopback("::1"));
    try std.testing.expect(SlidingWindowLimiter.isLoopback("localhost"));
    try std.testing.expect(SlidingWindowLimiter.isLoopback("::ffff:127.0.0.1"));
    try std.testing.expect(!SlidingWindowLimiter.isLoopback("192.168.1.1"));
    try std.testing.expect(!SlidingWindowLimiter.isLoopback("10.0.0.1"));
    try std.testing.expect(!SlidingWindowLimiter.isLoopback(""));
}

test "SlidingWindowLimiter lockout retry_after accuracy" {
    const allocator = std.testing.allocator;
    var limiter = SlidingWindowLimiter.init(allocator, .{ .max_attempts = 1, .window_ms = 60_000, .lockout_ms = 30_000 });
    defer limiter.deinit();

    const base_time: i64 = 1_000_000;

    try limiter.recordFailureAt("ip-1", .default, base_time);

    // Check at base_time + 1000: locked until base_time + 30000
    const r = limiter.checkAt("ip-1", .default, base_time + 1_000);
    try std.testing.expect(!r.allowed);
    // retry_after should be lockout_ms minus elapsed since failure = 30000 - 1000 = 29000
    try std.testing.expectEqual(@as(i64, 29_000), r.retry_after_ms);
}

test "SlidingWindowLimiter high attempt count" {
    const allocator = std.testing.allocator;
    var limiter = SlidingWindowLimiter.init(allocator, .{ .max_attempts = 100, .window_ms = 60_000, .lockout_ms = 300_000 });
    defer limiter.deinit();

    const base_time: i64 = 1_000_000;

    for (0..99) |i| {
        try limiter.recordFailureAt("ip-1", .default, base_time + @as(i64, @intCast(i)));
    }

    const r = limiter.checkAt("ip-1", .default, base_time + 100);
    try std.testing.expect(r.allowed);
    try std.testing.expectEqual(@as(u32, 1), r.remaining);

    try limiter.recordFailureAt("ip-1", .default, base_time + 101);
    const r2 = limiter.checkAt("ip-1", .default, base_time + 102);
    try std.testing.expect(!r2.allowed);
}

test "SlidingWindowLimiter multiple IPs" {
    const allocator = std.testing.allocator;
    var limiter = SlidingWindowLimiter.init(allocator, .{ .max_attempts = 2, .window_ms = 60_000, .lockout_ms = 300_000 });
    defer limiter.deinit();

    const ips = [_][]const u8{ "10.0.0.1", "10.0.0.2", "10.0.0.3", "10.0.0.4", "10.0.0.5" };

    for (ips) |ip| {
        try limiter.recordFailure(ip, .default);
    }

    try std.testing.expectEqual(@as(u32, 5), limiter.size());

    for (ips) |ip| {
        const r = limiter.check(ip, .default);
        try std.testing.expect(r.allowed);
        try std.testing.expectEqual(@as(u32, 1), r.remaining);
    }
}

test "SlidingWindowLimiter reset clears lockout" {
    const allocator = std.testing.allocator;
    var limiter = SlidingWindowLimiter.init(allocator, .{ .max_attempts = 1, .window_ms = 60_000, .lockout_ms = 300_000 });
    defer limiter.deinit();

    try limiter.recordFailure("ip-1", .default);
    try std.testing.expect(!limiter.check("ip-1", .default).allowed);

    limiter.reset("ip-1", .default);
    try std.testing.expect(limiter.check("ip-1", .default).allowed);
    try std.testing.expectEqual(@as(u32, 0), limiter.size());
}
