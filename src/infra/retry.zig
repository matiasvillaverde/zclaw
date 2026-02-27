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

// ===== Additional comprehensive tests =====

// --- RetryConfig edge cases ---

test "RetryConfig - zero max retries" {
    const config = RetryConfig{ .max_retries = 0 };
    try std.testing.expectEqual(@as(u32, 0), config.max_retries);
    var state = RetryState.init(config);
    try std.testing.expect(state.isExhausted());
    try std.testing.expect(state.nextDelay() == null);
}

test "RetryConfig - single retry" {
    var state = RetryState.init(.{ .max_retries = 1, .initial_delay_ms = 500 });
    try std.testing.expect(!state.isExhausted());
    const d = state.nextDelay().?;
    try std.testing.expectEqual(@as(u64, 500), d);
    try std.testing.expect(state.isExhausted());
    try std.testing.expect(state.nextDelay() == null);
}

test "RetryConfig - very high max retries" {
    var state = RetryState.init(.{ .max_retries = 1000, .initial_delay_ms = 1 });
    try std.testing.expect(!state.isExhausted());
    try std.testing.expectEqual(@as(u32, 0), state.currentAttempt());
}

test "RetryConfig - zero initial delay" {
    const config = RetryConfig{ .initial_delay_ms = 0, .max_delay_ms = 1000, .backoff_multiplier = 2 };
    // 0 * 2 = 0, should stay zero
    try std.testing.expectEqual(@as(u64, 0), computeDelay(config, 0));
    try std.testing.expectEqual(@as(u64, 0), computeDelay(config, 1));
    try std.testing.expectEqual(@as(u64, 0), computeDelay(config, 10));
}

test "RetryConfig - max_delay equals initial_delay" {
    const config = RetryConfig{
        .initial_delay_ms = 1000,
        .max_delay_ms = 1000,
        .backoff_multiplier = 2,
    };
    try std.testing.expectEqual(@as(u64, 1000), computeDelay(config, 0));
    try std.testing.expectEqual(@as(u64, 1000), computeDelay(config, 1));
    try std.testing.expectEqual(@as(u64, 1000), computeDelay(config, 5));
}

test "RetryConfig - multiplier of 1 (no backoff)" {
    const config = RetryConfig{
        .initial_delay_ms = 100,
        .max_delay_ms = 10000,
        .backoff_multiplier = 1,
    };
    try std.testing.expectEqual(@as(u64, 100), computeDelay(config, 0));
    try std.testing.expectEqual(@as(u64, 100), computeDelay(config, 1));
    try std.testing.expectEqual(@as(u64, 100), computeDelay(config, 5));
    try std.testing.expectEqual(@as(u64, 100), computeDelay(config, 100));
}

test "RetryConfig - large multiplier" {
    const config = RetryConfig{
        .initial_delay_ms = 100,
        .max_delay_ms = 60000,
        .backoff_multiplier = 10,
    };
    try std.testing.expectEqual(@as(u64, 100), computeDelay(config, 0));
    try std.testing.expectEqual(@as(u64, 1000), computeDelay(config, 1));
    try std.testing.expectEqual(@as(u64, 10000), computeDelay(config, 2));
    try std.testing.expectEqual(@as(u64, 60000), computeDelay(config, 3)); // capped
}

test "RetryConfig - jitter_factor field" {
    const config = RetryConfig{ .jitter_factor = 0 };
    try std.testing.expectEqual(@as(u32, 0), config.jitter_factor);

    const config2 = RetryConfig{ .jitter_factor = 100 };
    try std.testing.expectEqual(@as(u32, 100), config2.jitter_factor);
}

// --- computeDelay edge cases ---

test "computeDelay - attempt 0 always returns initial_delay" {
    const configs = [_]RetryConfig{
        .{ .initial_delay_ms = 1, .max_delay_ms = 100 },
        .{ .initial_delay_ms = 100, .max_delay_ms = 100 },
        .{ .initial_delay_ms = 5000, .max_delay_ms = 5000 },
    };
    for (configs) |config| {
        try std.testing.expectEqual(config.initial_delay_ms, computeDelay(config, 0));
    }
}

