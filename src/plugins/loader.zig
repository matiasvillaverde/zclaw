const std = @import("std");
const manifest_mod = @import("manifest.zig");
const api_mod = @import("api.zig");

// --- Plugin Discovery ---

pub const PLUGIN_EXTENSION = switch (@import("builtin").os.tag) {
    .macos => ".dylib",
    .windows => ".dll",
    else => ".so",
};

pub const PLUGIN_DIR_NAME = "plugins";
pub const MANIFEST_FILE = "plugin.json";

// --- Plugin Path Builder ---

pub fn buildPluginDir(buf: []u8, base_dir: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll(base_dir);
    if (base_dir.len > 0 and base_dir[base_dir.len - 1] != '/') {
        try w.writeByte('/');
    }
    try w.writeAll(PLUGIN_DIR_NAME);
    return fbs.getWritten();
}

pub fn buildPluginPath(buf: []u8, plugin_dir: []const u8, name: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll(plugin_dir);
    if (plugin_dir.len > 0 and plugin_dir[plugin_dir.len - 1] != '/') {
        try w.writeByte('/');
    }
    try w.writeAll(name);
    try w.writeAll(PLUGIN_EXTENSION);
    return fbs.getWritten();
}

pub fn buildManifestPath(buf: []u8, plugin_dir: []const u8, name: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll(plugin_dir);
    if (plugin_dir.len > 0 and plugin_dir[plugin_dir.len - 1] != '/') {
        try w.writeByte('/');
    }
    try w.writeAll(name);
    try w.writeByte('/');
    try w.writeAll(MANIFEST_FILE);
    return fbs.getWritten();
}

// --- Plugin Registry ---

pub const PluginRegistry = struct {
    plugins: std.StringHashMapUnmanaged(api_mod.PluginEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PluginRegistry {
        return .{
            .plugins = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PluginRegistry) void {
        var iter = self.plugins.valueIterator();
        while (iter.next()) |entry| {
            if (entry.api) |*api| {
                api.deinit();
            }
        }
        self.plugins.deinit(self.allocator);
    }

    pub fn register(self: *PluginRegistry, entry: api_mod.PluginEntry) !void {
        try self.plugins.put(self.allocator, entry.manifest.name, entry);
    }

    pub fn get(self: *const PluginRegistry, name: []const u8) ?api_mod.PluginEntry {
        return self.plugins.get(name);
    }

    pub fn count(self: *const PluginRegistry) usize {
        return self.plugins.count();
    }

    pub fn activeCount(self: *const PluginRegistry) usize {
        var n: usize = 0;
        var iter = self.plugins.valueIterator();
        while (iter.next()) |entry| {
            if (entry.isActive()) n += 1;
        }
        return n;
    }

    pub fn disablePlugin(self: *PluginRegistry, name: []const u8) bool {
        if (self.plugins.getPtr(name)) |entry| {
            entry.state = .disabled;
            return true;
        }
        return false;
    }

    pub fn enablePlugin(self: *PluginRegistry, name: []const u8) bool {
        if (self.plugins.getPtr(name)) |entry| {
            if (entry.state == .disabled) {
                entry.state = .active;
                return true;
            }
        }
        return false;
    }
};

// --- Load Simulation (real loading needs std.DynLib) ---
// Real plugin loading would use std.DynLib to open shared libraries.
// For testing, we provide a mock loading function.

pub const LoadError = error{
    PluginNotFound,
    ManifestNotFound,
    ManifestInvalid,
    SymbolNotFound,
    InitFailed,
};

/// Load a plugin from a manifest.
/// Creates a PluginEntry with an active PluginApi.
pub fn loadFromManifest(
    allocator: std.mem.Allocator,
    m: manifest_mod.PluginManifest,
) LoadError!api_mod.PluginEntry {
    manifest_mod.validateManifest(&m) catch return error.ManifestInvalid;

    return .{
        .manifest = m,
        .state = .active,
        .api = api_mod.PluginApi.init(allocator, m.name),
    };
}

/// Discover plugin manifests in a directory.
/// Scans subdirectories of plugin_dir for plugin.json files.
/// Returns the number of plugins found and loaded.
pub fn discoverPlugins(
    allocator: std.mem.Allocator,
    registry: *PluginRegistry,
    plugin_dir: []const u8,
) !usize {
    var dir = std.fs.cwd().openDir(plugin_dir, .{ .iterate = true }) catch {
        return 0; // Plugin dir doesn't exist, no plugins
    };
    defer dir.close();

    var count: usize = 0;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        // Check for plugin.json in subdirectory
        var path_buf: [512]u8 = undefined;
        const manifest_path = buildManifestPath(&path_buf, plugin_dir, entry.name) catch continue;

        const file = std.fs.cwd().openFile(manifest_path, .{}) catch continue;
        defer file.close();

        const content = file.readToEndAlloc(allocator, 64 * 1024) catch continue;
        defer allocator.free(content);

        const parsed = manifest_mod.parseManifest(content) orelse continue;

        manifest_mod.validateManifest(&parsed) catch continue;

        // Copy manifest strings so they outlive content
        const m = manifest_mod.PluginManifest{
            .name = allocator.dupe(u8, parsed.name) catch continue,
            .version = allocator.dupe(u8, parsed.version) catch continue,
            .description = parsed.description,
            .author = parsed.author,
            .entry_point = parsed.entry_point,
            .min_zclaw_version = parsed.min_zclaw_version,
        };

        var plugin_entry = loadFromManifest(allocator, m) catch {
            allocator.free(m.name);
            allocator.free(m.version);
            continue;
        };
        _ = &plugin_entry;
        registry.register(plugin_entry) catch {
            allocator.free(m.name);
            allocator.free(m.version);
            continue;
        };
        count += 1;
    }

    return count;
}

// --- Serialize Plugin List ---

pub fn serializePluginList(buf: []u8, registry: *const PluginRegistry) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("{\"plugins\":[");
    var first = true;
    var iter = registry.plugins.valueIterator();
    while (iter.next()) |entry| {
        if (!first) try w.writeAll(",");
        try w.writeAll("{\"name\":\"");
        try w.writeAll(entry.manifest.name);
        try w.writeAll("\",\"state\":\"");
        try w.writeAll(entry.state.label());
        try w.writeAll("\"}");
        first = false;
    }
    try w.writeAll("],\"count\":");
    try std.fmt.format(w, "{d}", .{registry.count()});
    try w.writeAll("}");
    return fbs.getWritten();
}

