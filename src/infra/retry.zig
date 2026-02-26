const std = @import("std");

// --- Retry/Backoff Utility ---
//
// Standalone utility for retry logic with exponential backoff.
// Used by the provider reliability layer and HTTP tools.

pub const RetryConfig = struct {
    max_retries: u32 = 3,
    initial_delay_ms: u64 = 1000,
    max_delay_ms: u64 = 30_000,
    backoff_multiplier: u32 = 2,
    jitter_factor: u32 = 25, // percentage (0-100) of delay to add as jitter
};

pub const DEFAULT_CONFIG = RetryConfig{};

pub const RetryState = struct {
    config: RetryConfig,
    attempt: u32 = 0,

    pub fn init(config: RetryConfig) RetryState {
        return .{ .config = config };
    }

    /// Compute the delay for the next retry attempt.
    pub fn nextDelay(self: *RetryState) ?u64 {
        if (self.isExhausted()) return null;
        const delay = computeDelay(self.config, self.attempt);
        self.attempt += 1;
        return delay;
    }

    /// Reset the retry counter (e.g. after a successful request).
    pub fn reset(self: *RetryState) void {
        self.attempt = 0;
    }

    /// Whether all retries have been exhausted.
    pub fn isExhausted(self: *const RetryState) bool {
        return self.attempt >= self.config.max_retries;
    }

    /// Current attempt number.
    pub fn currentAttempt(self: *const RetryState) u32 {
        return self.attempt;
    }
};

/// Compute delay for a given attempt using exponential backoff.
pub fn computeDelay(config: RetryConfig, attempt: u32) u64 {
    var delay = config.initial_delay_ms;
    var i: u32 = 0;
    while (i < attempt) : (i += 1) {
        delay *|= config.backoff_multiplier;
        if (delay > config.max_delay_ms) {
            delay = config.max_delay_ms;
            break;
        }
    }
    return @min(delay, config.max_delay_ms);
}

/// Determine if an HTTP status code indicates a transient error worth retrying.
pub fn shouldRetry(status: u16) bool {
    return switch (status) {
        429 => true, // Rate limited
        500 => true, // Internal server error
        502 => true, // Bad gateway
        503 => true, // Service unavailable
        504 => true, // Gateway timeout
        else => false,
    };
}

/// Parse a Retry-After header value (seconds or HTTP date).
/// Returns delay in milliseconds, or null if unparseable.
pub fn parseRetryAfter(value: []const u8) ?u64 {
    if (value.len == 0) return null;

    // Try parsing as integer (seconds)
    const seconds = std.fmt.parseInt(u64, value, 10) catch {
        // Could be HTTP date — not supported, return null
        return null;
    };
    return seconds * 1000;
}

/// Check if an error represents a transient/retryable condition.
pub fn isTransientError(status: u16) bool {
    return status >= 500 or status == 429 or status == 408;
}

// --- Tests ---

test "RetryConfig defaults" {
    const config = RetryConfig{};
    try std.testing.expectEqual(@as(u32, 3), config.max_retries);
    try std.testing.expectEqual(@as(u64, 1000), config.initial_delay_ms);
    try std.testing.expectEqual(@as(u64, 30_000), config.max_delay_ms);
    try std.testing.expectEqual(@as(u32, 2), config.backoff_multiplier);
}

test "RetryState init and reset" {
    var state = RetryState.init(DEFAULT_CONFIG);
    try std.testing.expect(!state.isExhausted());
    try std.testing.expectEqual(@as(u32, 0), state.currentAttempt());

    _ = state.nextDelay();
    _ = state.nextDelay();
    try std.testing.expectEqual(@as(u32, 2), state.currentAttempt());

    state.reset();
    try std.testing.expectEqual(@as(u32, 0), state.currentAttempt());
    try std.testing.expect(!state.isExhausted());
}

test "RetryState exhaustion" {
    var state = RetryState.init(.{ .max_retries = 2 });
    try std.testing.expect(!state.isExhausted());

    _ = state.nextDelay();
    _ = state.nextDelay();
    try std.testing.expect(state.isExhausted());
    try std.testing.expect(state.nextDelay() == null);
}

