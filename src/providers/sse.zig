const std = @import("std");

// --- SSE Parser ---

/// Parses Server-Sent Events (SSE) from a stream of bytes.
/// SSE format: lines of `field: value\n` separated by blank lines.
/// Common fields: `data`, `event`, `id`, `retry`.
pub const SseParser = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayListUnmanaged(u8),
    event_type: ?[]const u8,
    data_lines: std.ArrayListUnmanaged([]const u8),

    pub fn init(allocator: std.mem.Allocator) SseParser {
        return .{
            .allocator = allocator,
            .buffer = .{},
            .event_type = null,
            .data_lines = .{},
        };
    }

    pub fn deinit(self: *SseParser) void {
        self.buffer.deinit(self.allocator);
        for (self.data_lines.items) |line| {
            self.allocator.free(line);
        }
        self.data_lines.deinit(self.allocator);
        if (self.event_type) |et| {
            self.allocator.free(et);
        }
    }

    pub fn reset(self: *SseParser) void {
        for (self.data_lines.items) |line| {
            self.allocator.free(line);
        }
        self.data_lines.clearRetainingCapacity();
        if (self.event_type) |et| {
            self.allocator.free(et);
            self.event_type = null;
        }
    }

    /// Feed bytes into the parser. Returns parsed events.
    pub fn feed(self: *SseParser, data: []const u8) ![]SseEvent {
        try self.buffer.appendSlice(self.allocator, data);

        var events = std.ArrayListUnmanaged(SseEvent){};

        // Process complete lines
        while (true) {
            const buf = self.buffer.items;
            const newline_pos = std.mem.indexOf(u8, buf, "\n") orelse break;

            const line = if (newline_pos > 0 and buf[newline_pos - 1] == '\r')
                buf[0 .. newline_pos - 1]
            else
                buf[0..newline_pos];

            if (line.len == 0) {
                // Empty line = event boundary
                if (self.data_lines.items.len > 0) {
                    const event = try self.buildEvent();
                    try events.append(self.allocator, event);
                }
                self.reset();
            } else {
                try self.parseLine(line);
            }

            // Remove processed bytes
            const consumed = newline_pos + 1;
            if (consumed < self.buffer.items.len) {
                std.mem.copyForwards(u8, self.buffer.items[0..], self.buffer.items[consumed..]);
            }
            self.buffer.shrinkRetainingCapacity(self.buffer.items.len - consumed);
        }

        if (events.items.len == 0) {
            events.deinit(self.allocator);
            return &.{};
        }

        return events.toOwnedSlice(self.allocator);
    }

    fn parseLine(self: *SseParser, line: []const u8) !void {
        // Comment line (starts with :)
        if (line[0] == ':') return;

        // Find colon separator
        if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
            const field = line[0..colon_pos];
            var value = line[colon_pos + 1 ..];
            // Skip leading space after colon
            if (value.len > 0 and value[0] == ' ') {
                value = value[1..];
            }

            if (std.mem.eql(u8, field, "data")) {
                const value_copy = try self.allocator.dupe(u8, value);
                try self.data_lines.append(self.allocator, value_copy);
            } else if (std.mem.eql(u8, field, "event")) {
                if (self.event_type) |et| {
                    self.allocator.free(et);
                }
                self.event_type = try self.allocator.dupe(u8, value);
            }
            // Ignore other fields (id, retry) for now
        }
    }

    fn buildEvent(self: *SseParser) !SseEvent {
        // Join data lines with \n
        var total_len: usize = 0;
        for (self.data_lines.items, 0..) |line, i| {
            total_len += line.len;
            if (i < self.data_lines.items.len - 1) total_len += 1; // newline between lines
        }

        const data = try self.allocator.alloc(u8, total_len);
        var offset: usize = 0;
        for (self.data_lines.items, 0..) |line, i| {
            @memcpy(data[offset .. offset + line.len], line);
            offset += line.len;
            if (i < self.data_lines.items.len - 1) {
                data[offset] = '\n';
                offset += 1;
            }
        }

        const event_type = if (self.event_type) |et|
            try self.allocator.dupe(u8, et)
        else
            null;

        return .{
            .event_type = event_type,
            .data = data,
        };
    }
};

