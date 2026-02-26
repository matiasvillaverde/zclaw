const std = @import("std");
const plugin = @import("plugin.zig");
const http_client = @import("../infra/http_client.zig");

// --- Discord API Constants ---

pub const API_BASE_URL = "https://discord.com/api/v10";
pub const GATEWAY_URL = "wss://gateway.discord.gg/?v=10&encoding=json";

// --- Discord Config ---

pub const DiscordConfig = struct {
    bot_token: []const u8,
    application_id: ?[]const u8 = null,
    intents: u32 = DEFAULT_INTENTS,
};

// Gateway intents
pub const INTENT_GUILDS: u32 = 1 << 0;
pub const INTENT_GUILD_MESSAGES: u32 = 1 << 9;
pub const INTENT_DIRECT_MESSAGES: u32 = 1 << 12;
pub const INTENT_MESSAGE_CONTENT: u32 = 1 << 15;
pub const DEFAULT_INTENTS: u32 = INTENT_GUILDS | INTENT_GUILD_MESSAGES | INTENT_DIRECT_MESSAGES | INTENT_MESSAGE_CONTENT;

// --- Gateway Opcodes ---

pub const GatewayOpcode = enum(u8) {
    dispatch = 0,
    heartbeat = 1,
    identify = 2,
    presence_update = 3,
    voice_state_update = 4,
    @"resume" = 6,
    reconnect = 7,
    request_guild_members = 8,
    invalid_session = 9,
    hello = 10,
    heartbeat_ack = 11,

    pub fn fromInt(val: u8) ?GatewayOpcode {
        return switch (val) {
            0 => .dispatch,
            1 => .heartbeat,
            2 => .identify,
            3 => .presence_update,
            6 => .@"resume",
            7 => .reconnect,
            9 => .invalid_session,
            10 => .hello,
            11 => .heartbeat_ack,
            else => null,
        };
    }
};

// --- API URL Builder ---

pub fn buildApiUrl(buf: []u8, endpoint: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    try writer.writeAll(API_BASE_URL);
    try writer.writeAll(endpoint);
    return fbs.getWritten();
}

// --- Request Builders ---

pub fn buildSendMessageBody(buf: []u8, content: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    try writer.writeAll("{\"content\":\"");
    try writeJsonEscaped(writer, content);
    try writer.writeAll("\"}");
    return fbs.getWritten();
}

pub fn buildIdentifyPayload(buf: []u8, token: []const u8, intents: u32) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    try writer.writeAll("{\"op\":2,\"d\":{\"token\":\"");
    try writer.writeAll(token);
    try writer.writeAll("\",\"intents\":");
    try std.fmt.format(writer, "{d}", .{intents});
    try writer.writeAll(",\"properties\":{\"os\":\"zig\",\"browser\":\"zclaw\",\"device\":\"zclaw\"}}}");
    return fbs.getWritten();
}

pub fn buildHeartbeatPayload(buf: []u8, sequence: ?i64) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    try writer.writeAll("{\"op\":1,\"d\":");
    if (sequence) |seq| {
        try std.fmt.format(writer, "{d}", .{seq});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("}");
    return fbs.getWritten();
}

// --- Response Parsing ---

pub fn extractOpcode(json: []const u8) ?u8 {
    const num = extractJsonNumber(json, "\"op\":") orelse return null;
    if (num < 0 or num > 255) return null;
    return @intCast(num);
}

pub fn extractEventName(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"t\":\"");
}

pub fn extractSequence(json: []const u8) ?i64 {
    return extractJsonNumber(json, "\"s\":");
}

pub fn extractHeartbeatInterval(json: []const u8) ?i64 {
    return extractJsonNumber(json, "\"heartbeat_interval\":");
}

pub fn extractMessageContent(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"content\":\"");
}

pub fn extractChannelId(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"channel_id\":\"");
}

pub fn extractAuthorId(json: []const u8) ?[]const u8 {
    // Look for author.id
    if (std.mem.indexOf(u8, json, "\"author\":{")) |author_start| {
        const sub = json[author_start..];
        return extractJsonString(sub, "\"id\":\"");
    }
    return null;
}

pub fn extractAuthorUsername(json: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, json, "\"author\":{")) |author_start| {
        const sub = json[author_start..];
        return extractJsonString(sub, "\"username\":\"");
    }
    return null;
}

pub fn extractGuildId(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"guild_id\":\"");
}

pub fn extractMessageId(json: []const u8) ?[]const u8 {
    // Get the top-level "id" (not nested)
    if (std.mem.indexOf(u8, json, "\"d\":{")) |d_start| {
        const sub = json[d_start..];
        return extractJsonString(sub, "\"id\":\"");
    }
    return null;
}

