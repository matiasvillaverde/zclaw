const std = @import("std");
const plugin = @import("plugin.zig");

// --- Slack API Constants ---

pub const API_BASE_URL = "https://slack.com/api";
pub const SOCKET_MODE_URL = "wss://wss-primary.slack.com";

// --- Slack Config ---

pub const SlackConfig = struct {
    bot_token: []const u8, // xoxb-...
    app_token: ?[]const u8 = null, // xapp-... for Socket Mode
    signing_secret: ?[]const u8 = null,
    default_channel: ?[]const u8 = null,
};

// --- Slack Event Types ---

pub const EventType = enum {
    message,
    app_mention,
    reaction_added,
    reaction_removed,
    channel_created,
    member_joined_channel,
    url_verification,

    pub fn fromString(s: []const u8) ?EventType {
        const map = std.StaticStringMap(EventType).initComptime(.{
            .{ "message", .message },
            .{ "app_mention", .app_mention },
            .{ "reaction_added", .reaction_added },
            .{ "reaction_removed", .reaction_removed },
            .{ "channel_created", .channel_created },
            .{ "member_joined_channel", .member_joined_channel },
            .{ "url_verification", .url_verification },
        });
        return map.get(s);
    }

    pub fn label(self: EventType) []const u8 {
        return switch (self) {
            .message => "message",
            .app_mention => "app_mention",
            .reaction_added => "reaction_added",
            .reaction_removed => "reaction_removed",
            .channel_created => "channel_created",
            .member_joined_channel => "member_joined_channel",
            .url_verification => "url_verification",
        };
    }
};

// --- API URL Builder ---

pub fn buildApiUrl(buf: []u8, method: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll(API_BASE_URL);
    try w.writeAll("/");
    try w.writeAll(method);
    return fbs.getWritten();
}

// --- Request Builders ---

pub fn buildPostMessageBody(buf: []u8, channel: []const u8, text: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("{\"channel\":\"");
    try w.writeAll(channel);
    try w.writeAll("\",\"text\":\"");
    try writeJsonEscaped(w, text);
    try w.writeAll("\"}");
    return fbs.getWritten();
}

pub fn buildAuthHeader(buf: []u8, token: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("Bearer ");
    try w.writeAll(token);
    return fbs.getWritten();
}

pub fn buildSocketModeAck(buf: []u8, envelope_id: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("{\"envelope_id\":\"");
    try w.writeAll(envelope_id);
    try w.writeAll("\"}");
    return fbs.getWritten();
}

// --- Response Parsing ---

pub fn extractText(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"text\":\"");
}

pub fn extractChannel(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"channel\":\"");
}

pub fn extractUser(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"user\":\"");
}

pub fn extractEventType(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"type\":\"");
}

pub fn extractSubtype(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"subtype\":\"");
}

pub fn extractTs(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"ts\":\"");
}

pub fn extractThreadTs(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"thread_ts\":\"");
}

pub fn extractEnvelopeId(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"envelope_id\":\"");
}

pub fn extractBotId(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"bot_id\":\"");
}

/// Check if a message is from a bot.
pub fn isBot(json: []const u8) bool {
    return extractBotId(json) != null or extractSubtype(json) != null;
}

// --- Incoming Message Parser ---

pub fn parseIncomingMessage(json: []const u8) ?plugin.IncomingMessage {
    const text = extractText(json) orelse return null;
    const channel = extractChannel(json) orelse return null;
    const user = extractUser(json) orelse return null;

    return .{
        .channel = .slack,
        .message_id = extractTs(json) orelse "",
        .sender_id = user,
        .chat_id = channel,
        .content = text,
        .reply_to_id = extractThreadTs(json),
        .is_group = true, // Slack channels are always group-like
    };
}

// --- Helpers ---

fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}

fn extractJsonString(json: []const u8, prefix: []const u8) ?[]const u8 {
    const start_idx = std.mem.indexOf(u8, json, prefix) orelse return null;
    const value_start = start_idx + prefix.len;
    if (value_start >= json.len) return null;
    var i = value_start;
    while (i < json.len) : (i += 1) {
        if (json[i] == '"' and (i == value_start or json[i - 1] != '\\')) {
            return json[value_start..i];
        }
    }
    return null;
}

// --- Tests ---

test "buildApiUrl" {
    var buf: [256]u8 = undefined;
    const url = try buildApiUrl(&buf, "chat.postMessage");
    try std.testing.expectEqualStrings("https://slack.com/api/chat.postMessage", url);
}

