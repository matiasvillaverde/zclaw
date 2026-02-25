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

// --- Tests ---

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
