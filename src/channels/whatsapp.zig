const std = @import("std");
const plugin = @import("plugin.zig");

// --- WhatsApp Cloud API Constants ---

pub const API_BASE_URL = "https://graph.facebook.com/v18.0";
pub const WEBHOOK_VERIFY_TOKEN_PARAM = "hub.verify_token";

// --- WhatsApp Config ---

pub const WhatsAppConfig = struct {
    phone_number_id: []const u8,
    access_token: []const u8,
    verify_token: []const u8 = "zclaw-webhook-verify",
    api_version: []const u8 = "v18.0",
};

// --- Message Types ---

pub const WaMessageType = enum {
    text,
    image,
    audio,
    video,
    document,
    location,
    sticker,
    reaction,
    interactive,

    pub fn label(self: WaMessageType) []const u8 {
        return switch (self) {
            .text => "text",
            .image => "image",
            .audio => "audio",
            .video => "video",
            .document => "document",
            .location => "location",
            .sticker => "sticker",
            .reaction => "reaction",
            .interactive => "interactive",
        };
    }

    pub fn fromString(s: []const u8) ?WaMessageType {
        const map = std.StaticStringMap(WaMessageType).initComptime(.{
            .{ "text", .text },
            .{ "image", .image },
            .{ "audio", .audio },
            .{ "video", .video },
            .{ "document", .document },
            .{ "location", .location },
            .{ "sticker", .sticker },
            .{ "reaction", .reaction },
            .{ "interactive", .interactive },
        });
        return map.get(s);
    }
};

// --- API URL Builder ---

pub fn buildApiUrl(buf: []u8, phone_number_id: []const u8, endpoint: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll(API_BASE_URL);
    try w.writeAll("/");
    try w.writeAll(phone_number_id);
    try w.writeAll("/");
    try w.writeAll(endpoint);
    return fbs.getWritten();
}

// --- Request Builders ---

pub fn buildSendTextBody(buf: []u8, to: []const u8, text: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("{\"messaging_product\":\"whatsapp\",\"to\":\"");
    try w.writeAll(to);
    try w.writeAll("\",\"type\":\"text\",\"text\":{\"body\":\"");
    try writeJsonEscaped(w, text);
    try w.writeAll("\"}}");
    return fbs.getWritten();
}

pub fn buildMarkReadBody(buf: []u8, message_id: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("{\"messaging_product\":\"whatsapp\",\"status\":\"read\",\"message_id\":\"");
    try w.writeAll(message_id);
    try w.writeAll("\"}");
    return fbs.getWritten();
}

pub fn buildReactionBody(buf: []u8, message_id: []const u8, emoji: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("{\"messaging_product\":\"whatsapp\",\"type\":\"reaction\",\"reaction\":{\"message_id\":\"");
    try w.writeAll(message_id);
    try w.writeAll("\",\"emoji\":\"");
    try w.writeAll(emoji);
    try w.writeAll("\"}}");
    return fbs.getWritten();
}

// --- Webhook Verification ---

pub fn verifyWebhook(mode: []const u8, token: []const u8, challenge: []const u8, expected_token: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, mode, "subscribe")) return null;
    if (!std.mem.eql(u8, token, expected_token)) return null;
    return challenge;
}

// --- Response Parsing ---

pub fn extractMessageText(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"body\":\"");
}

pub fn extractFrom(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"from\":\"");
}

pub fn extractWamid(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"id\":\"wamid.");
}

pub fn extractMessageId(json: []const u8) ?[]const u8 {
    // Look for "id":"wamid..." pattern
    if (std.mem.indexOf(u8, json, "\"id\":\"wamid.")) |start| {
        const value_start = start + "\"id\":\"".len;
        var i = value_start;
        while (i < json.len) : (i += 1) {
            if (json[i] == '"') return json[value_start..i];
        }
    }
    // Fallback to any "id" field
    return extractJsonString(json, "\"id\":\"");
}

pub fn extractMessageType(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"type\":\"");
}

pub fn extractDisplayPhoneNumber(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"display_phone_number\":\"");
}

pub fn extractProfileName(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"name\":\"");
}

// --- Group Detection ---

/// Detect group messages by checking for the "participant" field.
/// In WhatsApp Cloud API, group messages include a "participant" field.
pub fn isGroupMessage(json: []const u8) bool {
    return std.mem.indexOf(u8, json, "\"participant\":\"") != null;
}

// --- Incoming Message Parser ---

