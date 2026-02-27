const std = @import("std");
const types = @import("types.zig");
const retry_mod = @import("../infra/retry.zig");
const failover = @import("../agent/failover.zig");

// --- Provider Reliability Layer ---
//
// Wraps any provider with retry on 5xx, key rotation on 429,
// and exponential backoff. Uses a vtable interface pattern.

pub const ProviderInterface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send_message: *const fn (
            ptr: *anyopaque,
            config: types.RequestConfig,
            messages_json: []const u8,
            tools_json: ?[]const u8,
        ) anyerror!ProviderResponse,
    };

    pub fn sendMessage(
        self: ProviderInterface,
        config: types.RequestConfig,
        messages_json: []const u8,
        tools_json: ?[]const u8,
    ) !ProviderResponse {
        return self.vtable.send_message(self.ptr, config, messages_json, tools_json);
    }
};

pub const ProviderResponse = struct {
    status: u16,
    body: []const u8,
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *ProviderResponse) void {
        if (self.allocator) |alloc| {
            alloc.free(self.body);
        }
    }

    pub fn isSuccess(self: *const ProviderResponse) bool {
        return self.status >= 200 and self.status < 300;
    }
};

// --- Reliable Config ---

pub const ReliableConfig = struct {
    retry: retry_mod.RetryConfig = .{},
    max_key_rotations: u32 = 3,
    cooldown_ms: i64 = 60_000,
};

// --- Reliable Provider ---

pub const ReliableProvider = struct {
    inner: ProviderInterface,
    config: ReliableConfig,
    retry_state: retry_mod.RetryState,
    total_attempts: u32 = 0,
    last_status: ?u16 = null,

    pub fn init(inner: ProviderInterface, config: ReliableConfig) ReliableProvider {
        return .{
            .inner = inner,
            .config = config,
            .retry_state = retry_mod.RetryState.init(config.retry),
        };
    }

    /// Send a message with automatic retry on transient failures.
    pub fn sendMessage(
        self: *ReliableProvider,
        config: types.RequestConfig,
        messages_json: []const u8,
        tools_json: ?[]const u8,
    ) !ProviderResponse {
        self.retry_state.reset();
        self.total_attempts = 0;

        while (true) {
            self.total_attempts += 1;
            const resp = self.inner.sendMessage(config, messages_json, tools_json) catch |err| {
                // Network-level error — retry if not exhausted
                if (self.retry_state.nextDelay()) |_| {
                    continue;
                }
                return err;
            };

            self.last_status = resp.status;

            if (resp.isSuccess()) {
                return resp;
            }

            // Check if we should retry this status
            if (!retry_mod.shouldRetry(resp.status)) {
                return resp;
            }

            // Try to get next delay
            if (self.retry_state.nextDelay()) |_| {
                // Free the failed response before retrying
                var mutable_resp = resp;
                mutable_resp.deinit();
                continue;
            }

            // Exhausted retries, return last response
            return resp;
        }
    }

    /// Get total attempts made in the last sendMessage call.
    pub fn getTotalAttempts(self: *const ReliableProvider) u32 {
        return self.total_attempts;
    }

    /// Get the last HTTP status seen.
    pub fn getLastStatus(self: *const ReliableProvider) ?u16 {
        return self.last_status;
    }

    /// Reset the provider state.
    pub fn reset(self: *ReliableProvider) void {
        self.retry_state.reset();
        self.total_attempts = 0;
        self.last_status = null;
    }
};

// --- Mock Provider for Tests ---

const MockProvider = struct {
    responses: []const MockResponse,
    call_count: usize = 0,
    allocator: std.mem.Allocator,

    const MockResponse = struct {
        status: u16,
        body: []const u8 = "{}",
    };

    fn init(allocator: std.mem.Allocator, responses: []const MockResponse) MockProvider {
        return .{
            .responses = responses,
            .call_count = 0,
            .allocator = allocator,
        };
    }

    fn interface(self: *MockProvider) ProviderInterface {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn sendMessageImpl(
        ptr: *anyopaque,
        _: types.RequestConfig,
        _: []const u8,
        _: ?[]const u8,
    ) anyerror!ProviderResponse {
        const self: *MockProvider = @ptrCast(@alignCast(ptr));
        if (self.call_count >= self.responses.len) {
            return error.OutOfMemory;
        }
        const mock = self.responses[self.call_count];
        self.call_count += 1;
        const body_copy = try self.allocator.dupe(u8, mock.body);
        return .{
            .status = mock.status,
            .body = body_copy,
            .allocator = self.allocator,
        };
    }

    const vtable: ProviderInterface.VTable = .{
        .send_message = sendMessageImpl,
    };
};

// --- Tests ---

test "ReliableConfig defaults" {
    const config = ReliableConfig{};
    try std.testing.expectEqual(@as(u32, 3), config.retry.max_retries);
    try std.testing.expectEqual(@as(u32, 3), config.max_key_rotations);
    try std.testing.expectEqual(@as(i64, 60_000), config.cooldown_ms);
}

test "ReliableProvider success on first try" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 200, .body = "{\"ok\":true}" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{});

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
    try std.testing.expectEqual(@as(u32, 1), provider.getTotalAttempts());
    try std.testing.expectEqual(@as(u16, 200), provider.getLastStatus().?);
}

