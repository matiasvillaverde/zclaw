const std = @import("std");

// --- Failover State ---

pub const FailoverState = struct {
    cooldowns: std.StringHashMapUnmanaged(CooldownEntry),
    allocator: std.mem.Allocator,
    max_retries: u32,
    cooldown_ms: i64,

    const CooldownEntry = struct {
        failures: u32,
        last_failure_ms: i64,
        reason: FailoverReason,
    };

    pub fn init(allocator: std.mem.Allocator, max_retries: u32, cooldown_ms: i64) FailoverState {
        return .{
            .cooldowns = .{},
            .allocator = allocator,
            .max_retries = max_retries,
            .cooldown_ms = cooldown_ms,
        };
    }

    pub fn deinit(self: *FailoverState) void {
        var iter = self.cooldowns.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.cooldowns.deinit(self.allocator);
    }

    /// Record a failure for a provider/model combination.
    pub fn recordFailure(self: *FailoverState, key: []const u8, reason: FailoverReason) !void {
        const now = std.time.milliTimestamp();
        if (self.cooldowns.getPtr(key)) |entry| {
            entry.failures += 1;
            entry.last_failure_ms = now;
            entry.reason = reason;
        } else {
            const key_copy = try self.allocator.dupe(u8, key);
            try self.cooldowns.put(self.allocator, key_copy, .{
                .failures = 1,
                .last_failure_ms = now,
                .reason = reason,
            });
        }
    }

    /// Check if a provider/model is currently in cooldown.
    pub fn isInCooldown(self: *FailoverState, key: []const u8) bool {
        const entry = self.cooldowns.get(key) orelse return false;
        if (entry.failures < self.max_retries) return false;

        const now = std.time.milliTimestamp();
        return (now - entry.last_failure_ms) < self.cooldown_ms;
    }

    /// Reset failures for a provider/model (e.g., after successful request).
    pub fn reset(self: *FailoverState, key: []const u8) void {
        if (self.cooldowns.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    /// Get failure count for a key.
    pub fn getFailureCount(self: *FailoverState, key: []const u8) u32 {
        if (self.cooldowns.get(key)) |entry| {
            return entry.failures;
        }
        return 0;
    }
};

// --- Failover Reason ---

pub const FailoverReason = enum {
    billing,
    rate_limit,
    auth,
    timeout,
    format,
    model_not_found,
    overloaded,
    unknown,

    pub fn label(self: FailoverReason) []const u8 {
        return switch (self) {
            .billing => "billing",
            .rate_limit => "rate_limit",
            .auth => "auth",
            .timeout => "timeout",
            .format => "format",
            .model_not_found => "model_not_found",
            .overloaded => "overloaded",
            .unknown => "unknown",
        };
    }

    /// Whether this failure reason should trigger failover to another provider
    pub fn shouldFailover(self: FailoverReason) bool {
        return switch (self) {
            .billing, .rate_limit, .auth, .timeout, .overloaded => true,
            .format, .model_not_found => false,
            .unknown => true,
        };
    }

    /// Whether this failure is likely transient
    pub fn isTransient(self: FailoverReason) bool {
        return switch (self) {
            .rate_limit, .timeout, .overloaded => true,
            .billing, .auth, .format, .model_not_found => false,
            .unknown => true,
        };
    }
};

// --- Model Resolution Chain ---

pub const ModelResolution = struct {
    /// Resolve model ID from the chain: user override → session pin → agent default → global default → fallback.
    pub fn resolve(
        user_override: ?[]const u8,
        session_pin: ?[]const u8,
        agent_default: ?[]const u8,
        global_default: ?[]const u8,
    ) []const u8 {
        if (user_override) |m| return m;
        if (session_pin) |m| return m;
        if (agent_default) |m| return m;
        if (global_default) |m| return m;
        return FALLBACK_MODEL;
    }

    pub const FALLBACK_MODEL = "claude-sonnet-4-20250514";
};

// --- Auth Rotation ---

pub const AuthRotation = struct {
    keys: []const []const u8,
    current_index: usize,
    failures_per_key: std.ArrayListUnmanaged(u32),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, keys: []const []const u8) !AuthRotation {
        var failures = std.ArrayListUnmanaged(u32){};
        try failures.resize(allocator, keys.len);
        @memset(failures.items, 0);
        return .{
            .keys = keys,
            .current_index = 0,
            .failures_per_key = failures,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AuthRotation) void {
        self.failures_per_key.deinit(self.allocator);
    }

    /// Get the current API key.
    pub fn currentKey(self: *const AuthRotation) ?[]const u8 {
        if (self.keys.len == 0) return null;
        return self.keys[self.current_index];
    }

    /// Rotate to the next key (on auth failure).
    pub fn rotate(self: *AuthRotation) void {
        if (self.keys.len <= 1) return;
        self.failures_per_key.items[self.current_index] += 1;
        self.current_index = (self.current_index + 1) % self.keys.len;
    }

    /// Reset failure counter for current key (on success).
    pub fn resetCurrent(self: *AuthRotation) void {
        if (self.keys.len > 0) {
            self.failures_per_key.items[self.current_index] = 0;
        }
    }

    /// Check if all keys have been exhausted (all above max_failures).
    pub fn allExhausted(self: *const AuthRotation, max_failures: u32) bool {
        for (self.failures_per_key.items) |count| {
            if (count < max_failures) return false;
        }
        return true;
    }
};

// --- Failover Key Builder ---

pub fn buildFailoverKey(buf: []u8, provider: []const u8, model: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    try writer.writeAll(provider);
    try writer.writeByte(':');
    try writer.writeAll(model);
    return fbs.getWritten();
}

// --- Tests ---

test "FailoverState basic flow" {
    const allocator = std.testing.allocator;
    var state = FailoverState.init(allocator, 3, 60_000);
    defer state.deinit();

    const key = "anthropic:claude-3-5-sonnet";

    // Not in cooldown initially
    try std.testing.expect(!state.isInCooldown(key));
    try std.testing.expectEqual(@as(u32, 0), state.getFailureCount(key));

    // Record failures
    try state.recordFailure(key, .rate_limit);
    try std.testing.expectEqual(@as(u32, 1), state.getFailureCount(key));
    try std.testing.expect(!state.isInCooldown(key));

    try state.recordFailure(key, .rate_limit);
    try state.recordFailure(key, .rate_limit);

    // Should be in cooldown after max_retries
    try std.testing.expect(state.isInCooldown(key));

    // Reset clears cooldown
    state.reset(key);
    try std.testing.expect(!state.isInCooldown(key));
    try std.testing.expectEqual(@as(u32, 0), state.getFailureCount(key));
}

test "FailoverReason shouldFailover" {
    try std.testing.expect(FailoverReason.rate_limit.shouldFailover());
    try std.testing.expect(FailoverReason.billing.shouldFailover());
    try std.testing.expect(FailoverReason.auth.shouldFailover());
    try std.testing.expect(FailoverReason.timeout.shouldFailover());
    try std.testing.expect(FailoverReason.overloaded.shouldFailover());
    try std.testing.expect(!FailoverReason.format.shouldFailover());
    try std.testing.expect(!FailoverReason.model_not_found.shouldFailover());
}

test "FailoverReason isTransient" {
    try std.testing.expect(FailoverReason.rate_limit.isTransient());
    try std.testing.expect(FailoverReason.timeout.isTransient());
    try std.testing.expect(FailoverReason.overloaded.isTransient());
    try std.testing.expect(!FailoverReason.billing.isTransient());
    try std.testing.expect(!FailoverReason.auth.isTransient());
}

test "FailoverReason label" {
    try std.testing.expectEqualStrings("rate_limit", FailoverReason.rate_limit.label());
    try std.testing.expectEqualStrings("billing", FailoverReason.billing.label());
}

test "ModelResolution chain" {
    // Full chain
    try std.testing.expectEqualStrings("override", ModelResolution.resolve("override", "pinned", "default", "global"));
    // Skip override
    try std.testing.expectEqualStrings("pinned", ModelResolution.resolve(null, "pinned", "default", "global"));
    // Skip to default
    try std.testing.expectEqualStrings("default", ModelResolution.resolve(null, null, "default", "global"));
    // Skip to global
    try std.testing.expectEqualStrings("global", ModelResolution.resolve(null, null, null, "global"));
    // Fallback
    try std.testing.expectEqualStrings(ModelResolution.FALLBACK_MODEL, ModelResolution.resolve(null, null, null, null));
}

test "AuthRotation basic" {
    const allocator = std.testing.allocator;
    const keys = [_][]const u8{ "key-1", "key-2", "key-3" };
    var rotation = try AuthRotation.init(allocator, &keys);
    defer rotation.deinit();

    try std.testing.expectEqualStrings("key-1", rotation.currentKey().?);

    rotation.rotate();
    try std.testing.expectEqualStrings("key-2", rotation.currentKey().?);

    rotation.rotate();
    try std.testing.expectEqualStrings("key-3", rotation.currentKey().?);

    rotation.rotate();
    try std.testing.expectEqualStrings("key-1", rotation.currentKey().?); // Wraps around
}

test "AuthRotation resetCurrent" {
    const allocator = std.testing.allocator;
    const keys = [_][]const u8{ "key-1", "key-2" };
    var rotation = try AuthRotation.init(allocator, &keys);
    defer rotation.deinit();

    rotation.rotate(); // Fail key-1
    rotation.resetCurrent(); // Success on key-2 resets its counter

    try std.testing.expect(!rotation.allExhausted(3));
}

test "AuthRotation allExhausted" {
    const allocator = std.testing.allocator;
    const keys = [_][]const u8{ "key-1", "key-2" };
    var rotation = try AuthRotation.init(allocator, &keys);
    defer rotation.deinit();

    // Exhaust both keys (max_failures = 2)
    rotation.rotate(); // key-1 fail 1
    rotation.rotate(); // key-2 fail 1
    rotation.rotate(); // key-1 fail 2
    rotation.rotate(); // key-2 fail 2

    try std.testing.expect(rotation.allExhausted(2));
    try std.testing.expect(!rotation.allExhausted(3));
}

test "AuthRotation empty keys" {
    const allocator = std.testing.allocator;
    const keys = [_][]const u8{};
    var rotation = try AuthRotation.init(allocator, &keys);
    defer rotation.deinit();

    try std.testing.expect(rotation.currentKey() == null);
    try std.testing.expect(rotation.allExhausted(1));
}

test "buildFailoverKey" {
    var buf: [256]u8 = undefined;
    const key = try buildFailoverKey(&buf, "anthropic", "claude-3-5-sonnet");
    try std.testing.expectEqualStrings("anthropic:claude-3-5-sonnet", key);
}

test "buildFailoverKey openai" {
    var buf: [256]u8 = undefined;
    const key = try buildFailoverKey(&buf, "openai", "gpt-4-turbo");
    try std.testing.expectEqualStrings("openai:gpt-4-turbo", key);
}

// --- Additional Tests ---

test "FailoverReason all labels" {
    try std.testing.expectEqualStrings("auth", FailoverReason.auth.label());
    try std.testing.expectEqualStrings("timeout", FailoverReason.timeout.label());
    try std.testing.expectEqualStrings("format", FailoverReason.format.label());
    try std.testing.expectEqualStrings("model_not_found", FailoverReason.model_not_found.label());
    try std.testing.expectEqualStrings("overloaded", FailoverReason.overloaded.label());
    try std.testing.expectEqualStrings("unknown", FailoverReason.unknown.label());
}

test "FailoverReason unknown shouldFailover" {
    try std.testing.expect(FailoverReason.unknown.shouldFailover());
}

test "FailoverReason unknown isTransient" {
    try std.testing.expect(FailoverReason.unknown.isTransient());
}

test "FailoverReason format is not transient" {
    try std.testing.expect(!FailoverReason.format.isTransient());
    try std.testing.expect(!FailoverReason.format.shouldFailover());
}

test "FailoverReason model_not_found is not transient" {
    try std.testing.expect(!FailoverReason.model_not_found.isTransient());
    try std.testing.expect(!FailoverReason.model_not_found.shouldFailover());
}

test "FailoverState multiple different keys" {
    const allocator = std.testing.allocator;
    var state = FailoverState.init(allocator, 2, 60_000);
    defer state.deinit();

    try state.recordFailure("openai:gpt-4", .rate_limit);
    try state.recordFailure("anthropic:claude", .timeout);

    try std.testing.expectEqual(@as(u32, 1), state.getFailureCount("openai:gpt-4"));
    try std.testing.expectEqual(@as(u32, 1), state.getFailureCount("anthropic:claude"));
    try std.testing.expectEqual(@as(u32, 0), state.getFailureCount("unknown:model"));
}

test "FailoverState increment failure count" {
    const allocator = std.testing.allocator;
    var state = FailoverState.init(allocator, 5, 60_000);
    defer state.deinit();

    try state.recordFailure("k", .billing);
    try state.recordFailure("k", .billing);
    try state.recordFailure("k", .auth);

    try std.testing.expectEqual(@as(u32, 3), state.getFailureCount("k"));
}

test "FailoverState reset nonexistent key is safe" {
    const allocator = std.testing.allocator;
    var state = FailoverState.init(allocator, 3, 60_000);
    defer state.deinit();

    // Should not crash
    state.reset("does-not-exist");
    try std.testing.expectEqual(@as(u32, 0), state.getFailureCount("does-not-exist"));
}

test "FailoverState not in cooldown below max retries" {
    const allocator = std.testing.allocator;
    var state = FailoverState.init(allocator, 3, 60_000);
    defer state.deinit();

    try state.recordFailure("k", .rate_limit);
    try state.recordFailure("k", .rate_limit);
    // 2 failures, max is 3 -- not in cooldown
    try std.testing.expect(!state.isInCooldown("k"));
}

test "ModelResolution fallback model is valid" {
    try std.testing.expect(ModelResolution.FALLBACK_MODEL.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, ModelResolution.FALLBACK_MODEL, "claude") != null);
}

test "ModelResolution resolve with only global default" {
    const result = ModelResolution.resolve(null, null, null, "gpt-4");
    try std.testing.expectEqualStrings("gpt-4", result);
}

test "AuthRotation single key" {
    const allocator = std.testing.allocator;
    const keys = [_][]const u8{"only-key"};
    var rotation = try AuthRotation.init(allocator, &keys);
    defer rotation.deinit();

    try std.testing.expectEqualStrings("only-key", rotation.currentKey().?);
    rotation.rotate(); // should not change with single key
    try std.testing.expectEqualStrings("only-key", rotation.currentKey().?);
}

test "AuthRotation full cycle" {
    const allocator = std.testing.allocator;
    const keys = [_][]const u8{ "a", "b", "c" };
    var rotation = try AuthRotation.init(allocator, &keys);
    defer rotation.deinit();

    try std.testing.expectEqualStrings("a", rotation.currentKey().?);
    rotation.rotate();
    try std.testing.expectEqualStrings("b", rotation.currentKey().?);
    rotation.rotate();
    try std.testing.expectEqualStrings("c", rotation.currentKey().?);
    rotation.rotate();
    try std.testing.expectEqualStrings("a", rotation.currentKey().?);
}

test "AuthRotation resetCurrent clears counter" {
    const allocator = std.testing.allocator;
    const keys = [_][]const u8{ "k1", "k2" };
    var rotation = try AuthRotation.init(allocator, &keys);
    defer rotation.deinit();

    rotation.rotate(); // k1 gets 1 failure, now on k2
    rotation.rotate(); // k2 gets 1 failure, now on k1
    rotation.resetCurrent(); // reset k1's counter

    try std.testing.expect(!rotation.allExhausted(1));
}

test "buildFailoverKey buffer too small" {
    var buf: [3]u8 = undefined;
    const result = buildFailoverKey(&buf, "anthropic", "claude");
    try std.testing.expectError(error.NoSpaceLeft, result);
}

test "buildFailoverKey local provider" {
    var buf: [256]u8 = undefined;
    const key = try buildFailoverKey(&buf, "local", "llama-3");
    try std.testing.expectEqualStrings("local:llama-3", key);
}

// ===== New tests added for comprehensive coverage =====

test "FailoverState record and reset multiple keys" {
    const allocator = std.testing.allocator;
    var state = FailoverState.init(allocator, 2, 60_000);
    defer state.deinit();

    try state.recordFailure("key1", .rate_limit);
    try state.recordFailure("key2", .timeout);
    try state.recordFailure("key3", .billing);

    try std.testing.expectEqual(@as(u32, 1), state.getFailureCount("key1"));
    try std.testing.expectEqual(@as(u32, 1), state.getFailureCount("key2"));
    try std.testing.expectEqual(@as(u32, 1), state.getFailureCount("key3"));

    state.reset("key2");
    try std.testing.expectEqual(@as(u32, 0), state.getFailureCount("key2"));
    try std.testing.expectEqual(@as(u32, 1), state.getFailureCount("key1"));
}

test "FailoverState reason changes on subsequent failures" {
    const allocator = std.testing.allocator;
    var state = FailoverState.init(allocator, 5, 60_000);
    defer state.deinit();

    try state.recordFailure("k", .rate_limit);
    try state.recordFailure("k", .timeout);
    try state.recordFailure("k", .overloaded);

    try std.testing.expectEqual(@as(u32, 3), state.getFailureCount("k"));
}

test "FailoverState max_retries 1 goes into cooldown immediately" {
    const allocator = std.testing.allocator;
    var state = FailoverState.init(allocator, 1, 60_000);
    defer state.deinit();

    try state.recordFailure("k", .auth);
    try std.testing.expect(state.isInCooldown("k"));
}

test "FailoverState cooldown with 0 ms expires immediately" {
    const allocator = std.testing.allocator;
    var state = FailoverState.init(allocator, 1, 0);
    defer state.deinit();

    try state.recordFailure("k", .rate_limit);
    // cooldown_ms = 0, so cooldown should not be active (now - last >= 0)
    try std.testing.expect(!state.isInCooldown("k"));
}

test "FailoverState getFailureCount for unknown key" {
    const allocator = std.testing.allocator;
    var state = FailoverState.init(allocator, 3, 60_000);
    defer state.deinit();

    try std.testing.expectEqual(@as(u32, 0), state.getFailureCount("nonexistent"));
}

test "FailoverState isInCooldown for unknown key" {
    const allocator = std.testing.allocator;
    var state = FailoverState.init(allocator, 3, 60_000);
    defer state.deinit();

    try std.testing.expect(!state.isInCooldown("nonexistent"));
}

test "FailoverReason all variants have non-empty labels" {
    const reasons = [_]FailoverReason{
        .billing, .rate_limit, .auth, .timeout, .format, .model_not_found, .overloaded, .unknown,
    };
    for (reasons) |r| {
        try std.testing.expect(r.label().len > 0);
    }
}

test "FailoverReason shouldFailover and isTransient consistency" {
    // Things that are transient should also trigger failover
    try std.testing.expect(FailoverReason.rate_limit.shouldFailover());
    try std.testing.expect(FailoverReason.rate_limit.isTransient());

    try std.testing.expect(FailoverReason.timeout.shouldFailover());
    try std.testing.expect(FailoverReason.timeout.isTransient());

    try std.testing.expect(FailoverReason.overloaded.shouldFailover());
    try std.testing.expect(FailoverReason.overloaded.isTransient());
}

test "FailoverReason non-transient non-failover reasons" {
    // format and model_not_found are both non-transient and non-failover
    try std.testing.expect(!FailoverReason.format.shouldFailover());
    try std.testing.expect(!FailoverReason.format.isTransient());
    try std.testing.expect(!FailoverReason.model_not_found.shouldFailover());
    try std.testing.expect(!FailoverReason.model_not_found.isTransient());
}

test "ModelResolution all nulls returns fallback" {
    const result = ModelResolution.resolve(null, null, null, null);
    try std.testing.expectEqualStrings(ModelResolution.FALLBACK_MODEL, result);
}

test "ModelResolution user override wins over all" {
    const result = ModelResolution.resolve("user-model", "session-model", "agent-model", "global-model");
    try std.testing.expectEqualStrings("user-model", result);
}

test "ModelResolution session pin wins over defaults" {
    const result = ModelResolution.resolve(null, "session-model", "agent-model", "global-model");
    try std.testing.expectEqualStrings("session-model", result);
}

test "AuthRotation two keys exhaust check" {
    const allocator = std.testing.allocator;
    const keys = [_][]const u8{ "k1", "k2" };
    var rotation = try AuthRotation.init(allocator, &keys);
    defer rotation.deinit();

    // Not exhausted initially
    try std.testing.expect(!rotation.allExhausted(1));

    rotation.rotate(); // k1 = 1 fail, now on k2
    try std.testing.expect(!rotation.allExhausted(1)); // k2 has 0 failures

    rotation.rotate(); // k2 = 1 fail, now on k1
    try std.testing.expect(rotation.allExhausted(1)); // both >= 1
}

test "AuthRotation empty keys rotate is safe" {
    const allocator = std.testing.allocator;
    const keys = [_][]const u8{};
    var rotation = try AuthRotation.init(allocator, &keys);
    defer rotation.deinit();

    rotation.rotate(); // should not crash
    try std.testing.expect(rotation.currentKey() == null);
}

test "AuthRotation resetCurrent on empty keys is safe" {
    const allocator = std.testing.allocator;
    const keys = [_][]const u8{};
    var rotation = try AuthRotation.init(allocator, &keys);
    defer rotation.deinit();

    rotation.resetCurrent(); // should not crash
}

test "buildFailoverKey empty strings" {
    var buf: [256]u8 = undefined;
    const key = try buildFailoverKey(&buf, "", "");
    try std.testing.expectEqualStrings(":", key);
}
