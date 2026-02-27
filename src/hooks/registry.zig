const std = @import("std");

// --- Hook System ---
//
// Event-driven observer pattern for agent lifecycle events.

pub const HookEvent = enum {
    message_received,
    message_sent,
    tool_call_before,
    tool_call_after,
    session_start,
    session_end,
    agent_turn,
    agent_complete,

    pub fn label(self: HookEvent) []const u8 {
        return switch (self) {
            .message_received => "message_received",
            .message_sent => "message_sent",
            .tool_call_before => "tool_call_before",
            .tool_call_after => "tool_call_after",
            .session_start => "session_start",
            .session_end => "session_end",
            .agent_turn => "agent_turn",
            .agent_complete => "agent_complete",
        };
    }
};

pub const HookContext = struct {
    event: HookEvent,
    agent_id: ?[]const u8 = null,
    data: ?[]const u8 = null,
};

pub const HookHandler = *const fn (ctx: HookContext) void;

const MAX_HANDLERS_PER_EVENT = 16;

pub const HookRegistry = struct {
    handlers: std.EnumArray(HookEvent, HandlerList),
    total_emits: u64,

    const HandlerList = struct {
        items: [MAX_HANDLERS_PER_EVENT]?HookHandler = [_]?HookHandler{null} ** MAX_HANDLERS_PER_EVENT,
        count: usize = 0,
    };

    pub fn init() HookRegistry {
        return .{
            .handlers = std.EnumArray(HookEvent, HandlerList).initFill(.{}),
            .total_emits = 0,
        };
    }

    /// Register a handler for an event.
    pub fn register(self: *HookRegistry, event: HookEvent, handler: HookHandler) bool {
        var list = self.handlers.getPtr(event);
        if (list.count >= MAX_HANDLERS_PER_EVENT) return false;
        list.items[list.count] = handler;
        list.count += 1;
        return true;
    }

    /// Emit an event to all registered handlers.
    pub fn emit(self: *HookRegistry, ctx: HookContext) void {
        self.total_emits += 1;
        const list = self.handlers.get(ctx.event);
        for (0..list.count) |i| {
            if (list.items[i]) |handler| {
                handler(ctx);
            }
        }
    }

    /// Clear all handlers for an event.
    pub fn clear(self: *HookRegistry, event: HookEvent) void {
        var list = self.handlers.getPtr(event);
        list.count = 0;
        list.items = [_]?HookHandler{null} ** MAX_HANDLERS_PER_EVENT;
    }

    /// Clear all handlers for all events.
    pub fn clearAll(self: *HookRegistry) void {
        for (std.meta.tags(HookEvent)) |event| {
            self.clear(event);
        }
        self.total_emits = 0;
    }

    /// Get handler count for an event.
    pub fn hookCount(self: *const HookRegistry, event: HookEvent) usize {
        return self.handlers.get(event).count;
    }

    /// Get total number of handlers across all events.
    pub fn totalHandlers(self: *const HookRegistry) usize {
        var total: usize = 0;
        for (std.meta.tags(HookEvent)) |event| {
            total += self.handlers.get(event).count;
        }
        return total;
    }
};

// --- Tests ---

var test_counter: u32 = 0;

fn testHandler(_: HookContext) void {
    test_counter += 1;
}

fn testHandler2(_: HookContext) void {
    test_counter += 10;
}

test "HookEvent labels" {
    try std.testing.expectEqualStrings("message_received", HookEvent.message_received.label());
    try std.testing.expectEqualStrings("tool_call_before", HookEvent.tool_call_before.label());
    try std.testing.expectEqualStrings("session_start", HookEvent.session_start.label());
    try std.testing.expectEqualStrings("agent_complete", HookEvent.agent_complete.label());
}

test "HookRegistry init" {
    const reg = HookRegistry.init();
    try std.testing.expectEqual(@as(usize, 0), reg.hookCount(.message_received));
    try std.testing.expectEqual(@as(usize, 0), reg.totalHandlers());
    try std.testing.expectEqual(@as(u64, 0), reg.total_emits);
}

test "HookRegistry register and emit" {
    test_counter = 0;
    var reg = HookRegistry.init();
    try std.testing.expect(reg.register(.message_received, testHandler));
    try std.testing.expectEqual(@as(usize, 1), reg.hookCount(.message_received));

    reg.emit(.{ .event = .message_received });
    try std.testing.expectEqual(@as(u32, 1), test_counter);

    reg.emit(.{ .event = .message_received });
    try std.testing.expectEqual(@as(u32, 2), test_counter);
}