pub fn parseIncomingMessage(json: []const u8) ?plugin.IncomingMessage {
    const text = extractMessageText(json) orelse return null;
    const from = extractFrom(json) orelse return null;

    return .{
        .channel = .whatsapp,
        .message_id = extractMessageId(json) orelse "",
        .sender_id = from,
        .sender_name = extractProfileName(json),
        .chat_id = from, // WhatsApp DMs use sender as chat ID
        .content = text,
        .is_group = isGroupMessage(json),
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
    const url = try buildApiUrl(&buf, "123456", "messages");
    try std.testing.expectEqualStrings("https://graph.facebook.com/v18.0/123456/messages", url);
}

test "buildSendTextBody" {
    var buf: [1024]u8 = undefined;
    const body = try buildSendTextBody(&buf, "1234567890", "Hello WhatsApp!");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"messaging_product\":\"whatsapp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"to\":\"1234567890\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"body\":\"Hello WhatsApp!\"") != null);
}

test "buildMarkReadBody" {
    var buf: [256]u8 = undefined;
    const body = try buildMarkReadBody(&buf, "wamid.abc123");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"status\":\"read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"message_id\":\"wamid.abc123\"") != null);
}

test "buildReactionBody" {
    var buf: [256]u8 = undefined;
    const body = try buildReactionBody(&buf, "wamid.abc", "👍");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"reaction\"") != null);
}

test "verifyWebhook valid" {
    const result = verifyWebhook("subscribe", "my-token", "challenge-123", "my-token");
    try std.testing.expectEqualStrings("challenge-123", result.?);
}

test "verifyWebhook wrong mode" {
    try std.testing.expect(verifyWebhook("unsubscribe", "my-token", "c", "my-token") == null);
}

test "verifyWebhook wrong token" {
    try std.testing.expect(verifyWebhook("subscribe", "wrong", "c", "my-token") == null);
}

test "extractMessageText" {
    const json = "{\"text\":{\"body\":\"Hello there\"}}";
    try std.testing.expectEqualStrings("Hello there", extractMessageText(json).?);
}

test "extractFrom" {
    const json = "{\"from\":\"1234567890\"}";
    try std.testing.expectEqualStrings("1234567890", extractFrom(json).?);
}

test "extractMessageId wamid" {
    const json = "{\"id\":\"wamid.HBgNMTIzNDU2Nzg5MDEyFQI\"}";
    const id = extractMessageId(json).?;
    try std.testing.expect(std.mem.startsWith(u8, id, "wamid."));
}

test "extractProfileName" {
    const json = "{\"contacts\":[{\"profile\":{\"name\":\"John Doe\"}}]}";
    try std.testing.expectEqualStrings("John Doe", extractProfileName(json).?);
}

test "parseIncomingMessage" {
    const json = "{\"from\":\"1234567890\",\"text\":{\"body\":\"Hi bot\"},\"id\":\"wamid.abc\",\"contacts\":[{\"profile\":{\"name\":\"Alice\"}}]}";
    const msg = parseIncomingMessage(json).?;
    try std.testing.expectEqual(plugin.ChannelType.whatsapp, msg.channel);
    try std.testing.expectEqualStrings("Hi bot", msg.content);
    try std.testing.expectEqualStrings("1234567890", msg.sender_id);
    try std.testing.expect(!msg.is_group);
}

test "parseIncomingMessage no text" {
    const json = "{\"from\":\"1234567890\",\"type\":\"image\"}";
    try std.testing.expect(parseIncomingMessage(json) == null);
}

test "WaMessageType fromString and label" {
    try std.testing.expectEqual(WaMessageType.text, WaMessageType.fromString("text").?);
    try std.testing.expectEqual(WaMessageType.image, WaMessageType.fromString("image").?);
    try std.testing.expectEqualStrings("text", WaMessageType.text.label());
    try std.testing.expectEqual(@as(?WaMessageType, null), WaMessageType.fromString("unknown"));
}

test "isGroupMessage detects participant field" {
    const json = "{\"from\":\"group-jid\",\"participant\":\"123\",\"text\":{\"body\":\"Hi\"}}";
    try std.testing.expect(isGroupMessage(json));
}

test "isGroupMessage false for DM" {
    const json = "{\"from\":\"1234567890\",\"text\":{\"body\":\"Hi\"}}";
    try std.testing.expect(!isGroupMessage(json));
}

