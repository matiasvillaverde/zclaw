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

// --- Additional Tests ---

test "buildSessionKey discord channel" {
    var buf: [256]u8 = undefined;
    const key = try buildSessionKey(&buf, "bot", &.{ "discord", "guild", "123456" });
    try std.testing.expectEqualStrings("agent:bot:discord:guild:123456", key);
}

test "buildSessionKey slack channel" {
    var buf: [256]u8 = undefined;
    const key = try buildSessionKey(&buf, "main", &.{ "slack", "channel", "C01ABC" });
    try std.testing.expectEqualStrings("agent:main:slack:channel:C01ABC", key);
}

test "buildSessionKey webchat" {
    var buf: [256]u8 = undefined;
    const key = try buildSessionKey(&buf, "main", &.{ "webchat", "session", "ws-abc" });
    try std.testing.expectEqualStrings("agent:main:webchat:session:ws-abc", key);
}

test "buildSessionKey buffer too small" {
    var buf: [5]u8 = undefined;
    const result = buildSessionKey(&buf, "main", &.{ "telegram", "user123" });
    try std.testing.expectError(error.NoSpaceLeft, result);
}

test "buildSessionKey single part" {
    var buf: [256]u8 = undefined;
    const key = try buildSessionKey(&buf, "x", &.{"y"});
    try std.testing.expectEqualStrings("agent:x:y", key);
}

test "buildSessionKey many parts" {
    var buf: [256]u8 = undefined;
    const key = try buildSessionKey(&buf, "a", &.{ "b", "c", "d", "e" });
    try std.testing.expectEqualStrings("agent:a:b:c:d:e", key);
}

test "Role.fromString returns null for empty" {
    try std.testing.expectEqual(@as(?Role, null), Role.fromString(""));
}

test "Role.fromString returns null for partial match" {
    try std.testing.expectEqual(@as(?Role, null), Role.fromString("use"));
    try std.testing.expectEqual(@as(?Role, null), Role.fromString("User"));
}

test "SessionLineType.label usage" {
    try std.testing.expectEqualStrings("usage", SessionLineType.usage.label());
}

test "detectLineType usage" {
    const line = "{\"type\":\"usage\",\"input_tokens\":100,\"output_tokens\":50}";
    try std.testing.expectEqual(SessionLineType.usage, detectLineType(line).?);
}

test "detectLineType with extra whitespace" {
    try std.testing.expectEqual(@as(?SessionLineType, null), detectLineType(""));
    try std.testing.expectEqual(@as(?SessionLineType, null), detectLineType("{}"));
}

test "detectLineType not confused by content containing type string" {
    // The word "message" appears but not as a type field
    const line = "{\"type\":\"session\",\"data\":\"message in content\"}";
    try std.testing.expectEqual(SessionLineType.session, detectLineType(line).?);
}

test "extractJsonNumber valid" {
    const json = "{\"input_tokens\":42,\"output_tokens\":10}";
    try std.testing.expectEqual(@as(?i64, 42), extractJsonNumber(json, "\"input_tokens\":"));
    try std.testing.expectEqual(@as(?i64, 10), extractJsonNumber(json, "\"output_tokens\":"));
}

test "extractJsonNumber missing key" {
    const json = "{\"other\":99}";
    try std.testing.expectEqual(@as(?i64, null), extractJsonNumber(json, "\"input_tokens\":"));
}

test "extractJsonNumber zero value" {
    const json = "{\"input_tokens\":0}";
    try std.testing.expectEqual(@as(?i64, 0), extractJsonNumber(json, "\"input_tokens\":"));
}

test "extractJsonNumber large value" {
    const json = "{\"input_tokens\":999999}";
    try std.testing.expectEqual(@as(?i64, 999999), extractJsonNumber(json, "\"input_tokens\":"));
}

test "SessionUsage defaults to zero" {
    const usage = SessionUsage{};
    try std.testing.expectEqual(@as(u64, 0), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 0), usage.output_tokens);
    try std.testing.expectEqual(@as(u64, 0), usage.totalTokens());
}

test "SessionUsage add with zero" {
    var usage = SessionUsage{ .input_tokens = 50, .output_tokens = 25 };
    usage.add(.{});
    try std.testing.expectEqual(@as(u64, 50), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 25), usage.output_tokens);
}

test "SessionEntry defaults" {
    const entry = SessionEntry{ .session_id = "test" };
    try std.testing.expectEqual(@as(i64, 0), entry.updated_at);
    try std.testing.expectEqual(@as(?[]const u8, null), entry.session_file);
    try std.testing.expectEqual(@as(?[]const u8, null), entry.model);
    try std.testing.expectEqual(@as(u64, 0), entry.input_tokens);
    try std.testing.expectEqual(@as(u64, 0), entry.output_tokens);
    try std.testing.expectEqual(@as(u64, 0), entry.total_tokens);
    try std.testing.expectEqual(@as(u32, 0), entry.compaction_count);
}

