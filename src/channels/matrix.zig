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

// ======================================================================
// Additional comprehensive tests
// ======================================================================

// --- API URL Builder Tests ---

test "buildApiUrl login endpoint" {
    var buf: [256]u8 = undefined;
    const url = try buildApiUrl(&buf, DEFAULT_HOMESERVER, "/login");
    try std.testing.expectEqualStrings("https://matrix.org/_matrix/client/v3/login", url);
}

test "buildApiUrl rooms endpoint" {
    var buf: [512]u8 = undefined;
    const url = try buildApiUrl(&buf, DEFAULT_HOMESERVER, "/rooms/!abc:matrix.org/messages");
    try std.testing.expect(std.mem.indexOf(u8, url, "/rooms/!abc:matrix.org/messages") != null);
}

test "buildApiUrl joined_rooms endpoint" {
    var buf: [256]u8 = undefined;
    const url = try buildApiUrl(&buf, DEFAULT_HOMESERVER, "/joined_rooms");
    try std.testing.expectEqualStrings("https://matrix.org/_matrix/client/v3/joined_rooms", url);
}

test "buildApiUrl custom homeserver" {
    var buf: [256]u8 = undefined;
    const url = try buildApiUrl(&buf, "https://matrix.example.com", "/sync");
    try std.testing.expectEqualStrings("https://matrix.example.com/_matrix/client/v3/sync", url);
}

test "buildApiUrl buffer too small" {
    var buf: [5]u8 = undefined;
    const result = buildApiUrl(&buf, DEFAULT_HOMESERVER, "/login");
    try std.testing.expectError(error.NoSpaceLeft, result);
}

// --- Sync URL Tests ---

test "buildSyncUrl with custom timeout" {
    var buf: [512]u8 = undefined;
    const url = try buildSyncUrl(&buf, DEFAULT_HOMESERVER, null, 60000);
    try std.testing.expect(std.mem.indexOf(u8, url, "timeout=60000") != null);
}

test "buildSyncUrl with zero timeout" {
    var buf: [512]u8 = undefined;
    const url = try buildSyncUrl(&buf, DEFAULT_HOMESERVER, null, 0);
    try std.testing.expect(std.mem.indexOf(u8, url, "timeout=0") != null);
}

test "buildSyncUrl with since token" {
    var buf: [512]u8 = undefined;
    const url = try buildSyncUrl(&buf, DEFAULT_HOMESERVER, "s123_456_789", 30000);
    try std.testing.expect(std.mem.indexOf(u8, url, "&since=s123_456_789") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "timeout=30000") != null);
}

test "buildSyncUrl custom homeserver with since" {
    var buf: [512]u8 = undefined;
    const url = try buildSyncUrl(&buf, "https://matrix.example.com", "s1", 5000);
    try std.testing.expect(std.mem.startsWith(u8, url, "https://matrix.example.com"));
    try std.testing.expect(std.mem.indexOf(u8, url, "&since=s1") != null);
}

// --- Send Message Body Tests ---

test "buildSendMessageBody emote" {
    var buf: [512]u8 = undefined;
    const body = try buildSendMessageBody(&buf, .emote, "waves");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"msgtype\":\"m.emote\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"body\":\"waves\"") != null);
}

test "buildSendMessageBody image" {
    var buf: [512]u8 = undefined;
    const body = try buildSendMessageBody(&buf, .image, "photo.jpg");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"msgtype\":\"m.image\"") != null);
}

test "buildSendMessageBody file" {
    var buf: [512]u8 = undefined;
    const body = try buildSendMessageBody(&buf, .file, "document.pdf");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"msgtype\":\"m.file\"") != null);
}

test "buildSendMessageBody audio" {
    var buf: [512]u8 = undefined;
    const body = try buildSendMessageBody(&buf, .audio, "voice.ogg");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"msgtype\":\"m.audio\"") != null);
}

test "buildSendMessageBody video" {
    var buf: [512]u8 = undefined;
    const body = try buildSendMessageBody(&buf, .video, "clip.mp4");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"msgtype\":\"m.video\"") != null);
}

