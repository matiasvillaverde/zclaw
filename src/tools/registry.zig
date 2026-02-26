const std = @import("std");

// --- Tool Definition ---

pub const ToolCategory = enum {
    file,
    exec,
    web,
    memory,
    session,
    cron,
    image,
    message,
    browser,
    custom,

    pub fn label(self: ToolCategory) []const u8 {
        return switch (self) {
            .file => "file",
            .exec => "exec",
            .web => "web",
            .memory => "memory",
            .session => "session",
            .cron => "cron",
            .image => "image",
            .message => "message",
            .browser => "browser",
            .custom => "custom",
        };
    }
};

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8 = "",
    category: ToolCategory = .custom,
    parameters_json: ?[]const u8 = null,
    requires_approval: bool = false,
    sandboxed: bool = false,
};

// --- Tool Execution Result ---

pub const ToolResult = struct {
    success: bool,
    output: []const u8,
    error_message: ?[]const u8 = null,
    elapsed_ms: i64 = 0,
};

// --- Tool Handler ---

pub const ToolHandler = *const fn (input_json: []const u8, output_buf: []u8) ToolResult;

// --- Tool Registry ---

pub const ToolEntry = struct {
    def: ToolDef,
    handler: ToolHandler,
    enabled: bool,
};

pub const ToolRegistry = struct {
    tools: std.StringHashMapUnmanaged(ToolEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{
            .tools = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ToolRegistry) void {
        self.tools.deinit(self.allocator);
    }

    pub fn register(self: *ToolRegistry, def: ToolDef, handler: ToolHandler) !void {
        try self.tools.put(self.allocator, def.name, .{
            .def = def,
            .handler = handler,
            .enabled = true,
        });
    }

    pub fn get(self: *const ToolRegistry, name: []const u8) ?*const ToolEntry {
        return if (self.tools.getPtr(name)) |ptr| ptr else null;
    }

    pub fn execute(self: *const ToolRegistry, name: []const u8, input_json: []const u8, output_buf: []u8) ?ToolResult {
        const entry = self.tools.get(name) orelse return null;
        if (!entry.enabled) return ToolResult{
            .success = false,
            .output = "",
            .error_message = "tool is disabled",
        };
        return entry.handler(input_json, output_buf);
    }

    pub fn count(self: *const ToolRegistry) usize {
        return self.tools.count();
    }

    pub fn setEnabled(self: *ToolRegistry, name: []const u8, enabled: bool) bool {
        if (self.tools.getPtr(name)) |entry| {
            entry.enabled = enabled;
            return true;
        }
        return false;
    }

    /// List all tool names.
    pub fn listNames(self: *const ToolRegistry, allocator: std.mem.Allocator) ![][]const u8 {
        var names = std.ArrayListUnmanaged([]const u8){};
        var iter = self.tools.keyIterator();
        while (iter.next()) |key| {
            try names.append(allocator, key.*);
        }
        return names.toOwnedSlice(allocator);
    }

    /// List tools by category.
    pub fn listByCategory(self: *const ToolRegistry, allocator: std.mem.Allocator, category: ToolCategory) ![][]const u8 {
        var names = std.ArrayListUnmanaged([]const u8){};
        var iter = self.tools.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.def.category == category) {
                try names.append(allocator, entry.key_ptr.*);
            }
        }
        return names.toOwnedSlice(allocator);
    }

    /// Build tool definitions JSON for provider APIs.
    pub fn buildToolsJson(self: *const ToolRegistry, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        try writer.writeByte('[');
        var first = true;
        var iter = self.tools.iterator();
        while (iter.next()) |entry| {
            if (!entry.value_ptr.enabled) continue;
            if (!first) try writer.writeByte(',');
            first = false;

            try writer.writeAll("{\"name\":\"");
            try writer.writeAll(entry.value_ptr.def.name);
            try writer.writeAll("\"");

            if (entry.value_ptr.def.description.len > 0) {
                try writer.writeAll(",\"description\":\"");
                try writer.writeAll(entry.value_ptr.def.description);
                try writer.writeAll("\"");
            }

            if (entry.value_ptr.def.parameters_json) |params| {
                try writer.writeAll(",\"input_schema\":");
                try writer.writeAll(params);
            }

            try writer.writeByte('}');
        }
        try writer.writeByte(']');

        return fbs.getWritten();
    }
};

