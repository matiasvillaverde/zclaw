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

// ======================================================================
// Additional comprehensive tests
// ======================================================================

// --- API URL Builder Tests ---

test "buildApiUrl chat.update" {
    var buf: [256]u8 = undefined;
    const url = try buildApiUrl(&buf, "chat.update");
    try std.testing.expectEqualStrings("https://slack.com/api/chat.update", url);
}

test "buildApiUrl conversations.info" {
    var buf: [256]u8 = undefined;
    const url = try buildApiUrl(&buf, "conversations.info");
    try std.testing.expectEqualStrings("https://slack.com/api/conversations.info", url);
}

test "buildApiUrl users.info" {
    var buf: [256]u8 = undefined;
    const url = try buildApiUrl(&buf, "users.info");
    try std.testing.expectEqualStrings("https://slack.com/api/users.info", url);
}

test "buildApiUrl reactions.add" {
    var buf: [256]u8 = undefined;
    const url = try buildApiUrl(&buf, "reactions.add");
    try std.testing.expectEqualStrings("https://slack.com/api/reactions.add", url);
}

test "buildApiUrl files.upload" {
    var buf: [256]u8 = undefined;
    const url = try buildApiUrl(&buf, "files.upload");
    try std.testing.expectEqualStrings("https://slack.com/api/files.upload", url);
}

test "buildApiUrl buffer too small" {
    var buf: [5]u8 = undefined;
    const result = buildApiUrl(&buf, "chat.postMessage");
    try std.testing.expectError(error.NoSpaceLeft, result);
}

// --- Post Message Body Tests ---

test "buildPostMessageBody escapes quotes" {
    var buf: [1024]u8 = undefined;
    const body = try buildPostMessageBody(&buf, "C123", "He said \"hello\"");
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"hello\\\"") != null);
}

test "buildPostMessageBody escapes newlines" {
    var buf: [1024]u8 = undefined;
    const body = try buildPostMessageBody(&buf, "C123", "line1\nline2");
    try std.testing.expect(std.mem.indexOf(u8, body, "\\n") != null);
}

test "buildPostMessageBody escapes backslash" {
    var buf: [1024]u8 = undefined;
    const body = try buildPostMessageBody(&buf, "C123", "a\\b");
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\\") != null);
}

test "buildPostMessageBody empty text" {
    var buf: [1024]u8 = undefined;
    const body = try buildPostMessageBody(&buf, "C123", "");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":\"\"") != null);
}

test "buildPostMessageBody with DM channel" {
    var buf: [1024]u8 = undefined;
    const body = try buildPostMessageBody(&buf, "D0123456789", "DM message");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"channel\":\"D0123456789\"") != null);
}

// --- Auth Header Tests ---

test "buildAuthHeader with xoxb token" {
    var buf: [256]u8 = undefined;
    const header = try buildAuthHeader(&buf, "xoxb-123-456-abcdef");
    try std.testing.expectEqualStrings("Bearer xoxb-123-456-abcdef", header);
}

test "buildAuthHeader with xapp token" {
    var buf: [256]u8 = undefined;
    const header = try buildAuthHeader(&buf, "xapp-1-A1234-5678-abc");
    try std.testing.expectEqualStrings("Bearer xapp-1-A1234-5678-abc", header);
}

// --- Socket Mode Ack Tests ---

test "buildSocketModeAck valid JSON structure" {
    var buf: [256]u8 = undefined;
    const ack = try buildSocketModeAck(&buf, "abc-def-ghi");
    try std.testing.expectEqualStrings("{\"envelope_id\":\"abc-def-ghi\"}", ack);
}

test "buildSocketModeAck long envelope id" {
    var buf: [512]u8 = undefined;
    const ack = try buildSocketModeAck(&buf, "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx");
    try std.testing.expect(std.mem.indexOf(u8, ack, "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx") != null);
}

// --- Extraction Tests ---

test "extractText from event payload" {
    const json = "{\"event\":{\"type\":\"message\",\"text\":\"Hello from Slack!\",\"channel\":\"C1\",\"user\":\"U1\"}}";
    try std.testing.expectEqualStrings("Hello from Slack!", extractText(json).?);
}

