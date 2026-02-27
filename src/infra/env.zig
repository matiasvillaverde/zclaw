const std = @import("std");
const builtin = @import("builtin");

// --- OS Detection ---

pub const OsKind = enum {
    linux,
    macos,
    windows,
    other,

    pub fn label(self: OsKind) []const u8 {
        return switch (self) {
            .linux => "linux",
            .macos => "macos",
            .windows => "windows",
            .other => "other",
        };
    }
};

pub fn detectOs() OsKind {
    return switch (builtin.os.tag) {
        .linux => .linux,
        .macos => .macos,
        .windows => .windows,
        else => .other,
    };
}

// --- Hostname ---

pub fn getHostname(buf: *[std.posix.HOST_NAME_MAX]u8) []const u8 {
    if (std.posix.gethostname(buf)) |hostname| {
        return hostname;
    } else |_| {
        return "unknown";
    }
}

// --- Home Directory ---

pub fn getHomeDir() ?[]const u8 {
    return std.posix.getenv("HOME") orelse
        std.posix.getenv("USERPROFILE");
}

// --- State Directory ---

pub const DEFAULT_STATE_DIR_NAME = ".openclaw";

pub fn getStateDir(buf: []u8) ?[]const u8 {
    // Check env overrides first
    if (std.posix.getenv("OPENCLAW_STATE_DIR")) |dir| return dir;
    if (std.posix.getenv("CLAWDBOT_STATE_DIR")) |dir| return dir;

    // Default: ~/.openclaw
    const home = getHomeDir() orelse return null;
    const result = std.fmt.bufPrint(buf, "{s}/{s}", .{ home, DEFAULT_STATE_DIR_NAME }) catch return null;
    return result;
}

// --- Config Path ---

pub const DEFAULT_CONFIG_FILENAME = "openclaw.json";

pub fn getConfigPath(buf: []u8) ?[]const u8 {
    // Check env overrides first
    if (std.posix.getenv("OPENCLAW_CONFIG_PATH")) |path| return path;
    if (std.posix.getenv("CLAWDBOT_CONFIG_PATH")) |path| return path;

    // Default: ~/.openclaw/openclaw.json
    var state_buf: [4096]u8 = undefined;
    const state_dir = getStateDir(&state_buf) orelse return null;
    const result = std.fmt.bufPrint(buf, "{s}/{s}", .{ state_dir, DEFAULT_CONFIG_FILENAME }) catch return null;
    return result;
}

// --- Gateway Port ---

pub const DEFAULT_GATEWAY_PORT: u16 = 18789;

pub fn getGatewayPort() u16 {
    // Check env overrides
    const port_str = std.posix.getenv("OPENCLAW_GATEWAY_PORT") orelse
        std.posix.getenv("CLAWDBOT_GATEWAY_PORT") orelse
        return DEFAULT_GATEWAY_PORT;

    return std.fmt.parseInt(u16, port_str, 10) catch DEFAULT_GATEWAY_PORT;
}

// --- Temp Directory ---

pub fn getTempDir(buf: []u8) []const u8 {
    const tmp = std.posix.getenv("TMPDIR") orelse
        std.posix.getenv("TEMP") orelse
        std.posix.getenv("TMP") orelse
        "/tmp";

    const result = std.fmt.bufPrint(buf, "{s}", .{tmp}) catch "/tmp";
    return result;
}

// --- Tests ---

test "detectOs returns valid kind" {
    const os = detectOs();
    // On any platform, the result should be one of the enum values
    try std.testing.expect(os == .linux or os == .macos or os == .windows or os == .other);
}

test "detectOs matches build target" {
    const os = detectOs();
    switch (builtin.os.tag) {
        .linux => try std.testing.expectEqual(OsKind.linux, os),
        .macos => try std.testing.expectEqual(OsKind.macos, os),
        .windows => try std.testing.expectEqual(OsKind.windows, os),
        else => try std.testing.expectEqual(OsKind.other, os),
    }
}

test "OsKind.label" {
    try std.testing.expectEqualStrings("linux", OsKind.linux.label());
    try std.testing.expectEqualStrings("macos", OsKind.macos.label());
    try std.testing.expectEqualStrings("windows", OsKind.windows.label());
    try std.testing.expectEqualStrings("other", OsKind.other.label());
}

test "getHostname returns non-empty string" {
    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = getHostname(&buf);
    try std.testing.expect(hostname.len > 0);
}

test "getHomeDir returns a path" {
    const home = getHomeDir();
    if (home) |h| {
        try std.testing.expect(h.len > 0);
        try std.testing.expect(h[0] == '/');
    }
}

