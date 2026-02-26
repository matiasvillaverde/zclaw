const std = @import("std");

// --- Plugin Manifest ---

pub const PluginManifest = struct {
    name: []const u8,
    version: []const u8 = "0.0.0",
    description: []const u8 = "",
    author: []const u8 = "",
    entry_point: []const u8 = "zclaw_plugin_init",
    min_zclaw_version: []const u8 = "0.1.0",
    capabilities: []const Capability = &.{},
};

pub const Capability = enum {
    rpc_methods,
    http_handlers,
    tools,
    cli_commands,
    services,
    channels,

    pub fn label(self: Capability) []const u8 {
        return switch (self) {
            .rpc_methods => "rpc_methods",
            .http_handlers => "http_handlers",
            .tools => "tools",
            .cli_commands => "cli_commands",
            .services => "services",
            .channels => "channels",
        };
    }

    pub fn fromString(s: []const u8) ?Capability {
        const map = std.StaticStringMap(Capability).initComptime(.{
            .{ "rpc_methods", .rpc_methods },
            .{ "http_handlers", .http_handlers },
            .{ "tools", .tools },
            .{ "cli_commands", .cli_commands },
            .{ "services", .services },
            .{ "channels", .channels },
        });
        return map.get(s);
    }
};

// --- Manifest Parsing ---

/// Parse a plugin manifest from JSON-like string.
/// Format: {"name":"...","version":"...","description":"...",...}
pub fn parseManifest(json: []const u8) ?PluginManifest {
    const name = extractJsonString(json, "\"name\":\"") orelse return null;
    return .{
        .name = name,
        .version = extractJsonString(json, "\"version\":\"") orelse "0.0.0",
        .description = extractJsonString(json, "\"description\":\"") orelse "",
        .author = extractJsonString(json, "\"author\":\"") orelse "",
        .entry_point = extractJsonString(json, "\"entry_point\":\"") orelse "zclaw_plugin_init",
        .min_zclaw_version = extractJsonString(json, "\"min_zclaw_version\":\"") orelse "0.1.0",
    };
}

/// Serialize a manifest to JSON.
pub fn serializeManifest(buf: []u8, m: *const PluginManifest) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("{\"name\":\"");
    try w.writeAll(m.name);
    try w.writeAll("\",\"version\":\"");
    try w.writeAll(m.version);
    try w.writeAll("\",\"description\":\"");
    try w.writeAll(m.description);
    try w.writeAll("\",\"author\":\"");
    try w.writeAll(m.author);
    try w.writeAll("\",\"entry_point\":\"");
    try w.writeAll(m.entry_point);
    try w.writeAll("\"}");
    return fbs.getWritten();
}

/// Validate a manifest has required fields.
pub fn validateManifest(m: *const PluginManifest) ManifestError!void {
    if (m.name.len == 0) return error.MissingName;
    if (m.version.len == 0) return error.MissingVersion;
    // Validate version format (basic semver: X.Y.Z)
    if (!isValidVersion(m.version)) return error.InvalidVersion;
}

pub const ManifestError = error{
    MissingName,
    MissingVersion,
    InvalidVersion,
};

fn isValidVersion(v: []const u8) bool {
    var dots: u32 = 0;
    var has_digit = false;
    for (v) |c| {
        if (c == '.') {
            if (!has_digit) return false;
            dots += 1;
            has_digit = false;
        } else if (c >= '0' and c <= '9') {
            has_digit = true;
        } else {
            return false;
        }
    }
    return dots == 2 and has_digit;
}

// --- Helpers ---

fn extractJsonString(json: []const u8, prefix: []const u8) ?[]const u8 {
    const start_idx = std.mem.indexOf(u8, json, prefix) orelse return null;
    const value_start = start_idx + prefix.len;
    if (value_start >= json.len) return null;
    var i = value_start;
    while (i < json.len) : (i += 1) {
        if (json[i] == '"' and (i == value_start or json[i - 1] != '\\')) {
            return json[value_start..i];
        }
    }
    return null;
}

