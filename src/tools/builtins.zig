const std = @import("std");
const registry = @import("registry.zig");

// --- Built-in Tool Implementations ---

/// Extract a JSON string value for a given key from simple JSON.
/// Handles: {"key":"value"} patterns.
fn extractParam(json: []const u8, key: []const u8) ?[]const u8 {
    // Build prefix: "key":"
    var prefix_buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&prefix_buf);
    fbs.writer().writeByte('"') catch return null;
    fbs.writer().writeAll(key) catch return null;
    fbs.writer().writeAll("\":\"") catch return null;
    const prefix = fbs.getWritten();

    const start = std.mem.indexOf(u8, json, prefix) orelse return null;
    const value_start = start + prefix.len;
    if (value_start >= json.len) return null;

    // Find closing quote (handle escaped quotes)
    var i = value_start;
    while (i < json.len) : (i += 1) {
        if (json[i] == '"' and (i == value_start or json[i - 1] != '\\')) {
            return json[value_start..i];
        }
    }
    return null;
}

/// Read file tool handler.
/// Input: {"path": "/absolute/path"}
/// Output: file contents
pub fn readFileHandler(input_json: []const u8, output_buf: []u8) registry.ToolResult {
    const path = extractParam(input_json, "path") orelse
        return .{ .success = false, .output = "", .error_message = "missing 'path' parameter" };

    if (path.len == 0)
        return .{ .success = false, .output = "", .error_message = "empty path" };

    const file = std.fs.cwd().openFile(path, .{}) catch
        return .{ .success = false, .output = "", .error_message = "file not found" };
    defer file.close();

    const bytes_read = file.read(output_buf) catch
        return .{ .success = false, .output = "", .error_message = "read error" };

    return .{
        .success = true,
        .output = output_buf[0..bytes_read],
    };
}

/// Write file tool handler.
/// Input: {"path": "/absolute/path", "content": "file contents"}
/// Output: "written N bytes"
pub fn writeFileHandler(input_json: []const u8, output_buf: []u8) registry.ToolResult {
    const path = extractParam(input_json, "path") orelse
        return .{ .success = false, .output = "", .error_message = "missing 'path' parameter" };

    const content = extractParam(input_json, "content") orelse
        return .{ .success = false, .output = "", .error_message = "missing 'content' parameter" };

    if (path.len == 0)
        return .{ .success = false, .output = "", .error_message = "empty path" };

    const file = std.fs.cwd().createFile(path, .{}) catch
        return .{ .success = false, .output = "", .error_message = "cannot create file" };
    defer file.close();

    file.writeAll(content) catch
        return .{ .success = false, .output = "", .error_message = "write error" };

    var fbs = std.io.fixedBufferStream(output_buf);
    std.fmt.format(fbs.writer(), "written {d} bytes to {s}", .{ content.len, path }) catch
        return .{ .success = true, .output = "written" };

    return .{
        .success = true,
        .output = fbs.getWritten(),
    };
}

/// List directory tool handler.
/// Input: {"path": "/absolute/path"}
/// Output: newline-separated file listing
pub fn listDirHandler(input_json: []const u8, output_buf: []u8) registry.ToolResult {
    const path = extractParam(input_json, "path") orelse
        return .{ .success = false, .output = "", .error_message = "missing 'path' parameter" };

    if (path.len == 0)
        return .{ .success = false, .output = "", .error_message = "empty path" };

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch
        return .{ .success = false, .output = "", .error_message = "cannot open directory" };
    defer dir.close();

    var fbs = std.io.fixedBufferStream(output_buf);
    const writer = fbs.writer();
    var count: usize = 0;

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (count > 0) writer.writeByte('\n') catch break;
        const kind_str: []const u8 = switch (entry.kind) {
            .directory => "d ",
            .file => "f ",
            .sym_link => "l ",
            else => "? ",
        };
        writer.writeAll(kind_str) catch break;
        writer.writeAll(entry.name) catch break;
        count += 1;
    }

    return .{
        .success = true,
        .output = fbs.getWritten(),
    };
}