test "parseIncomingMessage group detection" {
    const json = "{\"from\":\"group-jid\",\"participant\":\"123\",\"text\":{\"body\":\"Hello group\"},\"id\":\"wamid.xyz\",\"contacts\":[{\"profile\":{\"name\":\"Alice\"}}]}";
    const msg = parseIncomingMessage(json).?;
    try std.testing.expect(msg.is_group);
    try std.testing.expectEqualStrings("Hello group", msg.content);
}

test "WhatsAppConfig defaults" {
    const config = WhatsAppConfig{ .phone_number_id = "123", .access_token = "tok" };
    try std.testing.expectEqualStrings("zclaw-webhook-verify", config.verify_token);
    try std.testing.expectEqualStrings("v18.0", config.api_version);
}

test "extractMessageType" {
    const json = "{\"type\":\"text\"}";
    try std.testing.expectEqualStrings("text", extractMessageType(json).?);
}

// ======================================================================
// Additional comprehensive tests
// ======================================================================

// --- API URL Builder Tests ---

test "buildApiUrl messages endpoint" {
    var buf: [256]u8 = undefined;
    const url = try buildApiUrl(&buf, "123456789", "messages");
    try std.testing.expectEqualStrings("https://graph.facebook.com/v18.0/123456789/messages", url);
}

test "buildApiUrl media endpoint" {
    var buf: [256]u8 = undefined;
    const url = try buildApiUrl(&buf, "987654321", "media");
    try std.testing.expectEqualStrings("https://graph.facebook.com/v18.0/987654321/media", url);
}

test "buildApiUrl phone_numbers endpoint" {
    var buf: [256]u8 = undefined;
    const url = try buildApiUrl(&buf, "111222333", "phone_numbers");
    try std.testing.expectEqualStrings("https://graph.facebook.com/v18.0/111222333/phone_numbers", url);
}

test "buildApiUrl buffer too small" {
    var buf: [5]u8 = undefined;
    const result = buildApiUrl(&buf, "123", "messages");
    try std.testing.expectError(error.NoSpaceLeft, result);
}

// --- Send Text Body Tests ---

test "buildSendTextBody contains messaging_product" {
    var buf: [1024]u8 = undefined;
    const body = try buildSendTextBody(&buf, "15551234567", "Hi");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"messaging_product\":\"whatsapp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"text\"") != null);
}

test "buildSendTextBody escapes quotes" {
    var buf: [1024]u8 = undefined;
    const body = try buildSendTextBody(&buf, "15551234567", "He said \"hi\"");
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"hi\\\"") != null);
}

test "buildSendTextBody escapes newlines" {
    var buf: [1024]u8 = undefined;
    const body = try buildSendTextBody(&buf, "15551234567", "line1\nline2");
    try std.testing.expect(std.mem.indexOf(u8, body, "\\n") != null);
}

test "buildSendTextBody international phone number" {
    var buf: [1024]u8 = undefined;
    const body = try buildSendTextBody(&buf, "4915112345678", "Hallo");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"to\":\"4915112345678\"") != null);
}

test "buildSendTextBody empty text" {
    var buf: [1024]u8 = undefined;
    const body = try buildSendTextBody(&buf, "123", "");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"body\":\"\"") != null);
}

// --- Mark Read Body Tests ---

test "buildMarkReadBody structure" {
    var buf: [256]u8 = undefined;
    const body = try buildMarkReadBody(&buf, "wamid.XYZ123");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"messaging_product\":\"whatsapp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"status\":\"read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"message_id\":\"wamid.XYZ123\"") != null);
}

test "buildMarkReadBody with long wamid" {
    var buf: [512]u8 = undefined;
    const body = try buildMarkReadBody(&buf, "wamid.HBgNMTIzNDU2Nzg5MDEyFQIAEhgWM0VCMEU5RjM2REIzNzRDQjc5MjkA");
    try std.testing.expect(std.mem.indexOf(u8, body, "wamid.HBgNMTIzNDU2Nzg5MDEyFQIAEhgWM0VCMEU5RjM2REIzNzRDQjc5MjkA") != null);
}

// --- Reaction Body Tests ---

test "buildReactionBody structure" {
    var buf: [256]u8 = undefined;
    const body = try buildReactionBody(&buf, "wamid.abc", "👍");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"messaging_product\":\"whatsapp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"reaction\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"message_id\":\"wamid.abc\"") != null);
}

test "buildReactionBody different emoji" {
    var buf: [256]u8 = undefined;
    const body = try buildReactionBody(&buf, "wamid.xyz", "❤️");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reaction\":{") != null);
}