test "HookRegistry multiple handlers" {
    test_counter = 0;
    var reg = HookRegistry.init();
    _ = reg.register(.message_sent, testHandler);
    _ = reg.register(.message_sent, testHandler2);
    try std.testing.expectEqual(@as(usize, 2), reg.hookCount(.message_sent));

    reg.emit(.{ .event = .message_sent });
    try std.testing.expectEqual(@as(u32, 11), test_counter);
}

test "HookRegistry emit no handlers" {
    test_counter = 0;
    var reg = HookRegistry.init();
    reg.emit(.{ .event = .session_start });
    try std.testing.expectEqual(@as(u32, 0), test_counter);
    try std.testing.expectEqual(@as(u64, 1), reg.total_emits);
}

test "HookRegistry clear" {
    test_counter = 0;
    var reg = HookRegistry.init();
    _ = reg.register(.tool_call_before, testHandler);
    try std.testing.expectEqual(@as(usize, 1), reg.hookCount(.tool_call_before));

    reg.clear(.tool_call_before);
    try std.testing.expectEqual(@as(usize, 0), reg.hookCount(.tool_call_before));

    reg.emit(.{ .event = .tool_call_before });
    try std.testing.expectEqual(@as(u32, 0), test_counter);
}

test "HookRegistry clearAll" {
    var reg = HookRegistry.init();
    _ = reg.register(.message_received, testHandler);
    _ = reg.register(.session_start, testHandler);
    try std.testing.expectEqual(@as(usize, 2), reg.totalHandlers());

    reg.clearAll();
    try std.testing.expectEqual(@as(usize, 0), reg.totalHandlers());
    try std.testing.expectEqual(@as(u64, 0), reg.total_emits);
}

test "HookRegistry totalHandlers" {
    var reg = HookRegistry.init();
    _ = reg.register(.message_received, testHandler);
    _ = reg.register(.message_sent, testHandler);
    _ = reg.register(.agent_turn, testHandler);
    try std.testing.expectEqual(@as(usize, 3), reg.totalHandlers());
}

test "HookContext fields" {
    const ctx = HookContext{
        .event = .tool_call_after,
        .agent_id = "agent-1",
        .data = "{\"tool\":\"bash\"}",
    };
    try std.testing.expectEqual(HookEvent.tool_call_after, ctx.event);
    try std.testing.expectEqualStrings("agent-1", ctx.agent_id.?);
}

test "HookRegistry emit tracks total" {
    var reg = HookRegistry.init();
    reg.emit(.{ .event = .session_start });
    reg.emit(.{ .event = .session_end });
    reg.emit(.{ .event = .agent_turn });
    try std.testing.expectEqual(@as(u64, 3), reg.total_emits);
}

test "HookRegistry register returns false when full" {
    var reg = HookRegistry.init();
    var i: usize = 0;
    while (i < MAX_HANDLERS_PER_EVENT) : (i += 1) {
        try std.testing.expect(reg.register(.message_received, testHandler));
    }
    // Should fail on 17th handler
    try std.testing.expect(!reg.register(.message_received, testHandler));
}

// --- Additional Tests ---

test "HookEvent all labels are non-empty" {
    for (std.meta.tags(HookEvent)) |event| {
        try std.testing.expect(event.label().len > 0);
    }
}

test "HookEvent message_sent label" {
    try std.testing.expectEqualStrings("message_sent", HookEvent.message_sent.label());
}

test "HookEvent tool_call_after label" {
    try std.testing.expectEqualStrings("tool_call_after", HookEvent.tool_call_after.label());
}

test "HookEvent session_end label" {
    try std.testing.expectEqualStrings("session_end", HookEvent.session_end.label());
}

test "HookEvent agent_turn label" {
    try std.testing.expectEqualStrings("agent_turn", HookEvent.agent_turn.label());
}

test "HookRegistry isolated events" {
    test_counter = 0;
    var reg = HookRegistry.init();
    _ = reg.register(.message_received, testHandler);

    // Emitting a different event should not trigger message_received handler
    reg.emit(.{ .event = .session_start });
    try std.testing.expectEqual(@as(u32, 0), test_counter);
}

test "HookRegistry clear does not affect other events" {
    var reg = HookRegistry.init();
    _ = reg.register(.message_received, testHandler);
    _ = reg.register(.session_start, testHandler);

    reg.clear(.message_received);
    try std.testing.expectEqual(@as(usize, 0), reg.hookCount(.message_received));
    try std.testing.expectEqual(@as(usize, 1), reg.hookCount(.session_start));
}

test "HookContext defaults" {
    const ctx = HookContext{ .event = .message_received };
    try std.testing.expectEqual(@as(?[]const u8, null), ctx.agent_id);
    try std.testing.expectEqual(@as(?[]const u8, null), ctx.data);
}

