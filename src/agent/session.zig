const std = @import("std");

// --- Session Key ---

/// Builds a session key in the format: agent:{agentId}:{channel}:{scope}:{identifier}
pub fn buildSessionKey(buf: []u8, agent_id: []const u8, parts: []const []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    try writer.writeAll("agent:");
    try writer.writeAll(agent_id);
    for (parts) |part| {
        try writer.writeByte(':');
        try writer.writeAll(part);
    }
    return fbs.getWritten();
}

// --- Message Role ---

pub const Role = enum {
    user,
    assistant,
    tool_result,

    pub fn label(self: Role) []const u8 {
        return switch (self) {
            .user => "user",
            .assistant => "assistant",
            .tool_result => "toolResult",
        };
    }

    pub fn fromString(s: []const u8) ?Role {
        const map = std.StaticStringMap(Role).initComptime(.{
            .{ "user", .user },
            .{ "assistant", .assistant },
            .{ "toolResult", .tool_result },
        });
        return map.get(s);
    }
};

// --- Session Entry (metadata in sessions.json) ---

pub const SessionEntry = struct {
    session_id: []const u8,
    updated_at: i64 = 0,
    session_file: ?[]const u8 = null,
    model: ?[]const u8 = null,
    model_provider: ?[]const u8 = null,
    channel: ?[]const u8 = null,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    total_tokens: u64 = 0,
    compaction_count: u32 = 0,
};

// --- JSONL Session Line Types ---

pub const SessionLineType = enum {
    session,
    message,
    compaction,
    usage,

    pub fn label(self: SessionLineType) []const u8 {
        return switch (self) {
            .session => "session",
            .message => "message",
            .compaction => "compaction",
            .usage => "usage",
        };
    }
};

// --- JSONL Writer ---

pub const JsonlWriter = struct {
    file: std.fs.File,

    pub fn init(path: []const u8) !JsonlWriter {
        // Create parent directory
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }

        const file = try std.fs.cwd().createFile(path, .{
            .truncate = false,
            .mode = 0o600,
        });
        // Seek to end for appending
        file.seekFromEnd(0) catch {};

        return .{ .file = file };
    }

    pub fn close(self: *JsonlWriter) void {
        self.file.close();
    }

    /// Writes a session header line
    pub fn writeHeader(self: *JsonlWriter, session_id: []const u8) !void {
        var buf: [1024]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{{\"type\":\"session\",\"version\":3,\"id\":\"{s}\"}}\n", .{session_id}) catch return;
        try self.file.writeAll(line);
    }

    /// Writes a message line
    pub fn writeMessage(self: *JsonlWriter, role: Role, content: []const u8) !void {
        var buf: [8192]u8 = undefined;
        const timestamp = std.time.milliTimestamp();
        const line = std.fmt.bufPrint(&buf, "{{\"type\":\"message\",\"message\":{{\"role\":\"{s}\",\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}],\"timestamp\":{d}}}}}\n", .{
            role.label(), content, timestamp,
        }) catch return;
        try self.file.writeAll(line);
    }

    /// Writes a usage line
    pub fn writeUsage(self: *JsonlWriter, usage: SessionUsage) !void {
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{{\"type\":\"usage\",\"input_tokens\":{d},\"output_tokens\":{d}}}\n", .{
            usage.input_tokens, usage.output_tokens,
        }) catch return;
        try self.file.writeAll(line);
    }

    /// Writes a compaction marker
    pub fn writeCompaction(self: *JsonlWriter, summary: []const u8) !void {
        var buf: [8192]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{{\"type\":\"compaction\",\"summary\":\"{s}\"}}\n", .{summary}) catch return;
        try self.file.writeAll(line);
    }
};

// --- JSONL Reader ---

pub const JsonlLine = struct {
    line_type: SessionLineType,
    raw: []const u8,
};

pub const JsonlReader = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayListUnmanaged(JsonlLine),

    pub fn init(allocator: std.mem.Allocator) JsonlReader {
        return .{
            .allocator = allocator,
            .lines = .{},
        };
    }

    pub fn deinit(self: *JsonlReader) void {
        // Free copied line data
        for (self.lines.items) |line| {
            self.allocator.free(line.raw);
        }
        self.lines.deinit(self.allocator);
    }

    pub fn readFromPath(self: *JsonlReader, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 100 * 1024 * 1024);
        defer self.allocator.free(content);

        var iter = std.mem.splitSequence(u8, content, "\n");
        while (iter.next()) |line| {
            if (line.len == 0) continue;

            const line_type = detectLineType(line);
            if (line_type) |lt| {
                const raw_copy = try self.allocator.dupe(u8, line);
                try self.lines.append(self.allocator, .{
                    .line_type = lt,
                    .raw = raw_copy,
                });
            }
        }
    }

    pub fn messageCount(self: *const JsonlReader) usize {
        var count: usize = 0;
        for (self.lines.items) |line| {
            if (line.line_type == .message) count += 1;
        }
        return count;
    }

    /// Compute total token usage from usage lines.
    pub fn totalTokens(self: *const JsonlReader) SessionUsage {
        var usage = SessionUsage{};
        for (self.lines.items) |line| {
            // Parse usage lines: {"type":"usage","input_tokens":N,"output_tokens":M}
            if (std.mem.indexOf(u8, line.raw, "\"type\":\"usage\"") != null) {
                if (extractJsonNumber(line.raw, "\"input_tokens\":")) |it| {
                    usage.input_tokens += @intCast(@as(u64, @bitCast(it)));
                }
                if (extractJsonNumber(line.raw, "\"output_tokens\":")) |ot| {
                    usage.output_tokens += @intCast(@as(u64, @bitCast(ot)));
                }
            }
        }
        return usage;
    }

    pub fn hasHeader(self: *const JsonlReader) bool {
        if (self.lines.items.len == 0) return false;
        return self.lines.items[0].line_type == .session;
    }
};