test "RetryState nextDelay returns increasing values" {
    var state = RetryState.init(.{
        .max_retries = 4,
        .initial_delay_ms = 100,
        .max_delay_ms = 10_000,
        .backoff_multiplier = 2,
    });

    const d0 = state.nextDelay().?;
    const d1 = state.nextDelay().?;
    const d2 = state.nextDelay().?;

    try std.testing.expectEqual(@as(u64, 100), d0);
    try std.testing.expectEqual(@as(u64, 200), d1);
    try std.testing.expectEqual(@as(u64, 400), d2);
}

test "computeDelay exponential backoff" {
    const config = RetryConfig{
        .initial_delay_ms = 100,
        .max_delay_ms = 5000,
        .backoff_multiplier = 2,
    };
    try std.testing.expectEqual(@as(u64, 100), computeDelay(config, 0));
    try std.testing.expectEqual(@as(u64, 200), computeDelay(config, 1));
    try std.testing.expectEqual(@as(u64, 400), computeDelay(config, 2));
    try std.testing.expectEqual(@as(u64, 800), computeDelay(config, 3));
}

test "computeDelay caps at max" {
    const config = RetryConfig{
        .initial_delay_ms = 1000,
        .max_delay_ms = 2000,
        .backoff_multiplier = 3,
    };
    try std.testing.expectEqual(@as(u64, 1000), computeDelay(config, 0));
    try std.testing.expectEqual(@as(u64, 2000), computeDelay(config, 1));
    try std.testing.expectEqual(@as(u64, 2000), computeDelay(config, 2));
    try std.testing.expectEqual(@as(u64, 2000), computeDelay(config, 10));
}

test "shouldRetry status codes" {
    try std.testing.expect(shouldRetry(429));
    try std.testing.expect(shouldRetry(500));
    try std.testing.expect(shouldRetry(502));
    try std.testing.expect(shouldRetry(503));
    try std.testing.expect(shouldRetry(504));
    try std.testing.expect(!shouldRetry(200));
    try std.testing.expect(!shouldRetry(400));
    try std.testing.expect(!shouldRetry(401));
    try std.testing.expect(!shouldRetry(404));
}

test "parseRetryAfter integer seconds" {
    try std.testing.expectEqual(@as(u64, 5000), parseRetryAfter("5").?);
    try std.testing.expectEqual(@as(u64, 60000), parseRetryAfter("60").?);
    try std.testing.expectEqual(@as(u64, 1000), parseRetryAfter("1").?);
}

test "parseRetryAfter empty or invalid" {
    try std.testing.expect(parseRetryAfter("") == null);
    try std.testing.expect(parseRetryAfter("not-a-number") == null);
    try std.testing.expect(parseRetryAfter("Thu, 01 Jan 2025 00:00:00 GMT") == null);
}

test "isTransientError" {
    try std.testing.expect(isTransientError(429));
    try std.testing.expect(isTransientError(500));
    try std.testing.expect(isTransientError(502));
    try std.testing.expect(isTransientError(503));
    try std.testing.expect(isTransientError(408));
    try std.testing.expect(!isTransientError(200));
    try std.testing.expect(!isTransientError(400));
    try std.testing.expect(!isTransientError(401));
}

test "RetryState full lifecycle" {
    var state = RetryState.init(.{ .max_retries = 2, .initial_delay_ms = 50 });

    // First attempt
    const d1 = state.nextDelay().?;
    try std.testing.expectEqual(@as(u64, 50), d1);

    // Second attempt
    const d2 = state.nextDelay().?;
    try std.testing.expectEqual(@as(u64, 100), d2);

    // Exhausted
    try std.testing.expect(state.isExhausted());
    try std.testing.expect(state.nextDelay() == null);

    // Reset and retry
    state.reset();
    try std.testing.expect(!state.isExhausted());
    try std.testing.expectEqual(@as(u64, 50), state.nextDelay().?);
}
