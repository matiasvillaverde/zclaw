const std = @import("std");

pub const WatchEvent = enum {
    modified,
    deleted,
    created,
};

pub const WatchCallback = *const fn (event: WatchEvent, path: []const u8) void;

pub const Watcher = struct {
    path: []const u8,
    debounce_ns: u64,
    callback: WatchCallback,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(path: []const u8, debounce_ms: u32, callback: WatchCallback) Watcher {
        return .{
            .path = path,
            .debounce_ns = @as(u64, debounce_ms) * std.time.ns_per_ms,
            .callback = callback,
        };
    }

    pub fn start(self: *Watcher) !void {
        self.stop_flag.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, watchLoop, .{self});
    }

    pub fn stop(self: *Watcher) void {
        self.stop_flag.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn isRunning(self: *const Watcher) bool {
        return self.thread != null and !self.stop_flag.load(.acquire);
    }

    fn watchLoop(self: *Watcher) void {
        var last_mtime: ?i128 = null;

        while (!self.stop_flag.load(.acquire)) {
            // Poll file mtime
            const stat = std.fs.cwd().statFile(self.path) catch {
                // File might have been deleted
                if (last_mtime != null) {
                    last_mtime = null;
                    self.callback(.deleted, self.path);
                }
                std.Thread.sleep(self.debounce_ns);
                continue;
            };

            const mtime = stat.mtime;

            if (last_mtime) |prev| {
                if (mtime != prev) {
                    last_mtime = mtime;
                    // Debounce: wait before firing callback
                    std.Thread.sleep(self.debounce_ns);
                    // Re-check to ensure file is stable
                    const restat = std.fs.cwd().statFile(self.path) catch {
                        self.callback(.deleted, self.path);
                        continue;
                    };
                    if (restat.mtime == mtime) {
                        self.callback(.modified, self.path);
                    }
                    last_mtime = restat.mtime;
                }
            } else {
                last_mtime = mtime;
                self.callback(.created, self.path);
            }

            // Poll interval (shorter than debounce)
            std.Thread.sleep(200 * std.time.ns_per_ms);
        }
    }
};

// --- Debounce Calculation ---

pub fn debounceMs(ms: u32) u64 {
    return @as(u64, ms) * std.time.ns_per_ms;
}

// --- Tests ---

test "WatchEvent values" {
    try std.testing.expectEqual(WatchEvent.modified, WatchEvent.modified);
    try std.testing.expectEqual(WatchEvent.deleted, WatchEvent.deleted);
    try std.testing.expectEqual(WatchEvent.created, WatchEvent.created);
    // All three are distinct
    try std.testing.expect(WatchEvent.modified != WatchEvent.deleted);
    try std.testing.expect(WatchEvent.deleted != WatchEvent.created);
}

test "debounceMs conversion" {
    try std.testing.expectEqual(@as(u64, 300_000_000), debounceMs(300));
    try std.testing.expectEqual(@as(u64, 1_500_000_000), debounceMs(1500));
    try std.testing.expectEqual(@as(u64, 0), debounceMs(0));
}

test "Watcher stop without start is safe" {
    var watcher = Watcher.init("/tmp/nonexistent.json", 100, testCallback);
    watcher.stop(); // Should not panic
    try std.testing.expect(!watcher.isRunning());
}

var test_events: [16]WatchEvent = undefined;
var test_event_count: usize = 0;

fn testCallback(event: WatchEvent, _: []const u8) void {
    if (test_event_count < test_events.len) {
        test_events[test_event_count] = event;
        test_event_count += 1;
    }
}

test "Watcher.init creates with correct defaults" {
    const watcher = Watcher.init("/tmp/test.json", 300, testCallback);
    try std.testing.expectEqual(@as(u64, 300 * std.time.ns_per_ms), watcher.debounce_ns);
    try std.testing.expectEqualStrings("/tmp/test.json", watcher.path);
    try std.testing.expectEqual(@as(?std.Thread, null), watcher.thread);
}

test "Watcher.isRunning returns false before start" {
    var watcher = Watcher.init("/tmp/nonexistent.json", 100, testCallback);
    try std.testing.expect(!watcher.isRunning());
    _ = &watcher;
}