// --- Session Usage ---

pub const SessionUsage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,

    pub fn totalTokens(self: SessionUsage) u64 {
        return self.input_tokens + self.output_tokens;
    }

    pub fn add(self: *SessionUsage, other: SessionUsage) void {
        self.input_tokens += other.input_tokens;
        self.output_tokens += other.output_tokens;
    }
};

fn detectLineType(line: []const u8) ?SessionLineType {
    // Quick heuristic: check for type field
    if (std.mem.indexOf(u8, line, "\"type\":\"session\"") != null) return .session;
    if (std.mem.indexOf(u8, line, "\"type\":\"message\"") != null) return .message;
    if (std.mem.indexOf(u8, line, "\"type\":\"compaction\"") != null) return .compaction;
    if (std.mem.indexOf(u8, line, "\"type\":\"usage\"") != null) return .usage;
    return null;
}

fn extractJsonNumber(json: []const u8, prefix: []const u8) ?i64 {
    const start_idx = std.mem.indexOf(u8, json, prefix) orelse return null;
    const value_start = start_idx + prefix.len;
    if (value_start >= json.len) return null;

    var end = value_start;
    while (end < json.len and (json[end] >= '0' and json[end] <= '9')) : (end += 1) {}
    if (end == value_start) return null;

    return std.fmt.parseInt(i64, json[value_start..end], 10) catch null;
}

// --- Tests ---

test "buildSessionKey basic" {
    var buf: [256]u8 = undefined;
    const key = try buildSessionKey(&buf, "main", &.{"main"});
    try std.testing.expectEqualStrings("agent:main:main", key);
}

test "buildSessionKey with channel and scope" {
    var buf: [256]u8 = undefined;
    const key = try buildSessionKey(&buf, "main", &.{ "telegram", "direct", "user123" });
    try std.testing.expectEqualStrings("agent:main:telegram:direct:user123", key);
}

test "buildSessionKey with empty parts" {
    var buf: [256]u8 = undefined;
    const key = try buildSessionKey(&buf, "assistant", &.{});
    try std.testing.expectEqualStrings("agent:assistant", key);
}

test "Role.label" {
    try std.testing.expectEqualStrings("user", Role.user.label());
    try std.testing.expectEqualStrings("assistant", Role.assistant.label());
    try std.testing.expectEqualStrings("toolResult", Role.tool_result.label());
}

test "Role.fromString" {
    try std.testing.expectEqual(Role.user, Role.fromString("user").?);
    try std.testing.expectEqual(Role.assistant, Role.fromString("assistant").?);
    try std.testing.expectEqual(Role.tool_result, Role.fromString("toolResult").?);
    try std.testing.expectEqual(@as(?Role, null), Role.fromString("unknown"));
}

test "SessionLineType.label" {
    try std.testing.expectEqualStrings("session", SessionLineType.session.label());
    try std.testing.expectEqualStrings("message", SessionLineType.message.label());
    try std.testing.expectEqualStrings("compaction", SessionLineType.compaction.label());
}

test "detectLineType" {
    try std.testing.expectEqual(SessionLineType.session, detectLineType("{\"type\":\"session\",\"version\":3}").?);
    try std.testing.expectEqual(SessionLineType.message, detectLineType("{\"type\":\"message\",\"message\":{}}").?);
    try std.testing.expectEqual(SessionLineType.compaction, detectLineType("{\"type\":\"compaction\",\"summary\":\"...\"}").?);
    try std.testing.expectEqual(@as(?SessionLineType, null), detectLineType("random text"));
}