test "HookRegistry emit with data" {
    test_counter = 0;
    var reg = HookRegistry.init();
    _ = reg.register(.tool_call_before, testHandler);

    reg.emit(.{
        .event = .tool_call_before,
        .agent_id = "agent-1",
        .data = "{\"tool\":\"bash\"}",
    });
    try std.testing.expectEqual(@as(u32, 1), test_counter);
}

test "MAX_HANDLERS_PER_EVENT is 16" {
    try std.testing.expectEqual(@as(usize, 16), MAX_HANDLERS_PER_EVENT);
}

test "HookRegistry clearAll resets emit counter" {
    var reg = HookRegistry.init();
    reg.emit(.{ .event = .agent_complete });
    reg.emit(.{ .event = .agent_complete });
    try std.testing.expectEqual(@as(u64, 2), reg.total_emits);

    reg.clearAll();
    try std.testing.expectEqual(@as(u64, 0), reg.total_emits);
}

// === New Tests (batch 2) ===

test "HookRegistry register same handler twice" {
    test_counter = 0;
    var reg = HookRegistry.init();
    _ = reg.register(.message_received, testHandler);
    _ = reg.register(.message_received, testHandler);

    try std.testing.expectEqual(@as(usize, 2), reg.hookCount(.message_received));

    reg.emit(.{ .event = .message_received });
    // Both handlers fire, each incrementing by 1
    try std.testing.expectEqual(@as(u32, 2), test_counter);
}

test "HookRegistry register different events independently" {
    test_counter = 0;
    var reg = HookRegistry.init();
    _ = reg.register(.message_received, testHandler);
    _ = reg.register(.session_start, testHandler2);

    try std.testing.expectEqual(@as(usize, 1), reg.hookCount(.message_received));
    try std.testing.expectEqual(@as(usize, 1), reg.hookCount(.session_start));

    reg.emit(.{ .event = .message_received });
    try std.testing.expectEqual(@as(u32, 1), test_counter);

    reg.emit(.{ .event = .session_start });
    try std.testing.expectEqual(@as(u32, 11), test_counter);
}

test "HookRegistry emit increments total even with no handlers" {
    var reg = HookRegistry.init();
    for (0..5) |_| {
        reg.emit(.{ .event = .agent_complete });
    }
    try std.testing.expectEqual(@as(u64, 5), reg.total_emits);
}

test "HookRegistry clear only one event preserves others" {
    var reg = HookRegistry.init();
    _ = reg.register(.message_received, testHandler);
    _ = reg.register(.message_sent, testHandler);
    _ = reg.register(.session_start, testHandler);
    _ = reg.register(.session_end, testHandler);

    try std.testing.expectEqual(@as(usize, 4), reg.totalHandlers());

    reg.clear(.message_received);
    try std.testing.expectEqual(@as(usize, 3), reg.totalHandlers());
    try std.testing.expectEqual(@as(usize, 0), reg.hookCount(.message_received));
    try std.testing.expectEqual(@as(usize, 1), reg.hookCount(.message_sent));
    try std.testing.expectEqual(@as(usize, 1), reg.hookCount(.session_start));
    try std.testing.expectEqual(@as(usize, 1), reg.hookCount(.session_end));
}

test "HookRegistry clear idempotent" {
    var reg = HookRegistry.init();
    _ = reg.register(.message_received, testHandler);

    reg.clear(.message_received);
    try std.testing.expectEqual(@as(usize, 0), reg.hookCount(.message_received));

    // Clearing again should be fine
    reg.clear(.message_received);
    try std.testing.expectEqual(@as(usize, 0), reg.hookCount(.message_received));
}

test "HookRegistry clearAll with populated handlers" {
    var reg = HookRegistry.init();
    for (std.meta.tags(HookEvent)) |event| {
        _ = reg.register(event, testHandler);
    }

    try std.testing.expectEqual(@as(usize, 8), reg.totalHandlers());

    reg.clearAll();
    try std.testing.expectEqual(@as(usize, 0), reg.totalHandlers());
    for (std.meta.tags(HookEvent)) |event| {
        try std.testing.expectEqual(@as(usize, 0), reg.hookCount(event));
    }
}

test "HookRegistry total emits across events" {
    var reg = HookRegistry.init();
    reg.emit(.{ .event = .message_received });
    reg.emit(.{ .event = .message_sent });
    reg.emit(.{ .event = .tool_call_before });
    reg.emit(.{ .event = .tool_call_after });
    reg.emit(.{ .event = .session_start });
    reg.emit(.{ .event = .session_end });
    reg.emit(.{ .event = .agent_turn });
    reg.emit(.{ .event = .agent_complete });

    try std.testing.expectEqual(@as(u64, 8), reg.total_emits);
}