test "buildSendMessageBody escapes quotes" {
    var buf: [512]u8 = undefined;
    const body = try buildSendMessageBody(&buf, .text, "He said \"hello\"");
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"hello\\\"") != null);
}

test "buildSendMessageBody escapes newlines" {
    var buf: [512]u8 = undefined;
    const body = try buildSendMessageBody(&buf, .text, "line1\nline2");
    try std.testing.expect(std.mem.indexOf(u8, body, "\\n") != null);
}

test "buildSendMessageBody empty body" {
    var buf: [512]u8 = undefined;
    const body = try buildSendMessageBody(&buf, .text, "");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"body\":\"\"") != null);
}

// --- Send URL Tests ---

test "buildSendUrl with room ID" {
    var buf: [512]u8 = undefined;
    const url = try buildSendUrl(&buf, DEFAULT_HOMESERVER, "!abc123:matrix.org", "txn-001");
    try std.testing.expect(std.mem.indexOf(u8, url, "/rooms/!abc123:matrix.org/send/m.room.message/txn-001") != null);
}

test "buildSendUrl with custom homeserver" {
    var buf: [512]u8 = undefined;
    const url = try buildSendUrl(&buf, "https://matrix.example.com", "!room:example.com", "t1");
    try std.testing.expect(std.mem.startsWith(u8, url, "https://matrix.example.com"));
}

// --- Auth Header Tests ---

test "buildAuthHeader with syt token" {
    var buf: [256]u8 = undefined;
    const header = try buildAuthHeader(&buf, "syt_abc123def456");
    try std.testing.expectEqualStrings("Bearer syt_abc123def456", header);
}

// --- Join Room Body Tests ---

test "buildJoinRoomBody returns empty JSON" {
    var buf: [32]u8 = undefined;
    const body = try buildJoinRoomBody(&buf);
    try std.testing.expectEqualStrings("{}", body);
}

// --- Response Parsing Tests ---

test "extractEventType m.room.member" {
    const json = "{\"type\":\"m.room.member\",\"content\":{\"membership\":\"join\"}}";
    try std.testing.expectEqualStrings("m.room.member", extractEventType(json).?);
}

test "extractEventType m.room.name" {
    const json = "{\"type\":\"m.room.name\",\"content\":{\"name\":\"Test Room\"}}";
    try std.testing.expectEqualStrings("m.room.name", extractEventType(json).?);
}

test "extractEventType m.room.topic" {
    const json = "{\"type\":\"m.room.topic\",\"content\":{\"topic\":\"Discussion\"}}";
    try std.testing.expectEqualStrings("m.room.topic", extractEventType(json).?);
}

test "extractEventType m.room.redaction" {
    const json = "{\"type\":\"m.room.redaction\",\"redacts\":\"$evt1\"}";
    try std.testing.expectEqualStrings("m.room.redaction", extractEventType(json).?);
}

test "extractEventType m.room.create" {
    const json = "{\"type\":\"m.room.create\",\"content\":{\"creator\":\"@admin:matrix.org\"}}";
    try std.testing.expectEqualStrings("m.room.create", extractEventType(json).?);
}

test "extractEventType m.room.encrypted" {
    const json = "{\"type\":\"m.room.encrypted\",\"content\":{\"algorithm\":\"m.megolm.v1.aes-sha2\"}}";
    try std.testing.expectEqualStrings("m.room.encrypted", extractEventType(json).?);
}

test "extractEventType missing" {
    const json = "{\"content\":{\"body\":\"hi\"}}";
    try std.testing.expect(extractEventType(json) == null);
}

test "extractMsgtype m.notice" {
    const json = "{\"content\":{\"msgtype\":\"m.notice\",\"body\":\"System notice\"}}";
    try std.testing.expectEqualStrings("m.notice", extractMsgtype(json).?);
}

test "extractMsgtype m.emote" {
    const json = "{\"content\":{\"msgtype\":\"m.emote\",\"body\":\"waves\"}}";
    try std.testing.expectEqualStrings("m.emote", extractMsgtype(json).?);
}