/// Check if message is from a bot
pub fn isBot(json: []const u8) bool {
    if (std.mem.indexOf(u8, json, "\"author\":{")) |author_start| {
        const sub = json[author_start..];
        return std.mem.indexOf(u8, sub, "\"bot\":true") != null;
    }
    return false;
}

// --- Incoming Message Parser ---

pub fn parseIncomingMessage(json: []const u8) ?plugin.IncomingMessage {
    const content = extractMessageContent(json) orelse return null;
    const channel_id = extractChannelId(json) orelse return null;
    const author_id = extractAuthorId(json) orelse return null;

    return .{
        .channel = .discord,
        .message_id = extractMessageId(json) orelse "",
        .sender_id = author_id,
        .sender_name = extractAuthorUsername(json),
        .chat_id = channel_id,
        .content = content,
        .is_group = extractGuildId(json) != null,
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

fn extractJsonNumber(json: []const u8, prefix: []const u8) ?i64 {
    const start_idx = std.mem.indexOf(u8, json, prefix) orelse return null;
    const value_start = start_idx + prefix.len;
    if (value_start >= json.len) return null;
    // Handle null
    if (json[value_start] == 'n') return null;
    var end = value_start;
    while (end < json.len and (json[end] >= '0' and json[end] <= '9')) : (end += 1) {}
    if (end == value_start) return null;
    return std.fmt.parseInt(i64, json[value_start..end], 10) catch null;
}

// --- Tests ---

test "buildApiUrl" {
    var buf: [512]u8 = undefined;
    const url = try buildApiUrl(&buf, "/channels/123/messages");
    try std.testing.expectEqualStrings("https://discord.com/api/v10/channels/123/messages", url);
}

test "buildSendMessageBody" {
    var buf: [4096]u8 = undefined;
    const body = try buildSendMessageBody(&buf, "Hello Discord!");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"Hello Discord!\"") != null);
}

test "buildIdentifyPayload" {
    var buf: [1024]u8 = undefined;
    const payload = try buildIdentifyPayload(&buf, "my-token", DEFAULT_INTENTS);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"op\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"token\":\"my-token\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"os\":\"zig\"") != null);
}

test "buildHeartbeatPayload with sequence" {
    var buf: [256]u8 = undefined;
    const payload = try buildHeartbeatPayload(&buf, 42);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"op\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"d\":42") != null);
}

test "buildHeartbeatPayload null" {
    var buf: [256]u8 = undefined;
    const payload = try buildHeartbeatPayload(&buf, null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"d\":null") != null);
}

test "extractOpcode" {
    try std.testing.expectEqual(@as(u8, 10), extractOpcode("{\"op\":10,\"d\":{}}").?);
    try std.testing.expectEqual(@as(u8, 0), extractOpcode("{\"op\":0,\"t\":\"MESSAGE_CREATE\"}").?);
}

test "extractEventName" {
    try std.testing.expectEqualStrings("MESSAGE_CREATE", extractEventName("{\"t\":\"MESSAGE_CREATE\",\"op\":0}").?);
    try std.testing.expect(extractEventName("{\"op\":10}") == null);
}

test "extractSequence" {
    try std.testing.expectEqual(@as(i64, 5), extractSequence("{\"s\":5,\"op\":0}").?);
    try std.testing.expect(extractSequence("{\"s\":null}") == null);
}

test "extractHeartbeatInterval" {
    const json = "{\"op\":10,\"d\":{\"heartbeat_interval\":41250}}";
    try std.testing.expectEqual(@as(i64, 41250), extractHeartbeatInterval(json).?);
}

test "extractMessageContent" {
    const json = "{\"content\":\"Hello world\",\"channel_id\":\"123\"}";
    try std.testing.expectEqualStrings("Hello world", extractMessageContent(json).?);
}

test "extractChannelId" {
    const json = "{\"channel_id\":\"456789\"}";
    try std.testing.expectEqualStrings("456789", extractChannelId(json).?);
}

test "extractAuthorId" {
    const json = "{\"author\":{\"id\":\"user123\",\"username\":\"john\"}}";
    try std.testing.expectEqualStrings("user123", extractAuthorId(json).?);
}

test "extractAuthorUsername" {
    const json = "{\"author\":{\"id\":\"1\",\"username\":\"johndoe\"}}";
    try std.testing.expectEqualStrings("johndoe", extractAuthorUsername(json).?);
}

test "extractGuildId" {
    const json = "{\"guild_id\":\"guild-abc\"}";
    try std.testing.expectEqualStrings("guild-abc", extractGuildId(json).?);
}

test "isBot true" {
    const json = "{\"author\":{\"id\":\"1\",\"bot\":true}}";
    try std.testing.expect(isBot(json));
}