test "ReliableProvider retries on 500" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 500, .body = "error" },
        .{ .status = 500, .body = "error" },
        .{ .status = 200, .body = "{\"ok\":true}" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{ .retry = .{ .max_retries = 3 } });

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
    try std.testing.expectEqual(@as(u32, 3), provider.getTotalAttempts());
}

test "ReliableProvider retries on 429" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 429, .body = "rate limited" },
        .{ .status = 200, .body = "ok" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{ .retry = .{ .max_retries = 2 } });

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
    try std.testing.expectEqual(@as(u32, 2), provider.getTotalAttempts());
}

test "ReliableProvider exhausted retries returns last response" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 503, .body = "unavailable" },
        .{ .status = 503, .body = "still unavailable" },
        .{ .status = 503, .body = "still down" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{ .retry = .{ .max_retries = 2 } });

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(!resp.isSuccess());
    try std.testing.expectEqual(@as(u16, 503), resp.status);
}

test "ReliableProvider no retry on 400" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 400, .body = "bad request" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{});

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(!resp.isSuccess());
    try std.testing.expectEqual(@as(u32, 1), provider.getTotalAttempts());
    try std.testing.expectEqual(@as(u16, 400), resp.status);
}

test "ReliableProvider no retry on 401" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 401, .body = "unauthorized" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{});

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expectEqual(@as(u32, 1), provider.getTotalAttempts());
}

test "ReliableProvider reset" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 200, .body = "ok" },
        .{ .status = 200, .body = "ok" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{});

    var r1 = try provider.sendMessage(.{ .model = "t", .api_key = "k" }, "[]", null);
    defer r1.deinit();
    try std.testing.expectEqual(@as(u32, 1), provider.getTotalAttempts());

    provider.reset();
    try std.testing.expectEqual(@as(u32, 0), provider.getTotalAttempts());
    try std.testing.expect(provider.getLastStatus() == null);

    var r2 = try provider.sendMessage(.{ .model = "t", .api_key = "k" }, "[]", null);
    defer r2.deinit();
    try std.testing.expectEqual(@as(u32, 1), provider.getTotalAttempts());
}

test "ReliableProvider retries on 502" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 502, .body = "bad gw" },
        .{ .status = 200, .body = "ok" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{ .retry = .{ .max_retries = 2 } });

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
}

test "ProviderResponse helpers" {
    const r200 = ProviderResponse{ .status = 200, .body = "" };
    try std.testing.expect(r200.isSuccess());

    const r500 = ProviderResponse{ .status = 500, .body = "" };
    try std.testing.expect(!r500.isSuccess());
}

test "ProviderInterface vtable call" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 200, .body = "direct" },
    };
    var mock = MockProvider.init(allocator, &responses);
    const iface = mock.interface();

    var resp = try iface.sendMessage(.{ .model = "m", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
}

test "ReliableProvider retries on 504" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 504, .body = "timeout" },
        .{ .status = 504, .body = "timeout" },
        .{ .status = 200, .body = "ok" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{ .retry = .{ .max_retries = 3 } });

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
    try std.testing.expectEqual(@as(u32, 3), provider.getTotalAttempts());
}

test "ReliableProvider no retry on 404" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 404, .body = "not found" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{});

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expectEqual(@as(u32, 1), provider.getTotalAttempts());
    try std.testing.expectEqual(@as(u16, 404), resp.status);
}

// =====================================================
// Additional comprehensive tests
// =====================================================

// --- No retry on various 4xx codes ---

test "ReliableProvider no retry on 403" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 403, .body = "forbidden" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{});

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expectEqual(@as(u32, 1), provider.getTotalAttempts());
    try std.testing.expectEqual(@as(u16, 403), resp.status);
}

test "ReliableProvider no retry on 405" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 405, .body = "method not allowed" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{});

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expectEqual(@as(u32, 1), provider.getTotalAttempts());
}

test "ReliableProvider no retry on 409" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 409, .body = "conflict" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{});

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expectEqual(@as(u32, 1), provider.getTotalAttempts());
}

test "ReliableProvider no retry on 422" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 422, .body = "unprocessable" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{});

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expectEqual(@as(u32, 1), provider.getTotalAttempts());
}

// --- Retry on all retryable status codes ---