test "buildPostMessageBody" {
    var buf: [1024]u8 = undefined;
    const body = try buildPostMessageBody(&buf, "C12345", "Hello Slack!");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"channel\":\"C12345\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":\"Hello Slack!\"") != null);
}

test "buildAuthHeader" {
    var buf: [256]u8 = undefined;
    const header = try buildAuthHeader(&buf, "xoxb-token");
    try std.testing.expectEqualStrings("Bearer xoxb-token", header);
}

test "buildSocketModeAck" {
    var buf: [256]u8 = undefined;
    const ack = try buildSocketModeAck(&buf, "env-123");
    try std.testing.expect(std.mem.indexOf(u8, ack, "\"envelope_id\":\"env-123\"") != null);
}

test "extractText" {
    const json = "{\"text\":\"Hello world\",\"channel\":\"C1\"}";
    try std.testing.expectEqualStrings("Hello world", extractText(json).?);
}

test "extractChannel" {
    const json = "{\"channel\":\"C12345\"}";
    try std.testing.expectEqualStrings("C12345", extractChannel(json).?);
}

test "extractUser" {
    const json = "{\"user\":\"U67890\"}";
    try std.testing.expectEqualStrings("U67890", extractUser(json).?);
}

test "extractTs" {
    const json = "{\"ts\":\"1234567890.123456\"}";
    try std.testing.expectEqualStrings("1234567890.123456", extractTs(json).?);
}

test "extractThreadTs" {
    const json = "{\"thread_ts\":\"1234567890.000000\"}";
    try std.testing.expectEqualStrings("1234567890.000000", extractThreadTs(json).?);
}

test "extractThreadTs missing" {
    const json = "{\"ts\":\"1234567890.123456\"}";
    try std.testing.expect(extractThreadTs(json) == null);
}

test "extractEnvelopeId" {
    const json = "{\"envelope_id\":\"abc-123\"}";
    try std.testing.expectEqualStrings("abc-123", extractEnvelopeId(json).?);
}

test "isBot true" {
    const json = "{\"user\":\"U1\",\"bot_id\":\"B123\",\"text\":\"hi\"}";
    try std.testing.expect(isBot(json));
}

test "isBot subtype" {
    const json = "{\"user\":\"U1\",\"subtype\":\"bot_message\",\"text\":\"hi\"}";
    try std.testing.expect(isBot(json));
}

test "isBot false" {
    const json = "{\"user\":\"U1\",\"text\":\"hi\",\"channel\":\"C1\"}";
    try std.testing.expect(!isBot(json));
}

test "parseIncomingMessage" {
    const json = "{\"text\":\"Hello\",\"channel\":\"C123\",\"user\":\"U456\",\"ts\":\"1234.5678\"}";
    const msg = parseIncomingMessage(json).?;
    try std.testing.expectEqual(plugin.ChannelType.slack, msg.channel);
    try std.testing.expectEqualStrings("Hello", msg.content);
    try std.testing.expectEqualStrings("C123", msg.chat_id);
    try std.testing.expectEqualStrings("U456", msg.sender_id);
    try std.testing.expect(msg.is_group);
}

test "parseIncomingMessage with thread" {
    const json = "{\"text\":\"reply\",\"channel\":\"C1\",\"user\":\"U1\",\"thread_ts\":\"1111.0000\"}";
    const msg = parseIncomingMessage(json).?;
    try std.testing.expectEqualStrings("1111.0000", msg.reply_to_id.?);
}

test "parseIncomingMessage no text" {
    const json = "{\"channel\":\"C1\",\"user\":\"U1\"}";
    try std.testing.expect(parseIncomingMessage(json) == null);
}

test "parseIncomingMessage no channel" {
    const json = "{\"text\":\"hi\",\"user\":\"U1\"}";
    try std.testing.expect(parseIncomingMessage(json) == null);
}

test "EventType fromString and label" {
    try std.testing.expectEqual(EventType.message, EventType.fromString("message").?);
    try std.testing.expectEqual(EventType.app_mention, EventType.fromString("app_mention").?);
    try std.testing.expectEqualStrings("message", EventType.message.label());
    try std.testing.expectEqual(@as(?EventType, null), EventType.fromString("unknown"));
}

test "SlackConfig defaults" {
    const config = SlackConfig{ .bot_token = "xoxb-test" };
    try std.testing.expect(config.app_token == null);
    try std.testing.expect(config.signing_secret == null);
    try std.testing.expect(config.default_channel == null);
}