test "isBot false" {
    const json = "{\"author\":{\"id\":\"1\",\"bot\":false}}";
    try std.testing.expect(!isBot(json));
}

test "parseIncomingMessage DM" {
    const json = "{\"d\":{\"id\":\"msg1\",\"content\":\"Hello\",\"channel_id\":\"ch1\",\"author\":{\"id\":\"u1\",\"username\":\"user\"}}}";
    const msg = parseIncomingMessage(json).?;
    try std.testing.expectEqual(plugin.ChannelType.discord, msg.channel);
    try std.testing.expectEqualStrings("Hello", msg.content);
    try std.testing.expectEqualStrings("ch1", msg.chat_id);
    try std.testing.expectEqualStrings("u1", msg.sender_id);
    try std.testing.expect(!msg.is_group);
}

test "parseIncomingMessage guild" {
    const json = "{\"d\":{\"id\":\"msg2\",\"content\":\"Hey\",\"channel_id\":\"ch2\",\"guild_id\":\"g1\",\"author\":{\"id\":\"u2\"}}}";
    const msg = parseIncomingMessage(json).?;
    try std.testing.expect(msg.is_group);
}

test "parseIncomingMessage no content" {
    const json = "{\"d\":{\"id\":\"1\",\"channel_id\":\"ch\"}}";
    try std.testing.expect(parseIncomingMessage(json) == null);
}

test "GatewayOpcode fromInt" {
    try std.testing.expectEqual(GatewayOpcode.hello, GatewayOpcode.fromInt(10).?);
    try std.testing.expectEqual(GatewayOpcode.dispatch, GatewayOpcode.fromInt(0).?);
    try std.testing.expectEqual(GatewayOpcode.heartbeat, GatewayOpcode.fromInt(1).?);
    try std.testing.expect(GatewayOpcode.fromInt(255) == null);
}

test "DEFAULT_INTENTS" {
    try std.testing.expect(DEFAULT_INTENTS & INTENT_GUILDS != 0);
    try std.testing.expect(DEFAULT_INTENTS & INTENT_GUILD_MESSAGES != 0);
    try std.testing.expect(DEFAULT_INTENTS & INTENT_DIRECT_MESSAGES != 0);
    try std.testing.expect(DEFAULT_INTENTS & INTENT_MESSAGE_CONTENT != 0);
}

test "DiscordConfig defaults" {
    const config = DiscordConfig{ .bot_token = "test" };
    try std.testing.expectEqual(DEFAULT_INTENTS, config.intents);
    try std.testing.expect(config.application_id == null);
}

// --- Discord Channel (PluginVTable Implementation) ---