test "getStateDir default path" {
    var buf: [4096]u8 = undefined;
    const state_dir = getStateDir(&buf);
    if (state_dir) |dir| {
        try std.testing.expect(dir.len > 0);
        try std.testing.expect(std.mem.endsWith(u8, dir, ".openclaw"));
    }
}

test "getConfigPath default path" {
    var buf: [4096]u8 = undefined;
    const config_path = getConfigPath(&buf);
    if (config_path) |path| {
        try std.testing.expect(path.len > 0);
        try std.testing.expect(std.mem.endsWith(u8, path, "openclaw.json"));
    }
}

test "getGatewayPort returns default" {
    const port = getGatewayPort();
    // Without env override, should return default (unless env is set in CI)
    try std.testing.expect(port > 0);
}

test "DEFAULT_GATEWAY_PORT is 18789" {
    try std.testing.expectEqual(@as(u16, 18789), DEFAULT_GATEWAY_PORT);
}

test "getTempDir returns non-empty" {
    var buf: [4096]u8 = undefined;
    const tmp = getTempDir(&buf);
    try std.testing.expect(tmp.len > 0);
}

// ===== Additional comprehensive tests =====

// --- OsKind enum ---

test "OsKind.label - all labels are non-empty" {
    const kinds = [_]OsKind{ .linux, .macos, .windows, .other };
    for (kinds) |kind| {
        try std.testing.expect(kind.label().len > 0);
    }
}

test "OsKind.label - all labels are unique" {
    const kinds = [_]OsKind{ .linux, .macos, .windows, .other };
    for (kinds, 0..) |k1, i| {
        for (kinds[i + 1 ..]) |k2| {
            try std.testing.expect(!std.mem.eql(u8, k1.label(), k2.label()));
        }
    }
}

test "OsKind.label - all lowercase" {
    const kinds = [_]OsKind{ .linux, .macos, .windows, .other };
    for (kinds) |kind| {
        for (kind.label()) |c| {
            try std.testing.expect(c >= 'a' and c <= 'z');
        }
    }
}

test "OsKind - four variants" {
    const kinds = [_]OsKind{ .linux, .macos, .windows, .other };
    try std.testing.expectEqual(@as(usize, 4), kinds.len);
}

// --- detectOs ---

test "detectOs - returns consistent value" {
    const os1 = detectOs();
    const os2 = detectOs();
    try std.testing.expectEqual(os1, os2);
}

test "detectOs - label is non-empty" {
    const os = detectOs();
    try std.testing.expect(os.label().len > 0);
}

// --- getHostname ---

test "getHostname - returns stable value" {
    var buf1: [std.posix.HOST_NAME_MAX]u8 = undefined;
    var buf2: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const h1 = getHostname(&buf1);
    const h2 = getHostname(&buf2);
    try std.testing.expectEqualStrings(h1, h2);
}

test "getHostname - does not contain null bytes" {
    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = getHostname(&buf);
    for (hostname) |c| {
        try std.testing.expect(c != 0);
    }
}

test "getHostname - reasonable length" {
    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = getHostname(&buf);
    try std.testing.expect(hostname.len > 0);
    try std.testing.expect(hostname.len <= std.posix.HOST_NAME_MAX);
}

// --- getHomeDir ---

test "getHomeDir - if present, starts with slash" {
    const home = getHomeDir();
    if (home) |h| {
        try std.testing.expect(h.len > 0);
        try std.testing.expect(h[0] == '/');
    }
}

test "getHomeDir - does not end with slash" {
    const home = getHomeDir();
    if (home) |h| {
        if (h.len > 1) {
            try std.testing.expect(h[h.len - 1] != '/');
        }
    }
}

test "getHomeDir - consistent return" {
    const h1 = getHomeDir();
    const h2 = getHomeDir();
    if (h1) |v1| {
        if (h2) |v2| {
            try std.testing.expectEqualStrings(v1, v2);
        }
    }
}

// --- DEFAULT_STATE_DIR_NAME ---

test "DEFAULT_STATE_DIR_NAME is .openclaw" {
    try std.testing.expectEqualStrings(".openclaw", DEFAULT_STATE_DIR_NAME);
}

// --- DEFAULT_CONFIG_FILENAME ---

test "DEFAULT_CONFIG_FILENAME is openclaw.json" {
    try std.testing.expectEqualStrings("openclaw.json", DEFAULT_CONFIG_FILENAME);
}

// --- getStateDir ---

test "getStateDir - result contains DEFAULT_STATE_DIR_NAME" {
    var buf: [4096]u8 = undefined;
    const state_dir = getStateDir(&buf);
    if (state_dir) |dir| {
        try std.testing.expect(std.mem.endsWith(u8, dir, DEFAULT_STATE_DIR_NAME));
    }
}

