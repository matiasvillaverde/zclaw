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