// --- Tests ---

test "PLUGIN_EXTENSION" {
    // Should be one of the platform extensions
    try std.testing.expect(std.mem.eql(u8, PLUGIN_EXTENSION, ".dylib") or
        std.mem.eql(u8, PLUGIN_EXTENSION, ".so") or
        std.mem.eql(u8, PLUGIN_EXTENSION, ".dll"));
}

test "buildPluginDir" {
    var buf: [256]u8 = undefined;
    const dir = try buildPluginDir(&buf, "/home/user/.openclaw");
    try std.testing.expectEqualStrings("/home/user/.openclaw/plugins", dir);
}

test "buildPluginDir trailing slash" {
    var buf: [256]u8 = undefined;
    const dir = try buildPluginDir(&buf, "/home/user/.openclaw/");
    try std.testing.expectEqualStrings("/home/user/.openclaw/plugins", dir);
}

test "buildPluginPath" {
    var buf: [256]u8 = undefined;
    const path = try buildPluginPath(&buf, "/plugins", "my-plugin");
    try std.testing.expect(std.mem.startsWith(u8, path, "/plugins/my-plugin"));
    try std.testing.expect(std.mem.endsWith(u8, path, PLUGIN_EXTENSION));
}

test "buildManifestPath" {
    var buf: [256]u8 = undefined;
    const path = try buildManifestPath(&buf, "/plugins", "my-plugin");
    try std.testing.expectEqualStrings("/plugins/my-plugin/plugin.json", path);
}

test "PluginRegistry init and register" {
    const allocator = std.testing.allocator;
    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .manifest = .{ .name = "plugin-a", .version = "1.0.0" },
        .state = .active,
    });
    try registry.register(.{
        .manifest = .{ .name = "plugin-b", .version = "2.0.0" },
        .state = .unloaded,
    });

    try std.testing.expectEqual(@as(usize, 2), registry.count());
    try std.testing.expectEqual(@as(usize, 1), registry.activeCount());
}

test "PluginRegistry get" {
    const allocator = std.testing.allocator;
    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .manifest = .{ .name = "test-plugin", .version = "1.0.0" },
        .state = .active,
    });

    const entry = registry.get("test-plugin").?;
    try std.testing.expectEqualStrings("test-plugin", entry.manifest.name);
    try std.testing.expect(entry.isActive());

    try std.testing.expect(registry.get("nonexistent") == null);
}

