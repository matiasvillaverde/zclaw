const std = @import("std");
const state = @import("state.zig");

// --- Dashboard Data ---

pub const DashboardData = struct {
    gateway_status: []const u8 = "not_running",
    uptime_seconds: u64 = 0,
    channel_count: u32 = 0,
    active_sessions: u32 = 0,
    agent_count: u32 = 0,
    messages_today: u32 = 0,
};

pub fn serializeDashboard(buf: []u8, data: *const DashboardData) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("{\"gateway\":\"");
    try w.writeAll(data.gateway_status);
    try w.writeAll("\",\"uptime\":");
    try std.fmt.format(w, "{d}", .{data.uptime_seconds});
    try w.writeAll(",\"channels\":");
    try std.fmt.format(w, "{d}", .{data.channel_count});
    try w.writeAll(",\"sessions\":");
    try std.fmt.format(w, "{d}", .{data.active_sessions});
    try w.writeAll(",\"agents\":");
    try std.fmt.format(w, "{d}", .{data.agent_count});
    try w.writeAll(",\"messages_today\":");
    try std.fmt.format(w, "{d}", .{data.messages_today});
    try w.writeAll("}");
    return fbs.getWritten();
}

// --- Channel List Data ---

pub const ChannelListItem = struct {
    name: []const u8,
    channel_type: []const u8,
    status: []const u8,
};

pub fn serializeChannelList(buf: []u8, channels: []const ChannelListItem) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("[");
    for (channels, 0..) |ch, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":\"");
        try w.writeAll(ch.name);
        try w.writeAll("\",\"type\":\"");
        try w.writeAll(ch.channel_type);
        try w.writeAll("\",\"status\":\"");
        try w.writeAll(ch.status);
        try w.writeAll("\"}");
    }
    try w.writeAll("]");
    return fbs.getWritten();
}

// --- Session List Data ---

pub const SessionListItem = struct {
    key: []const u8,
    agent: []const u8,
    channel: []const u8,
    message_count: u32 = 0,
    last_active: []const u8 = "",
};

pub fn serializeSessionList(buf: []u8, sessions: []const SessionListItem) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("[");
    for (sessions, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"key\":\"");
        try w.writeAll(s.key);
        try w.writeAll("\",\"agent\":\"");
        try w.writeAll(s.agent);
        try w.writeAll("\",\"channel\":\"");
        try w.writeAll(s.channel);
        try w.writeAll("\",\"messages\":");
        try std.fmt.format(w, "{d}", .{s.message_count});
        try w.writeAll("}");
    }
    try w.writeAll("]");
    return fbs.getWritten();
}

// --- Memory Search Results ---

pub const MemoryResult = struct {
    chunk_text: []const u8,
    source: []const u8,
    score: f32 = 0,
};

pub fn serializeMemoryResults(buf: []u8, results: []const MemoryResult) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("[");
    for (results, 0..) |r, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"text\":\"");
        try w.writeAll(r.chunk_text);
        try w.writeAll("\",\"source\":\"");
        try w.writeAll(r.source);
        try w.writeAll("\"}");
    }
    try w.writeAll("]");
    return fbs.getWritten();
}

// --- Navigation Item ---

pub const NavItem = struct {
    view: state.View,
    icon: []const u8,
    badge: u32 = 0,
};

pub const NAV_ITEMS = [_]NavItem{
    .{ .view = .dashboard, .icon = "home" },
    .{ .view = .chat, .icon = "chat" },
    .{ .view = .channels, .icon = "plug" },
    .{ .view = .agents, .icon = "bot" },
    .{ .view = .sessions, .icon = "list" },
    .{ .view = .memory, .icon = "brain" },
    .{ .view = .config, .icon = "gear" },
    .{ .view = .logs, .icon = "terminal" },
};

pub fn serializeNavItems(buf: []u8, app_state: *const state.AppState) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("[");
    for (NAV_ITEMS, 0..) |item, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"label\":\"");
        try w.writeAll(item.view.label());
        try w.writeAll("\",\"path\":\"");
        try w.writeAll(item.view.path());
        try w.writeAll("\",\"icon\":\"");
        try w.writeAll(item.icon);
        try w.writeAll("\",\"active\":");
        try w.writeAll(if (item.view == app_state.current_view) "true" else "false");
        try w.writeAll("}");
    }
    try w.writeAll("]");
    return fbs.getWritten();
}

