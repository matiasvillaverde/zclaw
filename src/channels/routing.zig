const std = @import("std");
const plugin = @import("plugin.zig");

// --- Scope Types ---

pub const Scope = enum {
    direct,
    group,

    pub fn label(self: Scope) []const u8 {
        return switch (self) {
            .direct => "direct",
            .group => "group",
        };
    }
};

// --- Session Key Builder ---

/// Build session key: agent:{agentId}:{channel}:{scope}:{identifier}
pub fn buildSessionKey(buf: []u8, agent_id: []const u8, channel: plugin.ChannelType, scope: Scope, identifier: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    try writer.writeAll("agent:");
    try writer.writeAll(agent_id);
    try writer.writeByte(':');
    try writer.writeAll(channel.label());
    try writer.writeByte(':');
    try writer.writeAll(scope.label());
    try writer.writeByte(':');
    try writer.writeAll(identifier);
    return fbs.getWritten();
}

/// Resolve session key from an incoming message.
pub fn resolveSessionKey(buf: []u8, agent_id: []const u8, msg: plugin.IncomingMessage) ![]const u8 {
    const scope: Scope = if (msg.is_group) .group else .direct;
    const identifier = if (msg.is_group) msg.chat_id else msg.sender_id;
    return buildSessionKey(buf, agent_id, msg.channel, scope, identifier);
}

// --- Agent Routing ---

pub const RouteConfig = struct {
    default_agent: []const u8 = "main",
    channel_agents: std.StringHashMapUnmanaged([]const u8) = .{},
};

/// Resolve which agent should handle a message.
pub fn resolveAgent(channel_name: []const u8, config: *const RouteConfig) []const u8 {
    if (config.channel_agents.get(channel_name)) |agent_id| {
        return agent_id;
    }
    return config.default_agent;
}

// --- Tests ---

test "Scope labels" {
    try std.testing.expectEqualStrings("direct", Scope.direct.label());
    try std.testing.expectEqualStrings("group", Scope.group.label());
}

test "buildSessionKey direct" {
    var buf: [256]u8 = undefined;
    const key = try buildSessionKey(&buf, "main", .telegram, .direct, "user123");
    try std.testing.expectEqualStrings("agent:main:telegram:direct:user123", key);
}

test "buildSessionKey group" {
    var buf: [256]u8 = undefined;
    const key = try buildSessionKey(&buf, "assistant", .discord, .group, "guild456");
    try std.testing.expectEqualStrings("agent:assistant:discord:group:guild456", key);
}

test "buildSessionKey webchat" {
    var buf: [256]u8 = undefined;
    const key = try buildSessionKey(&buf, "main", .webchat, .direct, "session-abc");
    try std.testing.expectEqualStrings("agent:main:webchat:direct:session-abc", key);
}

test "resolveSessionKey direct message" {
    var buf: [256]u8 = undefined;
    const msg = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "1",
        .sender_id = "user123",
        .chat_id = "chat456",
        .content = "hello",
        .is_group = false,
    };
    const key = try resolveSessionKey(&buf, "main", msg);
    try std.testing.expectEqualStrings("agent:main:telegram:direct:user123", key);
}

test "resolveSessionKey group message" {
    var buf: [256]u8 = undefined;
    const msg = plugin.IncomingMessage{
        .channel = .discord,
        .message_id = "1",
        .sender_id = "user123",
        .chat_id = "guild789",
        .content = "hello",
        .is_group = true,
    };
    const key = try resolveSessionKey(&buf, "main", msg);
    try std.testing.expectEqualStrings("agent:main:discord:group:guild789", key);
}

test "resolveAgent default" {
    const config = RouteConfig{};
    try std.testing.expectEqualStrings("main", resolveAgent("telegram", &config));
}

test "resolveAgent channel-specific" {
    const allocator = std.testing.allocator;
    var agents = std.StringHashMapUnmanaged([]const u8){};
    defer agents.deinit(allocator);
    try agents.put(allocator, "telegram", "tg-bot");

    const config = RouteConfig{
        .default_agent = "main",
        .channel_agents = agents,
    };
    try std.testing.expectEqualStrings("tg-bot", resolveAgent("telegram", &config));
    try std.testing.expectEqualStrings("main", resolveAgent("discord", &config));
}

// ======================================================================
// Additional comprehensive tests
// ======================================================================

// --- Session Key Builder Tests ---

test "buildSessionKey slack direct" {
    var buf: [256]u8 = undefined;
    const key = try buildSessionKey(&buf, "helper", .slack, .direct, "U12345");
    try std.testing.expectEqualStrings("agent:helper:slack:direct:U12345", key);
}