test "computeDelay - overflow protection with saturating multiply" {
    const config = RetryConfig{
        .initial_delay_ms = std.math.maxInt(u64) / 2,
        .max_delay_ms = std.math.maxInt(u64),
        .backoff_multiplier = 3,
    };
    // Should not overflow due to *|= (saturating multiply)
    const result = computeDelay(config, 5);
    try std.testing.expect(result <= config.max_delay_ms);
}

test "computeDelay - very high attempt number" {
    const config = RetryConfig{
        .initial_delay_ms = 1,
        .max_delay_ms = 1000,
        .backoff_multiplier = 2,
    };
    // After many doublings, should be capped at max
    try std.testing.expectEqual(@as(u64, 1000), computeDelay(config, 100));
    try std.testing.expectEqual(@as(u64, 1000), computeDelay(config, 1000));
}

test "computeDelay - multiplier 3 progression" {
    const config = RetryConfig{
        .initial_delay_ms = 10,
        .max_delay_ms = 100000,
        .backoff_multiplier = 3,
    };
    try std.testing.expectEqual(@as(u64, 10), computeDelay(config, 0));
    try std.testing.expectEqual(@as(u64, 30), computeDelay(config, 1));
    try std.testing.expectEqual(@as(u64, 90), computeDelay(config, 2));
    try std.testing.expectEqual(@as(u64, 270), computeDelay(config, 3));
    try std.testing.expectEqual(@as(u64, 810), computeDelay(config, 4));
}

test "computeDelay - multiplier 0 results in zero delay" {
    const config = RetryConfig{
        .initial_delay_ms = 1000,
        .max_delay_ms = 10000,
        .backoff_multiplier = 0,
    };
    // 1000 * 0 = 0
    try std.testing.expectEqual(@as(u64, 1000), computeDelay(config, 0));
    try std.testing.expectEqual(@as(u64, 0), computeDelay(config, 1));
}

// --- RetryState extended ---

test "RetryState - multiple resets" {
    var state = RetryState.init(.{ .max_retries = 2, .initial_delay_ms = 100 });

    // First cycle
    _ = state.nextDelay();
    _ = state.nextDelay();
    try std.testing.expect(state.isExhausted());

    // Reset 1
    state.reset();
    try std.testing.expect(!state.isExhausted());
    try std.testing.expectEqual(@as(u32, 0), state.currentAttempt());

    // Second cycle
    _ = state.nextDelay();
    _ = state.nextDelay();
    try std.testing.expect(state.isExhausted());

    // Reset 2
    state.reset();
    try std.testing.expect(!state.isExhausted());
}

test "RetryState - reset before any attempts" {
    var state = RetryState.init(DEFAULT_CONFIG);
    state.reset();
    try std.testing.expectEqual(@as(u32, 0), state.currentAttempt());
    try std.testing.expect(!state.isExhausted());
}

test "RetryState - currentAttempt tracks correctly" {
    var state = RetryState.init(.{ .max_retries = 5 });
    try std.testing.expectEqual(@as(u32, 0), state.currentAttempt());
    _ = state.nextDelay();
    try std.testing.expectEqual(@as(u32, 1), state.currentAttempt());
    _ = state.nextDelay();
    try std.testing.expectEqual(@as(u32, 2), state.currentAttempt());
    _ = state.nextDelay();
    try std.testing.expectEqual(@as(u32, 3), state.currentAttempt());
}

test "RetryState - nextDelay returns null repeatedly after exhaustion" {
    var state = RetryState.init(.{ .max_retries = 1 });
    _ = state.nextDelay();
    try std.testing.expect(state.nextDelay() == null);
    try std.testing.expect(state.nextDelay() == null);
    try std.testing.expect(state.nextDelay() == null);
    // Attempt should not increase beyond max
    try std.testing.expectEqual(@as(u32, 1), state.currentAttempt());
}

