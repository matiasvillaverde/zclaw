const std = @import("std");
const plugin = @import("plugin.zig");

// --- Matrix Client-Server API Constants ---

pub const DEFAULT_HOMESERVER = "https://matrix.org";
pub const CLIENT_API_PREFIX = "/_matrix/client/v3";
pub const SYNC_TIMEOUT: u32 = 30000; // 30 seconds

// --- Matrix Config ---

pub const MatrixConfig = struct {
    homeserver: []const u8 = DEFAULT_HOMESERVER,
    access_token: []const u8,
    user_id: ?[]const u8 = null,
    device_id: ?[]const u8 = null,
    sync_timeout: u32 = SYNC_TIMEOUT,
};

// --- Room Event Types ---

pub const RoomEventType = enum {
    message,
    member,
    name,
    topic,
    create,
    power_levels,
    redaction,

    pub fn label(self: RoomEventType) []const u8 {
        return switch (self) {
            .message => "m.room.message",
            .member => "m.room.member",
            .name => "m.room.name",
            .topic => "m.room.topic",
            .create => "m.room.create",
            .power_levels => "m.room.power_levels",
            .redaction => "m.room.redaction",
        };
    }

    pub fn fromString(s: []const u8) ?RoomEventType {
        const map = std.StaticStringMap(RoomEventType).initComptime(.{
            .{ "m.room.message", .message },
            .{ "m.room.member", .member },
            .{ "m.room.name", .name },
            .{ "m.room.topic", .topic },
            .{ "m.room.create", .create },
            .{ "m.room.power_levels", .power_levels },
            .{ "m.room.redaction", .redaction },
        });
        return map.get(s);
    }
};

// --- Message Types (msgtype) ---

pub const MessageType = enum {
    text,
    notice,
    emote,
    image,
    file,
    audio,
    video,

    pub fn label(self: MessageType) []const u8 {
        return switch (self) {
            .text => "m.text",
            .notice => "m.notice",
            .emote => "m.emote",
            .image => "m.image",
            .file => "m.file",
            .audio => "m.audio",
            .video => "m.video",
        };
    }

    pub fn fromString(s: []const u8) ?MessageType {
        const map = std.StaticStringMap(MessageType).initComptime(.{
            .{ "m.text", .text },
            .{ "m.notice", .notice },
            .{ "m.emote", .emote },
            .{ "m.image", .image },
            .{ "m.file", .file },
            .{ "m.audio", .audio },
            .{ "m.video", .video },
        });
        return map.get(s);
    }
};

// --- API URL Builder ---

pub fn buildApiUrl(buf: []u8, homeserver: []const u8, endpoint: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll(homeserver);
    try w.writeAll(CLIENT_API_PREFIX);
    try w.writeAll(endpoint);
    return fbs.getWritten();
}

pub fn buildSyncUrl(buf: []u8, homeserver: []const u8, since: ?[]const u8, timeout: u32) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll(homeserver);
    try w.writeAll(CLIENT_API_PREFIX);
    try w.writeAll("/sync?timeout=");
    try std.fmt.format(w, "{d}", .{timeout});
    if (since) |s| {
        try w.writeAll("&since=");
        try w.writeAll(s);
    }
    return fbs.getWritten();
}

// --- Request Builders ---

pub fn buildSendMessageBody(buf: []u8, msgtype: MessageType, body: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("{\"msgtype\":\"");
    try w.writeAll(msgtype.label());
    try w.writeAll("\",\"body\":\"");
    try writeJsonEscaped(w, body);
    try w.writeAll("\"}");
    return fbs.getWritten();
}

pub fn buildSendUrl(buf: []u8, homeserver: []const u8, room_id: []const u8, txn_id: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll(homeserver);
    try w.writeAll(CLIENT_API_PREFIX);
    try w.writeAll("/rooms/");
    try w.writeAll(room_id);
    try w.writeAll("/send/m.room.message/");
    try w.writeAll(txn_id);
    return fbs.getWritten();
}