test "extractMsgtype m.image" {
    const json = "{\"content\":{\"msgtype\":\"m.image\",\"body\":\"photo.jpg\"}}";
    try std.testing.expectEqualStrings("m.image", extractMsgtype(json).?);
}

test "extractMsgtype missing" {
    const json = "{\"content\":{\"body\":\"hi\"}}";
    try std.testing.expect(extractMsgtype(json) == null);
}

test "extractBody from message content" {
    const json = "{\"content\":{\"body\":\"Test message body\"}}";
    try std.testing.expectEqualStrings("Test message body", extractBody(json).?);
}

test "extractBody missing" {
    const json = "{\"content\":{\"msgtype\":\"m.text\"}}";
    try std.testing.expect(extractBody(json) == null);
}

test "extractSender with domain" {
    const json = "{\"sender\":\"@user:example.com\",\"content\":{}}";
    try std.testing.expectEqualStrings("@user:example.com", extractSender(json).?);
}

test "extractSender missing" {
    const json = "{\"content\":{\"body\":\"hi\"}}";
    try std.testing.expect(extractSender(json) == null);
}

test "extractRoomId with special characters" {
    const json = "{\"room_id\":\"!OGEhHVWSdvArJzumhm:matrix.org\"}";
    try std.testing.expectEqualStrings("!OGEhHVWSdvArJzumhm:matrix.org", extractRoomId(json).?);
}

test "extractRoomId missing" {
    const json = "{\"sender\":\"@a:b\"}";
    try std.testing.expect(extractRoomId(json) == null);
}

test "extractEventId with dollar sign" {
    const json = "{\"event_id\":\"$143273582443PhrSn:example.org\"}";
    try std.testing.expectEqualStrings("$143273582443PhrSn:example.org", extractEventId(json).?);
}

test "extractEventId missing" {
    const json = "{\"sender\":\"@a:b\"}";
    try std.testing.expect(extractEventId(json) == null);
}

test "extractNextBatch typical value" {
    const json = "{\"next_batch\":\"s1234_5678_9012\",\"rooms\":{}}";
    try std.testing.expectEqualStrings("s1234_5678_9012", extractNextBatch(json).?);
}

test "extractNextBatch missing" {
    const json = "{\"rooms\":{}}";
    try std.testing.expect(extractNextBatch(json) == null);
}

// --- Incoming Message Parser Tests ---

test "parseIncomingMessage full room event" {
    const json =
        \\{"type":"m.room.message","event_id":"$evt001","sender":"@alice:matrix.org","room_id":"!room1:matrix.org","content":{"msgtype":"m.text","body":"Hello Matrix room!"}}
    ;
    const msg = parseIncomingMessage(json).?;
    try std.testing.expectEqual(plugin.ChannelType.matrix, msg.channel);
    try std.testing.expectEqualStrings("Hello Matrix room!", msg.content);
    try std.testing.expectEqualStrings("@alice:matrix.org", msg.sender_id);
    try std.testing.expectEqualStrings("!room1:matrix.org", msg.chat_id);
    try std.testing.expectEqualStrings("$evt001", msg.message_id);
    try std.testing.expect(msg.is_group);
}

test "parseIncomingMessage notice message" {
    const json = "{\"type\":\"m.room.message\",\"sender\":\"@bot:matrix.org\",\"room_id\":\"!r:m\",\"event_id\":\"$e1\",\"content\":{\"msgtype\":\"m.notice\",\"body\":\"System notice\"}}";
    const msg = parseIncomingMessage(json).?;
    try std.testing.expectEqualStrings("System notice", msg.content);
}

test "parseIncomingMessage missing room_id" {
    const json = "{\"type\":\"m.room.message\",\"sender\":\"@a:b\",\"content\":{\"body\":\"hi\"}}";
    try std.testing.expect(parseIncomingMessage(json) == null);
}

test "parseIncomingMessage member event has no body" {
    const json = "{\"type\":\"m.room.member\",\"sender\":\"@a:b\",\"room_id\":\"!r:b\",\"content\":{\"membership\":\"join\"}}";
    try std.testing.expect(parseIncomingMessage(json) == null);
}

