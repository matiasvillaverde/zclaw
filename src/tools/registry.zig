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

// --- Additional Tests ---

test "ToolCategory all labels are non-empty" {
    for (std.meta.tags(ToolCategory)) |cat| {
        try std.testing.expect(cat.label().len > 0);
    }
}

test "ToolCategory memory label" {
    try std.testing.expectEqualStrings("memory", ToolCategory.memory.label());
}

test "ToolCategory session label" {
    try std.testing.expectEqualStrings("session", ToolCategory.session.label());
}

test "ToolCategory cron label" {
    try std.testing.expectEqualStrings("cron", ToolCategory.cron.label());
}

test "ToolCategory image label" {
    try std.testing.expectEqualStrings("image", ToolCategory.image.label());
}

test "ToolCategory message label" {
    try std.testing.expectEqualStrings("message", ToolCategory.message.label());
}

test "ToolCategory browser label" {
    try std.testing.expectEqualStrings("browser", ToolCategory.browser.label());
}

test "ToolRegistry empty" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 0), registry.count());
    try std.testing.expect(registry.get("anything") == null);
}

test "ToolRegistry setEnabled nonexistent returns false" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expect(!registry.setEnabled("missing", true));
    try std.testing.expect(!registry.setEnabled("missing", false));
}

test "ToolRegistry listNames empty" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    const names = try registry.listNames(allocator);
    defer allocator.free(names);
    try std.testing.expectEqual(@as(usize, 0), names.len);
}

test "ToolRegistry listByCategory empty category" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{ .name = "bash", .category = .exec }, dummyHandler);

    const web_tools = try registry.listByCategory(allocator, .web);
    defer allocator.free(web_tools);
    try std.testing.expectEqual(@as(usize, 0), web_tools.len);
}

test "ToolRegistry execute with fail handler" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{ .name = "fail_tool" }, failHandler);

    var buf: [1024]u8 = undefined;
    const result = registry.execute("fail_tool", "{}", &buf).?;
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("failed", result.error_message.?);
}

test "ToolRegistry buildToolsJson empty" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    var buf: [256]u8 = undefined;
    const json = try registry.buildToolsJson(&buf);
    try std.testing.expectEqualStrings("[]", json);
}

test "ToolRegistry buildToolsJson skips disabled" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{ .name = "enabled_tool", .description = "desc" }, dummyHandler);
    try registry.register(.{ .name = "disabled_tool", .description = "desc2" }, dummyHandler);
    _ = registry.setEnabled("disabled_tool", false);

    var buf: [4096]u8 = undefined;
    const json = try registry.buildToolsJson(&buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "enabled_tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "disabled_tool") == null);
}

test "ToolRegistry execute disabled returns error message" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{ .name = "tool1" }, dummyHandler);
    _ = registry.setEnabled("tool1", false);

    var buf: [1024]u8 = undefined;
    const result = registry.execute("tool1", "{}", &buf).?;
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("tool is disabled", result.error_message.?);
    try std.testing.expectEqualStrings("", result.output);
}

test "ToolResult defaults" {
    const result = ToolResult{
        .success = false,
        .output = "out",
    };
    try std.testing.expect(result.error_message == null);
    try std.testing.expectEqual(@as(i64, 0), result.elapsed_ms);
}

test "ToolDef with all fields" {
    const def = ToolDef{
        .name = "complex",
        .description = "A complex tool",
        .category = .exec,
        .parameters_json = "{\"type\":\"object\"}",
        .requires_approval = true,
        .sandboxed = true,
    };
    try std.testing.expectEqualStrings("complex", def.name);
    try std.testing.expectEqualStrings("A complex tool", def.description);
    try std.testing.expectEqual(ToolCategory.exec, def.category);
    try std.testing.expect(def.requires_approval);
    try std.testing.expect(def.sandboxed);
    try std.testing.expect(def.parameters_json != null);
}

test "ToolRegistry re-register overwrites" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{ .name = "tool1", .category = .file }, dummyHandler);
    try registry.register(.{ .name = "tool1", .category = .exec }, failHandler);

    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expectEqual(ToolCategory.exec, registry.get("tool1").?.def.category);
}

// === New Tests (batch 2) ===

