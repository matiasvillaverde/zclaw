const std = @import("std");
const schema = @import("schema.zig");
const env = @import("../infra/env.zig");

pub const LoadError = error{
    FileNotFound,
    ParseFailed,
    OutOfMemory,
    InvalidPath,
};

pub const LoadResult = struct {
    config: schema.Config,
    raw_json: ?[]const u8,
    source_path: ?[]const u8,
};

/// Loads configuration from the default path (~/.openclaw/openclaw.json).
/// Returns a default config if the file doesn't exist.
pub fn loadConfig(allocator: std.mem.Allocator) LoadResult {
    var path_buf: [4096]u8 = undefined;
    const config_path = env.getConfigPath(&path_buf) orelse {
        return .{ .config = schema.defaultConfig(), .raw_json = null, .source_path = null };
    };

    return loadConfigFromPath(allocator, config_path);
}

/// Loads configuration from a specific file path.
/// Returns a default config if the file doesn't exist.
pub fn loadConfigFromPath(allocator: std.mem.Allocator, path: []const u8) LoadResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return .{ .config = schema.defaultConfig(), .raw_json = null, .source_path = path };
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch {
        return .{ .config = schema.defaultConfig(), .raw_json = null, .source_path = path };
    };

    const config = parseConfigJson(content) orelse {
        return .{ .config = schema.defaultConfig(), .raw_json = content, .source_path = path };
    };

    return .{ .config = config, .raw_json = content, .source_path = path };
}

/// Parses a JSON string into a Config struct.
/// Falls back to defaults for missing fields.
pub fn parseConfigJson(json_str: []const u8) ?schema.Config {
    var config = schema.defaultConfig();

    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json_str, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    const obj = root.object;

    // Parse gateway section
    if (obj.get("gateway")) |gw| {
        if (gw == .object) {
            const gw_obj = gw.object;
            if (gw_obj.get("port")) |p| {
                if (p == .integer) {
                    config.gateway.port = @intCast(@as(u16, @truncate(@as(u64, @bitCast(p.integer)))));
                }
            }
        }
    }

    // Parse logging section
    if (obj.get("logging")) |log| {
        if (log == .object) {
            const log_obj = log.object;
            if (log_obj.get("level")) |lvl| {
                if (lvl == .string) {
                    config.logging.level = parseLogLevel(lvl.string) orelse .info;
                }
            }
            if (log_obj.get("consoleStyle")) |cs| {
                if (cs == .string) {
                    config.logging.console_style = parseConsoleStyle(cs.string) orelse .pretty;
                }
            }
        }
    }

    // Parse session section
    if (obj.get("session")) |sess| {
        if (sess == .object) {
            const sess_obj = sess.object;
            if (sess_obj.get("mainKey")) |mk| {
                if (mk == .string) {
                    config.session.main_key = mk.string;
                }
            }
        }
    }

    return config;
}

fn parseLogLevel(s: []const u8) ?schema.LogLevel {
    const map = std.StaticStringMap(schema.LogLevel).initComptime(.{
        .{ "silent", .silent },
        .{ "fatal", .fatal },
        .{ "error", .err },
        .{ "warn", .warn },
        .{ "info", .info },
        .{ "debug", .debug },
        .{ "trace", .trace },
    });
    return map.get(s);
}

fn parseConsoleStyle(s: []const u8) ?schema.ConsoleStyle {
    const map = std.StaticStringMap(schema.ConsoleStyle).initComptime(.{
        .{ "pretty", .pretty },
        .{ "compact", .compact },
        .{ "json", .json },
    });
    return map.get(s);
}

/// Writes config as JSON to the given path.
pub fn writeConfigToPath(allocator: std.mem.Allocator, config: *const schema.Config, path: []const u8) !void {
    _ = allocator;

    // Create parent directory if needed
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    const file = try std.fs.cwd().createFile(path, .{ .mode = 0o600 });
    defer file.close();

    // Write a simple JSON representation
    try file.writeAll("{\n");

    // Gateway
    try std.fmt.format(file.writer(
        &.{},
    ), "  \"gateway\": {{\n    \"port\": {d}\n  }},\n", .{config.gateway.port});

    // Logging
    try std.fmt.format(file.writer(&.{}), "  \"logging\": {{\n    \"level\": \"{s}\"\n  }}\n", .{config.logging.level.label()});

    try file.writeAll("}\n");
}

// --- Tests ---

test "parseConfigJson with empty object" {
    const config = parseConfigJson("{}").?;
    try std.testing.expectEqual(@as(u16, 18789), config.gateway.port);
    try std.testing.expectEqual(schema.LogLevel.info, config.logging.level);
}

test "parseConfigJson with gateway port" {
    const config = parseConfigJson(
        \\{"gateway":{"port":9999}}
    ).?;
    try std.testing.expectEqual(@as(u16, 9999), config.gateway.port);
}

test "parseConfigJson with logging level" {
    const config = parseConfigJson(
        \\{"logging":{"level":"debug"}}
    ).?;
    try std.testing.expectEqual(schema.LogLevel.debug, config.logging.level);
}

test "parseConfigJson with console style" {
    const config = parseConfigJson(
        \\{"logging":{"consoleStyle":"json"}}
    ).?;
    try std.testing.expectEqual(schema.ConsoleStyle.json, config.logging.console_style);
}

test "parseConfigJson with invalid JSON returns null" {
    try std.testing.expectEqual(@as(?schema.Config, null), parseConfigJson("not json"));
}

test "parseConfigJson with non-object root returns null" {
    try std.testing.expectEqual(@as(?schema.Config, null), parseConfigJson("42"));
    try std.testing.expectEqual(@as(?schema.Config, null), parseConfigJson("\"string\""));
}

test "loadConfigFromPath with nonexistent file returns defaults" {
    const result = loadConfigFromPath(std.testing.allocator, "/nonexistent/path/config.json");
    try std.testing.expectEqual(@as(u16, 18789), result.config.gateway.port);
    try std.testing.expectEqual(@as(?[]const u8, null), result.raw_json);
}