// --- Tests ---

fn dummyHandler(_: []const u8, _: []u8) ToolResult {
    return .{ .success = true, .output = "ok" };
}

fn failHandler(_: []const u8, _: []u8) ToolResult {
    return .{ .success = false, .output = "", .error_message = "failed" };
}

test "ToolCategory labels" {
    try std.testing.expectEqualStrings("file", ToolCategory.file.label());
    try std.testing.expectEqualStrings("exec", ToolCategory.exec.label());
    try std.testing.expectEqualStrings("web", ToolCategory.web.label());
    try std.testing.expectEqualStrings("custom", ToolCategory.custom.label());
}

test "ToolRegistry register and get" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{ .name = "bash", .category = .exec }, dummyHandler);
    try std.testing.expectEqual(@as(usize, 1), registry.count());

    const entry = registry.get("bash").?;
    try std.testing.expectEqualStrings("bash", entry.def.name);
    try std.testing.expect(entry.enabled);

    try std.testing.expect(registry.get("nonexistent") == null);
}

test "ToolRegistry execute" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{ .name = "bash", .category = .exec }, dummyHandler);

    var buf: [1024]u8 = undefined;
    const result = registry.execute("bash", "{}", &buf).?;
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("ok", result.output);
}

test "ToolRegistry execute nonexistent" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    var buf: [1024]u8 = undefined;
    try std.testing.expect(registry.execute("nonexistent", "{}", &buf) == null);
}

test "ToolRegistry execute disabled" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{ .name = "bash", .category = .exec }, dummyHandler);
    _ = registry.setEnabled("bash", false);

    var buf: [1024]u8 = undefined;
    const result = registry.execute("bash", "{}", &buf).?;
    try std.testing.expect(!result.success);
}

test "ToolRegistry setEnabled" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{ .name = "bash" }, dummyHandler);
    try std.testing.expect(registry.get("bash").?.enabled);

    try std.testing.expect(registry.setEnabled("bash", false));
    try std.testing.expect(!registry.get("bash").?.enabled);

    try std.testing.expect(!registry.setEnabled("nonexistent", true));
}

test "ToolRegistry listNames" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{ .name = "bash", .category = .exec }, dummyHandler);
    try registry.register(.{ .name = "read", .category = .file }, dummyHandler);

    const names = try registry.listNames(allocator);
    defer allocator.free(names);

    try std.testing.expectEqual(@as(usize, 2), names.len);
}

test "ToolRegistry listByCategory" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{ .name = "bash", .category = .exec }, dummyHandler);
    try registry.register(.{ .name = "read", .category = .file }, dummyHandler);
    try registry.register(.{ .name = "write", .category = .file }, dummyHandler);

    const file_tools = try registry.listByCategory(allocator, .file);
    defer allocator.free(file_tools);
    try std.testing.expectEqual(@as(usize, 2), file_tools.len);

    const exec_tools = try registry.listByCategory(allocator, .exec);
    defer allocator.free(exec_tools);
    try std.testing.expectEqual(@as(usize, 1), exec_tools.len);
}

test "ToolRegistry buildToolsJson" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .name = "bash",
        .description = "Execute commands",
        .category = .exec,
        .parameters_json = "{\"type\":\"object\"}",
    }, dummyHandler);

    var buf: [4096]u8 = undefined;
    const json = try registry.buildToolsJson(&buf);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"bash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"description\":\"Execute commands\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"input_schema\":{") != null);
}

test "ToolResult fields" {
    const result = ToolResult{
        .success = true,
        .output = "file contents",
        .elapsed_ms = 42,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(i64, 42), result.elapsed_ms);
    try std.testing.expect(result.error_message == null);
}

test "ToolDef defaults" {
    const def = ToolDef{ .name = "test" };
    try std.testing.expectEqualStrings("test", def.name);
    try std.testing.expectEqual(ToolCategory.custom, def.category);
    try std.testing.expect(!def.requires_approval);
    try std.testing.expect(!def.sandboxed);
}