test "extractText missing" {
    const json = "{\"event\":{\"type\":\"reaction_added\"}}";
    try std.testing.expect(extractText(json) == null);
}

test "extractChannel DM channel (D prefix)" {
    const json = "{\"channel\":\"D0123456789\"}";
    try std.testing.expectEqualStrings("D0123456789", extractChannel(json).?);
}

test "extractChannel group channel (G prefix)" {
    const json = "{\"channel\":\"G0123456789\"}";
    try std.testing.expectEqualStrings("G0123456789", extractChannel(json).?);
}

test "extractChannel missing" {
    const json = "{\"user\":\"U1\",\"text\":\"hi\"}";
    try std.testing.expect(extractChannel(json) == null);
}

test "extractUser from event" {
    const json = "{\"user\":\"U0ABCDEFG\",\"text\":\"hi\"}";
    try std.testing.expectEqualStrings("U0ABCDEFG", extractUser(json).?);
}

test "extractUser missing" {
    const json = "{\"text\":\"hi\",\"channel\":\"C1\"}";
    try std.testing.expect(extractUser(json) == null);
}

test "extractEventType message" {
    const json = "{\"type\":\"message\",\"channel\":\"C1\"}";
    try std.testing.expectEqualStrings("message", extractEventType(json).?);
}

test "extractEventType url_verification" {
    const json = "{\"type\":\"url_verification\",\"challenge\":\"abc123\"}";
    try std.testing.expectEqualStrings("url_verification", extractEventType(json).?);
}

test "extractSubtype bot_message" {
    const json = "{\"subtype\":\"bot_message\",\"text\":\"automated\"}";
    try std.testing.expectEqualStrings("bot_message", extractSubtype(json).?);
}

test "extractSubtype channel_join" {
    const json = "{\"subtype\":\"channel_join\",\"user\":\"U1\"}";
    try std.testing.expectEqualStrings("channel_join", extractSubtype(json).?);
}

test "extractSubtype missing" {
    const json = "{\"text\":\"normal message\"}";
    try std.testing.expect(extractSubtype(json) == null);
}

test "extractTs from message" {
    const json = "{\"ts\":\"1700000000.000100\",\"text\":\"hi\"}";
    try std.testing.expectEqualStrings("1700000000.000100", extractTs(json).?);
}

test "extractThreadTs from threaded reply" {
    const json = "{\"ts\":\"1700000000.000200\",\"thread_ts\":\"1700000000.000100\",\"text\":\"reply\"}";
    try std.testing.expectEqualStrings("1700000000.000100", extractThreadTs(json).?);
}

test "extractEnvelopeId from socket mode event" {
    const json = "{\"envelope_id\":\"1d2e3f4g-5h6i-7j8k-9l0m-abcdef123456\",\"payload\":{}}";
    try std.testing.expectEqualStrings("1d2e3f4g-5h6i-7j8k-9l0m-abcdef123456", extractEnvelopeId(json).?);
}

test "extractBotId present" {
    const json = "{\"bot_id\":\"B0123456789\",\"text\":\"bot message\"}";
    try std.testing.expectEqualStrings("B0123456789", extractBotId(json).?);
}

test "extractBotId missing" {
    const json = "{\"user\":\"U1\",\"text\":\"human message\"}";
    try std.testing.expect(extractBotId(json) == null);
}

// --- Bot Detection Tests ---

test "isBot with both bot_id and subtype" {
    const json = "{\"bot_id\":\"B1\",\"subtype\":\"bot_message\",\"text\":\"hi\"}";
    try std.testing.expect(isBot(json));
}

test "isBot with channel_join subtype" {
    const json = "{\"subtype\":\"channel_join\",\"user\":\"U1\"}";
    // channel_join has a subtype so isBot returns true (subtype != null)
    try std.testing.expect(isBot(json));
}