pub const DiscordChannel = struct {
    config: DiscordConfig,
    client: *http_client.HttpClient,
    status: plugin.ChannelStatus = .disconnected,
    sequence: ?i64 = null,
    allocator: std.mem.Allocator,
    auth_value_buf: [520]u8 = undefined,
    auth_value_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, config: DiscordConfig, client: *http_client.HttpClient) DiscordChannel {
        var channel = DiscordChannel{
            .config = config,
            .client = client,
            .status = .disconnected,
            .sequence = null,
            .allocator = allocator,
        };
        // Compute "Bot <token>" once
        const prefix = "Bot ";
        @memcpy(channel.auth_value_buf[0..prefix.len], prefix);
        const token = config.bot_token;
        const token_len = @min(token.len, channel.auth_value_buf.len - prefix.len);
        @memcpy(channel.auth_value_buf[prefix.len..][0..token_len], token[0..token_len]);
        channel.auth_value_len = prefix.len + token_len;
        return channel;
    }

    pub fn asPlugin(self: *DiscordChannel) plugin.ChannelPlugin {
        return .{
            .vtable = &vtable,
            .ctx = @ptrCast(self),
        };
    }

    /// Verify bot token by calling GET /users/@me.
    pub fn start(self: *DiscordChannel) !void {
        self.status = .connecting;

        var url_buf: [256]u8 = undefined;
        const url = buildApiUrl(&url_buf, "/users/@me") catch {
            self.status = .error_state;
            return;
        };

        const auth_header = self.authHeader();
        var resp = self.client.get(url, &auth_header) catch {
            self.status = .error_state;
            return;
        };
        defer resp.deinit();

        if (resp.status == 200) {
            self.status = .connected;
        } else {
            self.status = .error_state;
        }
    }

    /// Send a message to a channel via REST API.
    pub fn sendText(self: *DiscordChannel, msg: plugin.OutgoingMessage) !void {
        var url_buf: [256]u8 = undefined;
        var path_buf: [128]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&path_buf);
        try fbs.writer().writeAll("/channels/");
        try fbs.writer().writeAll(msg.chat_id);
        try fbs.writer().writeAll("/messages");
        const path = fbs.getWritten();

        const url = try buildApiUrl(&url_buf, path);

        var body_buf: [4096]u8 = undefined;
        const body = try buildSendMessageBody(&body_buf, msg.content);

        const headers = [_]http_client.Header{
            .{ .name = "authorization", .value = self.authValue() },
            .{ .name = "content-type", .value = "application/json" },
        };

        var resp = try self.client.post(url, &headers, body);
        defer resp.deinit();

        if (resp.status != 200) {
            return error.SendFailed;
        }
    }

    fn authHeader(self: *const DiscordChannel) [1]http_client.Header {
        return .{
            .{ .name = "authorization", .value = self.authValue() },
        };
    }

    fn authValue(self: *const DiscordChannel) []const u8 {
        return self.auth_value_buf[0..self.auth_value_len];
    }

    fn stopImpl(ctx: *anyopaque) void {
        const self: *DiscordChannel = @ptrCast(@alignCast(ctx));
        self.status = .disconnected;
        self.sequence = null;
    }

    fn startImpl(ctx: *anyopaque) anyerror!void {
        const self: *DiscordChannel = @ptrCast(@alignCast(ctx));
        return self.start();
    }

    fn sendTextImpl(ctx: *anyopaque, msg: plugin.OutgoingMessage) anyerror!void {
        const self: *DiscordChannel = @ptrCast(@alignCast(ctx));
        return self.sendText(msg);
    }

    fn getStatusImpl(ctx: *anyopaque) plugin.ChannelStatus {
        const self: *const DiscordChannel = @ptrCast(@alignCast(ctx));
        return self.status;
    }

    fn getTypeImpl(_: *anyopaque) plugin.ChannelType {
        return .discord;
    }

    const vtable = plugin.PluginVTable{
        .start = startImpl,
        .stop = stopImpl,
        .send_text = sendTextImpl,
        .get_status = getStatusImpl,
        .get_type = getTypeImpl,
    };

    pub const SendError = error{SendFailed};
};

// --- DiscordChannel Tests ---

test "DiscordChannel init" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{};
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());

    const channel = DiscordChannel.init(allocator, .{ .bot_token = "test-token" }, &client);
    try std.testing.expectEqual(plugin.ChannelStatus.disconnected, channel.status);
}

test "DiscordChannel start success" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "{\"id\":\"123\",\"username\":\"zclaw-bot\"}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = DiscordChannel.init(allocator, .{ .bot_token = "test-token" }, &client);

    try channel.start();
    try std.testing.expectEqual(plugin.ChannelStatus.connected, channel.status);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_url.?, "/users/@me") != null);
}

test "DiscordChannel start failure" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 401, .body = "{\"message\":\"401: Unauthorized\"}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = DiscordChannel.init(allocator, .{ .bot_token = "bad" }, &client);

    try channel.start();
    try std.testing.expectEqual(plugin.ChannelStatus.error_state, channel.status);
}

test "DiscordChannel sendText" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "{\"id\":\"msg-1\"}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = DiscordChannel.init(allocator, .{ .bot_token = "tok" }, &client);
    channel.status = .connected;

    try channel.sendText(.{ .chat_id = "ch-123", .content = "Hello Discord!" });
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_url.?, "/channels/ch-123/messages") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_body.?, "Hello Discord!") != null);
}

test "DiscordChannel sendText failure" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 403, .body = "{\"message\":\"Missing Permissions\"}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = DiscordChannel.init(allocator, .{ .bot_token = "tok" }, &client);

    const result = channel.sendText(.{ .chat_id = "ch-1", .content = "hi" });
    try std.testing.expectError(DiscordChannel.SendError.SendFailed, result);
}

test "DiscordChannel authValue prefixes Bot" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{};
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());

    const channel = DiscordChannel.init(allocator, .{ .bot_token = "my-token" }, &client);
    try std.testing.expectEqualStrings("Bot my-token", channel.authValue());
}

test "DiscordChannel as PluginVTable" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "{\"id\":\"1\",\"username\":\"bot\"}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = DiscordChannel.init(allocator, .{ .bot_token = "tok" }, &client);

    var p = channel.asPlugin();
    try std.testing.expectEqual(plugin.ChannelType.discord, p.getType());
    try std.testing.expectEqual(plugin.ChannelStatus.disconnected, p.getStatus());

    try p.start();
    try std.testing.expectEqual(plugin.ChannelStatus.connected, p.getStatus());

    p.stop();
    try std.testing.expectEqual(plugin.ChannelStatus.disconnected, p.getStatus());
}