// --- Tests ---

test "Capability labels and fromString" {
    try std.testing.expectEqualStrings("rpc_methods", Capability.rpc_methods.label());
    try std.testing.expectEqualStrings("tools", Capability.tools.label());
    try std.testing.expectEqual(Capability.tools, Capability.fromString("tools").?);
    try std.testing.expectEqual(Capability.channels, Capability.fromString("channels").?);
    try std.testing.expectEqual(@as(?Capability, null), Capability.fromString("unknown"));
}

test "parseManifest basic" {
    const json = "{\"name\":\"my-plugin\",\"version\":\"1.0.0\",\"description\":\"A test plugin\",\"author\":\"Test\"}";
    const m = parseManifest(json).?;
    try std.testing.expectEqualStrings("my-plugin", m.name);
    try std.testing.expectEqualStrings("1.0.0", m.version);
    try std.testing.expectEqualStrings("A test plugin", m.description);
    try std.testing.expectEqualStrings("Test", m.author);
    try std.testing.expectEqualStrings("zclaw_plugin_init", m.entry_point);
}

test "parseManifest minimal" {
    const json = "{\"name\":\"simple\"}";
    const m = parseManifest(json).?;
    try std.testing.expectEqualStrings("simple", m.name);
    try std.testing.expectEqualStrings("0.0.0", m.version);
}

test "parseManifest no name" {
    const json = "{\"version\":\"1.0.0\"}";
    try std.testing.expect(parseManifest(json) == null);
}

test "parseManifest custom entry_point" {
    const json = "{\"name\":\"p\",\"entry_point\":\"custom_init\"}";
    const m = parseManifest(json).?;
    try std.testing.expectEqualStrings("custom_init", m.entry_point);
}

test "serializeManifest" {
    const m = PluginManifest{
        .name = "test-plugin",
        .version = "2.0.0",
        .description = "desc",
        .author = "me",
    };
    var buf: [512]u8 = undefined;
    const json = try serializeManifest(&buf, &m);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"test-plugin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"version\":\"2.0.0\"") != null);
}

test "validateManifest valid" {
    const m = PluginManifest{ .name = "test", .version = "1.0.0" };
    try validateManifest(&m);
}

test "validateManifest missing name" {
    const m = PluginManifest{ .name = "", .version = "1.0.0" };
    try std.testing.expectError(error.MissingName, validateManifest(&m));
}

test "validateManifest missing version" {
    const m = PluginManifest{ .name = "test", .version = "" };
    try std.testing.expectError(error.MissingVersion, validateManifest(&m));
}

test "validateManifest invalid version" {
    const m = PluginManifest{ .name = "test", .version = "1.0" };
    try std.testing.expectError(error.InvalidVersion, validateManifest(&m));
}

test "validateManifest invalid version format" {
    const m = PluginManifest{ .name = "test", .version = "abc" };
    try std.testing.expectError(error.InvalidVersion, validateManifest(&m));
}

test "isValidVersion" {
    try std.testing.expect(isValidVersion("1.0.0"));
    try std.testing.expect(isValidVersion("0.1.0"));
    try std.testing.expect(isValidVersion("10.20.30"));
    try std.testing.expect(!isValidVersion("1.0"));
    try std.testing.expect(!isValidVersion("1"));
    try std.testing.expect(!isValidVersion(""));
    try std.testing.expect(!isValidVersion("a.b.c"));
    try std.testing.expect(!isValidVersion("1..0"));
}

test "PluginManifest defaults" {
    const m = PluginManifest{ .name = "p" };
    try std.testing.expectEqualStrings("0.0.0", m.version);
    try std.testing.expectEqualStrings("", m.description);
    try std.testing.expectEqualStrings("zclaw_plugin_init", m.entry_point);
    try std.testing.expectEqualStrings("0.1.0", m.min_zclaw_version);
}