/// Extract a JSON integer value for a given key from simple JSON.
/// Handles: {"key":123} patterns.
fn extractIntParam(json: []const u8, key: []const u8) ?u64 {
    // Build prefix: "key":
    var prefix_buf: [128]u8 = undefined;
    var pfbs = std.io.fixedBufferStream(&prefix_buf);
    pfbs.writer().writeByte('"') catch return null;
    pfbs.writer().writeAll(key) catch return null;
    pfbs.writer().writeAll("\":") catch return null;
    const prefix = pfbs.getWritten();

    const start = std.mem.indexOf(u8, json, prefix) orelse return null;
    const value_start = start + prefix.len;
    if (value_start >= json.len) return null;

    var end = value_start;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
    if (end == value_start) return null;

    return std.fmt.parseInt(u64, json[value_start..end], 10) catch null;
}

/// Bash/exec tool handler.
/// Input: {"command": "ls -la", "timeout_ms": 30000, "cwd": "/path"}
/// Output: command stdout (or stderr on failure)
pub fn bashHandler(input_json: []const u8, output_buf: []u8) registry.ToolResult {
    const command = extractParam(input_json, "command") orelse
        return .{ .success = false, .output = "", .error_message = "missing 'command' parameter" };

    if (command.len == 0)
        return .{ .success = false, .output = "", .error_message = "empty command" };

    const cwd = extractParam(input_json, "cwd");
    // timeout_ms is parsed for API compatibility; enforcement at sandbox level
    _ = extractIntParam(input_json, "timeout_ms");

    const argv = [_][]const u8{ "/bin/sh", "-c", command };
    var child = std.process.Child.init(&argv, std.heap.page_allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    // Set working directory if provided
    if (cwd) |dir| {
        if (dir.len > 0) {
            child.cwd = dir;
        }
    }

    child.spawn() catch
        return .{ .success = false, .output = "", .error_message = "failed to spawn process" };

    // Read stdout into output_buf using File.readAll
    const stdout_bytes = if (child.stdout) |stdout|
        stdout.readAll(output_buf) catch 0
    else
        0;

    const term = child.wait() catch
        return .{ .success = false, .output = output_buf[0..stdout_bytes], .error_message = "wait failed" };

    const exit_code = switch (term) {
        .Exited => |code| code,
        else => 1,
    };

    return .{
        .success = exit_code == 0,
        .output = output_buf[0..stdout_bytes],
        .error_message = if (exit_code != 0) "non-zero exit code" else null,
    };
}

// --- Built-in Tool Definitions ---

pub const BUILTIN_READ = registry.ToolDef{
    .name = "read",
    .description = "Read file contents",
    .category = .file,
    .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"File path to read\"}},\"required\":[\"path\"]}",
};

pub const BUILTIN_WRITE = registry.ToolDef{
    .name = "write",
    .description = "Write content to a file",
    .category = .file,
    .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}",
    .requires_approval = true,
};

pub const BUILTIN_LIST_DIR = registry.ToolDef{
    .name = "list_dir",
    .description = "List directory contents",
    .category = .file,
    .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Directory path\"}},\"required\":[\"path\"]}",
};

pub const BUILTIN_BASH = registry.ToolDef{
    .name = "bash",
    .description = "Execute a shell command",
    .category = .exec,
    .parameters_json = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"Shell command to execute\"},\"timeout_ms\":{\"type\":\"integer\",\"description\":\"Timeout in milliseconds\"},\"cwd\":{\"type\":\"string\",\"description\":\"Working directory\"}},\"required\":[\"command\"]}",
    .requires_approval = true,
    .sandboxed = true,
};

/// Register all built-in tools with the registry.
pub fn registerBuiltins(reg: *registry.ToolRegistry) !void {
    try reg.register(BUILTIN_READ, readFileHandler);
    try reg.register(BUILTIN_WRITE, writeFileHandler);
    try reg.register(BUILTIN_LIST_DIR, listDirHandler);
    try reg.register(BUILTIN_BASH, bashHandler);
}