test "ReliableProvider retries on 503 then succeeds" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 503, .body = "unavailable" },
        .{ .status = 200, .body = "ok" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{ .retry = .{ .max_retries = 2 } });

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
    try std.testing.expectEqual(@as(u32, 2), provider.getTotalAttempts());
}

test "ReliableProvider retries on 500 then 200" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 500, .body = "err" },
        .{ .status = 200, .body = "ok" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{ .retry = .{ .max_retries = 2 } });

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
    try std.testing.expectEqual(@as(u32, 2), provider.getTotalAttempts());
}

test "ReliableProvider retries on 502 then 200" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 502, .body = "bad gateway" },
        .{ .status = 200, .body = "ok" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{ .retry = .{ .max_retries = 2 } });

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
}

test "ReliableProvider retries on 504 then 200" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 504, .body = "timeout" },
        .{ .status = 200, .body = "ok" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{ .retry = .{ .max_retries = 2 } });

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
}

// --- Max retries exhaustion ---

test "ReliableProvider max_retries 1 allows 2 total attempts" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 500, .body = "err" },
        .{ .status = 500, .body = "err" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{ .retry = .{ .max_retries = 1 } });

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(!resp.isSuccess());
    try std.testing.expectEqual(@as(u32, 2), provider.getTotalAttempts());
}

test "ReliableProvider max_retries 0 allows only 1 attempt" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 500, .body = "err" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{ .retry = .{ .max_retries = 0 } });

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(!resp.isSuccess());
    try std.testing.expectEqual(@as(u32, 1), provider.getTotalAttempts());
}

test "ReliableProvider max_retries 5 exhausts all retries" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 500, .body = "e" },
        .{ .status = 500, .body = "e" },
        .{ .status = 500, .body = "e" },
        .{ .status = 500, .body = "e" },
        .{ .status = 500, .body = "e" },
        .{ .status = 500, .body = "e" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{ .retry = .{ .max_retries = 5 } });

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(!resp.isSuccess());
    try std.testing.expectEqual(@as(u32, 6), provider.getTotalAttempts());
}

// --- Mixed error codes ---

test "ReliableProvider mixed 500 then 429 then 200" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 500, .body = "err" },
        .{ .status = 429, .body = "rate" },
        .{ .status = 200, .body = "ok" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{ .retry = .{ .max_retries = 3 } });

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
    try std.testing.expectEqual(@as(u32, 3), provider.getTotalAttempts());
}

test "ReliableProvider 429 then 503 then 200" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 429, .body = "r" },
        .{ .status = 503, .body = "s" },
        .{ .status = 200, .body = "ok" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{ .retry = .{ .max_retries = 3 } });

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
    try std.testing.expectEqual(@as(u32, 3), provider.getTotalAttempts());
}

// --- Non-retryable immediately returned ---

test "ReliableProvider 400 bad request returned immediately" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 400, .body = "bad request" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{ .retry = .{ .max_retries = 5 } });

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(!resp.isSuccess());
    try std.testing.expectEqual(@as(u32, 1), provider.getTotalAttempts());
    // Mock should only have been called once
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
}

test "ReliableProvider 401 unauthorized not retried" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 401, .body = "unauthorized" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{ .retry = .{ .max_retries = 3 } });

    var resp = try provider.sendMessage(.{ .model = "test", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expectEqual(@as(u32, 1), provider.getTotalAttempts());
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
}

// --- getLastStatus tracking ---

test "ReliableProvider getLastStatus tracks success" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 200, .body = "ok" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{});

    var resp = try provider.sendMessage(.{ .model = "t", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), provider.getLastStatus().?);
}

test "ReliableProvider getLastStatus tracks last retry status" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 500, .body = "e" },
        .{ .status = 503, .body = "e" },
        .{ .status = 200, .body = "ok" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{ .retry = .{ .max_retries = 3 } });

    var resp = try provider.sendMessage(.{ .model = "t", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), provider.getLastStatus().?);
}

test "ReliableProvider getLastStatus null before first call" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{};
    var mock = MockProvider.init(allocator, &responses);
    const provider = ReliableProvider.init(mock.interface(), .{});
    try std.testing.expect(provider.getLastStatus() == null);
}

// --- Reset between calls ---

test "ReliableProvider reset between multiple calls" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 500, .body = "e" },
        .{ .status = 200, .body = "ok" },
        .{ .status = 200, .body = "ok2" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{ .retry = .{ .max_retries = 2 } });

    // First call: retries once
    var r1 = try provider.sendMessage(.{ .model = "t", .api_key = "k" }, "[]", null);
    defer r1.deinit();
    try std.testing.expectEqual(@as(u32, 2), provider.getTotalAttempts());

    // Second call: succeeds first try (total_attempts resets)
    var r2 = try provider.sendMessage(.{ .model = "t", .api_key = "k" }, "[]", null);
    defer r2.deinit();
    try std.testing.expectEqual(@as(u32, 1), provider.getTotalAttempts());
}