// --- Webhook Verification Tests ---

test "verifyWebhook case sensitive mode" {
    try std.testing.expect(verifyWebhook("Subscribe", "tok", "c", "tok") == null);
}

test "verifyWebhook case sensitive token" {
    try std.testing.expect(verifyWebhook("subscribe", "Token", "c", "token") == null);
}

test "verifyWebhook empty challenge" {
    const result = verifyWebhook("subscribe", "tok", "", "tok");
    try std.testing.expectEqualStrings("", result.?);
}

test "verifyWebhook empty token" {
    try std.testing.expect(verifyWebhook("subscribe", "", "c", "tok") == null);
}

test "verifyWebhook empty expected_token" {
    try std.testing.expect(verifyWebhook("subscribe", "tok", "c", "") == null);
}

test "verifyWebhook matching empty tokens" {
    const result = verifyWebhook("subscribe", "", "challenge", "");
    try std.testing.expectEqualStrings("challenge", result.?);
}

// --- Extraction Tests ---

test "extractMessageText from webhook payload" {
    const json =
        \\{"object":"whatsapp_business_account","entry":[{"changes":[{"value":{"messages":[{"from":"15551234567","text":{"body":"Hello from webhook"},"type":"text"}]}}]}]}
    ;
    try std.testing.expectEqualStrings("Hello from webhook", extractMessageText(json).?);
}

test "extractMessageText missing" {
    const json = "{\"type\":\"image\",\"image\":{\"id\":\"abc\"}}";
    try std.testing.expect(extractMessageText(json) == null);
}

test "extractFrom from message" {
    const json = "{\"from\":\"491234567890\",\"type\":\"text\"}";
    try std.testing.expectEqualStrings("491234567890", extractFrom(json).?);
}

test "extractFrom missing" {
    const json = "{\"type\":\"text\"}";
    try std.testing.expect(extractFrom(json) == null);
}

test "extractWamid from message" {
    const json = "{\"id\":\"wamid.HBgNMTIzNDU2Nzg5MDEyFQ\",\"type\":\"text\"}";
    const result = extractWamid(json);
    try std.testing.expect(result != null);
}

test "extractWamid missing" {
    const json = "{\"id\":\"not-a-wamid\",\"type\":\"text\"}";
    try std.testing.expect(extractWamid(json) == null);
}

test "extractMessageId with wamid" {
    const json = "{\"id\":\"wamid.ABC123\"}";
    const id = extractMessageId(json).?;
    try std.testing.expect(std.mem.startsWith(u8, id, "wamid."));
}

test "extractMessageId without wamid prefix" {
    const json = "{\"id\":\"regular-id-123\"}";
    const id = extractMessageId(json).?;
    try std.testing.expectEqualStrings("regular-id-123", id);
}

test "extractMessageId missing" {
    const json = "{\"type\":\"text\"}";
    try std.testing.expect(extractMessageId(json) == null);
}

test "extractMessageType image" {
    const json = "{\"type\":\"image\",\"image\":{\"id\":\"abc\"}}";
    try std.testing.expectEqualStrings("image", extractMessageType(json).?);
}

test "extractMessageType video" {
    const json = "{\"type\":\"video\",\"video\":{\"id\":\"xyz\"}}";
    try std.testing.expectEqualStrings("video", extractMessageType(json).?);
}

test "extractMessageType audio" {
    const json = "{\"type\":\"audio\",\"audio\":{\"id\":\"123\"}}";
    try std.testing.expectEqualStrings("audio", extractMessageType(json).?);
}

test "extractMessageType document" {
    const json = "{\"type\":\"document\",\"document\":{\"id\":\"doc\"}}";
    try std.testing.expectEqualStrings("document", extractMessageType(json).?);
}

test "extractMessageType sticker" {
    const json = "{\"type\":\"sticker\",\"sticker\":{\"id\":\"stk\"}}";
    try std.testing.expectEqualStrings("sticker", extractMessageType(json).?);
}

test "extractMessageType location" {
    const json = "{\"type\":\"location\",\"location\":{\"latitude\":40.7}}";
    try std.testing.expectEqualStrings("location", extractMessageType(json).?);
}

test "extractMessageType reaction" {
    const json = "{\"type\":\"reaction\",\"reaction\":{\"emoji\":\"👍\"}}";
    try std.testing.expectEqualStrings("reaction", extractMessageType(json).?);
}