test "isBot normal user message" {
    const json = "{\"user\":\"U1\",\"text\":\"hello world\",\"channel\":\"C1\",\"ts\":\"123.456\"}";
    try std.testing.expect(!isBot(json));
}

// --- Parse Incoming Message Tests ---

test "parseIncomingMessage with all fields" {
    const json = "{\"text\":\"Hello Slack!\",\"channel\":\"C0123456789\",\"user\":\"U0ABCDEFG\",\"ts\":\"1700000000.000100\",\"thread_ts\":\"1700000000.000001\"}";
    const msg = parseIncomingMessage(json).?;
    try std.testing.expectEqual(plugin.ChannelType.slack, msg.channel);
    try std.testing.expectEqualStrings("Hello Slack!", msg.content);
    try std.testing.expectEqualStrings("C0123456789", msg.chat_id);
    try std.testing.expectEqualStrings("U0ABCDEFG", msg.sender_id);
    try std.testing.expectEqualStrings("1700000000.000100", msg.message_id);
    try std.testing.expectEqualStrings("1700000000.000001", msg.reply_to_id.?);
    try std.testing.expect(msg.is_group);
}

test "parseIncomingMessage always sets is_group true" {
    const json = "{\"text\":\"hi\",\"channel\":\"D0123456789\",\"user\":\"U1\",\"ts\":\"1.0\"}";
    const msg = parseIncomingMessage(json).?;
    // Slack implementation always sets is_group = true
    try std.testing.expect(msg.is_group);
}

test "parseIncomingMessage no user" {
    const json = "{\"text\":\"hi\",\"channel\":\"C1\"}";
    try std.testing.expect(parseIncomingMessage(json) == null);
}

test "parseIncomingMessage without ts gives empty message_id" {
    const json = "{\"text\":\"hi\",\"channel\":\"C1\",\"user\":\"U1\"}";
    const msg = parseIncomingMessage(json).?;
    try std.testing.expectEqualStrings("", msg.message_id);
}

test "parseIncomingMessage without thread_ts gives null reply_to_id" {
    const json = "{\"text\":\"hi\",\"channel\":\"C1\",\"user\":\"U1\"}";
    const msg = parseIncomingMessage(json).?;
    try std.testing.expect(msg.reply_to_id == null);
}

// --- Event Type Tests ---

test "EventType fromString reaction_added" {
    try std.testing.expectEqual(EventType.reaction_added, EventType.fromString("reaction_added").?);
}

test "EventType fromString reaction_removed" {
    try std.testing.expectEqual(EventType.reaction_removed, EventType.fromString("reaction_removed").?);
}

test "EventType fromString channel_created" {
    try std.testing.expectEqual(EventType.channel_created, EventType.fromString("channel_created").?);
}

test "EventType fromString member_joined_channel" {
    try std.testing.expectEqual(EventType.member_joined_channel, EventType.fromString("member_joined_channel").?);
}

test "EventType fromString url_verification" {
    try std.testing.expectEqual(EventType.url_verification, EventType.fromString("url_verification").?);
}

test "EventType label roundtrip for all types" {
    const types = [_]EventType{ .message, .app_mention, .reaction_added, .reaction_removed, .channel_created, .member_joined_channel, .url_verification };
    for (types) |t| {
        const label_str = t.label();
        const parsed = EventType.fromString(label_str).?;
        try std.testing.expectEqual(t, parsed);
    }
}

test "EventType fromString empty string" {
    try std.testing.expect(EventType.fromString("") == null);
}

// --- SlackConfig Tests ---

test "SlackConfig with all fields" {
    const config = SlackConfig{
        .bot_token = "xoxb-123-456",
        .app_token = "xapp-1-A123-456",
        .signing_secret = "abc123def456",
        .default_channel = "C0123456789",
    };
    try std.testing.expectEqualStrings("xoxb-123-456", config.bot_token);
    try std.testing.expectEqualStrings("xapp-1-A123-456", config.app_token.?);
    try std.testing.expectEqualStrings("abc123def456", config.signing_secret.?);
    try std.testing.expectEqualStrings("C0123456789", config.default_channel.?);
}