test "JSONL writer and reader round-trip" {
    const allocator = std.testing.allocator;
    const tmp_path = "/tmp/zclaw_session_test.jsonl";

    // Write session
    {
        var writer = try JsonlWriter.init(tmp_path);
        defer writer.close();
        try writer.writeHeader("test-session");
        try writer.writeMessage(.user, "hello");
        try writer.writeMessage(.assistant, "world");
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    // Read it back
    var reader = JsonlReader.init(allocator);
    defer reader.deinit();
    try reader.readFromPath(tmp_path);

    try std.testing.expect(reader.hasHeader());
    try std.testing.expectEqual(@as(usize, 2), reader.messageCount());
    try std.testing.expectEqual(@as(usize, 3), reader.lines.items.len);
    try std.testing.expectEqual(SessionLineType.session, reader.lines.items[0].line_type);
    try std.testing.expectEqual(SessionLineType.message, reader.lines.items[1].line_type);
    try std.testing.expectEqual(SessionLineType.message, reader.lines.items[2].line_type);
}

test "JsonlReader with empty file" {
    const allocator = std.testing.allocator;
    const tmp_path = "/tmp/zclaw_session_empty.jsonl";

    {
        const f = try std.fs.cwd().createFile(tmp_path, .{});
        f.close();
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var reader = JsonlReader.init(allocator);
    defer reader.deinit();
    try reader.readFromPath(tmp_path);

    try std.testing.expect(!reader.hasHeader());
    try std.testing.expectEqual(@as(usize, 0), reader.messageCount());
}

test "SessionUsage tracking" {
    var usage = SessionUsage{};
    try std.testing.expectEqual(@as(u64, 0), usage.totalTokens());

    usage.add(.{ .input_tokens = 100, .output_tokens = 50 });
    try std.testing.expectEqual(@as(u64, 150), usage.totalTokens());
    try std.testing.expectEqual(@as(u64, 100), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 50), usage.output_tokens);
}

test "SessionUsage add multiple" {
    var usage = SessionUsage{};
    usage.add(.{ .input_tokens = 10, .output_tokens = 5 });
    usage.add(.{ .input_tokens = 20, .output_tokens = 15 });
    try std.testing.expectEqual(@as(u64, 30), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 20), usage.output_tokens);
    try std.testing.expectEqual(@as(u64, 50), usage.totalTokens());
}

test "JsonlWriter writes usage" {
    const allocator = std.testing.allocator;
    const tmp_path = "/tmp/zclaw_session_usage.jsonl";

    {
        var writer = try JsonlWriter.init(tmp_path);
        defer writer.close();
        try writer.writeHeader("usage-test");
        try writer.writeUsage(.{ .input_tokens = 100, .output_tokens = 50 });
        try writer.writeUsage(.{ .input_tokens = 200, .output_tokens = 100 });
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    // Verify file content
    const file = try std.fs.cwd().openFile(tmp_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "\"input_tokens\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"output_tokens\":50") != null);
}

test "JsonlReader totalTokens" {
    const allocator = std.testing.allocator;
    const tmp_path = "/tmp/zclaw_session_tokens.jsonl";

    {
        var writer = try JsonlWriter.init(tmp_path);
        defer writer.close();
        try writer.writeHeader("token-test");
        try writer.writeUsage(.{ .input_tokens = 100, .output_tokens = 50 });
        try writer.writeMessage(.user, "hello");
        try writer.writeUsage(.{ .input_tokens = 200, .output_tokens = 75 });
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var reader = JsonlReader.init(allocator);
    defer reader.deinit();
    try reader.readFromPath(tmp_path);

    const usage = reader.totalTokens();
    try std.testing.expectEqual(@as(u64, 300), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 125), usage.output_tokens);
    try std.testing.expectEqual(@as(u64, 425), usage.totalTokens());
}

test "JsonlWriter writes compaction marker" {
    const allocator = std.testing.allocator;
    const tmp_path = "/tmp/zclaw_session_compact.jsonl";

    {
        var writer = try JsonlWriter.init(tmp_path);
        defer writer.close();
        try writer.writeHeader("compact-test");
        try writer.writeMessage(.user, "msg1");
        try writer.writeCompaction("summary of previous messages");
        try writer.writeMessage(.user, "msg2");
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var reader = JsonlReader.init(allocator);
    defer reader.deinit();
    try reader.readFromPath(tmp_path);

    try std.testing.expectEqual(@as(usize, 4), reader.lines.items.len);
    try std.testing.expectEqual(SessionLineType.compaction, reader.lines.items[2].line_type);
}