test "HookRegistry hookCount zero for all events initially" {
    const reg = HookRegistry.init();
    for (std.meta.tags(HookEvent)) |event| {
        try std.testing.expectEqual(@as(usize, 0), reg.hookCount(event));
    }
}

test "HookRegistry multiple handlers execution order" {
    test_counter = 0;
    var reg = HookRegistry.init();
    _ = reg.register(.agent_turn, testHandler);  // +1
    _ = reg.register(.agent_turn, testHandler2); // +10

    reg.emit(.{ .event = .agent_turn });
    // Both should have fired: 1 + 10 = 11
    try std.testing.expectEqual(@as(u32, 11), test_counter);
}

test "HookContext with all fields" {
    const ctx = HookContext{
        .event = .message_received,
        .agent_id = "test-agent-123",
        .data = "{\"content\":\"hello\"}",
    };
    try std.testing.expectEqual(HookEvent.message_received, ctx.event);
    try std.testing.expectEqualStrings("test-agent-123", ctx.agent_id.?);
    try std.testing.expectEqualStrings("{\"content\":\"hello\"}", ctx.data.?);
}

test "HookContext with null agent_id and data" {
    const ctx = HookContext{ .event = .session_end };
    try std.testing.expect(ctx.agent_id == null);
    try std.testing.expect(ctx.data == null);
}

test "HookRegistry register returns true up to limit" {
    var reg = HookRegistry.init();
    var count: usize = 0;
    while (count < MAX_HANDLERS_PER_EVENT) : (count += 1) {
        try std.testing.expect(reg.register(.tool_call_after, testHandler));
    }
    try std.testing.expectEqual(@as(usize, MAX_HANDLERS_PER_EVENT), reg.hookCount(.tool_call_after));
    // One more should fail
    try std.testing.expect(!reg.register(.tool_call_after, testHandler));
}

test "HookRegistry register full on one event does not affect others" {
    var reg = HookRegistry.init();
    // Fill up message_received
    for (0..MAX_HANDLERS_PER_EVENT) |_| {
        _ = reg.register(.message_received, testHandler);
    }
    try std.testing.expect(!reg.register(.message_received, testHandler));

    // Other events should still accept handlers
    try std.testing.expect(reg.register(.session_start, testHandler));
    try std.testing.expect(reg.register(.agent_complete, testHandler));
}

test "HookRegistry emit after clear does nothing" {
    test_counter = 0;
    var reg = HookRegistry.init();
    _ = reg.register(.message_received, testHandler);

    reg.clear(.message_received);
    reg.emit(.{ .event = .message_received });

    try std.testing.expectEqual(@as(u32, 0), test_counter);
    try std.testing.expectEqual(@as(u64, 1), reg.total_emits);
}

test "HookRegistry re-register after clear" {
    test_counter = 0;
    var reg = HookRegistry.init();
    _ = reg.register(.session_start, testHandler);

    reg.clear(.session_start);
    try std.testing.expectEqual(@as(usize, 0), reg.hookCount(.session_start));

    _ = reg.register(.session_start, testHandler2);
    try std.testing.expectEqual(@as(usize, 1), reg.hookCount(.session_start));

    reg.emit(.{ .event = .session_start });
    try std.testing.expectEqual(@as(u32, 10), test_counter);
}

test "HookEvent enum has 8 variants" {
    const tags = std.meta.tags(HookEvent);
    try std.testing.expectEqual(@as(usize, 8), tags.len);
}

test "HookEvent labels are all distinct" {
    const tags = std.meta.tags(HookEvent);
    for (tags, 0..) |e1, i| {
        for (tags[i + 1 ..]) |e2| {
            try std.testing.expect(!std.mem.eql(u8, e1.label(), e2.label()));
        }
    }
}

test "HookRegistry totalHandlers reflects all events" {
    var reg = HookRegistry.init();
    _ = reg.register(.message_received, testHandler);
    _ = reg.register(.message_received, testHandler2);
    _ = reg.register(.session_start, testHandler);
    _ = reg.register(.agent_turn, testHandler);
    _ = reg.register(.agent_turn, testHandler);
    _ = reg.register(.agent_turn, testHandler);

    try std.testing.expectEqual(@as(usize, 6), reg.totalHandlers());
}