test "ToolRegistry register multiple unique tools" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    try reg.register(.{ .name = "a", .category = .file }, dummyHandler);
    try reg.register(.{ .name = "b", .category = .exec }, dummyHandler);
    try reg.register(.{ .name = "c", .category = .web }, dummyHandler);
    try reg.register(.{ .name = "d", .category = .memory }, dummyHandler);
    try reg.register(.{ .name = "e", .category = .session }, dummyHandler);

    try std.testing.expectEqual(@as(usize, 5), reg.count());
    try std.testing.expect(reg.get("a") != null);
    try std.testing.expect(reg.get("b") != null);
    try std.testing.expect(reg.get("c") != null);
    try std.testing.expect(reg.get("d") != null);
    try std.testing.expect(reg.get("e") != null);
}

test "ToolRegistry get returns correct handler" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    try reg.register(.{ .name = "dummy" }, dummyHandler);
    try reg.register(.{ .name = "fail" }, failHandler);

    var buf: [1024]u8 = undefined;
    const r1 = reg.get("dummy").?.handler("{}", &buf);
    try std.testing.expect(r1.success);

    const r2 = reg.get("fail").?.handler("{}", &buf);
    try std.testing.expect(!r2.success);
}

test "ToolRegistry setEnabled toggle on off on" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    try reg.register(.{ .name = "tool" }, dummyHandler);
    try std.testing.expect(reg.get("tool").?.enabled);

    _ = reg.setEnabled("tool", false);
    try std.testing.expect(!reg.get("tool").?.enabled);

    _ = reg.setEnabled("tool", true);
    try std.testing.expect(reg.get("tool").?.enabled);

    _ = reg.setEnabled("tool", false);
    try std.testing.expect(!reg.get("tool").?.enabled);
}

test "ToolRegistry listByCategory returns empty for unused category" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    try reg.register(.{ .name = "a", .category = .file }, dummyHandler);
    try reg.register(.{ .name = "b", .category = .file }, dummyHandler);

    const cron_tools = try reg.listByCategory(allocator, .cron);
    defer allocator.free(cron_tools);
    try std.testing.expectEqual(@as(usize, 0), cron_tools.len);

    const image_tools = try reg.listByCategory(allocator, .image);
    defer allocator.free(image_tools);
    try std.testing.expectEqual(@as(usize, 0), image_tools.len);

    const browser_tools = try reg.listByCategory(allocator, .browser);
    defer allocator.free(browser_tools);
    try std.testing.expectEqual(@as(usize, 0), browser_tools.len);
}

test "ToolRegistry buildToolsJson with no description" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    try reg.register(.{ .name = "simple_tool" }, dummyHandler);

    var buf: [4096]u8 = undefined;
    const json = try reg.buildToolsJson(&buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"simple_tool\"") != null);
    // No description field should appear since it's empty
    try std.testing.expect(std.mem.indexOf(u8, json, "\"description\"") == null);
}

test "ToolRegistry buildToolsJson with no parameters" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    try reg.register(.{ .name = "no_params", .description = "Tool without params" }, dummyHandler);

    var buf: [4096]u8 = undefined;
    const json = try reg.buildToolsJson(&buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"no_params\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"description\":\"Tool without params\"") != null);
    // No input_schema since parameters_json is null
    try std.testing.expect(std.mem.indexOf(u8, json, "input_schema") == null);
}

test "ToolRegistry buildToolsJson multiple tools" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    try reg.register(.{ .name = "tool_a", .description = "First" }, dummyHandler);
    try reg.register(.{ .name = "tool_b", .description = "Second" }, dummyHandler);

    var buf: [4096]u8 = undefined;
    const json = try reg.buildToolsJson(&buf);

    // Should start with [ and end with ]
    try std.testing.expect(json.len > 0);
    try std.testing.expectEqual(@as(u8, '['), json[0]);
    try std.testing.expectEqual(@as(u8, ']'), json[json.len - 1]);

    // Both tools present
    try std.testing.expect(std.mem.indexOf(u8, json, "tool_a") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "tool_b") != null);
}

test "ToolRegistry execute re-enabled tool succeeds" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    try reg.register(.{ .name = "tool" }, dummyHandler);
    _ = reg.setEnabled("tool", false);
    _ = reg.setEnabled("tool", true);

    var buf: [1024]u8 = undefined;
    const result = reg.execute("tool", "{}", &buf).?;
    try std.testing.expect(result.success);
}

test "ToolRegistry listNames with disabled tools still lists them" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    try reg.register(.{ .name = "active" }, dummyHandler);
    try reg.register(.{ .name = "inactive" }, dummyHandler);
    _ = reg.setEnabled("inactive", false);

    const names = try reg.listNames(allocator);
    defer allocator.free(names);

    // Both names should be listed regardless of enabled status
    try std.testing.expectEqual(@as(usize, 2), names.len);
}