pub const SseEvent = struct {
    event_type: ?[]const u8,
    data: []const u8,

    pub fn isDone(self: *const SseEvent) bool {
        return std.mem.eql(u8, self.data, "[DONE]");
    }
};

/// Free a slice of SseEvents returned by SseParser.feed()
pub fn freeEvents(allocator: std.mem.Allocator, events: []SseEvent) void {
    for (events) |event| {
        allocator.free(event.data);
        if (event.event_type) |et| allocator.free(et);
    }
    allocator.free(events);
}

// --- Tests ---

test "SseParser basic data event" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("data: hello world\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("hello world", events[0].data);
    try std.testing.expect(events[0].event_type == null);
}

test "SseParser named event" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("event: content_block_delta\ndata: {\"text\":\"hi\"}\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("content_block_delta", events[0].event_type.?);
    try std.testing.expectEqualStrings("{\"text\":\"hi\"}", events[0].data);
}

test "SseParser multiple events" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("data: first\n\ndata: second\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("first", events[0].data);
    try std.testing.expectEqualStrings("second", events[1].data);
}

test "SseParser multi-line data" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("data: line1\ndata: line2\ndata: line3\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("line1\nline2\nline3", events[0].data);
}

test "SseParser [DONE] sentinel" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("data: [DONE]\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expect(events[0].isDone());
}

test "SseParser comment lines ignored" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed(":this is a comment\ndata: actual data\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("actual data", events[0].data);
}

test "SseParser incremental feeding" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    // Feed partial data
    const events1 = try parser.feed("data: hel");
    try std.testing.expectEqual(@as(usize, 0), events1.len);

    const events2 = try parser.feed("lo\n");
    try std.testing.expectEqual(@as(usize, 0), events2.len);

    const events3 = try parser.feed("\n");
    defer freeEvents(allocator, events3);
    try std.testing.expectEqual(@as(usize, 1), events3.len);
    try std.testing.expectEqualStrings("hello", events3[0].data);
}

test "SseParser CRLF line endings" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("data: hello\r\n\r\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("hello", events[0].data);
}

test "SseParser empty data" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("data: \n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("", events[0].data);
}

test "SseParser Anthropic stream simulation" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const stream =
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"Hello\"}}\n\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";

    const events = try parser.feed(stream);
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 4), events.len);
    try std.testing.expectEqualStrings("content_block_start", events[0].event_type.?);
    try std.testing.expectEqualStrings("content_block_delta", events[1].event_type.?);
    try std.testing.expectEqualStrings("content_block_stop", events[2].event_type.?);
    try std.testing.expectEqualStrings("message_stop", events[3].event_type.?);
}

test "SseParser OpenAI stream simulation" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const stream =
        "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\n\n" ++
        "data: [DONE]\n\n";

    const events = try parser.feed(stream);
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 4), events.len);
    try std.testing.expect(!events[0].isDone());
    try std.testing.expect(!events[1].isDone());
    try std.testing.expect(!events[2].isDone());
    try std.testing.expect(events[3].isDone());
}

// =====================================================
// Additional comprehensive tests
// =====================================================

// --- Comment line tests ---

test "SseParser comment-only input produces no events" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed(":this is a comment\n:another comment\n\n");
    try std.testing.expectEqual(@as(usize, 0), events.len);
}

test "SseParser multiple comments before data" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed(":comment1\n:comment2\n:comment3\ndata: actual\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("actual", events[0].data);
}

test "SseParser comment between data lines" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("data: part1\n:ignore me\ndata: part2\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("part1\npart2", events[0].data);
}

test "SseParser empty comment line" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed(":\ndata: hello\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("hello", events[0].data);
}

// --- Empty and edge case data tests ---

test "SseParser data with no space after colon" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("data:nospace\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("nospace", events[0].data);
}