test "PluginRegistry disable and enable" {
    const allocator = std.testing.allocator;
    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .manifest = .{ .name = "p", .version = "1.0.0" },
        .state = .active,
    });

    try std.testing.expectEqual(@as(usize, 1), registry.activeCount());
    try std.testing.expect(registry.disablePlugin("p"));
    try std.testing.expectEqual(@as(usize, 0), registry.activeCount());

    try std.testing.expect(registry.enablePlugin("p"));
    try std.testing.expectEqual(@as(usize, 1), registry.activeCount());
}

test "PluginRegistry disable nonexistent" {
    const allocator = std.testing.allocator;
    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expect(!registry.disablePlugin("nope"));
    try std.testing.expect(!registry.enablePlugin("nope"));
}

test "loadFromManifest valid" {
    const allocator = std.testing.allocator;
    const m = manifest_mod.PluginManifest{ .name = "test", .version = "1.0.0" };
    var entry = try loadFromManifest(allocator, m);
    defer entry.api.?.deinit();

    try std.testing.expect(entry.isActive());
    try std.testing.expectEqualStrings("test", entry.manifest.name);
}

test "loadFromManifest invalid manifest" {
    const allocator = std.testing.allocator;
    const m = manifest_mod.PluginManifest{ .name = "", .version = "1.0.0" };
    try std.testing.expectError(error.ManifestInvalid, loadFromManifest(allocator, m));
}

test "serializePluginList" {
    const allocator = std.testing.allocator;
    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .manifest = .{ .name = "p1", .version = "1.0.0" },
        .state = .active,
    });

    var buf: [1024]u8 = undefined;
    const json = try serializePluginList(&buf, &registry);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugins\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"p1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\":1") != null);
}

test "serializePluginList empty" {
    const allocator = std.testing.allocator;
    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    var buf: [256]u8 = undefined;
    const json = try serializePluginList(&buf, &registry);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugins\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\":0") != null);
}

test "PluginRegistry with api" {
    const allocator = std.testing.allocator;
    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    const m = manifest_mod.PluginManifest{ .name = "rich", .version = "1.0.0" };
    var entry = try loadFromManifest(allocator, m);
    try entry.api.?.registerTool("custom_tool", "desc");

    try registry.register(entry);
    try std.testing.expectEqual(@as(usize, 1), registry.count());
}

test "discoverPlugins nonexistent dir returns 0" {
    const allocator = std.testing.allocator;
    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    const count = try discoverPlugins(allocator, &registry, "/nonexistent/plugin/dir");
    try std.testing.expectEqual(@as(usize, 0), count);
    try std.testing.expectEqual(@as(usize, 0), registry.count());
}

test "discoverPlugins with real directory" {
    const allocator = std.testing.allocator;

    // Create temp plugin directory with a manifest
    const tmp_dir = "/tmp/zclaw_test_plugins";
    const plugin_subdir = "/tmp/zclaw_test_plugins/test-plugin";
    const manifest_path = "/tmp/zclaw_test_plugins/test-plugin/plugin.json";

    std.fs.cwd().makePath(plugin_subdir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    // Write a manifest file
    {
        const f = try std.fs.cwd().createFile(manifest_path, .{});
        defer f.close();
        try f.writeAll("{\"name\":\"test-plugin\",\"version\":\"1.0.0\",\"description\":\"A test plugin\"}");
    }

    var registry = PluginRegistry.init(allocator);
    defer {
        // Free duped manifest strings from discoverPlugins
        var iter = registry.plugins.valueIterator();
        while (iter.next()) |e| {
            allocator.free(e.manifest.name);
            allocator.free(e.manifest.version);
        }
        registry.deinit();
    }

    const count = try discoverPlugins(allocator, &registry, tmp_dir);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 1), registry.count());

    const entry = registry.get("test-plugin").?;
    try std.testing.expectEqualStrings("test-plugin", entry.manifest.name);
    try std.testing.expect(entry.isActive());
}