pub fn buildAuthHeader(buf: []u8, token: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("Bearer ");
    try w.writeAll(token);
    return fbs.getWritten();
}

pub fn buildJoinRoomBody(buf: []u8) ![]const u8 {
    _ = buf;
    return "{}";
}

// --- Response Parsing ---

pub fn extractEventType(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"type\":\"");
}

pub fn extractMsgtype(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"msgtype\":\"");
}

pub fn extractBody(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"body\":\"");
}

pub fn extractSender(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"sender\":\"");
}

pub fn extractRoomId(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"room_id\":\"");
}

pub fn extractEventId(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"event_id\":\"");
}

pub fn extractNextBatch(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"next_batch\":\"");
}

// --- Incoming Message Parser ---

pub fn parseIncomingMessage(json: []const u8) ?plugin.IncomingMessage {
    const body = extractBody(json) orelse return null;
    const sender = extractSender(json) orelse return null;
    const room_id = extractRoomId(json) orelse return null;

    return .{
        .channel = .matrix,
        .message_id = extractEventId(json) orelse "",
        .sender_id = sender,
        .chat_id = room_id,
        .content = body,
        .is_group = true, // Matrix rooms are inherently group-like
    };
}

// --- Transaction ID Generator ---

var txn_counter: u32 = 0;

pub fn nextTxnId(buf: []u8) []const u8 {
    txn_counter += 1;
    var fbs = std.io.fixedBufferStream(buf);
    std.fmt.format(fbs.writer(), "zclaw-{d}", .{txn_counter}) catch return "zclaw-0";
    return fbs.getWritten();
}

pub fn resetTxnCounter() void {
    txn_counter = 0;
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
    const url = try buildApiUrl(&buf, DEFAULT_HOMESERVER, "/login");
    try std.testing.expectEqualStrings("https://matrix.org/_matrix/client/v3/login", url);
}

test "buildSyncUrl no since" {
    var buf: [512]u8 = undefined;
    const url = try buildSyncUrl(&buf, DEFAULT_HOMESERVER, null, 30000);
    try std.testing.expect(std.mem.indexOf(u8, url, "/sync?timeout=30000") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "since") == null);
}

test "buildSyncUrl with since" {
    var buf: [512]u8 = undefined;
    const url = try buildSyncUrl(&buf, DEFAULT_HOMESERVER, "s72594_4483_1934", 30000);
    try std.testing.expect(std.mem.indexOf(u8, url, "&since=s72594_4483_1934") != null);
}

test "buildSendMessageBody text" {
    var buf: [512]u8 = undefined;
    const body = try buildSendMessageBody(&buf, .text, "Hello Matrix!");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"msgtype\":\"m.text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"body\":\"Hello Matrix!\"") != null);
}

test "buildSendMessageBody notice" {
    var buf: [512]u8 = undefined;
    const body = try buildSendMessageBody(&buf, .notice, "Bot reply");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"msgtype\":\"m.notice\"") != null);
}

test "buildSendUrl" {
    var buf: [512]u8 = undefined;
    const url = try buildSendUrl(&buf, DEFAULT_HOMESERVER, "!room:matrix.org", "txn1");
    try std.testing.expect(std.mem.indexOf(u8, url, "/rooms/!room:matrix.org/send/m.room.message/txn1") != null);
}

test "buildAuthHeader" {
    var buf: [256]u8 = undefined;
    const header = try buildAuthHeader(&buf, "syt_token_here");
    try std.testing.expectEqualStrings("Bearer syt_token_here", header);
}

test "extractEventType" {
    const json = "{\"type\":\"m.room.message\",\"content\":{}}";
    try std.testing.expectEqualStrings("m.room.message", extractEventType(json).?);
}