test "ToolDef empty description is default" {
    const def = ToolDef{ .name = "x" };
    try std.testing.expectEqualStrings("", def.description);
}

test "ToolDef null parameters_json is default" {
    const def = ToolDef{ .name = "x" };
    try std.testing.expect(def.parameters_json == null);
}

test "ToolResult with error message" {
    const result = ToolResult{
        .success = false,
        .output = "",
        .error_message = "something went wrong",
        .elapsed_ms = 100,
    };
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("something went wrong", result.error_message.?);
    try std.testing.expectEqual(@as(i64, 100), result.elapsed_ms);
}

test "ToolEntry has correct initial enabled state" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    try reg.register(.{ .name = "test_tool", .sandboxed = true, .requires_approval = true }, dummyHandler);
    const entry = reg.get("test_tool").?;
    try std.testing.expect(entry.enabled);
    try std.testing.expect(entry.def.sandboxed);
    try std.testing.expect(entry.def.requires_approval);
}

test "ToolRegistry listByCategory all categories" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    try reg.register(.{ .name = "f", .category = .file }, dummyHandler);
    try reg.register(.{ .name = "e", .category = .exec }, dummyHandler);
    try reg.register(.{ .name = "w", .category = .web }, dummyHandler);
    try reg.register(.{ .name = "m", .category = .memory }, dummyHandler);
    try reg.register(.{ .name = "s", .category = .session }, dummyHandler);
    try reg.register(.{ .name = "cr", .category = .cron }, dummyHandler);
    try reg.register(.{ .name = "i", .category = .image }, dummyHandler);
    try reg.register(.{ .name = "ms", .category = .message }, dummyHandler);
    try reg.register(.{ .name = "br", .category = .browser }, dummyHandler);
    try reg.register(.{ .name = "cu", .category = .custom }, dummyHandler);

    for (std.meta.tags(ToolCategory)) |cat| {
        const tools = try reg.listByCategory(allocator, cat);
        defer allocator.free(tools);
        try std.testing.expectEqual(@as(usize, 1), tools.len);
    }
}

test "ToolRegistry count after re-register same name" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    try reg.register(.{ .name = "tool" }, dummyHandler);
    try reg.register(.{ .name = "tool" }, failHandler);
    try reg.register(.{ .name = "tool" }, dummyHandler);

    try std.testing.expectEqual(@as(usize, 1), reg.count());
}

test "ToolRegistry buildToolsJson all disabled is empty array" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    try reg.register(.{ .name = "a" }, dummyHandler);
    try reg.register(.{ .name = "b" }, dummyHandler);
    _ = reg.setEnabled("a", false);
    _ = reg.setEnabled("b", false);

    var buf: [4096]u8 = undefined;
    const json = try reg.buildToolsJson(&buf);
    try std.testing.expectEqualStrings("[]", json);
}

test "ToolRegistry listByCategory empty registry" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const tools = try reg.listByCategory(allocator, .file);
    defer allocator.free(tools);
    try std.testing.expectEqual(@as(usize, 0), tools.len);
}

test "ToolRegistry execute returns output from handler" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    try reg.register(.{ .name = "ok" }, dummyHandler);
    try reg.register(.{ .name = "fail" }, failHandler);

    var buf: [1024]u8 = undefined;
    const ok_result = reg.execute("ok", "{}", &buf).?;
    try std.testing.expectEqualStrings("ok", ok_result.output);

    const fail_result = reg.execute("fail", "{}", &buf).?;
    try std.testing.expectEqualStrings("", fail_result.output);
    try std.testing.expectEqualStrings("failed", fail_result.error_message.?);
}

test "ToolDef categories match label round-trip" {
    const categories = std.meta.tags(ToolCategory);
    for (categories) |cat| {
        const l = cat.label();
        try std.testing.expect(l.len > 0);
        // labels should be lowercase alphabetical
        for (l) |c| {
            try std.testing.expect(c >= 'a' and c <= 'z');
        }
    }
}

test "ToolRegistry get returns non-null for registered tool" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    try reg.register(.{ .name = "test_get" }, dummyHandler);
    const entry = reg.get("test_get");
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("test_get", entry.?.def.name);
}

test "ToolCategory has 10 variants" {
    const tags = std.meta.tags(ToolCategory);
    try std.testing.expectEqual(@as(usize, 10), tags.len);
}