test "RetryState - delays increase then cap" {
    var state = RetryState.init(.{
        .max_retries = 10,
        .initial_delay_ms = 100,
        .max_delay_ms = 500,
        .backoff_multiplier = 2,
    });

    try std.testing.expectEqual(@as(u64, 100), state.nextDelay().?);
    try std.testing.expectEqual(@as(u64, 200), state.nextDelay().?);
    try std.testing.expectEqual(@as(u64, 400), state.nextDelay().?);
    try std.testing.expectEqual(@as(u64, 500), state.nextDelay().?); // capped
    try std.testing.expectEqual(@as(u64, 500), state.nextDelay().?); // still capped
}

// --- shouldRetry extended ---

test "shouldRetry - all retryable codes" {
    const retryable = [_]u16{ 429, 500, 502, 503, 504 };
    for (retryable) |code| {
        try std.testing.expect(shouldRetry(code));
    }
}

test "shouldRetry - all non-retryable 4xx codes" {
    const non_retryable = [_]u16{ 400, 401, 402, 403, 404, 405, 406, 407, 408, 409, 410, 411, 412, 413, 414, 415, 416, 417, 418, 422, 426, 428 };
    for (non_retryable) |code| {
        try std.testing.expect(!shouldRetry(code));
    }
}

test "shouldRetry - all 2xx codes are non-retryable" {
    const success = [_]u16{ 200, 201, 202, 203, 204, 205, 206 };
    for (success) |code| {
        try std.testing.expect(!shouldRetry(code));
    }
}

test "shouldRetry - 3xx codes are non-retryable" {
    const redirect = [_]u16{ 300, 301, 302, 303, 304, 307, 308 };
    for (redirect) |code| {
        try std.testing.expect(!shouldRetry(code));
    }
}

test "shouldRetry - 5xx non-retryable" {
    // Only 500, 502, 503, 504 are retryable; others in 5xx are not
    try std.testing.expect(!shouldRetry(501));
    try std.testing.expect(!shouldRetry(505));
    try std.testing.expect(!shouldRetry(506));
    try std.testing.expect(!shouldRetry(507));
    try std.testing.expect(!shouldRetry(508));
    try std.testing.expect(!shouldRetry(510));
    try std.testing.expect(!shouldRetry(511));
}

test "shouldRetry - boundary values" {
    try std.testing.expect(!shouldRetry(0));
    try std.testing.expect(!shouldRetry(1));
    try std.testing.expect(!shouldRetry(99));
    try std.testing.expect(!shouldRetry(100));
    try std.testing.expect(!shouldRetry(199));
    try std.testing.expect(!shouldRetry(65535));
}

// --- parseRetryAfter extended ---

test "parseRetryAfter - zero seconds" {
    try std.testing.expectEqual(@as(u64, 0), parseRetryAfter("0").?);
}

test "parseRetryAfter - large values" {
    try std.testing.expectEqual(@as(u64, 3600000), parseRetryAfter("3600").?);
    try std.testing.expectEqual(@as(u64, 86400000), parseRetryAfter("86400").?);
}

test "parseRetryAfter - single digit" {
    try std.testing.expectEqual(@as(u64, 1000), parseRetryAfter("1").?);
    try std.testing.expectEqual(@as(u64, 9000), parseRetryAfter("9").?);
}

test "parseRetryAfter - whitespace is invalid" {
    try std.testing.expect(parseRetryAfter(" 5") == null);
    try std.testing.expect(parseRetryAfter("5 ") == null);
    try std.testing.expect(parseRetryAfter(" ") == null);
}

test "parseRetryAfter - negative number is invalid" {
    try std.testing.expect(parseRetryAfter("-1") == null);
    try std.testing.expect(parseRetryAfter("-100") == null);
}

test "parseRetryAfter - decimal is invalid" {
    try std.testing.expect(parseRetryAfter("1.5") == null);
    try std.testing.expect(parseRetryAfter("0.5") == null);
}

test "parseRetryAfter - HTTP date formats are not supported" {
    try std.testing.expect(parseRetryAfter("Mon, 01 Jan 2025 00:00:00 GMT") == null);
    try std.testing.expect(parseRetryAfter("Sat, 15 Mar 2025 12:30:00 GMT") == null);
}