test "SseParser data with multiple spaces after colon" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    // Only the first space after colon is stripped per SSE spec
    const events = try parser.feed("data:  two spaces\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings(" two spaces", events[0].data);
}

test "SseParser empty data produces event with empty string" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("data:\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("", events[0].data);
}

test "SseParser consecutive empty lines do not produce events without data" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("\n\n\n\n");
    try std.testing.expectEqual(@as(usize, 0), events.len);
}

// --- Event type tests ---

test "SseParser event type overwrite" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("event: first\nevent: second\ndata: test\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("second", events[0].event_type.?);
}

test "SseParser event type with empty value" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("event: \ndata: hello\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("", events[0].event_type.?);
}

test "SseParser event type without data produces no event" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("event: something\n\n");
    try std.testing.expectEqual(@as(usize, 0), events.len);
}

// --- Multiple events in one chunk ---

test "SseParser three events in one chunk" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("data: a\n\ndata: b\n\ndata: c\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqualStrings("a", events[0].data);
    try std.testing.expectEqualStrings("b", events[1].data);
    try std.testing.expectEqualStrings("c", events[2].data);
}

test "SseParser five events rapidly" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("data: 1\n\ndata: 2\n\ndata: 3\n\ndata: 4\n\ndata: 5\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 5), events.len);
    try std.testing.expectEqualStrings("5", events[4].data);
}

// --- Partial events across multiple chunks ---

test "SseParser split in middle of field name" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events1 = try parser.feed("da");
    try std.testing.expectEqual(@as(usize, 0), events1.len);

    const events2 = try parser.feed("ta: hello\n\n");
    defer freeEvents(allocator, events2);
    try std.testing.expectEqual(@as(usize, 1), events2.len);
    try std.testing.expectEqualStrings("hello", events2[0].data);
}

test "SseParser split at boundary between events" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events1 = try parser.feed("data: first\n\ndata: sec");
    defer freeEvents(allocator, events1);
    try std.testing.expectEqual(@as(usize, 1), events1.len);
    try std.testing.expectEqualStrings("first", events1[0].data);

    const events2 = try parser.feed("ond\n\n");
    defer freeEvents(allocator, events2);
    try std.testing.expectEqual(@as(usize, 1), events2.len);
    try std.testing.expectEqualStrings("second", events2[0].data);
}

test "SseParser split at newline" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events1 = try parser.feed("data: test\n");
    try std.testing.expectEqual(@as(usize, 0), events1.len);

    const events2 = try parser.feed("\n");
    defer freeEvents(allocator, events2);
    try std.testing.expectEqual(@as(usize, 1), events2.len);
    try std.testing.expectEqualStrings("test", events2[0].data);
}

test "SseParser feed byte by byte" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const input = "data: hi\n\n";
    var found_events: ?[]SseEvent = null;
    for (input) |byte| {
        const events = try parser.feed(&[_]u8{byte});
        if (events.len > 0) {
            found_events = events;
        }
    }
    try std.testing.expect(found_events != null);
    defer freeEvents(allocator, found_events.?);
    try std.testing.expectEqual(@as(usize, 1), found_events.?.len);
    try std.testing.expectEqualStrings("hi", found_events.?[0].data);
}

// --- CRLF and LF line ending tests ---

test "SseParser CRLF multi-line data" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("data: line1\r\ndata: line2\r\n\r\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("line1\nline2", events[0].data);
}

test "SseParser mixed CRLF and LF" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("data: a\r\ndata: b\ndata: c\r\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("a\nb\nc", events[0].data);
}

test "SseParser CRLF event type" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("event: delta\r\ndata: text\r\n\r\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("delta", events[0].event_type.?);
    try std.testing.expectEqualStrings("text", events[0].data);
}

// --- [DONE] sentinel variations ---

test "SseParser isDone only matches exact [DONE]" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("data: [DONE]\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expect(events[0].isDone());
}