test "discoverPlugins skips invalid manifests" {
    const allocator = std.testing.allocator;

    const tmp_dir = "/tmp/zclaw_test_plugins_invalid";
    const plugin_subdir = "/tmp/zclaw_test_plugins_invalid/bad-plugin";
    const manifest_path = "/tmp/zclaw_test_plugins_invalid/bad-plugin/plugin.json";

    std.fs.cwd().makePath(plugin_subdir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    // Write invalid manifest (empty name)
    {
        const f = try std.fs.cwd().createFile(manifest_path, .{});
        defer f.close();
        try f.writeAll("{\"name\":\"\",\"version\":\"1.0.0\"}");
    }

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    const count = try discoverPlugins(allocator, &registry, tmp_dir);
    try std.testing.expectEqual(@as(usize, 0), count);
}

// --- Additional Tests ---

test "PLUGIN_DIR_NAME constant" {
    try std.testing.expectEqualStrings("plugins", PLUGIN_DIR_NAME);
}

test "MANIFEST_FILE constant" {
    try std.testing.expectEqualStrings("plugin.json", MANIFEST_FILE);
}

test "buildPluginDir empty base" {
    var buf: [256]u8 = undefined;
    const dir = try buildPluginDir(&buf, "");
    try std.testing.expectEqualStrings("plugins", dir);
}

test "buildPluginPath trailing slash" {
    var buf: [256]u8 = undefined;
    const path = try buildPluginPath(&buf, "/plugins/", "my-plugin");
    try std.testing.expect(std.mem.startsWith(u8, path, "/plugins/my-plugin"));
    try std.testing.expect(std.mem.endsWith(u8, path, PLUGIN_EXTENSION));
}

test "buildManifestPath trailing slash" {
    var buf: [256]u8 = undefined;
    const path = try buildManifestPath(&buf, "/plugins/", "my-plugin");
    try std.testing.expectEqualStrings("/plugins/my-plugin/plugin.json", path);
}

test "PluginRegistry empty" {
    const allocator = std.testing.allocator;
    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 0), registry.count());
    try std.testing.expectEqual(@as(usize, 0), registry.activeCount());
    try std.testing.expect(registry.get("anything") == null);
}

test "PluginRegistry enable non-disabled plugin" {
    const allocator = std.testing.allocator;
    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .manifest = .{ .name = "p", .version = "1.0.0" },
        .state = .active,
    });

    // enablePlugin should return false for already-active plugin
    try std.testing.expect(!registry.enablePlugin("p"));
}

test "PluginRegistry multiple plugins active count" {
    const allocator = std.testing.allocator;
    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .manifest = .{ .name = "a", .version = "1.0.0" },
        .state = .active,
    });
    try registry.register(.{
        .manifest = .{ .name = "b", .version = "1.0.0" },
        .state = .active,
    });
    try registry.register(.{
        .manifest = .{ .name = "c", .version = "1.0.0" },
        .state = .disabled,
    });

    try std.testing.expectEqual(@as(usize, 3), registry.count());
    try std.testing.expectEqual(@as(usize, 2), registry.activeCount());
}

test "loadFromManifest invalid version" {
    const allocator = std.testing.allocator;
    const m = manifest_mod.PluginManifest{ .name = "test", .version = "bad" };
    try std.testing.expectError(error.ManifestInvalid, loadFromManifest(allocator, m));
}

test "loadFromManifest sets api plugin_name" {
    const allocator = std.testing.allocator;
    const m = manifest_mod.PluginManifest{ .name = "my-plug", .version = "1.0.0" };
    var entry = try loadFromManifest(allocator, m);
    defer entry.api.?.deinit();

    try std.testing.expectEqualStrings("my-plug", entry.api.?.plugin_name);
}

test "serializePluginList multiple plugins" {
    const allocator = std.testing.allocator;
    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .manifest = .{ .name = "p1", .version = "1.0.0" },
        .state = .active,
    });
    try registry.register(.{
        .manifest = .{ .name = "p2", .version = "2.0.0" },
        .state = .disabled,
    });

    var buf: [1024]u8 = undefined;
    const json = try serializePluginList(&buf, &registry);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\":2") != null);
}

test "PluginRegistry disable then enable round trip" {
    const allocator = std.testing.allocator;
    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .manifest = .{ .name = "rt", .version = "1.0.0" },
        .state = .active,
    });

    try std.testing.expect(registry.disablePlugin("rt"));
    const disabled = registry.get("rt").?;
    try std.testing.expectEqual(api_mod.PluginState.disabled, disabled.state);

    try std.testing.expect(registry.enablePlugin("rt"));
    const enabled = registry.get("rt").?;
    try std.testing.expectEqual(api_mod.PluginState.active, enabled.state);
}

test "LoadError variants" {
    // Verify the error set contains expected variants
    const err: LoadError = error.PluginNotFound;
    try std.testing.expect(err == error.PluginNotFound);
}

// === Tests batch 3: manifest validation edge cases, registry operations, lifecycle ===