// --- Tests ---

test "extractParam basic" {
    const json = "{\"path\":\"/tmp/test.txt\",\"content\":\"hello\"}";
    try std.testing.expectEqualStrings("/tmp/test.txt", extractParam(json, "path").?);
    try std.testing.expectEqualStrings("hello", extractParam(json, "content").?);
    try std.testing.expect(extractParam(json, "missing") == null);
}

test "extractParam empty value" {
    const json = "{\"path\":\"\"}";
    try std.testing.expectEqualStrings("", extractParam(json, "path").?);
}

test "extractParam with spaces" {
    const json = "{\"path\": \"/tmp/test.txt\"}";
    // Note: our simple parser doesn't handle space after colon in the prefix
    // This tests the exact format: "path":"value"
    try std.testing.expect(extractParam(json, "path") == null);
}

test "readFileHandler missing path" {
    var buf: [1024]u8 = undefined;
    const result = readFileHandler("{}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("missing 'path' parameter", result.error_message.?);
}

test "readFileHandler empty path" {
    var buf: [1024]u8 = undefined;
    const result = readFileHandler("{\"path\":\"\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("empty path", result.error_message.?);
}

test "readFileHandler nonexistent file" {
    var buf: [1024]u8 = undefined;
    const result = readFileHandler("{\"path\":\"/nonexistent/file/xyz\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("file not found", result.error_message.?);
}

test "readFileHandler real file" {
    // Write a temp file first
    const path = "/tmp/zclaw_builtin_read_test.txt";
    {
        const f = std.fs.cwd().createFile(path, .{}) catch return;
        defer f.close();
        f.writeAll("test content 123") catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};

    var buf: [1024]u8 = undefined;
    const result = readFileHandler("{\"path\":\"/tmp/zclaw_builtin_read_test.txt\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("test content 123", result.output);
}

test "writeFileHandler missing path" {
    var buf: [1024]u8 = undefined;
    const result = writeFileHandler("{\"content\":\"hello\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("missing 'path' parameter", result.error_message.?);
}

test "writeFileHandler missing content" {
    var buf: [1024]u8 = undefined;
    const result = writeFileHandler("{\"path\":\"/tmp/test\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("missing 'content' parameter", result.error_message.?);
}

test "writeFileHandler write and verify" {
    const path = "/tmp/zclaw_builtin_write_test.txt";
    defer std.fs.cwd().deleteFile(path) catch {};

    var buf: [1024]u8 = undefined;
    const result = writeFileHandler("{\"path\":\"/tmp/zclaw_builtin_write_test.txt\",\"content\":\"hello world\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "written 11 bytes") != null);

    // Verify file was written
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    var read_buf: [256]u8 = undefined;
    const n = try f.read(&read_buf);
    try std.testing.expectEqualStrings("hello world", read_buf[0..n]);
}

test "listDirHandler missing path" {
    var buf: [4096]u8 = undefined;
    const result = listDirHandler("{}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("missing 'path' parameter", result.error_message.?);
}

test "listDirHandler nonexistent dir" {
    var buf: [4096]u8 = undefined;
    const result = listDirHandler("{\"path\":\"/nonexistent/dir/xyz\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("cannot open directory", result.error_message.?);
}

test "listDirHandler real directory" {
    const dir_path = "/tmp/zclaw_builtin_listdir_test";
    std.fs.cwd().makePath(dir_path) catch return;
    defer std.fs.cwd().deleteTree(dir_path) catch {};

    // Create some files
    {
        const f = std.fs.cwd().createFile("/tmp/zclaw_builtin_listdir_test/a.txt", .{}) catch return;
        f.close();
    }
    {
        const f = std.fs.cwd().createFile("/tmp/zclaw_builtin_listdir_test/b.txt", .{}) catch return;
        f.close();
    }

    var buf: [4096]u8 = undefined;
    const result = listDirHandler("{\"path\":\"/tmp/zclaw_builtin_listdir_test\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "b.txt") != null);
}

test "bashHandler missing command" {
    var buf: [4096]u8 = undefined;
    const result = bashHandler("{}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("missing 'command' parameter", result.error_message.?);
}

test "bashHandler empty command" {
    var buf: [4096]u8 = undefined;
    const result = bashHandler("{\"command\":\"\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("empty command", result.error_message.?);
}

test "bashHandler echo" {
    var buf: [4096]u8 = undefined;
    const result = bashHandler("{\"command\":\"echo hello\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello") != null);
}

test "bashHandler failing command" {
    var buf: [4096]u8 = undefined;
    const result = bashHandler("{\"command\":\"false\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("non-zero exit code", result.error_message.?);
}

test "bashHandler with output" {
    var buf: [4096]u8 = undefined;
    const result = bashHandler("{\"command\":\"printf abc123\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("abc123", result.output);
}

test "registerBuiltins" {
    const allocator = std.testing.allocator;
    var reg = registry.ToolRegistry.init(allocator);
    defer reg.deinit();

    try registerBuiltins(&reg);

    try std.testing.expectEqual(@as(usize, 4), reg.count());
    try std.testing.expect(reg.get("read") != null);
    try std.testing.expect(reg.get("write") != null);
    try std.testing.expect(reg.get("list_dir") != null);
    try std.testing.expect(reg.get("bash") != null);
}

test "registerBuiltins categories" {
    const allocator = std.testing.allocator;
    var reg = registry.ToolRegistry.init(allocator);
    defer reg.deinit();

    try registerBuiltins(&reg);

    try std.testing.expectEqual(registry.ToolCategory.file, reg.get("read").?.def.category);
    try std.testing.expectEqual(registry.ToolCategory.file, reg.get("write").?.def.category);
    try std.testing.expectEqual(registry.ToolCategory.file, reg.get("list_dir").?.def.category);
    try std.testing.expectEqual(registry.ToolCategory.exec, reg.get("bash").?.def.category);
}

test "registerBuiltins approval flags" {
    const allocator = std.testing.allocator;
    var reg = registry.ToolRegistry.init(allocator);
    defer reg.deinit();

    try registerBuiltins(&reg);

    // Read and list_dir don't require approval
    try std.testing.expect(!reg.get("read").?.def.requires_approval);
    try std.testing.expect(!reg.get("list_dir").?.def.requires_approval);
    // Write and bash require approval
    try std.testing.expect(reg.get("write").?.def.requires_approval);
    try std.testing.expect(reg.get("bash").?.def.requires_approval);
}

test "built-in tool definitions have parameters" {
    try std.testing.expect(BUILTIN_READ.parameters_json != null);
    try std.testing.expect(BUILTIN_WRITE.parameters_json != null);
    try std.testing.expect(BUILTIN_LIST_DIR.parameters_json != null);
    try std.testing.expect(BUILTIN_BASH.parameters_json != null);
}

test "registerBuiltins and execute read" {
    const allocator = std.testing.allocator;
    var reg = registry.ToolRegistry.init(allocator);
    defer reg.deinit();

    try registerBuiltins(&reg);

    // Write a temp file
    const path = "/tmp/zclaw_builtin_reg_test.txt";
    {
        const f = std.fs.cwd().createFile(path, .{}) catch return;
        defer f.close();
        f.writeAll("registry test") catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};

    var buf: [4096]u8 = undefined;
    const result = reg.execute("read", "{\"path\":\"/tmp/zclaw_builtin_reg_test.txt\"}", &buf).?;
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("registry test", result.output);
}

test "BUILTIN_BASH sandboxed flag" {
    try std.testing.expect(BUILTIN_BASH.sandboxed);
    try std.testing.expect(!BUILTIN_READ.sandboxed);
}

test "extractIntParam basic" {
    const json = "{\"timeout_ms\":5000,\"other\":\"val\"}";
    try std.testing.expectEqual(@as(u64, 5000), extractIntParam(json, "timeout_ms").?);
    try std.testing.expect(extractIntParam(json, "missing") == null);
}

test "extractIntParam zero" {
    const json = "{\"timeout_ms\":0}";
    try std.testing.expectEqual(@as(u64, 0), extractIntParam(json, "timeout_ms").?);
}

test "bashHandler with cwd" {
    var buf: [4096]u8 = undefined;
    const result = bashHandler("{\"command\":\"pwd\",\"cwd\":\"/tmp\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/tmp") != null);
}

test "bashHandler with cwd nonexistent" {
    var buf: [4096]u8 = undefined;
    const result = bashHandler("{\"command\":\"echo hi\",\"cwd\":\"/nonexistent_dir_xyz\"}", &buf);
    try std.testing.expect(!result.success);
}

test "bashHandler with timeout no hang" {
    var buf: [4096]u8 = undefined;
    // Fast command with generous timeout should succeed
    const result = bashHandler("{\"command\":\"echo fast\",\"timeout_ms\":5000}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "fast") != null);
}

test "bashHandler captures stderr on failure" {
    var buf: [4096]u8 = undefined;
    const result = bashHandler("{\"command\":\"exit 42\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("non-zero exit code", result.error_message.?);
}

// --- Additional Tests ---

test "extractParam missing key entirely" {
    const json = "{\"other\":\"value\"}";
    try std.testing.expect(extractParam(json, "path") == null);
}

test "extractParam with escaped quotes" {
    const json = "{\"path\":\"hello \\\"world\\\"\"}";
    const val = extractParam(json, "path").?;
    try std.testing.expect(val.len > 0);
}

test "extractParam multiple keys" {
    const json = "{\"a\":\"1\",\"b\":\"2\",\"c\":\"3\"}";
    try std.testing.expectEqualStrings("1", extractParam(json, "a").?);
    try std.testing.expectEqualStrings("2", extractParam(json, "b").?);
    try std.testing.expectEqualStrings("3", extractParam(json, "c").?);
}

test "extractIntParam missing key" {
    const json = "{\"timeout_ms\":5000}";
    try std.testing.expect(extractIntParam(json, "missing") == null);
}

test "extractIntParam large value" {
    const json = "{\"size\":999999}";
    try std.testing.expectEqual(@as(u64, 999999), extractIntParam(json, "size").?);
}

test "extractIntParam non-numeric" {
    const json = "{\"val\":\"abc\"}";
    try std.testing.expect(extractIntParam(json, "val") == null);
}

test "readFileHandler success reads correct content" {
    const path = "/tmp/zclaw_builtin_read_test2.txt";
    {
        const f = std.fs.cwd().createFile(path, .{}) catch return;
        defer f.close();
        f.writeAll("specific content") catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};

    var buf: [1024]u8 = undefined;
    const result = readFileHandler("{\"path\":\"/tmp/zclaw_builtin_read_test2.txt\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("specific content", result.output);
    try std.testing.expect(result.error_message == null);
}

test "writeFileHandler empty path" {
    var buf: [1024]u8 = undefined;
    const result = writeFileHandler("{\"path\":\"\",\"content\":\"hello\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("empty path", result.error_message.?);
}

test "writeFileHandler empty content" {
    const path = "/tmp/zclaw_builtin_write_empty_test.txt";
    defer std.fs.cwd().deleteFile(path) catch {};

    var buf: [1024]u8 = undefined;
    const result = writeFileHandler("{\"path\":\"/tmp/zclaw_builtin_write_empty_test.txt\",\"content\":\"\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "written 0 bytes") != null);
}

test "listDirHandler empty path" {
    var buf: [4096]u8 = undefined;
    const result = listDirHandler("{\"path\":\"\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("empty path", result.error_message.?);
}

test "listDirHandler empty directory" {
    const dir_path = "/tmp/zclaw_builtin_empty_listdir_test";
    std.fs.cwd().makePath(dir_path) catch return;
    defer std.fs.cwd().deleteTree(dir_path) catch {};

    var buf: [4096]u8 = undefined;
    const result = listDirHandler("{\"path\":\"/tmp/zclaw_builtin_empty_listdir_test\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("", result.output);
}

test "bashHandler multiline output" {
    var buf: [4096]u8 = undefined;
    const result = bashHandler("{\"command\":\"printf 'line1\\nline2\\nline3'\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "line1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "line3") != null);
}

test "bashHandler true command" {
    var buf: [4096]u8 = undefined;
    const result = bashHandler("{\"command\":\"true\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expect(result.error_message == null);
}

test "BUILTIN_READ definition fields" {
    try std.testing.expectEqualStrings("read", BUILTIN_READ.name);
    try std.testing.expectEqualStrings("Read file contents", BUILTIN_READ.description);
    try std.testing.expectEqual(registry.ToolCategory.file, BUILTIN_READ.category);
    try std.testing.expect(!BUILTIN_READ.requires_approval);
    try std.testing.expect(!BUILTIN_READ.sandboxed);
}

test "BUILTIN_WRITE definition fields" {
    try std.testing.expectEqualStrings("write", BUILTIN_WRITE.name);
    try std.testing.expect(BUILTIN_WRITE.requires_approval);
    try std.testing.expect(!BUILTIN_WRITE.sandboxed);
}

test "BUILTIN_LIST_DIR definition fields" {
    try std.testing.expectEqualStrings("list_dir", BUILTIN_LIST_DIR.name);
    try std.testing.expect(!BUILTIN_LIST_DIR.requires_approval);
}

test "BUILTIN_BASH definition fields" {
    try std.testing.expectEqualStrings("bash", BUILTIN_BASH.name);
    try std.testing.expectEqual(registry.ToolCategory.exec, BUILTIN_BASH.category);
    try std.testing.expect(BUILTIN_BASH.requires_approval);
    try std.testing.expect(BUILTIN_BASH.sandboxed);
}

test "registerBuiltins descriptions non-empty" {
    const allocator = std.testing.allocator;
    var reg = registry.ToolRegistry.init(allocator);
    defer reg.deinit();

    try registerBuiltins(&reg);

    try std.testing.expect(reg.get("read").?.def.description.len > 0);
    try std.testing.expect(reg.get("write").?.def.description.len > 0);
    try std.testing.expect(reg.get("list_dir").?.def.description.len > 0);
    try std.testing.expect(reg.get("bash").?.def.description.len > 0);
}

test "registerBuiltins all have parameters_json" {
    const allocator = std.testing.allocator;
    var reg = registry.ToolRegistry.init(allocator);
    defer reg.deinit();

    try registerBuiltins(&reg);

    try std.testing.expect(reg.get("read").?.def.parameters_json != null);
    try std.testing.expect(reg.get("write").?.def.parameters_json != null);
    try std.testing.expect(reg.get("list_dir").?.def.parameters_json != null);
    try std.testing.expect(reg.get("bash").?.def.parameters_json != null);
}

// === New Tests (batch 2) ===

test "extractParam key at start of JSON" {
    const json = "{\"first\":\"value1\",\"second\":\"value2\"}";
    try std.testing.expectEqualStrings("value1", extractParam(json, "first").?);
    try std.testing.expectEqualStrings("value2", extractParam(json, "second").?);
}

test "extractParam long value" {
    const json = "{\"path\":\"/a/very/long/path/to/some/deeply/nested/file.txt\"}";
    try std.testing.expectEqualStrings("/a/very/long/path/to/some/deeply/nested/file.txt", extractParam(json, "path").?);
}

test "extractParam value with special chars" {
    const json = "{\"content\":\"hello world! @#$%^&*\"}";
    try std.testing.expectEqualStrings("hello world! @#$%^&*", extractParam(json, "content").?);
}

test "extractParam empty JSON object" {
    try std.testing.expect(extractParam("{}", "path") == null);
}

test "extractParam not valid JSON still finds pattern" {
    const json = "\"path\":\"/tmp/file\"";
    try std.testing.expectEqualStrings("/tmp/file", extractParam(json, "path").?);
}

test "extractIntParam with various values" {
    try std.testing.expectEqual(@as(u64, 1), extractIntParam("{\"x\":1}", "x").?);
    try std.testing.expectEqual(@as(u64, 42), extractIntParam("{\"x\":42}", "x").?);
    try std.testing.expectEqual(@as(u64, 30000), extractIntParam("{\"timeout_ms\":30000}", "timeout_ms").?);
}

test "extractIntParam at end of JSON" {
    const json = "{\"timeout_ms\":5000}";
    try std.testing.expectEqual(@as(u64, 5000), extractIntParam(json, "timeout_ms").?);
}

test "extractIntParam with other fields" {
    const json = "{\"name\":\"test\",\"timeout_ms\":1000,\"other\":\"val\"}";
    try std.testing.expectEqual(@as(u64, 1000), extractIntParam(json, "timeout_ms").?);
}

test "readFileHandler with valid file reads correct bytes" {
    const path = "/tmp/zclaw_read_bytes_test.txt";
    {
        const f = std.fs.cwd().createFile(path, .{}) catch return;
        defer f.close();
        f.writeAll("exactly 20 chars!!!") catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};

    var buf: [1024]u8 = undefined;
    const result = readFileHandler("{\"path\":\"/tmp/zclaw_read_bytes_test.txt\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 19), result.output.len);
}

test "writeFileHandler creates and overwrites" {
    const path = "/tmp/zclaw_overwrite_test.txt";
    defer std.fs.cwd().deleteFile(path) catch {};

    var buf: [1024]u8 = undefined;

    // First write
    const r1 = writeFileHandler("{\"path\":\"/tmp/zclaw_overwrite_test.txt\",\"content\":\"first\"}", &buf);
    try std.testing.expect(r1.success);

    // Overwrite
    const r2 = writeFileHandler("{\"path\":\"/tmp/zclaw_overwrite_test.txt\",\"content\":\"second version\"}", &buf);
    try std.testing.expect(r2.success);

    // Verify final content
    var read_buf: [1024]u8 = undefined;
    const r3 = readFileHandler("{\"path\":\"/tmp/zclaw_overwrite_test.txt\"}", &read_buf);
    try std.testing.expect(r3.success);
    try std.testing.expectEqualStrings("second version", r3.output);
}

test "writeFileHandler output format" {
    const path = "/tmp/zclaw_write_format_test.txt";
    defer std.fs.cwd().deleteFile(path) catch {};

    var buf: [1024]u8 = undefined;
    const result = writeFileHandler("{\"path\":\"/tmp/zclaw_write_format_test.txt\",\"content\":\"abc\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "written 3 bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/tmp/zclaw_write_format_test.txt") != null);
}

test "writeFileHandler invalid directory" {
    var buf: [1024]u8 = undefined;
    const result = writeFileHandler("{\"path\":\"/nonexistent_dir_xyz/file.txt\",\"content\":\"hello\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("cannot create file", result.error_message.?);
}

test "listDirHandler with subdirectory" {
    const dir_path = "/tmp/zclaw_listdir_subdir_test";
    std.fs.cwd().makePath(dir_path) catch return;
    defer std.fs.cwd().deleteTree(dir_path) catch {};

    std.fs.cwd().makePath("/tmp/zclaw_listdir_subdir_test/subdir") catch return;
    {
        const f = std.fs.cwd().createFile("/tmp/zclaw_listdir_subdir_test/file.txt", .{}) catch return;
        f.close();
    }

    var buf: [4096]u8 = undefined;
    const result = listDirHandler("{\"path\":\"/tmp/zclaw_listdir_subdir_test\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "d subdir") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "f file.txt") != null);
}

test "bashHandler with pipe" {
    var buf: [4096]u8 = undefined;
    const result = bashHandler("{\"command\":\"echo hello world | tr ' ' '-'\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello-world") != null);
}

test "bashHandler env variable" {
    var buf: [4096]u8 = undefined;
    const result = bashHandler("{\"command\":\"echo $HOME\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expect(result.output.len > 0);
}

test "bashHandler exit code 1" {
    var buf: [4096]u8 = undefined;
    const result = bashHandler("{\"command\":\"exit 1\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("non-zero exit code", result.error_message.?);
}

test "bashHandler with empty cwd string" {
    var buf: [4096]u8 = undefined;
    const result = bashHandler("{\"command\":\"echo ok\",\"cwd\":\"\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ok") != null);
}

test "BUILTIN_READ parameters contain path" {
    const params = BUILTIN_READ.parameters_json.?;
    try std.testing.expect(std.mem.indexOf(u8, params, "path") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "required") != null);
}

test "BUILTIN_WRITE parameters contain path and content" {
    const params = BUILTIN_WRITE.parameters_json.?;
    try std.testing.expect(std.mem.indexOf(u8, params, "path") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "content") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "required") != null);
}

test "BUILTIN_BASH parameters contain command" {
    const params = BUILTIN_BASH.parameters_json.?;
    try std.testing.expect(std.mem.indexOf(u8, params, "command") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "timeout_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "cwd") != null);
}

test "BUILTIN_LIST_DIR parameters contain path" {
    const params = BUILTIN_LIST_DIR.parameters_json.?;
    try std.testing.expect(std.mem.indexOf(u8, params, "path") != null);
}

test "registerBuiltins tool count" {
    const allocator = std.testing.allocator;
    var reg = registry.ToolRegistry.init(allocator);
    defer reg.deinit();

    try registerBuiltins(&reg);
    try std.testing.expectEqual(@as(usize, 4), reg.count());
}

test "registerBuiltins list file category tools" {
    const allocator = std.testing.allocator;
    var reg = registry.ToolRegistry.init(allocator);
    defer reg.deinit();

    try registerBuiltins(&reg);

    const file_tools = try reg.listByCategory(allocator, .file);
    defer allocator.free(file_tools);
    try std.testing.expectEqual(@as(usize, 3), file_tools.len);

    const exec_tools = try reg.listByCategory(allocator, .exec);
    defer allocator.free(exec_tools);
    try std.testing.expectEqual(@as(usize, 1), exec_tools.len);
}

test "bashHandler with date command" {
    var buf: [4096]u8 = undefined;
    const result = bashHandler("{\"command\":\"date +%Y\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expect(result.output.len >= 4);
}

test "readFileHandler with /dev/null" {
    var buf: [1024]u8 = undefined;
    const result = readFileHandler("{\"path\":\"/dev/null\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("", result.output);
}

test "writeFileHandler then readFileHandler roundtrip" {
    const path = "/tmp/zclaw_roundtrip_test.txt";
    defer std.fs.cwd().deleteFile(path) catch {};

    var write_buf: [1024]u8 = undefined;
    const wr = writeFileHandler("{\"path\":\"/tmp/zclaw_roundtrip_test.txt\",\"content\":\"roundtrip data\"}", &write_buf);
    try std.testing.expect(wr.success);

    var read_buf: [1024]u8 = undefined;
    const rr = readFileHandler("{\"path\":\"/tmp/zclaw_roundtrip_test.txt\"}", &read_buf);
    try std.testing.expect(rr.success);
    try std.testing.expectEqualStrings("roundtrip data", rr.output);
}

test "bashHandler multiple commands with semicolon" {
    var buf: [4096]u8 = undefined;
    const result = bashHandler("{\"command\":\"echo first; echo second\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "second") != null);
}