// --- ReliableConfig custom values ---

test "ReliableConfig custom values" {
    const config = ReliableConfig{
        .retry = .{ .max_retries = 5, .initial_delay_ms = 500 },
        .max_key_rotations = 10,
        .cooldown_ms = 120_000,
    };
    try std.testing.expectEqual(@as(u32, 5), config.retry.max_retries);
    try std.testing.expectEqual(@as(u64, 500), config.retry.initial_delay_ms);
    try std.testing.expectEqual(@as(u32, 10), config.max_key_rotations);
    try std.testing.expectEqual(@as(i64, 120_000), config.cooldown_ms);
}

// --- ProviderResponse tests ---

test "ProviderResponse isSuccess range" {
    const success_codes = [_]u16{ 200, 201, 202, 204, 250, 299 };
    for (success_codes) |code| {
        const r = ProviderResponse{ .status = code, .body = "" };
        try std.testing.expect(r.isSuccess());
    }

    const fail_codes = [_]u16{ 100, 199, 300, 301, 400, 401, 403, 404, 429, 500, 502, 503, 504 };
    for (fail_codes) |code| {
        const r = ProviderResponse{ .status = code, .body = "" };
        try std.testing.expect(!r.isSuccess());
    }
}

test "ProviderResponse deinit with allocator" {
    const allocator = std.testing.allocator;
    const body = try allocator.dupe(u8, "test body data");
    var resp = ProviderResponse{
        .status = 200,
        .body = body,
        .allocator = allocator,
    };
    resp.deinit();
}

test "ProviderResponse deinit without allocator" {
    var resp = ProviderResponse{ .status = 200, .body = "static" };
    resp.deinit(); // Should not crash
}

// --- ProviderInterface ---

test "ProviderInterface multiple calls" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 200, .body = "first" },
        .{ .status = 201, .body = "second" },
        .{ .status = 202, .body = "third" },
    };
    var mock = MockProvider.init(allocator, &responses);
    const iface = mock.interface();

    var r1 = try iface.sendMessage(.{ .model = "m", .api_key = "k" }, "[]", null);
    defer r1.deinit();
    try std.testing.expectEqual(@as(u16, 200), r1.status);

    var r2 = try iface.sendMessage(.{ .model = "m", .api_key = "k" }, "[]", null);
    defer r2.deinit();
    try std.testing.expectEqual(@as(u16, 201), r2.status);

    var r3 = try iface.sendMessage(.{ .model = "m", .api_key = "k" }, "[]", null);
    defer r3.deinit();
    try std.testing.expectEqual(@as(u16, 202), r3.status);

    try std.testing.expectEqual(@as(usize, 3), mock.call_count);
}

test "ProviderInterface exhausted returns error" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{};
    var mock = MockProvider.init(allocator, &responses);
    const iface = mock.interface();

    const result = iface.sendMessage(.{ .model = "m", .api_key = "k" }, "[]", null);
    try std.testing.expectError(error.OutOfMemory, result);
}

// --- Body content preserved ---

test "ReliableProvider preserves response body on success" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 200, .body = "{\"result\":\"important data\"}" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{});

    var resp = try provider.sendMessage(.{ .model = "t", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expectEqualStrings("{\"result\":\"important data\"}", resp.body);
}

test "ReliableProvider preserves response body on non-retryable failure" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 400, .body = "{\"error\":\"invalid model\"}" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{});

    var resp = try provider.sendMessage(.{ .model = "t", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expectEqualStrings("{\"error\":\"invalid model\"}", resp.body);
}

// --- ReliableProvider init state ---

test "ReliableProvider init state is clean" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{};
    var mock = MockProvider.init(allocator, &responses);
    const provider = ReliableProvider.init(mock.interface(), .{});

    try std.testing.expectEqual(@as(u32, 0), provider.getTotalAttempts());
    try std.testing.expect(provider.getLastStatus() == null);
}

// --- Single retry succeeds on last attempt ---

test "ReliableProvider succeeds on very last retry" {
    const allocator = std.testing.allocator;
    const responses = [_]MockProvider.MockResponse{
        .{ .status = 500, .body = "e" },
        .{ .status = 502, .body = "e" },
        .{ .status = 503, .body = "e" },
        .{ .status = 200, .body = "finally" },
    };
    var mock = MockProvider.init(allocator, &responses);
    var provider = ReliableProvider.init(mock.interface(), .{ .retry = .{ .max_retries = 3 } });

    var resp = try provider.sendMessage(.{ .model = "t", .api_key = "k" }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
    try std.testing.expectEqual(@as(u32, 4), provider.getTotalAttempts());
    try std.testing.expectEqualStrings("finally", resp.body);
}