test "extractDisplayPhoneNumber" {
    const json = "{\"display_phone_number\":\"+1 555 123 4567\"}";
    try std.testing.expectEqualStrings("+1 555 123 4567", extractDisplayPhoneNumber(json).?);
}

test "extractDisplayPhoneNumber missing" {
    const json = "{\"phone_number_id\":\"123\"}";
    try std.testing.expect(extractDisplayPhoneNumber(json) == null);
}

test "extractProfileName from contacts" {
    const json = "{\"contacts\":[{\"profile\":{\"name\":\"Alice Smith\"},\"wa_id\":\"15551234567\"}]}";
    try std.testing.expectEqualStrings("Alice Smith", extractProfileName(json).?);
}

test "extractProfileName missing" {
    const json = "{\"from\":\"123\",\"type\":\"text\"}";
    try std.testing.expect(extractProfileName(json) == null);
}

// --- Group Detection Tests ---

test "isGroupMessage with participant field" {
    const json = "{\"from\":\"group-jid\",\"participant\":\"15551234567\",\"type\":\"text\"}";
    try std.testing.expect(isGroupMessage(json));
}

test "isGroupMessage without participant is DM" {
    const json = "{\"from\":\"15551234567\",\"type\":\"text\",\"text\":{\"body\":\"hi\"}}";
    try std.testing.expect(!isGroupMessage(json));
}

test "isGroupMessage empty json" {
    try std.testing.expect(!isGroupMessage("{}"));
}

// --- Incoming Message Parser Tests ---

test "parseIncomingMessage full webhook message" {
    const json =
        \\{"from":"15551234567","id":"wamid.abc123","type":"text","text":{"body":"Hello!"},"contacts":[{"profile":{"name":"John Doe"}}]}
    ;
    const msg = parseIncomingMessage(json).?;
    try std.testing.expectEqual(plugin.ChannelType.whatsapp, msg.channel);
    try std.testing.expectEqualStrings("Hello!", msg.content);
    try std.testing.expectEqualStrings("15551234567", msg.sender_id);
    try std.testing.expectEqualStrings("15551234567", msg.chat_id); // DM uses sender as chat_id
    try std.testing.expectEqualStrings("John Doe", msg.sender_name.?);
    try std.testing.expect(!msg.is_group);
}

test "parseIncomingMessage group message with participant" {
    const json = "{\"from\":\"group-jid\",\"participant\":\"15551234567\",\"text\":{\"body\":\"Group msg\"},\"id\":\"wamid.xyz\"}";
    const msg = parseIncomingMessage(json).?;
    try std.testing.expect(msg.is_group);
    try std.testing.expectEqualStrings("Group msg", msg.content);
}

test "parseIncomingMessage image message no text returns null" {
    const json = "{\"from\":\"123\",\"type\":\"image\",\"image\":{\"id\":\"abc\"}}";
    try std.testing.expect(parseIncomingMessage(json) == null);
}

test "parseIncomingMessage missing from returns null" {
    const json = "{\"text\":{\"body\":\"hi\"},\"type\":\"text\"}";
    try std.testing.expect(parseIncomingMessage(json) == null);
}

// --- WaMessageType Tests ---

test "WaMessageType all types roundtrip" {
    const types = [_]WaMessageType{ .text, .image, .audio, .video, .document, .location, .sticker, .reaction, .interactive };
    for (types) |t| {
        const label_str = t.label();
        const parsed = WaMessageType.fromString(label_str).?;
        try std.testing.expectEqual(t, parsed);
    }
}

test "WaMessageType fromString case sensitive" {
    try std.testing.expect(WaMessageType.fromString("Text") == null);
    try std.testing.expect(WaMessageType.fromString("IMAGE") == null);
}

// --- WhatsAppConfig Tests ---

test "WhatsAppConfig with custom verify_token" {
    const config = WhatsAppConfig{
        .phone_number_id = "123",
        .access_token = "tok",
        .verify_token = "my-custom-verify",
        .api_version = "v19.0",
    };
    try std.testing.expectEqualStrings("my-custom-verify", config.verify_token);
    try std.testing.expectEqualStrings("v19.0", config.api_version);
}

// --- Status Webhook Detection ---

test "extractMessageType status update" {
    const json = "{\"type\":\"status\",\"status\":\"delivered\"}";
    // The type field here is "status" not a message type
    try std.testing.expectEqualStrings("status", extractMessageType(json).?);
}