// --- Format Uptime ---

pub fn formatUptime(buf: []u8, seconds: u64) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    if (seconds < 60) {
        try std.fmt.format(w, "{d}s", .{seconds});
    } else if (seconds < 3600) {
        try std.fmt.format(w, "{d}m {d}s", .{ seconds / 60, seconds % 60 });
    } else if (seconds < 86400) {
        const h = seconds / 3600;
        const m = (seconds % 3600) / 60;
        try std.fmt.format(w, "{d}h {d}m", .{ h, m });
    } else {
        const d = seconds / 86400;
        const h = (seconds % 86400) / 3600;
        try std.fmt.format(w, "{d}d {d}h", .{ d, h });
    }
    return fbs.getWritten();
}

// --- Tests ---

test "DashboardData defaults" {
    const data = DashboardData{};
    try std.testing.expectEqualStrings("not_running", data.gateway_status);
    try std.testing.expectEqual(@as(u32, 0), data.channel_count);
}

test "serializeDashboard" {
    const data = DashboardData{
        .gateway_status = "running",
        .uptime_seconds = 3600,
        .channel_count = 2,
        .active_sessions = 5,
        .agent_count = 1,
        .messages_today = 42,
    };
    var buf: [512]u8 = undefined;
    const json = try serializeDashboard(&buf, &data);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"gateway\":\"running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"uptime\":3600") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"channels\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"messages_today\":42") != null);
}

test "serializeChannelList empty" {
    var buf: [256]u8 = undefined;
    const json = try serializeChannelList(&buf, &.{});
    try std.testing.expectEqualStrings("[]", json);
}

test "serializeChannelList with items" {
    const channels = [_]ChannelListItem{
        .{ .name = "telegram", .channel_type = "telegram", .status = "connected" },
        .{ .name = "discord", .channel_type = "discord", .status = "disconnected" },
    };
    var buf: [1024]u8 = undefined;
    const json = try serializeChannelList(&buf, &channels);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"telegram\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"discord\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"connected\"") != null);
}

test "serializeSessionList" {
    const sessions = [_]SessionListItem{
        .{ .key = "agent:default:telegram:dm:123", .agent = "default", .channel = "telegram", .message_count = 10 },
    };
    var buf: [1024]u8 = undefined;
    const json = try serializeSessionList(&buf, &sessions);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"agent\":\"default\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"messages\":10") != null);
}

test "serializeSessionList empty" {
    var buf: [256]u8 = undefined;
    const json = try serializeSessionList(&buf, &.{});
    try std.testing.expectEqualStrings("[]", json);
}

test "serializeMemoryResults" {
    const results = [_]MemoryResult{
        .{ .chunk_text = "Some text about AI", .source = "docs/ai.md", .score = 0.95 },
    };
    var buf: [1024]u8 = undefined;
    const json = try serializeMemoryResults(&buf, &results);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"text\":\"Some text about AI\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"source\":\"docs/ai.md\"") != null);
}

test "serializeMemoryResults empty" {
    var buf: [256]u8 = undefined;
    const json = try serializeMemoryResults(&buf, &.{});
    try std.testing.expectEqualStrings("[]", json);
}

test "NAV_ITEMS" {
    try std.testing.expectEqual(@as(usize, 8), NAV_ITEMS.len);
    try std.testing.expectEqual(state.View.dashboard, NAV_ITEMS[0].view);
    try std.testing.expectEqualStrings("home", NAV_ITEMS[0].icon);
}

test "serializeNavItems" {
    const app = state.AppState{ .current_view = .chat };
    var buf: [2048]u8 = undefined;
    const json = try serializeNavItems(&buf, &app);
    // Dashboard should not be active
    try std.testing.expect(std.mem.indexOf(u8, json, "\"label\":\"Dashboard\"") != null);
    // Chat should be active
    try std.testing.expect(std.mem.indexOf(u8, json, "\"label\":\"Chat\"") != null);
}

test "formatUptime seconds" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("45s", try formatUptime(&buf, 45));
}

test "formatUptime minutes" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("5m 30s", try formatUptime(&buf, 330));
}

test "formatUptime hours" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("2h 15m", try formatUptime(&buf, 8100));
}

test "formatUptime days" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1d 12h", try formatUptime(&buf, 129600));
}

test "formatUptime zero" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0s", try formatUptime(&buf, 0));
}