test "buildSessionKey slack group" {
    var buf: [256]u8 = undefined;
    const key = try buildSessionKey(&buf, "helper", .slack, .group, "C12345");
    try std.testing.expectEqualStrings("agent:helper:slack:group:C12345", key);
}

test "buildSessionKey whatsapp direct" {
    var buf: [256]u8 = undefined;
    const key = try buildSessionKey(&buf, "main", .whatsapp, .direct, "15551234567");
    try std.testing.expectEqualStrings("agent:main:whatsapp:direct:15551234567", key);
}

test "buildSessionKey whatsapp group" {
    var buf: [256]u8 = undefined;
    const key = try buildSessionKey(&buf, "main", .whatsapp, .group, "group-jid");
    try std.testing.expectEqualStrings("agent:main:whatsapp:group:group-jid", key);
}

test "buildSessionKey signal direct" {
    var buf: [256]u8 = undefined;
    const key = try buildSessionKey(&buf, "bot", .signal, .direct, "+15551234567");
    try std.testing.expectEqualStrings("agent:bot:signal:direct:+15551234567", key);
}

test "buildSessionKey signal group" {
    var buf: [256]u8 = undefined;
    const key = try buildSessionKey(&buf, "bot", .signal, .group, "group-abc");
    try std.testing.expectEqualStrings("agent:bot:signal:group:group-abc", key);
}

test "buildSessionKey matrix direct" {
    var buf: [256]u8 = undefined;
    const key = try buildSessionKey(&buf, "main", .matrix, .direct, "@user:matrix.org");
    try std.testing.expectEqualStrings("agent:main:matrix:direct:@user:matrix.org", key);
}

test "buildSessionKey matrix group" {
    var buf: [256]u8 = undefined;
    const key = try buildSessionKey(&buf, "main", .matrix, .group, "!room:matrix.org");
    try std.testing.expectEqualStrings("agent:main:matrix:group:!room:matrix.org", key);
}

test "buildSessionKey buffer too small" {
    var buf: [5]u8 = undefined;
    const result = buildSessionKey(&buf, "main", .telegram, .direct, "user123");
    try std.testing.expectError(error.NoSpaceLeft, result);
}

test "buildSessionKey telegram direct" {
    var buf: [256]u8 = undefined;
    const key = try buildSessionKey(&buf, "main", .telegram, .direct, "12345");
    try std.testing.expectEqualStrings("agent:main:telegram:direct:12345", key);
}

test "buildSessionKey telegram group" {
    var buf: [256]u8 = undefined;
    const key = try buildSessionKey(&buf, "main", .telegram, .group, "-1001234567890");
    try std.testing.expectEqualStrings("agent:main:telegram:group:-1001234567890", key);
}

test "buildSessionKey discord direct" {
    var buf: [256]u8 = undefined;
    const key = try buildSessionKey(&buf, "main", .discord, .direct, "user-snowflake-id");
    try std.testing.expectEqualStrings("agent:main:discord:direct:user-snowflake-id", key);
}

// --- Resolve Session Key Tests ---

test "resolveSessionKey telegram DM" {
    var buf: [256]u8 = undefined;
    const msg = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "1",
        .sender_id = "user42",
        .chat_id = "chat42",
        .content = "hi",
        .is_group = false,
    };
    const key = try resolveSessionKey(&buf, "main", msg);
    try std.testing.expectEqualStrings("agent:main:telegram:direct:user42", key);
}

test "resolveSessionKey telegram group" {
    var buf: [256]u8 = undefined;
    const msg = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "1",
        .sender_id = "user42",
        .chat_id = "-1001234",
        .content = "hi",
        .is_group = true,
    };
    const key = try resolveSessionKey(&buf, "main", msg);
    try std.testing.expectEqualStrings("agent:main:telegram:group:-1001234", key);
}

test "resolveSessionKey discord DM" {
    var buf: [256]u8 = undefined;
    const msg = plugin.IncomingMessage{
        .channel = .discord,
        .message_id = "1",
        .sender_id = "user-disc",
        .chat_id = "dm-ch",
        .content = "hi",
        .is_group = false,
    };
    const key = try resolveSessionKey(&buf, "helper", msg);
    try std.testing.expectEqualStrings("agent:helper:discord:direct:user-disc", key);
}