test "parseIncomingMessage redaction event has no body" {
    const json = "{\"type\":\"m.room.redaction\",\"sender\":\"@a:b\",\"room_id\":\"!r:b\",\"redacts\":\"$old\"}";
    try std.testing.expect(parseIncomingMessage(json) == null);
}

test "parseIncomingMessage encrypted event has no body" {
    const json = "{\"type\":\"m.room.encrypted\",\"sender\":\"@a:b\",\"room_id\":\"!r:b\",\"content\":{\"algorithm\":\"m.megolm.v1.aes-sha2\"}}";
    try std.testing.expect(parseIncomingMessage(json) == null);
}

// --- Transaction ID Tests ---

test "nextTxnId increments" {
    resetTxnCounter();
    var buf1: [32]u8 = undefined;
    const id1 = nextTxnId(&buf1);
    try std.testing.expectEqualStrings("zclaw-1", id1);

    var buf2: [32]u8 = undefined;
    const id2 = nextTxnId(&buf2);
    try std.testing.expectEqualStrings("zclaw-2", id2);

    var buf3: [32]u8 = undefined;
    const id3 = nextTxnId(&buf3);
    try std.testing.expectEqualStrings("zclaw-3", id3);
}

test "resetTxnCounter resets to zero" {
    resetTxnCounter();
    var buf: [32]u8 = undefined;
    _ = nextTxnId(&buf);
    _ = nextTxnId(&buf);
    resetTxnCounter();
    var buf2: [32]u8 = undefined;
    const id = nextTxnId(&buf2);
    try std.testing.expectEqualStrings("zclaw-1", id);
}

// --- RoomEventType Tests ---

test "RoomEventType all types roundtrip" {
    const types = [_]RoomEventType{ .message, .member, .name, .topic, .create, .power_levels, .redaction };
    for (types) |t| {
        const label_str = t.label();
        const parsed = RoomEventType.fromString(label_str).?;
        try std.testing.expectEqual(t, parsed);
    }
}

test "RoomEventType fromString case sensitive" {
    try std.testing.expect(RoomEventType.fromString("M.ROOM.MESSAGE") == null);
    try std.testing.expect(RoomEventType.fromString("m.Room.Message") == null);
}

test "RoomEventType fromString empty" {
    try std.testing.expect(RoomEventType.fromString("") == null);
}

test "RoomEventType fromString partial match" {
    try std.testing.expect(RoomEventType.fromString("m.room") == null);
}

// --- MessageType Tests ---

test "MessageType all types roundtrip" {
    const types = [_]MessageType{ .text, .notice, .emote, .image, .file, .audio, .video };
    for (types) |t| {
        const label_str = t.label();
        const parsed = MessageType.fromString(label_str).?;
        try std.testing.expectEqual(t, parsed);
    }
}

test "MessageType fromString invalid" {
    try std.testing.expect(MessageType.fromString("m.sticker") == null);
    try std.testing.expect(MessageType.fromString("text") == null); // must have m. prefix
}

// --- MatrixConfig Tests ---

test "MatrixConfig with all fields" {
    const config = MatrixConfig{
        .homeserver = "https://matrix.example.com",
        .access_token = "syt_token_abc",
        .user_id = "@bot:example.com",
        .device_id = "ABCDEF",
        .sync_timeout = 60000,
    };
    try std.testing.expectEqualStrings("https://matrix.example.com", config.homeserver);
    try std.testing.expectEqualStrings("syt_token_abc", config.access_token);
    try std.testing.expectEqualStrings("@bot:example.com", config.user_id.?);
    try std.testing.expectEqualStrings("ABCDEF", config.device_id.?);
    try std.testing.expectEqual(@as(u32, 60000), config.sync_timeout);
}

test "MatrixConfig optional fields default null" {
    const config = MatrixConfig{ .access_token = "tok" };
    try std.testing.expect(config.user_id == null);
    try std.testing.expect(config.device_id == null);
}
