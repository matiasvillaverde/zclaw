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
