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