test "loadFromManifest missing version returns ManifestInvalid" {
    const allocator = std.testing.allocator;
    const m = manifest_mod.PluginManifest{ .name = "test", .version = "" };
    try std.testing.expectError(error.ManifestInvalid, loadFromManifest(allocator, m));
}

test "loadFromManifest partial semver returns ManifestInvalid" {
    const allocator = std.testing.allocator;
    // "1.0" is not a valid semver (needs X.Y.Z)
    const m = manifest_mod.PluginManifest{ .name = "test", .version = "1.0" };
    try std.testing.expectError(error.ManifestInvalid, loadFromManifest(allocator, m));
}

test "loadFromManifest entry has correct state and api fields" {
    const allocator = std.testing.allocator;
    const m = manifest_mod.PluginManifest{
        .name = "lifecycle-test",
        .version = "2.3.4",
        .description = "a test plugin",
        .author = "tester",
    };
    var entry = try loadFromManifest(allocator, m);
    defer entry.api.?.deinit();

    // Verify state is active upon loading
    try std.testing.expectEqual(api_mod.PluginState.active, entry.state);
    // Verify API was initialized with the manifest name
    try std.testing.expectEqualStrings("lifecycle-test", entry.api.?.plugin_name);
    // Verify the API starts with zero registrations
    try std.testing.expectEqual(@as(usize, 0), entry.api.?.count());
    // Verify manifest fields are preserved
    try std.testing.expectEqualStrings("2.3.4", entry.manifest.version);
}

test "PluginRegistry register overwrites same name" {
    const allocator = std.testing.allocator;
    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .manifest = .{ .name = "dup", .version = "1.0.0" },
        .state = .active,
    });
    try registry.register(.{
        .manifest = .{ .name = "dup", .version = "2.0.0" },
        .state = .disabled,
    });

    // HashMap put overwrites, so count stays 1
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    // The second registration should overwrite the first
    const entry = registry.get("dup").?;
    try std.testing.expectEqualStrings("2.0.0", entry.manifest.version);
    try std.testing.expectEqual(api_mod.PluginState.disabled, entry.state);
}

test "PluginRegistry activeCount with all states" {
    const allocator = std.testing.allocator;
    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .manifest = .{ .name = "a", .version = "1.0.0" },
        .state = .active,
    });
    try registry.register(.{
        .manifest = .{ .name = "b", .version = "1.0.0" },
        .state = .unloaded,
    });
    try registry.register(.{
        .manifest = .{ .name = "c", .version = "1.0.0" },
        .state = .error_state,
    });
    try registry.register(.{
        .manifest = .{ .name = "d", .version = "1.0.0" },
        .state = .loading,
    });
    try registry.register(.{
        .manifest = .{ .name = "e", .version = "1.0.0" },
        .state = .disabled,
    });

    // Only .active counts as active
    try std.testing.expectEqual(@as(usize, 5), registry.count());
    try std.testing.expectEqual(@as(usize, 1), registry.activeCount());
}

test "PluginRegistry disable then get confirms disabled state" {
    const allocator = std.testing.allocator;
    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .manifest = .{ .name = "toggler", .version = "1.0.0" },
        .state = .active,
    });

    try std.testing.expect(registry.get("toggler").?.isActive());
    try std.testing.expect(registry.disablePlugin("toggler"));
    try std.testing.expect(!registry.get("toggler").?.isActive());
    try std.testing.expectEqual(api_mod.PluginState.disabled, registry.get("toggler").?.state);
}

test "PluginRegistry enable on unloaded plugin returns false" {
    const allocator = std.testing.allocator;
    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .manifest = .{ .name = "unloaded-p", .version = "1.0.0" },
        .state = .unloaded,
    });

    // enablePlugin only works on .disabled state, not .unloaded
    try std.testing.expect(!registry.enablePlugin("unloaded-p"));
    try std.testing.expectEqual(api_mod.PluginState.unloaded, registry.get("unloaded-p").?.state);
}

test "serializePluginList reflects disabled state label" {
    const allocator = std.testing.allocator;
    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .manifest = .{ .name = "d-plug", .version = "1.0.0" },
        .state = .disabled,
    });

    var buf: [1024]u8 = undefined;
    const json = try serializePluginList(&buf, &registry);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"d-plug\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"state\":\"disabled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\":1") != null);
}

test "buildPluginPath buffer too small returns error" {
    var buf: [5]u8 = undefined;
    const result = buildPluginPath(&buf, "/plugins", "my-plugin");
    try std.testing.expectError(error.NoSpaceLeft, result);
}
