const std = @import("std");
const manifest_mod = @import("manifest.zig");

// --- Plugin Hook Types ---

pub const HookType = enum {
    on_message, // Called when a message is received
    on_response, // Called before sending a response
    on_connect, // Called when a channel connects
    on_disconnect, // Called when a channel disconnects
    on_startup, // Called on gateway startup
    on_shutdown, // Called on gateway shutdown

    pub fn label(self: HookType) []const u8 {
        return switch (self) {
            .on_message => "on_message",
            .on_response => "on_response",
            .on_connect => "on_connect",
            .on_disconnect => "on_disconnect",
            .on_startup => "on_startup",
            .on_shutdown => "on_shutdown",
        };
    }
};

// --- Plugin Registration ---

pub const RegistrationType = enum {
    rpc_method,
    http_route,
    tool,
    cli_command,
    hook,
    service,

    pub fn label(self: RegistrationType) []const u8 {
        return switch (self) {
            .rpc_method => "rpc_method",
            .http_route => "http_route",
            .tool => "tool",
            .cli_command => "cli_command",
            .hook => "hook",
            .service => "service",
        };
    }
};

pub const Registration = struct {
    reg_type: RegistrationType,
    name: []const u8,
    description: []const u8 = "",
    plugin_name: []const u8 = "",
};

// --- Plugin API (passed to plugin_init) ---

pub const PluginApi = struct {
    registrations: std.ArrayListUnmanaged(Registration),
    allocator: std.mem.Allocator,
    plugin_name: []const u8,

    pub fn init(allocator: std.mem.Allocator, plugin_name: []const u8) PluginApi {
        return .{
            .registrations = .{},
            .allocator = allocator,
            .plugin_name = plugin_name,
        };
    }

    pub fn deinit(self: *PluginApi) void {
        self.registrations.deinit(self.allocator);
    }

    pub fn registerRpcMethod(self: *PluginApi, name: []const u8, description: []const u8) !void {
        try self.registrations.append(self.allocator, .{
            .reg_type = .rpc_method,
            .name = name,
            .description = description,
            .plugin_name = self.plugin_name,
        });
    }

    pub fn registerHttpRoute(self: *PluginApi, path: []const u8, description: []const u8) !void {
        try self.registrations.append(self.allocator, .{
            .reg_type = .http_route,
            .name = path,
            .description = description,
            .plugin_name = self.plugin_name,
        });
    }

    pub fn registerTool(self: *PluginApi, name: []const u8, description: []const u8) !void {
        try self.registrations.append(self.allocator, .{
            .reg_type = .tool,
            .name = name,
            .description = description,
            .plugin_name = self.plugin_name,
        });
    }

    pub fn registerCliCommand(self: *PluginApi, name: []const u8, description: []const u8) !void {
        try self.registrations.append(self.allocator, .{
            .reg_type = .cli_command,
            .name = name,
            .description = description,
            .plugin_name = self.plugin_name,
        });
    }

    pub fn registerHook(self: *PluginApi, hook_type: HookType) !void {
        try self.registrations.append(self.allocator, .{
            .reg_type = .hook,
            .name = hook_type.label(),
            .plugin_name = self.plugin_name,
        });
    }

    pub fn registerService(self: *PluginApi, name: []const u8, description: []const u8) !void {
        try self.registrations.append(self.allocator, .{
            .reg_type = .service,
            .name = name,
            .description = description,
            .plugin_name = self.plugin_name,
        });
    }

    pub fn count(self: *const PluginApi) usize {
        return self.registrations.items.len;
    }

    pub fn getByType(self: *const PluginApi, reg_type: RegistrationType) []const Registration {
        // Return a view of registrations of a given type
        // Since we can't allocate, just count for now
        _ = reg_type;
        return self.registrations.items;
    }

    pub fn countByType(self: *const PluginApi, reg_type: RegistrationType) usize {
        var n: usize = 0;
        for (self.registrations.items) |r| {
            if (r.reg_type == reg_type) n += 1;
        }
        return n;
    }
};

// --- Plugin State ---

pub const PluginState = enum {
    unloaded,
    loading,
    active,
    error_state,
    disabled,

    pub fn label(self: PluginState) []const u8 {
        return switch (self) {
            .unloaded => "unloaded",
            .loading => "loading",
            .active => "active",
            .error_state => "error",
            .disabled => "disabled",
        };
    }

    pub fn isRunning(self: PluginState) bool {
        return self == .active;
    }
};

// --- Plugin Entry ---

pub const PluginEntry = struct {
    manifest: manifest_mod.PluginManifest,
    state: PluginState = .unloaded,
    api: ?PluginApi = null,
    load_error: ?[]const u8 = null,

    pub fn isActive(self: *const PluginEntry) bool {
        return self.state == .active;
    }

    pub fn registrationCount(self: *const PluginEntry) usize {
        if (self.api) |*api| {
            return api.count();
        }
        return 0;
    }
};

// --- Serialize Plugin Info ---

pub fn serializePluginInfo(buf: []u8, entry: *const PluginEntry) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("{\"name\":\"");
    try w.writeAll(entry.manifest.name);
    try w.writeAll("\",\"version\":\"");
    try w.writeAll(entry.manifest.version);
    try w.writeAll("\",\"state\":\"");
    try w.writeAll(entry.state.label());
    try w.writeAll("\",\"registrations\":");
    try std.fmt.format(w, "{d}", .{entry.registrationCount()});
    try w.writeAll("}");
    return fbs.getWritten();
}