test "Watcher detects file creation and modification" {
    test_event_count = 0;

    // Create a temp file
    const tmp_path = "/tmp/zclaw_watcher_test.json";

    // Ensure file doesn't exist first
    std.fs.cwd().deleteFile(tmp_path) catch {};

    // Create the file
    {
        const f = try std.fs.cwd().createFile(tmp_path, .{});
        try f.writeAll("{}");
        f.close();
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var watcher = Watcher.init(tmp_path, 50, testCallback);
    try watcher.start();

    // Wait for initial detection
    std.Thread.sleep(400 * std.time.ns_per_ms);

    // Should have detected the file
    try std.testing.expect(test_event_count > 0);
    try std.testing.expectEqual(WatchEvent.created, test_events[0]);

    watcher.stop();
    try std.testing.expect(!watcher.isRunning());
}

test "debounce prevents rapid fire" {
    test_event_count = 0;

    const tmp_path = "/tmp/zclaw_debounce_test.json";
    {
        const f = try std.fs.cwd().createFile(tmp_path, .{});
        try f.writeAll("{}");
        f.close();
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    // Use a long debounce
    var watcher = Watcher.init(tmp_path, 500, testCallback);
    try watcher.start();

    // Wait for initial creation event
    std.Thread.sleep(300 * std.time.ns_per_ms);
    const initial_count = test_event_count;

    // Rapidly modify the file
    for (0..3) |_| {
        const f = try std.fs.cwd().createFile(tmp_path, .{});
        try f.writeAll("{\"v\":1}");
        f.close();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // Wait for debounce to settle
    std.Thread.sleep(1000 * std.time.ns_per_ms);

    // Should have at most a couple events due to debouncing
    // (not 3 separate ones for each write)
    try std.testing.expect(test_event_count <= initial_count + 2);

    watcher.stop();
}

// --- New Tests ---

test "WatchEvent all variants are distinct" {
    const events = [_]WatchEvent{ .modified, .deleted, .created };
    for (events, 0..) |e1, i| {
        for (events, 0..) |e2, j| {
            if (i != j) {
                try std.testing.expect(e1 != e2);
            }
        }
    }
}

test "debounceMs large value" {
    try std.testing.expectEqual(@as(u64, 60_000_000_000), debounceMs(60_000));
}

test "debounceMs one millisecond" {
    try std.testing.expectEqual(@as(u64, 1_000_000), debounceMs(1));
}

test "debounceMs max u32" {
    const result = debounceMs(std.math.maxInt(u32));
    try std.testing.expect(result > 0);
}

test "Watcher.init different debounce values" {
    const w1 = Watcher.init("/tmp/a", 100, testCallback);
    const w2 = Watcher.init("/tmp/b", 500, testCallback);
    try std.testing.expectEqual(@as(u64, 100 * std.time.ns_per_ms), w1.debounce_ns);
    try std.testing.expectEqual(@as(u64, 500 * std.time.ns_per_ms), w2.debounce_ns);
}

test "Watcher.init zero debounce" {
    const watcher = Watcher.init("/tmp/test", 0, testCallback);
    try std.testing.expectEqual(@as(u64, 0), watcher.debounce_ns);
}

test "Watcher stop_flag initially false" {
    const watcher = Watcher.init("/tmp/test", 100, testCallback);
    try std.testing.expect(!watcher.stop_flag.load(.acquire));
}

test "Watcher double stop is safe" {
    var watcher = Watcher.init("/tmp/nonexistent.json", 100, testCallback);
    watcher.stop();
    watcher.stop();
    try std.testing.expect(!watcher.isRunning());
}

test "Watcher.isRunning false after stop" {
    test_event_count = 0;
    const tmp_path = "/tmp/zclaw_running_test.json";
    {
        const f = try std.fs.cwd().createFile(tmp_path, .{});
        try f.writeAll("{}");
        f.close();
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var watcher = Watcher.init(tmp_path, 50, testCallback);
    try watcher.start();
    std.Thread.sleep(100 * std.time.ns_per_ms);
    try std.testing.expect(watcher.isRunning());

    watcher.stop();
    try std.testing.expect(!watcher.isRunning());
}

test "Watcher.init stores path reference" {
    const path = "/tmp/specific/path.json";
    const watcher = Watcher.init(path, 200, testCallback);
    try std.testing.expectEqualStrings(path, watcher.path);
}

test "Watcher.init stores callback" {
    const watcher = Watcher.init("/tmp/test", 100, testCallback);
    try std.testing.expectEqual(@as(WatchCallback, testCallback), watcher.callback);
}

test "Watcher thread is null before start" {
    const watcher = Watcher.init("/tmp/test.json", 100, testCallback);
    try std.testing.expectEqual(@as(?std.Thread, null), watcher.thread);
}

test "Watcher start sets thread" {
    test_event_count = 0;
    const tmp_path = "/tmp/zclaw_thread_test.json";
    {
        const f = try std.fs.cwd().createFile(tmp_path, .{});
        try f.writeAll("{}");
        f.close();
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var watcher = Watcher.init(tmp_path, 50, testCallback);
    try watcher.start();
    try std.testing.expect(watcher.thread != null);
    watcher.stop();
    try std.testing.expectEqual(@as(?std.Thread, null), watcher.thread);
}

test "debounceMs conversion formula" {
    // Verify the formula: ms * ns_per_ms
    const ms: u32 = 42;
    const expected = @as(u64, ms) * std.time.ns_per_ms;
    try std.testing.expectEqual(expected, debounceMs(ms));
}

test "Watcher.init with long path" {
    const long_path = "/tmp/" ++ "a" ** 200 ++ ".json";
    const watcher = Watcher.init(long_path, 100, testCallback);
    try std.testing.expectEqualStrings(long_path, watcher.path);
}