test "getStateDir - result starts with slash" {
    var buf: [4096]u8 = undefined;
    const state_dir = getStateDir(&buf);
    if (state_dir) |dir| {
        try std.testing.expect(dir[0] == '/');
    }
}

test "getStateDir - small buffer returns null or valid" {
    var buf: [2]u8 = undefined;
    const state_dir = getStateDir(&buf);
    // If buffer is too small, bufPrint fails and returns null
    // Unless env override is set which returns directly
    if (std.posix.getenv("OPENCLAW_STATE_DIR") == null and std.posix.getenv("CLAWDBOT_STATE_DIR") == null) {
        try std.testing.expect(state_dir == null);
    }
}

test "getStateDir - consistent results" {
    var buf1: [4096]u8 = undefined;
    var buf2: [4096]u8 = undefined;
    const dir1 = getStateDir(&buf1);
    const dir2 = getStateDir(&buf2);
    if (dir1) |d1| {
        if (dir2) |d2| {
            try std.testing.expectEqualStrings(d1, d2);
        }
    }
}

// --- getConfigPath ---

test "getConfigPath - result contains DEFAULT_CONFIG_FILENAME" {
    var buf: [4096]u8 = undefined;
    const config_path = getConfigPath(&buf);
    if (config_path) |path| {
        try std.testing.expect(std.mem.endsWith(u8, path, DEFAULT_CONFIG_FILENAME));
    }
}

test "getConfigPath - result starts with slash" {
    var buf: [4096]u8 = undefined;
    const config_path = getConfigPath(&buf);
    if (config_path) |path| {
        try std.testing.expect(path[0] == '/');
    }
}

test "getConfigPath - result contains state dir" {
    var buf: [4096]u8 = undefined;
    const config_path = getConfigPath(&buf);
    if (config_path) |path| {
        try std.testing.expect(std.mem.indexOf(u8, path, DEFAULT_STATE_DIR_NAME) != null);
    }
}

test "getConfigPath - small buffer returns null or valid" {
    var buf: [2]u8 = undefined;
    const config_path = getConfigPath(&buf);
    if (std.posix.getenv("OPENCLAW_CONFIG_PATH") == null and std.posix.getenv("CLAWDBOT_CONFIG_PATH") == null) {
        try std.testing.expect(config_path == null);
    }
}

test "getConfigPath - consistent results" {
    var buf1: [4096]u8 = undefined;
    var buf2: [4096]u8 = undefined;
    const path1 = getConfigPath(&buf1);
    const path2 = getConfigPath(&buf2);
    if (path1) |p1| {
        if (path2) |p2| {
            try std.testing.expectEqualStrings(p1, p2);
        }
    }
}

// --- getGatewayPort ---

test "DEFAULT_GATEWAY_PORT value" {
    try std.testing.expectEqual(@as(u16, 18789), DEFAULT_GATEWAY_PORT);
}

test "getGatewayPort - returns valid port" {
    const port = getGatewayPort();
    try std.testing.expect(port > 0);
    try std.testing.expect(port <= 65535);
}

test "getGatewayPort - consistent results" {
    const p1 = getGatewayPort();
    const p2 = getGatewayPort();
    try std.testing.expectEqual(p1, p2);
}

// --- getTempDir ---

test "getTempDir - starts with slash" {
    var buf: [4096]u8 = undefined;
    const tmp = getTempDir(&buf);
    try std.testing.expect(tmp.len > 0);
    try std.testing.expect(tmp[0] == '/');
}

test "getTempDir - consistent results" {
    var buf1: [4096]u8 = undefined;
    var buf2: [4096]u8 = undefined;
    const tmp1 = getTempDir(&buf1);
    const tmp2 = getTempDir(&buf2);
    try std.testing.expectEqualStrings(tmp1, tmp2);
}

test "getTempDir - is a valid directory path" {
    var buf: [4096]u8 = undefined;
    const tmp = getTempDir(&buf);
    // Should be a path starting with /
    try std.testing.expect(tmp[0] == '/');
    // Should not contain null bytes
    for (tmp) |c| {
        try std.testing.expect(c != 0);
    }
}

test "getTempDir - no null bytes" {
    var buf: [4096]u8 = undefined;
    const tmp = getTempDir(&buf);
    for (tmp) |c| {
        try std.testing.expect(c != 0);
    }
}

test "getTempDir - small buffer falls back to /tmp" {
    var buf: [2]u8 = undefined;
    const tmp = getTempDir(&buf);
    // If env vars are set with a long path and buffer is too small,
    // bufPrint fails and returns "/tmp"
    try std.testing.expect(tmp.len > 0);
}