test "parseRetryAfter - hex string is invalid" {
    try std.testing.expect(parseRetryAfter("0xff") == null);
    try std.testing.expect(parseRetryAfter("abc") == null);
}

// --- isTransientError extended ---

test "isTransientError - all transient codes" {
    try std.testing.expect(isTransientError(408)); // Request Timeout
    try std.testing.expect(isTransientError(429)); // Rate Limited
    try std.testing.expect(isTransientError(500)); // Internal Server Error
    try std.testing.expect(isTransientError(501)); // Not Implemented (>= 500)
    try std.testing.expect(isTransientError(502)); // Bad Gateway
    try std.testing.expect(isTransientError(503)); // Service Unavailable
    try std.testing.expect(isTransientError(504)); // Gateway Timeout
}

test "isTransientError - all 5xx are transient" {
    const codes = [_]u16{ 500, 501, 502, 503, 504, 505, 506, 507, 508, 510, 511 };
    for (codes) |code| {
        try std.testing.expect(isTransientError(code));
    }
}

test "isTransientError - 4xx non-transient except 408 and 429" {
    const non_transient = [_]u16{ 400, 401, 402, 403, 404, 405, 406, 407, 409, 410, 411, 412, 413, 414, 415, 416, 417, 418, 422, 426, 428 };
    for (non_transient) |code| {
        try std.testing.expect(!isTransientError(code));
    }
}

test "isTransientError - success codes are not transient" {
    try std.testing.expect(!isTransientError(200));
    try std.testing.expect(!isTransientError(201));
    try std.testing.expect(!isTransientError(204));
}

test "isTransientError vs shouldRetry - difference for 408" {
    // 408 is transient but not in shouldRetry
    try std.testing.expect(isTransientError(408));
    try std.testing.expect(!shouldRetry(408));
}

test "isTransientError vs shouldRetry - difference for 501" {
    // 501 is transient (>= 500) but not in shouldRetry
    try std.testing.expect(isTransientError(501));
    try std.testing.expect(!shouldRetry(501));
}

// --- DEFAULT_CONFIG tests ---

test "DEFAULT_CONFIG values" {
    try std.testing.expectEqual(@as(u32, 3), DEFAULT_CONFIG.max_retries);
    try std.testing.expectEqual(@as(u64, 1000), DEFAULT_CONFIG.initial_delay_ms);
    try std.testing.expectEqual(@as(u64, 30_000), DEFAULT_CONFIG.max_delay_ms);
    try std.testing.expectEqual(@as(u32, 2), DEFAULT_CONFIG.backoff_multiplier);
    try std.testing.expectEqual(@as(u32, 25), DEFAULT_CONFIG.jitter_factor);
}

test "DEFAULT_CONFIG delays" {
    try std.testing.expectEqual(@as(u64, 1000), computeDelay(DEFAULT_CONFIG, 0));
    try std.testing.expectEqual(@as(u64, 2000), computeDelay(DEFAULT_CONFIG, 1));
    try std.testing.expectEqual(@as(u64, 4000), computeDelay(DEFAULT_CONFIG, 2));
}

test "RetryState - init preserves config" {
    const config = RetryConfig{
        .max_retries = 7,
        .initial_delay_ms = 500,
        .max_delay_ms = 60000,
        .backoff_multiplier = 3,
        .jitter_factor = 50,
    };
    const state = RetryState.init(config);
    try std.testing.expectEqual(@as(u32, 7), state.config.max_retries);
    try std.testing.expectEqual(@as(u64, 500), state.config.initial_delay_ms);
    try std.testing.expectEqual(@as(u64, 60000), state.config.max_delay_ms);
    try std.testing.expectEqual(@as(u32, 3), state.config.backoff_multiplier);
    try std.testing.expectEqual(@as(u32, 50), state.config.jitter_factor);
    try std.testing.expectEqual(@as(u32, 0), state.attempt);
}
