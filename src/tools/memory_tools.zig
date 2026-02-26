const std = @import("std");
const registry = @import("registry.zig");

// --- Memory Tools ---
//
// Bridges the MemoryManager to the tool registry via module-level state.

const manager_mod = @import("../memory/manager.zig");
const MemoryManager = manager_mod.MemoryManager;

var global_manager: ?*MemoryManager = null;
var global_allocator: ?std.mem.Allocator = null;

/// Set the memory manager for tool handlers.
pub fn setManager(mgr: *MemoryManager) void {
    global_manager = mgr;
}

/// Clear the memory manager reference.
pub fn clearManager() void {
    global_manager = null;
}

/// Set the allocator for search result allocation.
pub fn setAllocator(alloc: std.mem.Allocator) void {
    global_allocator = alloc;
}

/// Clear the allocator reference.
pub fn clearAllocator() void {
    global_allocator = null;
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

    const mgr = global_manager orelse
        return .{ .success = false, .output = "", .error_message = "memory manager not initialized" };

    const alloc = global_allocator orelse std.heap.page_allocator;

    const results = mgr.keywordSearch(alloc, query, 5) catch
        return .{ .success = false, .output = "", .error_message = "search failed" };
    defer manager_mod.freeResults(alloc, results);

    if (results.len == 0) {
        const msg = "No matching memories found.";
        if (msg.len <= output_buf.len) {
            @memcpy(output_buf[0..msg.len], msg);
            return .{ .success = true, .output = output_buf[0..msg.len] };
        }
        return .{ .success = true, .output = msg };
    }

    var fbs = std.io.fixedBufferStream(output_buf);
    const writer = fbs.writer();
    for (results, 0..) |result, idx| {
        const num = idx + 1;
        std.fmt.format(writer, "{d}. ", .{num}) catch break;
        if (result.source_file) |sf| {
            std.fmt.format(writer, "[{s}] ", .{sf}) catch break;
        }
        std.fmt.format(writer, "(score: {d:.2})\n", .{result.score}) catch break;
        writer.writeAll(result.text) catch break;
        writer.writeAll("\n\n") catch break;
    }

    return .{ .success = true, .output = fbs.getWritten() };
}

/// Memory index tool handler.
/// Input: {"content": "text to remember", "tag": "optional tag"}
pub fn memoryIndexHandler(input_json: []const u8, output_buf: []u8) registry.ToolResult {
    const content = extractParam(input_json, "content") orelse
        return .{ .success = false, .output = "", .error_message = "missing 'content' parameter" };

    if (content.len == 0)
        return .{ .success = false, .output = "", .error_message = "empty content" };

    const mgr = global_manager orelse
        return .{ .success = false, .output = "", .error_message = "memory manager not initialized" };

    const tag = extractParam(input_json, "tag") orelse "memory";

    const doc_id = mgr.indexDocument(tag, content) catch
        return .{ .success = false, .output = "", .error_message = "indexing failed" };

    const chunk_count = mgr.chunkCount();

    var fbs = std.io.fixedBufferStream(output_buf);
    std.fmt.format(fbs.writer(), "Indexed {d} chars as document {d} (tag: {s}), {d} chunks stored", .{
        content.len, doc_id, tag, chunk_count,
    }) catch return .{ .success = false, .output = "", .error_message = "output buffer overflow" };

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
}

test "memorySearchHandler with real manager - found" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.indexDocument("notes.md", "Zig is a systems programming language designed for safety.");

    setManager(&mgr);
    setAllocator(allocator);
    defer clearManager();
    defer clearAllocator();

    var buf: [4096]u8 = undefined;
    const result = memorySearchHandler("{\"query\":\"zig\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "score:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Zig") != null);
}

test "memorySearchHandler with real manager - not found" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.indexDocument("notes.md", "Hello world content.");

    setManager(&mgr);
    setAllocator(allocator);
    defer clearManager();
    defer clearAllocator();

    var buf: [4096]u8 = undefined;
    const result = memorySearchHandler("{\"query\":\"xyznonexistent\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("No matching memories found.", result.output);
}

test "memorySearchHandler multiple results" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.indexDocument("a.md", "Zig is great for low-level work.");
    _ = try mgr.indexDocument("b.md", "Learning Zig after C is natural.");

    setManager(&mgr);
    setAllocator(allocator);
    defer clearManager();
    defer clearAllocator();

    var buf: [4096]u8 = undefined;
    const result = memorySearchHandler("{\"query\":\"zig\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "1.") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "2.") != null);
}

test "memoryIndexHandler with real manager" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    setManager(&mgr);
    defer clearManager();

    var buf: [4096]u8 = undefined;
    const result = memoryIndexHandler("{\"content\":\"Remember this important fact.\",\"tag\":\"notes\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 1), mgr.documentCount());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Indexed") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "tag: notes") != null);
}

test "memoryIndexHandler default tag" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    setManager(&mgr);
    defer clearManager();

    var buf: [4096]u8 = undefined;
    const result = memoryIndexHandler("{\"content\":\"Some content here.\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "tag: memory") != null);
}

test "memoryIndexHandler then search roundtrip" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    setManager(&mgr);
    setAllocator(allocator);
    defer clearManager();
    defer clearAllocator();

    // Index via handler
    var idx_buf: [4096]u8 = undefined;
    const idx_result = memoryIndexHandler("{\"content\":\"Zig comptime is powerful.\"}", &idx_buf);
    try std.testing.expect(idx_result.success);

    // Search via handler
    var search_buf: [4096]u8 = undefined;
    const search_result = memorySearchHandler("{\"query\":\"comptime\"}", &search_buf);
    try std.testing.expect(search_result.success);
    try std.testing.expect(std.mem.indexOf(u8, search_result.output, "comptime") != null);
}
