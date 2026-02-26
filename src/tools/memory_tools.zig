const std = @import("std");
const registry = @import("registry.zig");

// --- Memory Tools ---
//
// Bridges the MemoryManager to the tool registry via module-level state.

const MemoryManager = @import("../memory/manager.zig").MemoryManager;

var global_manager: ?*MemoryManager = null;

/// Set the memory manager for tool handlers.
pub fn setManager(mgr: *MemoryManager) void {
    global_manager = mgr;
}

/// Clear the memory manager reference.
pub fn clearManager() void {
    global_manager = null;
}

fn extractParam(json: []const u8, key: []const u8) ?[]const u8 {
    var prefix_buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&prefix_buf);
    fbs.writer().writeByte('"') catch return null;
    fbs.writer().writeAll(key) catch return null;
    fbs.writer().writeAll("\":\"") catch return null;
    const prefix = fbs.getWritten();

    const start = std.mem.indexOf(u8, json, prefix) orelse return null;
    const value_start = start + prefix.len;
    if (value_start >= json.len) return null;

    var i = value_start;
    while (i < json.len) : (i += 1) {
        if (json[i] == '"' and (i == value_start or json[i - 1] != '\\')) {
            return json[value_start..i];
        }
    }
    return null;
}

/// Memory search tool handler.
/// Input: {"query": "search terms"}
pub fn memorySearchHandler(input_json: []const u8, output_buf: []u8) registry.ToolResult {
    const query = extractParam(input_json, "query") orelse
        return .{ .success = false, .output = "", .error_message = "missing 'query' parameter" };

    if (query.len == 0)
        return .{ .success = false, .output = "", .error_message = "empty query" };

    if (global_manager == null)
        return .{ .success = false, .output = "", .error_message = "memory manager not initialized" };

    // Delegate to manager — in a real implementation, this would do vector search
    var fbs = std.io.fixedBufferStream(output_buf);
    std.fmt.format(fbs.writer(), "memory_search: query={s}", .{query}) catch
        return .{ .success = false, .output = "", .error_message = "output buffer overflow" };

    return .{ .success = true, .output = fbs.getWritten() };
}

/// Memory index tool handler.
/// Input: {"content": "text to remember", "tag": "optional tag"}
pub fn memoryIndexHandler(input_json: []const u8, output_buf: []u8) registry.ToolResult {
    const content = extractParam(input_json, "content") orelse
        return .{ .success = false, .output = "", .error_message = "missing 'content' parameter" };

    if (content.len == 0)
        return .{ .success = false, .output = "", .error_message = "empty content" };

    if (global_manager == null)
        return .{ .success = false, .output = "", .error_message = "memory manager not initialized" };

    const tag = extractParam(input_json, "tag");

    _ = tag;

    // Delegate to manager — in a real implementation, this would chunk and index
    var fbs = std.io.fixedBufferStream(output_buf);
    std.fmt.format(fbs.writer(), "memory_index: stored {d} chars", .{content.len}) catch
        return .{ .success = false, .output = "", .error_message = "output buffer overflow" };

    return .{ .success = true, .output = fbs.getWritten() };
}

pub const BUILTIN_MEMORY_SEARCH = registry.ToolDef{
    .name = "memory_search",
    .description = "Search agent memory for relevant information",
    .category = .memory,
    .parameters_json = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"Search query\"}},\"required\":[\"query\"]}",
};

pub const BUILTIN_MEMORY_INDEX = registry.ToolDef{
    .name = "memory_index",
    .description = "Store information in agent memory",
    .category = .memory,
    .parameters_json = "{\"type\":\"object\",\"properties\":{\"content\":{\"type\":\"string\",\"description\":\"Content to remember\"},\"tag\":{\"type\":\"string\",\"description\":\"Optional tag\"}},\"required\":[\"content\"]}",
};

/// Register memory tools with the registry.
pub fn registerMemoryTools(reg: *registry.ToolRegistry) !void {
    try reg.register(BUILTIN_MEMORY_SEARCH, memorySearchHandler);
    try reg.register(BUILTIN_MEMORY_INDEX, memoryIndexHandler);
}

// --- Tests ---

test "memorySearchHandler missing query" {
    var buf: [4096]u8 = undefined;
    const result = memorySearchHandler("{}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("missing 'query' parameter", result.error_message.?);
}

test "memorySearchHandler empty query" {
    var buf: [4096]u8 = undefined;
    const result = memorySearchHandler("{\"query\":\"\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("empty query", result.error_message.?);
}

test "memorySearchHandler no manager" {
    clearManager();
    var buf: [4096]u8 = undefined;
    const result = memorySearchHandler("{\"query\":\"test\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("memory manager not initialized", result.error_message.?);
}

test "memoryIndexHandler missing content" {
    var buf: [4096]u8 = undefined;
    const result = memoryIndexHandler("{}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("missing 'content' parameter", result.error_message.?);
}

test "memoryIndexHandler empty content" {
    var buf: [4096]u8 = undefined;
    const result = memoryIndexHandler("{\"content\":\"\"}", &buf);
    try std.testing.expect(!result.success);
}

test "memoryIndexHandler no manager" {
    clearManager();
    var buf: [4096]u8 = undefined;
    const result = memoryIndexHandler("{\"content\":\"hello\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("memory manager not initialized", result.error_message.?);
}

test "registerMemoryTools" {
    const allocator = std.testing.allocator;
    var reg = registry.ToolRegistry.init(allocator);
    defer reg.deinit();

    try registerMemoryTools(&reg);
    try std.testing.expectEqual(@as(usize, 2), reg.count());
    try std.testing.expect(reg.get("memory_search") != null);
    try std.testing.expect(reg.get("memory_index") != null);
}

test "BUILTIN_MEMORY_SEARCH definition" {
    try std.testing.expectEqualStrings("memory_search", BUILTIN_MEMORY_SEARCH.name);
    try std.testing.expectEqual(registry.ToolCategory.memory, BUILTIN_MEMORY_SEARCH.category);
}

test "BUILTIN_MEMORY_INDEX definition" {
    try std.testing.expectEqualStrings("memory_index", BUILTIN_MEMORY_INDEX.name);
    try std.testing.expectEqual(registry.ToolCategory.memory, BUILTIN_MEMORY_INDEX.category);
}

test "setManager and clearManager" {
    clearManager();
    try std.testing.expect(global_manager == null);
    // We can't easily test setManager without a real MemoryManager instance
    // but we verify the null state is correct
}