// --- Additional Tests ---

test "DashboardData custom values" {
    const data = DashboardData{
        .gateway_status = "running",
        .uptime_seconds = 100,
        .channel_count = 5,
        .active_sessions = 10,
        .agent_count = 3,
        .messages_today = 99,
    };
    try std.testing.expectEqualStrings("running", data.gateway_status);
    try std.testing.expectEqual(@as(u32, 99), data.messages_today);
}

test "serializeDashboard defaults" {
    const data = DashboardData{};
    var buf: [512]u8 = undefined;
    const json = try serializeDashboard(&buf, &data);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"gateway\":\"not_running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"uptime\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"channels\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sessions\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"agents\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"messages_today\":0") != null);
}

test "ChannelListItem struct" {
    const item = ChannelListItem{ .name = "web", .channel_type = "webchat", .status = "active" };
    try std.testing.expectEqualStrings("web", item.name);
    try std.testing.expectEqualStrings("webchat", item.channel_type);
}

test "serializeChannelList single item" {
    const channels = [_]ChannelListItem{
        .{ .name = "slack", .channel_type = "slack", .status = "connected" },
    };
    var buf: [1024]u8 = undefined;
    const json = try serializeChannelList(&buf, &channels);
    try std.testing.expect(std.mem.startsWith(u8, json, "["));
    try std.testing.expect(std.mem.endsWith(u8, json, "]"));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"slack\"") != null);
}

test "SessionListItem defaults" {
    const item = SessionListItem{ .key = "k", .agent = "a", .channel = "c" };
    try std.testing.expectEqual(@as(u32, 0), item.message_count);
    try std.testing.expectEqualStrings("", item.last_active);
}

test "serializeSessionList multiple items" {
    const sessions = [_]SessionListItem{
        .{ .key = "k1", .agent = "a1", .channel = "c1", .message_count = 5 },
        .{ .key = "k2", .agent = "a2", .channel = "c2", .message_count = 10 },
    };
    var buf: [2048]u8 = undefined;
    const json = try serializeSessionList(&buf, &sessions);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"key\":\"k1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"key\":\"k2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"messages\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"messages\":10") != null);
}

test "MemoryResult defaults" {
    const r = MemoryResult{ .chunk_text = "text", .source = "src" };
    try std.testing.expectEqual(@as(f32, 0), r.score);
}

test "serializeMemoryResults multiple" {
    const results = [_]MemoryResult{
        .{ .chunk_text = "chunk1", .source = "doc1", .score = 0.9 },
        .{ .chunk_text = "chunk2", .source = "doc2", .score = 0.8 },
    };
    var buf: [2048]u8 = undefined;
    const json = try serializeMemoryResults(&buf, &results);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"text\":\"chunk1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"text\":\"chunk2\"") != null);
}

test "NavItem struct" {
    const item = NavItem{ .view = .chat, .icon = "msg", .badge = 5 };
    try std.testing.expectEqual(state.View.chat, item.view);
    try std.testing.expectEqualStrings("msg", item.icon);
    try std.testing.expectEqual(@as(u32, 5), item.badge);
}

test "NavItem default badge" {
    const item = NavItem{ .view = .dashboard, .icon = "home" };
    try std.testing.expectEqual(@as(u32, 0), item.badge);
}

test "NAV_ITEMS last is logs" {
    try std.testing.expectEqual(state.View.logs, NAV_ITEMS[NAV_ITEMS.len - 1].view);
    try std.testing.expectEqualStrings("terminal", NAV_ITEMS[NAV_ITEMS.len - 1].icon);
}

test "serializeNavItems dashboard active" {
    const app = state.AppState{ .current_view = .dashboard };
    var buf: [2048]u8 = undefined;
    const json = try serializeNavItems(&buf, &app);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"label\":\"Dashboard\"") != null);
}

test "formatUptime exactly 60 seconds" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1m 0s", try formatUptime(&buf, 60));
}

test "formatUptime exactly 1 hour" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1h 0m", try formatUptime(&buf, 3600));
}

test "formatUptime exactly 1 day" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1d 0h", try formatUptime(&buf, 86400));
}

test "formatUptime boundary 59 seconds" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("59s", try formatUptime(&buf, 59));
}

test "formatUptime boundary 3599 seconds" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("59m 59s", try formatUptime(&buf, 3599));
}
