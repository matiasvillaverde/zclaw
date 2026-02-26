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
        .is_group = false, // Would need group detection
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

test "WhatsAppConfig defaults" {
    const config = WhatsAppConfig{ .phone_number_id = "123", .access_token = "tok" };
    try std.testing.expectEqualStrings("zclaw-webhook-verify", config.verify_token);
    try std.testing.expectEqualStrings("v18.0", config.api_version);
}

test "extractMessageType" {
    const json = "{\"type\":\"text\"}";
    try std.testing.expectEqualStrings("text", extractMessageType(json).?);
}