test "SseParser isDone false for similar strings" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("data: [done]\n\ndata: DONE\n\ndata: [DONE] \n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expect(!events[0].isDone());
    try std.testing.expect(!events[1].isDone());
    try std.testing.expect(!events[2].isDone());
}

// --- Very long data ---

test "SseParser long data line" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    // Build a 10KB data line
    var long_data: [10240]u8 = undefined;
    @memset(&long_data, 'A');
    var input_buf: [10260]u8 = undefined;
    @memcpy(input_buf[0..6], "data: ");
    @memcpy(input_buf[6..10246], &long_data);
    @memcpy(input_buf[10246..10248], "\n\n");

    const events = try parser.feed(input_buf[0..10248]);
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(@as(usize, 10240), events[0].data.len);
}

// --- Unknown field ignored ---

test "SseParser ignores id and retry fields" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("id: 12345\nretry: 5000\ndata: actual data\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("actual data", events[0].data);
    try std.testing.expect(events[0].event_type == null);
}

test "SseParser ignores unknown fields" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("foo: bar\nbaz: qux\ndata: real\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("real", events[0].data);
}

// --- Reset behavior ---

test "SseParser reset clears state between events" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    // Event type should not carry over to next event
    const events = try parser.feed("event: typed\ndata: first\n\ndata: second\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("typed", events[0].event_type.?);
    try std.testing.expect(events[1].event_type == null);
}

test "SseParser reuse after deinit events" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events1 = try parser.feed("data: round1\n\n");
    defer freeEvents(allocator, events1);
    try std.testing.expectEqual(@as(usize, 1), events1.len);

    const events2 = try parser.feed("data: round2\n\n");
    defer freeEvents(allocator, events2);
    try std.testing.expectEqual(@as(usize, 1), events2.len);
    try std.testing.expectEqualStrings("round2", events2[0].data);
}

// --- SseEvent tests ---

test "SseEvent isDone method" {
    const done_event = SseEvent{ .event_type = null, .data = "[DONE]" };
    try std.testing.expect(done_event.isDone());

    const not_done = SseEvent{ .event_type = null, .data = "some data" };
    try std.testing.expect(!not_done.isDone());
}

test "SseEvent with typed event" {
    const event = SseEvent{ .event_type = "message_start", .data = "{}" };
    try std.testing.expectEqualStrings("message_start", event.event_type.?);
    try std.testing.expect(!event.isDone());
}

// --- Data with special characters ---

test "SseParser data with JSON content" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("data: {\"key\":\"value\",\"num\":42,\"arr\":[1,2,3]}\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("{\"key\":\"value\",\"num\":42,\"arr\":[1,2,3]}", events[0].data);
}

test "SseParser data with colons in value" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("data: time is 12:30:00\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("time is 12:30:00", events[0].data);
}

test "SseParser data with unicode content" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("data: Hello World\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("Hello World", events[0].data);
}

// --- freeEvents edge cases ---

test "freeEvents with events that have no event_type" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("data: no type\n\n");
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expect(events[0].event_type == null);
    freeEvents(allocator, events);
}

test "SseParser multi-line data with many lines" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("data: a\ndata: b\ndata: c\ndata: d\ndata: e\n\n");
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("a\nb\nc\nd\ne", events[0].data);
}

test "SseParser empty feed returns empty" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("");
    try std.testing.expectEqual(@as(usize, 0), events.len);
}

test "SseParser partial data then complete" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const e1 = try parser.feed("event: content_block_");
    try std.testing.expectEqual(@as(usize, 0), e1.len);

    const e2 = try parser.feed("delta\ndata: {\"te");
    try std.testing.expectEqual(@as(usize, 0), e2.len);

    const e3 = try parser.feed("xt\":\"hello\"}\n\n");
    defer freeEvents(allocator, e3);
    try std.testing.expectEqual(@as(usize, 1), e3.len);
    try std.testing.expectEqualStrings("content_block_delta", e3[0].event_type.?);
    try std.testing.expectEqualStrings("{\"text\":\"hello\"}", e3[0].data);
}
