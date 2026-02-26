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
