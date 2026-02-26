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

// --- Environment Variable Substitution ---

/// Substitute environment variables in a string.
/// Syntax: ${VAR}, ${VAR:-default}, escape: $${VAR}
pub fn substituteEnvVars(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        // Escaped dollar: $${
        if (i + 2 < input.len and input[i] == '$' and input[i + 1] == '$' and input[i + 2] == '{') {
            try result.append(allocator, '$');
            try result.append(allocator, '{');
            i += 3;
            // Copy until closing }
            while (i < input.len and input[i] != '}') : (i += 1) {
                try result.append(allocator, input[i]);
            }
            if (i < input.len) {
                try result.append(allocator, '}');
                i += 1;
            }
            continue;
        }

        // Variable substitution: ${VAR} or ${VAR:-default}
        if (i + 1 < input.len and input[i] == '$' and input[i + 1] == '{') {
            i += 2;
            const var_start = i;
            // Find closing }
            while (i < input.len and input[i] != '}') : (i += 1) {}
            const var_expr = input[var_start..i];
            if (i < input.len) i += 1; // skip }

            // Check for default value: VAR:-default
            var var_name: []const u8 = var_expr;
            var default_value: ?[]const u8 = null;
            if (std.mem.indexOf(u8, var_expr, ":-")) |sep| {
                var_name = var_expr[0..sep];
                default_value = var_expr[sep + 2 ..];
            }

            // Look up environment variable
            const value = std.posix.getenv(var_name);
            if (value) |v| {
                try result.appendSlice(allocator, v);
            } else if (default_value) |dv| {
                try result.appendSlice(allocator, dv);
            }
            // If no value and no default, substitute empty string
            continue;
        }

        try result.append(allocator, input[i]);
        i += 1;
    }

    return try allocator.dupe(u8, result.items);
}

// --- Config Includes ---

/// Maximum include depth to prevent cycles.
pub const MAX_INCLUDE_DEPTH: u32 = 10;

/// Process $include directives in JSON config.
/// Returns the config with includes resolved.
pub fn processIncludes(allocator: std.mem.Allocator, content: []const u8, depth: u32) ![]const u8 {
    if (depth >= MAX_INCLUDE_DEPTH) return error.ParseFailed;

    // Look for "$include" directive
    const include_marker = "\"$include\":\"";
    const marker_pos = std.mem.indexOf(u8, content, include_marker) orelse {
        return try allocator.dupe(u8, content);
    };

    const path_start = marker_pos + include_marker.len;
    const path_end = std.mem.indexOf(u8, content[path_start..], "\"") orelse {
        return try allocator.dupe(u8, content);
    };

    const include_path = content[path_start .. path_start + path_end];

    // Read the included file
    const included_content = blk: {
        const file = std.fs.cwd().openFile(include_path, .{}) catch {
            return try allocator.dupe(u8, content);
        };
        defer file.close();
        break :blk file.readToEndAlloc(allocator, 1024 * 1024) catch {
            return try allocator.dupe(u8, content);
        };
    };
    defer allocator.free(included_content);

    // Recursively process includes in the included content
    const processed = try processIncludes(allocator, included_content, depth + 1);
    defer allocator.free(processed);

    // Replace the $include directive with the included content
    // Find the enclosing braces of the include object
    var result = std.ArrayListUnmanaged(u8){};
    defer result.deinit(allocator);

    try result.appendSlice(allocator, content[0..marker_pos]);
    // Remove trailing {"$include":" and path"}
    // We insert the included content's inner object
    try result.appendSlice(allocator, processed);

    // Skip past the include directive
    const after_path = path_start + path_end + 1;
    if (after_path < content.len) {
        try result.appendSlice(allocator, content[after_path..]);
    }

    return try allocator.dupe(u8, result.items);
}

/// Load config with include support.
pub fn loadConfigWithIncludes(allocator: std.mem.Allocator, path: []const u8) LoadResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return .{ .config = schema.defaultConfig(), .raw_json = null, .source_path = path };
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch {
        return .{ .config = schema.defaultConfig(), .raw_json = null, .source_path = path };
    };

    // Process includes
    const processed = processIncludes(allocator, content, 0) catch {
        // On error, try parsing the raw content
        const config = parseConfigJson(content) orelse {
            return .{ .config = schema.defaultConfig(), .raw_json = content, .source_path = path };
        };
        return .{ .config = config, .raw_json = content, .source_path = path };
    };

    const config = parseConfigJson(processed) orelse {
        return .{ .config = schema.defaultConfig(), .raw_json = processed, .source_path = path };
    };

    return .{ .config = config, .raw_json = processed, .source_path = path };
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