test "JsonlReader init empty" {
    const allocator = std.testing.allocator;
    var reader = JsonlReader.init(allocator);
    defer reader.deinit();

    try std.testing.expect(!reader.hasHeader());
    try std.testing.expectEqual(@as(usize, 0), reader.messageCount());
    try std.testing.expectEqual(@as(usize, 0), reader.lines.items.len);
}

test "JsonlReader totalTokens with no usage lines" {
    const allocator = std.testing.allocator;
    const tmp_path = "/tmp/zclaw_session_nousage.jsonl";

    {
        var writer = try JsonlWriter.init(tmp_path);
        defer writer.close();
        try writer.writeHeader("no-usage");
        try writer.writeMessage(.user, "hi");
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var reader = JsonlReader.init(allocator);
    defer reader.deinit();
    try reader.readFromPath(tmp_path);

    const usage = reader.totalTokens();
    try std.testing.expectEqual(@as(u64, 0), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 0), usage.output_tokens);
}

// ===== New tests added for comprehensive coverage =====

test "buildSessionKey long agent id" {
    var buf: [256]u8 = undefined;
    const long_id = "a" ** 50;
    const key = try buildSessionKey(&buf, long_id, &.{"ch"});
    try std.testing.expect(std.mem.startsWith(u8, key, "agent:"));
    try std.testing.expect(std.mem.endsWith(u8, key, ":ch"));
}

test "buildSessionKey special characters in parts" {
    var buf: [256]u8 = undefined;
    const key = try buildSessionKey(&buf, "bot-1", &.{ "web", "user@domain.com" });
    try std.testing.expectEqualStrings("agent:bot-1:web:user@domain.com", key);
}

test "buildSessionKey exact buffer fit" {
    // "agent:a:b" = 9 chars
    var buf: [9]u8 = undefined;
    const key = try buildSessionKey(&buf, "a", &.{"b"});
    try std.testing.expectEqualStrings("agent:a:b", key);
}

test "buildSessionKey exact buffer overflow by one" {
    // "agent:ab:b" = 10 chars, buf is 9
    var buf: [9]u8 = undefined;
    const result = buildSessionKey(&buf, "ab", &.{"b"});
    try std.testing.expectError(error.NoSpaceLeft, result);
}

test "Role roundtrip all variants" {
    const roles = [_]Role{ .user, .assistant, .tool_result };
    for (roles) |r| {
        const label_str = r.label();
        const parsed = Role.fromString(label_str).?;
        try std.testing.expectEqual(r, parsed);
    }
}

test "Role.fromString case sensitive" {
    try std.testing.expectEqual(@as(?Role, null), Role.fromString("USER"));
    try std.testing.expectEqual(@as(?Role, null), Role.fromString("Assistant"));
    try std.testing.expectEqual(@as(?Role, null), Role.fromString("TOOLRESULT"));
}

test "SessionLineType all labels roundtrip" {
    const types = [_]SessionLineType{ .session, .message, .compaction, .usage };
    for (types) |t| {
        try std.testing.expect(t.label().len > 0);
    }
}

test "detectLineType with embedded type strings" {
    // Ensure first match wins when multiple type strings appear
    const line = "{\"type\":\"message\",\"data\":\"compaction info\"}";
    try std.testing.expectEqual(SessionLineType.message, detectLineType(line).?);
}

test "detectLineType partial type string no match" {
    try std.testing.expectEqual(@as(?SessionLineType, null), detectLineType("{\"type\":\"sess\"}"));
    try std.testing.expectEqual(@as(?SessionLineType, null), detectLineType("{\"type\":\"msg\"}"));
}

test "extractJsonNumber at end of json" {
    const json = "{\"input_tokens\":12345}";
    try std.testing.expectEqual(@as(?i64, 12345), extractJsonNumber(json, "\"input_tokens\":"));
}

test "extractJsonNumber with non-numeric after number" {
    const json = "{\"input_tokens\":42,\"other\":1}";
    try std.testing.expectEqual(@as(?i64, 42), extractJsonNumber(json, "\"input_tokens\":"));
}

test "extractJsonNumber with empty value" {
    const json = "{\"input_tokens\":}";
    try std.testing.expectEqual(@as(?i64, null), extractJsonNumber(json, "\"input_tokens\":"));
}

test "extractJsonNumber prefix at end of string" {
    const json = "{\"input_tokens\":";
    try std.testing.expectEqual(@as(?i64, null), extractJsonNumber(json, "\"input_tokens\":"));
}

test "SessionUsage add is cumulative" {
    var usage = SessionUsage{};
    usage.add(.{ .input_tokens = 1, .output_tokens = 1 });
    usage.add(.{ .input_tokens = 1, .output_tokens = 1 });
    usage.add(.{ .input_tokens = 1, .output_tokens = 1 });
    try std.testing.expectEqual(@as(u64, 3), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 3), usage.output_tokens);
    try std.testing.expectEqual(@as(u64, 6), usage.totalTokens());
}