test "resolveSessionKey discord guild" {
    var buf: [256]u8 = undefined;
    const msg = plugin.IncomingMessage{
        .channel = .discord,
        .message_id = "1",
        .sender_id = "user-disc",
        .chat_id = "guild-ch",
        .content = "hi",
        .is_group = true,
    };
    const key = try resolveSessionKey(&buf, "helper", msg);
    try std.testing.expectEqualStrings("agent:helper:discord:group:guild-ch", key);
}

test "resolveSessionKey slack" {
    var buf: [256]u8 = undefined;
    const msg = plugin.IncomingMessage{
        .channel = .slack,
        .message_id = "1",
        .sender_id = "U123",
        .chat_id = "C456",
        .content = "hi",
        .is_group = true,
    };
    const key = try resolveSessionKey(&buf, "main", msg);
    try std.testing.expectEqualStrings("agent:main:slack:group:C456", key);
}

test "resolveSessionKey whatsapp DM" {
    var buf: [256]u8 = undefined;
    const msg = plugin.IncomingMessage{
        .channel = .whatsapp,
        .message_id = "1",
        .sender_id = "15551234567",
        .chat_id = "15551234567",
        .content = "hi",
        .is_group = false,
    };
    const key = try resolveSessionKey(&buf, "main", msg);
    try std.testing.expectEqualStrings("agent:main:whatsapp:direct:15551234567", key);
}

test "resolveSessionKey signal DM" {
    var buf: [256]u8 = undefined;
    const msg = plugin.IncomingMessage{
        .channel = .signal,
        .message_id = "1",
        .sender_id = "+15551234567",
        .chat_id = "+15551234567",
        .content = "hi",
        .is_group = false,
    };
    const key = try resolveSessionKey(&buf, "main", msg);
    try std.testing.expectEqualStrings("agent:main:signal:direct:+15551234567", key);
}

test "resolveSessionKey matrix" {
    var buf: [256]u8 = undefined;
    const msg = plugin.IncomingMessage{
        .channel = .matrix,
        .message_id = "1",
        .sender_id = "@bot:matrix.org",
        .chat_id = "!room:matrix.org",
        .content = "hi",
        .is_group = true,
    };
    const key = try resolveSessionKey(&buf, "main", msg);
    try std.testing.expectEqualStrings("agent:main:matrix:group:!room:matrix.org", key);
}

test "resolveSessionKey webchat" {
    var buf: [256]u8 = undefined;
    const msg = plugin.IncomingMessage{
        .channel = .webchat,
        .message_id = "1",
        .sender_id = "session-xyz",
        .chat_id = "session-xyz",
        .content = "hi",
        .is_group = false,
    };
    const key = try resolveSessionKey(&buf, "main", msg);
    try std.testing.expectEqualStrings("agent:main:webchat:direct:session-xyz", key);
}

// --- Agent Routing Tests ---

test "resolveAgent with multiple channel agents" {
    const allocator = std.testing.allocator;
    var agents = std.StringHashMapUnmanaged([]const u8){};
    defer agents.deinit(allocator);
    try agents.put(allocator, "telegram", "tg-agent");
    try agents.put(allocator, "discord", "dc-agent");
    try agents.put(allocator, "slack", "sl-agent");

    const config = RouteConfig{
        .default_agent = "fallback",
        .channel_agents = agents,
    };
    try std.testing.expectEqualStrings("tg-agent", resolveAgent("telegram", &config));
    try std.testing.expectEqualStrings("dc-agent", resolveAgent("discord", &config));
    try std.testing.expectEqualStrings("sl-agent", resolveAgent("slack", &config));
    try std.testing.expectEqualStrings("fallback", resolveAgent("whatsapp", &config));
    try std.testing.expectEqualStrings("fallback", resolveAgent("signal", &config));
    try std.testing.expectEqualStrings("fallback", resolveAgent("matrix", &config));
}

test "resolveAgent unknown channel falls back to default" {
    const config = RouteConfig{ .default_agent = "default-bot" };
    try std.testing.expectEqualStrings("default-bot", resolveAgent("unknown", &config));
}

test "resolveAgent empty channel name falls back" {
    const config = RouteConfig{};
    try std.testing.expectEqualStrings("main", resolveAgent("", &config));
}

// --- RouteConfig Defaults ---

test "RouteConfig defaults" {
    const config = RouteConfig{};
    try std.testing.expectEqualStrings("main", config.default_agent);
    try std.testing.expectEqual(@as(usize, 0), config.channel_agents.count());
}

// --- Scope Tests ---

test "Scope direct label" {
    try std.testing.expectEqualStrings("direct", Scope.direct.label());
}

test "Scope group label" {
    try std.testing.expectEqualStrings("group", Scope.group.label());
}