test "extractMsgtype" {
    const json = "{\"content\":{\"msgtype\":\"m.text\",\"body\":\"hi\"}}";
    try std.testing.expectEqualStrings("m.text", extractMsgtype(json).?);
}

test "extractBody" {
    const json = "{\"content\":{\"body\":\"Hello world\"}}";
    try std.testing.expectEqualStrings("Hello world", extractBody(json).?);
}

test "extractSender" {
    const json = "{\"sender\":\"@alice:matrix.org\"}";
    try std.testing.expectEqualStrings("@alice:matrix.org", extractSender(json).?);
}

test "extractRoomId" {
    const json = "{\"room_id\":\"!abc:matrix.org\"}";
    try std.testing.expectEqualStrings("!abc:matrix.org", extractRoomId(json).?);
}

test "extractEventId" {
    const json = "{\"event_id\":\"$evt123\"}";
    try std.testing.expectEqualStrings("$evt123", extractEventId(json).?);
}

test "extractNextBatch" {
    const json = "{\"next_batch\":\"s72594_4483_1934\"}";
    try std.testing.expectEqualStrings("s72594_4483_1934", extractNextBatch(json).?);
}

test "parseIncomingMessage" {
    const json = "{\"type\":\"m.room.message\",\"sender\":\"@bob:matrix.org\",\"room_id\":\"!room:matrix.org\",\"event_id\":\"$e1\",\"content\":{\"msgtype\":\"m.text\",\"body\":\"Hey!\"}}";
    const msg = parseIncomingMessage(json).?;
    try std.testing.expectEqual(plugin.ChannelType.matrix, msg.channel);
    try std.testing.expectEqualStrings("Hey!", msg.content);
    try std.testing.expectEqualStrings("@bob:matrix.org", msg.sender_id);
    try std.testing.expectEqualStrings("!room:matrix.org", msg.chat_id);
    try std.testing.expect(msg.is_group);
}

test "parseIncomingMessage no body" {
    const json = "{\"type\":\"m.room.message\",\"sender\":\"@a:b\",\"room_id\":\"!r:b\"}";
    try std.testing.expect(parseIncomingMessage(json) == null);
}

test "parseIncomingMessage no sender" {
    const json = "{\"content\":{\"body\":\"hi\"},\"room_id\":\"!r:b\"}";
    try std.testing.expect(parseIncomingMessage(json) == null);
}

test "nextTxnId" {
    resetTxnCounter();
    var buf: [32]u8 = undefined;
    const id1 = nextTxnId(&buf);
    try std.testing.expectEqualStrings("zclaw-1", id1);

    var buf2: [32]u8 = undefined;
    const id2 = nextTxnId(&buf2);
    try std.testing.expectEqualStrings("zclaw-2", id2);
}

test "RoomEventType fromString and label" {
    try std.testing.expectEqual(RoomEventType.message, RoomEventType.fromString("m.room.message").?);
    try std.testing.expectEqual(RoomEventType.member, RoomEventType.fromString("m.room.member").?);
    try std.testing.expectEqualStrings("m.room.message", RoomEventType.message.label());
    try std.testing.expectEqual(@as(?RoomEventType, null), RoomEventType.fromString("unknown"));
}

test "MessageType fromString and label" {
    try std.testing.expectEqual(MessageType.text, MessageType.fromString("m.text").?);
    try std.testing.expectEqual(MessageType.notice, MessageType.fromString("m.notice").?);
    try std.testing.expectEqualStrings("m.text", MessageType.text.label());
    try std.testing.expectEqual(@as(?MessageType, null), MessageType.fromString("xyz"));
}

test "MatrixConfig defaults" {
    const config = MatrixConfig{ .access_token = "token" };
    try std.testing.expectEqualStrings(DEFAULT_HOMESERVER, config.homeserver);
    try std.testing.expectEqual(@as(u32, 30000), config.sync_timeout);
    try std.testing.expect(config.user_id == null);
}