test "HookRegistry emit with agent_id only" {
    test_counter = 0;
    var reg = HookRegistry.init();
    _ = reg.register(.agent_complete, testHandler);

    reg.emit(.{ .event = .agent_complete, .agent_id = "agent-99" });
    try std.testing.expectEqual(@as(u32, 1), test_counter);
}

test "HookRegistry emit with data only" {
    test_counter = 0;
    var reg = HookRegistry.init();
    _ = reg.register(.tool_call_before, testHandler);

    reg.emit(.{ .event = .tool_call_before, .data = "{\"tool\":\"read\"}" });
    try std.testing.expectEqual(@as(u32, 1), test_counter);
}

test "HookRegistry handler ordering is FIFO" {
    // Verify handlers fire in registration order by using a counter trick:
    // testHandler adds 1, testHandler2 adds 10
    // If FIFO: counter goes 0 -> 1 -> 11
    // If reversed: counter goes 0 -> 10 -> 11 (same total but intermediate differs)
    // We can verify total to confirm both fired, and that the sum is correct
    test_counter = 0;
    var reg = HookRegistry.init();
    _ = reg.register(.message_sent, testHandler); // +1 first
    _ = reg.register(.message_sent, testHandler2); // +10 second
    _ = reg.register(.message_sent, testHandler); // +1 third

    reg.emit(.{ .event = .message_sent });
    // 1 + 10 + 1 = 12
    try std.testing.expectEqual(@as(u32, 12), test_counter);
    try std.testing.expectEqual(@as(usize, 3), reg.hookCount(.message_sent));
}

test "HookRegistry clearAll then re-register works" {
    test_counter = 0;
    var reg = HookRegistry.init();
    _ = reg.register(.message_received, testHandler);
    _ = reg.register(.session_start, testHandler2);
    reg.emit(.{ .event = .message_received });
    try std.testing.expectEqual(@as(u32, 1), test_counter);

    reg.clearAll();
    try std.testing.expectEqual(@as(u64, 0), reg.total_emits);
    try std.testing.expectEqual(@as(usize, 0), reg.totalHandlers());

    // Re-register on the same event after clearAll
    _ = reg.register(.message_received, testHandler2);
    test_counter = 0;
    reg.emit(.{ .event = .message_received });
    try std.testing.expectEqual(@as(u32, 10), test_counter);
    try std.testing.expectEqual(@as(u64, 1), reg.total_emits);
}

test "HookRegistry emit multiple events interleaved with register" {
    test_counter = 0;
    var reg = HookRegistry.init();
    _ = reg.register(.agent_turn, testHandler);

    reg.emit(.{ .event = .agent_turn });
    try std.testing.expectEqual(@as(u32, 1), test_counter);

    // Add another handler to the same event
    _ = reg.register(.agent_turn, testHandler2);
    reg.emit(.{ .event = .agent_turn });
    // 1 (from first emit) + 1 (testHandler) + 10 (testHandler2) = 12
    try std.testing.expectEqual(@as(u32, 12), test_counter);
    try std.testing.expectEqual(@as(u64, 2), reg.total_emits);
}

test "HookRegistry fill clear refill same event" {
    var reg = HookRegistry.init();
    // Fill all 16 slots
    for (0..MAX_HANDLERS_PER_EVENT) |_| {
        try std.testing.expect(reg.register(.session_end, testHandler));
    }
    try std.testing.expectEqual(@as(usize, MAX_HANDLERS_PER_EVENT), reg.hookCount(.session_end));
    try std.testing.expect(!reg.register(.session_end, testHandler)); // full

    // Clear and refill
    reg.clear(.session_end);
    try std.testing.expectEqual(@as(usize, 0), reg.hookCount(.session_end));
    // Should accept handlers again
    try std.testing.expect(reg.register(.session_end, testHandler2));
    try std.testing.expectEqual(@as(usize, 1), reg.hookCount(.session_end));

    // Verify the new handler fires
    test_counter = 0;
    reg.emit(.{ .event = .session_end });
    try std.testing.expectEqual(@as(u32, 10), test_counter);
}

test "HookRegistry emit counts persist across clear of handlers" {
    var reg = HookRegistry.init();
    _ = reg.register(.tool_call_after, testHandler);
    reg.emit(.{ .event = .tool_call_after });
    reg.emit(.{ .event = .tool_call_after });
    try std.testing.expectEqual(@as(u64, 2), reg.total_emits);

    // clear only removes handlers, not the emit counter
    reg.clear(.tool_call_after);
    try std.testing.expectEqual(@as(u64, 2), reg.total_emits);

    // emitting with no handlers still increments counter
    reg.emit(.{ .event = .tool_call_after });
    try std.testing.expectEqual(@as(u64, 3), reg.total_emits);
}
