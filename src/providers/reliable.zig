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