// --- Tests ---

test "HookType labels" {
    try std.testing.expectEqualStrings("on_message", HookType.on_message.label());
    try std.testing.expectEqualStrings("on_startup", HookType.on_startup.label());
    try std.testing.expectEqualStrings("on_shutdown", HookType.on_shutdown.label());
}

test "RegistrationType labels" {
    try std.testing.expectEqualStrings("rpc_method", RegistrationType.rpc_method.label());
    try std.testing.expectEqualStrings("tool", RegistrationType.tool.label());
    try std.testing.expectEqualStrings("hook", RegistrationType.hook.label());
}

test "PluginApi init and register" {
    const allocator = std.testing.allocator;
    var api = PluginApi.init(allocator, "test-plugin");
    defer api.deinit();

    try api.registerRpcMethod("custom.method", "A custom RPC method");
    try api.registerTool("my_tool", "My custom tool");
    try api.registerHttpRoute("/api/custom", "Custom endpoint");
    try api.registerCliCommand("custom-cmd", "A CLI command");
    try api.registerHook(.on_message);
    try api.registerService("bg-worker", "Background worker");

    try std.testing.expectEqual(@as(usize, 6), api.count());
    try std.testing.expectEqual(@as(usize, 1), api.countByType(.rpc_method));
    try std.testing.expectEqual(@as(usize, 1), api.countByType(.tool));
    try std.testing.expectEqual(@as(usize, 1), api.countByType(.http_route));
    try std.testing.expectEqual(@as(usize, 1), api.countByType(.cli_command));
    try std.testing.expectEqual(@as(usize, 1), api.countByType(.hook));
    try std.testing.expectEqual(@as(usize, 1), api.countByType(.service));
}

test "PluginApi empty" {
    const allocator = std.testing.allocator;
    var api = PluginApi.init(allocator, "empty");
    defer api.deinit();

    try std.testing.expectEqual(@as(usize, 0), api.count());
    try std.testing.expectEqual(@as(usize, 0), api.countByType(.tool));
}

test "PluginApi plugin_name propagated" {
    const allocator = std.testing.allocator;
    var api = PluginApi.init(allocator, "my-plugin");
    defer api.deinit();

    try api.registerTool("tool1", "desc");
    try std.testing.expectEqualStrings("my-plugin", api.registrations.items[0].plugin_name);
}

test "PluginState labels" {
    try std.testing.expectEqualStrings("active", PluginState.active.label());
    try std.testing.expectEqualStrings("unloaded", PluginState.unloaded.label());
    try std.testing.expectEqualStrings("error", PluginState.error_state.label());
    try std.testing.expectEqualStrings("disabled", PluginState.disabled.label());
}

test "PluginState isRunning" {
    try std.testing.expect(PluginState.active.isRunning());
    try std.testing.expect(!PluginState.unloaded.isRunning());
    try std.testing.expect(!PluginState.error_state.isRunning());
    try std.testing.expect(!PluginState.disabled.isRunning());
}

test "PluginEntry defaults" {
    const entry = PluginEntry{
        .manifest = .{ .name = "test" },
    };
    try std.testing.expectEqual(PluginState.unloaded, entry.state);
    try std.testing.expect(!entry.isActive());
    try std.testing.expectEqual(@as(usize, 0), entry.registrationCount());
}

test "PluginEntry with api" {
    const allocator = std.testing.allocator;
    var api = PluginApi.init(allocator, "test");
    try api.registerTool("t1", "d");
    try api.registerTool("t2", "d");

    var entry = PluginEntry{
        .manifest = .{ .name = "test", .version = "1.0.0" },
        .state = .active,
        .api = api,
    };
    defer entry.api.?.deinit();

    try std.testing.expect(entry.isActive());
    try std.testing.expectEqual(@as(usize, 2), entry.registrationCount());
}

test "serializePluginInfo" {
    const entry = PluginEntry{
        .manifest = .{ .name = "my-plugin", .version = "1.2.3" },
        .state = .active,
    };
    var buf: [512]u8 = undefined;
    const json = try serializePluginInfo(&buf, &entry);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"my-plugin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"version\":\"1.2.3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"state\":\"active\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"registrations\":0") != null);
}

test "PluginEntry error state" {
    const entry = PluginEntry{
        .manifest = .{ .name = "broken" },
        .state = .error_state,
        .load_error = "Failed to load symbol",
    };
    try std.testing.expectEqual(PluginState.error_state, entry.state);
    try std.testing.expectEqualStrings("Failed to load symbol", entry.load_error.?);
}

test "PluginApi multiple of same type" {
    const allocator = std.testing.allocator;
    var api = PluginApi.init(allocator, "multi");
    defer api.deinit();

    try api.registerTool("tool1", "d1");
    try api.registerTool("tool2", "d2");
    try api.registerTool("tool3", "d3");

    try std.testing.expectEqual(@as(usize, 3), api.countByType(.tool));
    try std.testing.expectEqual(@as(usize, 0), api.countByType(.rpc_method));
}