test "SessionUsage large values" {
    var usage = SessionUsage{ .input_tokens = 1_000_000, .output_tokens = 500_000 };
    try std.testing.expectEqual(@as(u64, 1_500_000), usage.totalTokens());
    usage.add(.{ .input_tokens = 1_000_000, .output_tokens = 500_000 });
    try std.testing.expectEqual(@as(u64, 3_000_000), usage.totalTokens());
}

test "SessionEntry with all fields set" {
    const entry = SessionEntry{
        .session_id = "sess-123",
        .updated_at = 1700000000,
        .session_file = "sessions/sess-123.jsonl",
        .model = "claude-3-opus",
        .model_provider = "anthropic",
        .channel = "telegram",
        .input_tokens = 5000,
        .output_tokens = 2000,
        .total_tokens = 7000,
        .compaction_count = 3,
    };
    try std.testing.expectEqualStrings("sess-123", entry.session_id);
    try std.testing.expectEqual(@as(i64, 1700000000), entry.updated_at);
    try std.testing.expectEqualStrings("sessions/sess-123.jsonl", entry.session_file.?);
    try std.testing.expectEqualStrings("claude-3-opus", entry.model.?);
    try std.testing.expectEqualStrings("anthropic", entry.model_provider.?);
    try std.testing.expectEqualStrings("telegram", entry.channel.?);
    try std.testing.expectEqual(@as(u64, 5000), entry.input_tokens);
    try std.testing.expectEqual(@as(u64, 2000), entry.output_tokens);
    try std.testing.expectEqual(@as(u64, 7000), entry.total_tokens);
    try std.testing.expectEqual(@as(u32, 3), entry.compaction_count);
}

test "JsonlReader deinit on empty reader" {
    const allocator = std.testing.allocator;
    var reader = JsonlReader.init(allocator);
    reader.deinit(); // should not crash
}

test "JsonlReader totalTokens returns zero for empty reader" {
    const allocator = std.testing.allocator;
    var reader = JsonlReader.init(allocator);
    defer reader.deinit();
    const usage = reader.totalTokens();
    try std.testing.expectEqual(@as(u64, 0), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 0), usage.output_tokens);
}

test "JsonlWriter and reader with tool_result role" {
    const allocator = std.testing.allocator;
    const tmp_path = "/tmp/zclaw_session_toolresult.jsonl";

    {
        var writer = try JsonlWriter.init(tmp_path);
        defer writer.close();
        try writer.writeHeader("tool-sess");
        try writer.writeMessage(.tool_result, "result data");
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var reader = JsonlReader.init(allocator);
    defer reader.deinit();
    try reader.readFromPath(tmp_path);

    try std.testing.expectEqual(@as(usize, 2), reader.lines.items.len);
    try std.testing.expectEqual(SessionLineType.message, reader.lines.items[1].line_type);
}

test "JsonlWriter multiple compactions and messages" {
    const allocator = std.testing.allocator;
    const tmp_path = "/tmp/zclaw_session_multi.jsonl";

    {
        var writer = try JsonlWriter.init(tmp_path);
        defer writer.close();
        try writer.writeHeader("multi-test");
        try writer.writeMessage(.user, "m1");
        try writer.writeMessage(.assistant, "m2");
        try writer.writeCompaction("first compaction");
        try writer.writeMessage(.user, "m3");
        try writer.writeUsage(.{ .input_tokens = 50, .output_tokens = 25 });
        try writer.writeCompaction("second compaction");
        try writer.writeMessage(.user, "m4");
        try writer.writeUsage(.{ .input_tokens = 30, .output_tokens = 10 });
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var reader = JsonlReader.init(allocator);
    defer reader.deinit();
    try reader.readFromPath(tmp_path);

    try std.testing.expect(reader.hasHeader());
    try std.testing.expectEqual(@as(usize, 4), reader.messageCount());
    try std.testing.expectEqual(@as(usize, 9), reader.lines.items.len);

    const usage = reader.totalTokens();
    try std.testing.expectEqual(@as(u64, 80), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 35), usage.output_tokens);
    try std.testing.expectEqual(@as(u64, 115), usage.totalTokens());
}

test "JsonlReader readFromPath nonexistent file" {
    const allocator = std.testing.allocator;
    var reader = JsonlReader.init(allocator);
    defer reader.deinit();
    const result = reader.readFromPath("/tmp/zclaw_nonexistent_file_12345.jsonl");
    try std.testing.expectError(error.FileNotFound, result);
}

test "JsonlReader hasHeader false when first line is message" {
    const allocator = std.testing.allocator;
    const tmp_path = "/tmp/zclaw_session_noheader.jsonl";

    {
        const f = try std.fs.cwd().createFile(tmp_path, .{});
        defer f.close();
        try f.writeAll("{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}\n");
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var reader = JsonlReader.init(allocator);
    defer reader.deinit();
    try reader.readFromPath(tmp_path);

    try std.testing.expect(!reader.hasHeader());
    try std.testing.expectEqual(@as(usize, 1), reader.messageCount());
}