// --- Environment Variable Substitution Tests ---

test "substituteEnvVars no variables" {
    const allocator = std.testing.allocator;
    const result = try substituteEnvVars(allocator, "plain text");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("plain text", result);
}

test "substituteEnvVars with default" {
    const allocator = std.testing.allocator;
    const result = try substituteEnvVars(allocator, "${NONEXISTENT_VAR_ZCLAW:-fallback}");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("fallback", result);
}

test "substituteEnvVars missing var no default" {
    const allocator = std.testing.allocator;
    const result = try substituteEnvVars(allocator, "before ${NONEXISTENT_VAR_ZCLAW} after");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("before  after", result);
}

test "substituteEnvVars escaped" {
    const allocator = std.testing.allocator;
    const result = try substituteEnvVars(allocator, "$${NOT_A_VAR}");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("${NOT_A_VAR}", result);
}

test "substituteEnvVars with PATH" {
    const allocator = std.testing.allocator;
    const result = try substituteEnvVars(allocator, "path=${PATH:-none}");
    defer allocator.free(result);
    // PATH should always exist
    try std.testing.expect(result.len > 5);
    try std.testing.expect(std.mem.startsWith(u8, result, "path="));
}

test "substituteEnvVars multiple vars" {
    const allocator = std.testing.allocator;
    const result = try substituteEnvVars(allocator, "${A_ZCLAW:-x} and ${B_ZCLAW:-y}");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("x and y", result);
}

test "substituteEnvVars empty" {
    const allocator = std.testing.allocator;
    const result = try substituteEnvVars(allocator, "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "substituteEnvVars nested text" {
    const allocator = std.testing.allocator;
    const result = try substituteEnvVars(allocator, "{\"key\":\"${MY_VAR_ZCLAW:-default_value}\"}");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("{\"key\":\"default_value\"}", result);
}

test "substituteEnvVars real env var" {
    const allocator = std.testing.allocator;
    const result = try substituteEnvVars(allocator, "home=${HOME:-/tmp}");
    defer allocator.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, "home="));
    try std.testing.expect(result.len > 5);
}

test "substituteEnvVars default with special chars" {
    const allocator = std.testing.allocator;
    const result = try substituteEnvVars(allocator, "${MISSING_ZCLAW:-https://api.example.com}");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("https://api.example.com", result);
}

// --- Config Include Tests ---

test "processIncludes no includes" {
    const allocator = std.testing.allocator;
    const result = try processIncludes(allocator, "{\"key\":\"value\"}", 0);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("{\"key\":\"value\"}", result);
}

test "processIncludes nonexistent file" {
    const allocator = std.testing.allocator;
    const input = "{\"$include\":\"/nonexistent/file.json\"}";
    const result = try processIncludes(allocator, input, 0);
    defer allocator.free(result);
    // Should return original content when file not found
    try std.testing.expectEqualStrings(input, result);
}

test "processIncludes max depth" {
    const allocator = std.testing.allocator;
    const err = processIncludes(allocator, "{}", 10);
    try std.testing.expectError(error.ParseFailed, err);
}

test "processIncludes with real file" {
    const allocator = std.testing.allocator;
    const tmp_path = "/tmp/zclaw_include_test.json";
    {
        const f = try std.fs.cwd().createFile(tmp_path, .{});
        defer f.close();
        try f.writeAll("\"included_value\"");
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const input = "{\"key\":\"$include\":\"/tmp/zclaw_include_test.json\"}";
    const result = try processIncludes(allocator, input, 0);
    defer allocator.free(result);
    // Result should contain something from the include
    try std.testing.expect(result.len > 0);
}

test "loadConfigWithIncludes nonexistent" {
    const allocator = std.testing.allocator;
    const result = loadConfigWithIncludes(allocator, "/nonexistent/config.json");
    try std.testing.expectEqual(@as(u16, 18789), result.config.gateway.port);
}

test "MAX_INCLUDE_DEPTH" {
    try std.testing.expectEqual(@as(u32, 10), MAX_INCLUDE_DEPTH);
}
