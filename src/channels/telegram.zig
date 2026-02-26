const std = @import("std");
const plugin = @import("plugin.zig");
const http_client = @import("../infra/http_client.zig");

// --- Telegram API Constants ---

pub const DEFAULT_API_URL = "https://api.telegram.org";
pub const LONG_POLL_TIMEOUT: u32 = 30;

// --- Telegram Config ---

pub const TelegramConfig = struct {
    bot_token: []const u8,
    api_url: []const u8 = DEFAULT_API_URL,
    poll_timeout: u32 = LONG_POLL_TIMEOUT,
    allowed_updates: []const u8 = "message",
};

// --- API URL Builder ---

pub fn buildApiUrl(buf: []u8, config: TelegramConfig, method: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    try writer.writeAll(config.api_url);
    try writer.writeAll("/bot");
    try writer.writeAll(config.bot_token);
    try writer.writeByte('/');
    try writer.writeAll(method);
    return fbs.getWritten();
}

// --- Request Builders ---

pub fn buildSendMessageBody(buf: []u8, chat_id: []const u8, text: []const u8, parse_mode: ?[]const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    try writer.writeAll("{\"chat_id\":\"");
    try writer.writeAll(chat_id);
    try writer.writeAll("\",\"text\":\"");
    try writeJsonEscaped(writer, text);
    try writer.writeAll("\"");
    if (parse_mode) |pm| {
        try writer.writeAll(",\"parse_mode\":\"");
        try writer.writeAll(pm);
        try writer.writeAll("\"");
    }
    try writer.writeAll("}");
    return fbs.getWritten();
}

pub fn buildGetUpdatesBody(buf: []u8, offset: ?i64, timeout: u32) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    try writer.writeAll("{\"timeout\":");
    try std.fmt.format(writer, "{d}", .{timeout});
    if (offset) |off| {
        try writer.writeAll(",\"offset\":");
        try std.fmt.format(writer, "{d}", .{off});
    }
    try writer.writeAll(",\"allowed_updates\":[\"message\"]}");
    return fbs.getWritten();
}

// --- Response Parsing ---

/// Extract text from a Telegram Update JSON.
/// Returns the message text or null if not a text message.
pub fn extractMessageText(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"text\":\"");
}

/// Extract chat ID from a Telegram Update JSON.
pub fn extractChatId(json: []const u8) ?[]const u8 {
    // Look for "chat":{"id": pattern
    if (std.mem.indexOf(u8, json, "\"chat\":{\"id\":")) |start| {
        const num_start = start + "\"chat\":{\"id\":".len;
        var end = num_start;
        while (end < json.len and (json[end] >= '0' and json[end] <= '9' or json[end] == '-')) : (end += 1) {}
        if (end > num_start) return json[num_start..end];
    }
    return null;
}

/// Extract sender user ID from a Telegram Update JSON.
pub fn extractFromId(json: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, json, "\"from\":{\"id\":")) |start| {
        const num_start = start + "\"from\":{\"id\":".len;
        var end = num_start;
        while (end < json.len and (json[end] >= '0' and json[end] <= '9')) : (end += 1) {}
        if (end > num_start) return json[num_start..end];
    }
    return null;
}

/// Extract update_id from a Telegram Update JSON.
pub fn extractUpdateId(json: []const u8) ?i64 {
    return extractJsonNumber(json, "\"update_id\":");
}

/// Extract first_name from a Telegram Update JSON.
pub fn extractFirstName(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"first_name\":\"");
}

/// Check if the message is from a group chat.
pub fn isGroupChat(json: []const u8) bool {
    return std.mem.indexOf(u8, json, "\"type\":\"group\"") != null or
        std.mem.indexOf(u8, json, "\"type\":\"supergroup\"") != null;
}

// --- Incoming Message Parser ---

pub fn parseIncomingMessage(json: []const u8) ?plugin.IncomingMessage {
    const text = extractMessageText(json) orelse return null;
    const chat_id = extractChatId(json) orelse return null;
    const sender_id = extractFromId(json) orelse return null;

    return .{
        .channel = .telegram,
        .message_id = "", // Would need update_id
        .sender_id = sender_id,
        .sender_name = extractFirstName(json),
        .chat_id = chat_id,
        .content = text,
        .is_group = isGroupChat(json),
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
    var end = value_start;
    while (end < json.len and (json[end] >= '0' and json[end] <= '9')) : (end += 1) {}
    if (end == value_start) return null;
    return std.fmt.parseInt(i64, json[value_start..end], 10) catch null;
}

// --- Tests ---

test "buildApiUrl" {
    var buf: [512]u8 = undefined;
    const url = try buildApiUrl(&buf, .{ .bot_token = "123:ABC" }, "sendMessage");
    try std.testing.expectEqualStrings("https://api.telegram.org/bot123:ABC/sendMessage", url);
}

test "buildApiUrl getUpdates" {
    var buf: [512]u8 = undefined;
    const url = try buildApiUrl(&buf, .{ .bot_token = "tok" }, "getUpdates");
    try std.testing.expectEqualStrings("https://api.telegram.org/bottok/getUpdates", url);
}

test "buildSendMessageBody" {
    var buf: [4096]u8 = undefined;
    const body = try buildSendMessageBody(&buf, "12345", "Hello!", null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"chat_id\":\"12345\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":\"Hello!\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "parse_mode") == null);
}

test "buildSendMessageBody with parse_mode" {
    var buf: [4096]u8 = undefined;
    const body = try buildSendMessageBody(&buf, "12345", "**bold**", "Markdown");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"parse_mode\":\"Markdown\"") != null);
}

test "buildGetUpdatesBody" {
    var buf: [256]u8 = undefined;
    const body = try buildGetUpdatesBody(&buf, 42, 30);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"timeout\":30") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"offset\":42") != null);
}

test "buildGetUpdatesBody no offset" {
    var buf: [256]u8 = undefined;
    const body = try buildGetUpdatesBody(&buf, null, 30);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"timeout\":30") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"offset\"") == null);
}

test "extractMessageText" {
    const json = "{\"message\":{\"text\":\"Hello world\",\"chat\":{\"id\":123}}}";
    try std.testing.expectEqualStrings("Hello world", extractMessageText(json).?);
}

test "extractMessageText no text" {
    const json = "{\"message\":{\"photo\":[],\"chat\":{\"id\":123}}}";
    try std.testing.expect(extractMessageText(json) == null);
}

test "extractChatId" {
    const json = "{\"message\":{\"chat\":{\"id\":12345,\"type\":\"private\"}}}";
    try std.testing.expectEqualStrings("12345", extractChatId(json).?);
}

test "extractFromId" {
    const json = "{\"message\":{\"from\":{\"id\":67890,\"first_name\":\"John\"}}}";
    try std.testing.expectEqualStrings("67890", extractFromId(json).?);
}

test "extractUpdateId" {
    const json = "{\"update_id\":999,\"message\":{}}";
    try std.testing.expectEqual(@as(i64, 999), extractUpdateId(json).?);
}

test "extractFirstName" {
    const json = "{\"from\":{\"id\":1,\"first_name\":\"Alice\"}}";
    try std.testing.expectEqualStrings("Alice", extractFirstName(json).?);
}

test "isGroupChat private" {
    const json = "{\"chat\":{\"type\":\"private\"}}";
    try std.testing.expect(!isGroupChat(json));
}

test "isGroupChat group" {
    const json = "{\"chat\":{\"type\":\"group\"}}";
    try std.testing.expect(isGroupChat(json));
}

test "isGroupChat supergroup" {
    const json = "{\"chat\":{\"type\":\"supergroup\"}}";
    try std.testing.expect(isGroupChat(json));
}

test "parseIncomingMessage" {
    const json = "{\"message\":{\"text\":\"Hi bot\",\"chat\":{\"id\":100,\"type\":\"private\"},\"from\":{\"id\":200,\"first_name\":\"Bob\"}}}";
    const msg = parseIncomingMessage(json).?;
    try std.testing.expectEqual(plugin.ChannelType.telegram, msg.channel);
    try std.testing.expectEqualStrings("Hi bot", msg.content);
    try std.testing.expectEqualStrings("100", msg.chat_id);
    try std.testing.expectEqualStrings("200", msg.sender_id);
    try std.testing.expect(!msg.is_group);
}

test "parseIncomingMessage group" {
    const json = "{\"message\":{\"text\":\"hey\",\"chat\":{\"id\":300,\"type\":\"group\"},\"from\":{\"id\":400}}}";
    const msg = parseIncomingMessage(json).?;
    try std.testing.expect(msg.is_group);
}

test "parseIncomingMessage no text" {
    const json = "{\"message\":{\"sticker\":{},\"chat\":{\"id\":1}}}";
    try std.testing.expect(parseIncomingMessage(json) == null);
}

test "TelegramConfig defaults" {
    const config = TelegramConfig{ .bot_token = "test" };
    try std.testing.expectEqualStrings(DEFAULT_API_URL, config.api_url);
    try std.testing.expectEqual(@as(u32, 30), config.poll_timeout);
}

// --- Telegram Channel (PluginVTable Implementation) ---

pub const TelegramChannel = struct {
    config: TelegramConfig,
    client: *http_client.HttpClient,
    status: plugin.ChannelStatus = .disconnected,
    last_update_id: ?i64 = null,
    allocator: std.mem.Allocator,
    poll_result_buf: [4096]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, config: TelegramConfig, client: *http_client.HttpClient) TelegramChannel {
        return .{
            .config = config,
            .client = client,
            .status = .disconnected,
            .last_update_id = null,
            .allocator = allocator,
        };
    }

    pub fn asPlugin(self: *TelegramChannel) plugin.ChannelPlugin {
        return .{
            .vtable = &vtable,
            .ctx = @ptrCast(self),
        };
    }

    /// Start the channel (verify bot token via getMe).
    pub fn start(self: *TelegramChannel) !void {
        self.status = .connecting;

        var url_buf: [512]u8 = undefined;
        const url = buildApiUrl(&url_buf, self.config, "getMe") catch {
            self.status = .error_state;
            return;
        };

        var resp = self.client.get(url, &.{}) catch {
            self.status = .error_state;
            return;
        };
        defer resp.deinit();

        if (resp.status == 200 and std.mem.indexOf(u8, resp.body, "\"ok\":true") != null) {
            self.status = .connected;
        } else {
            self.status = .error_state;
        }
    }

    /// Send a text message to a chat.
    pub fn sendText(self: *TelegramChannel, msg: plugin.OutgoingMessage) !void {
        var url_buf: [512]u8 = undefined;
        const url = try buildApiUrl(&url_buf, self.config, "sendMessage");

        var body_buf: [4096]u8 = undefined;
        const body = try buildSendMessageBody(&body_buf, msg.chat_id, msg.content, msg.parse_mode);

        const headers = [_]http_client.Header{
            .{ .name = "content-type", .value = "application/json" },
        };

        var resp = try self.client.post(url, &headers, body);
        defer resp.deinit();

        if (resp.status != 200) {
            return error.SendFailed;
        }
    }

    /// Poll for updates (single call, not a loop).
    /// Returned message fields are copied into poll_result_buf.
    pub fn pollUpdates(self: *TelegramChannel) !?PollResult {
        var url_buf: [512]u8 = undefined;
        const url = try buildApiUrl(&url_buf, self.config, "getUpdates");

        var body_buf: [256]u8 = undefined;
        const offset = if (self.last_update_id) |id| id + 1 else null;
        const body = try buildGetUpdatesBody(&body_buf, offset, 0); // timeout=0 for non-blocking

        const headers = [_]http_client.Header{
            .{ .name = "content-type", .value = "application/json" },
        };

        var resp = try self.client.post(url, &headers, body);
        defer resp.deinit();

        if (resp.status != 200) return null;

        // Extract update_id to track offset
        if (extractUpdateId(resp.body)) |uid| {
            self.last_update_id = uid;
        }

        // Parse the first message and copy into our stable buffer
        const msg = parseIncomingMessage(resp.body) orelse return null;

        // Copy text/ids into poll_result_buf so they survive after resp.deinit()
        var pos: usize = 0;
        const content_start = pos;
        @memcpy(self.poll_result_buf[pos..][0..msg.content.len], msg.content);
        pos += msg.content.len;
        const chat_start = pos;
        @memcpy(self.poll_result_buf[pos..][0..msg.chat_id.len], msg.chat_id);
        pos += msg.chat_id.len;
        const sender_start = pos;
        @memcpy(self.poll_result_buf[pos..][0..msg.sender_id.len], msg.sender_id);
        pos += msg.sender_id.len;

        return .{
            .content = self.poll_result_buf[content_start..][0..msg.content.len],
            .chat_id = self.poll_result_buf[chat_start..][0..msg.chat_id.len],
            .sender_id = self.poll_result_buf[sender_start..][0..msg.sender_id.len],
            .is_group = msg.is_group,
        };
    }

    pub const PollResult = struct {
        content: []const u8,
        chat_id: []const u8,
        sender_id: []const u8,
        is_group: bool,
    };

    fn stopImpl(ctx: *anyopaque) void {
        const self: *TelegramChannel = @ptrCast(@alignCast(ctx));
        self.status = .disconnected;
    }

    fn startImpl(ctx: *anyopaque) anyerror!void {
        const self: *TelegramChannel = @ptrCast(@alignCast(ctx));
        return self.start();
    }

    fn sendTextImpl(ctx: *anyopaque, msg: plugin.OutgoingMessage) anyerror!void {
        const self: *TelegramChannel = @ptrCast(@alignCast(ctx));
        return self.sendText(msg);
    }

    fn getStatusImpl(ctx: *anyopaque) plugin.ChannelStatus {
        const self: *const TelegramChannel = @ptrCast(@alignCast(ctx));
        return self.status;
    }

    fn getTypeImpl(_: *anyopaque) plugin.ChannelType {
        return .telegram;
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

// --- TelegramChannel Tests ---

test "TelegramChannel init" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{};
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());

    const channel = TelegramChannel.init(allocator, .{ .bot_token = "test-token" }, &client);
    try std.testing.expectEqual(plugin.ChannelStatus.disconnected, channel.status);
}

test "TelegramChannel start success" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "{\"ok\":true,\"result\":{\"id\":123,\"is_bot\":true}}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = TelegramChannel.init(allocator, .{ .bot_token = "test-token" }, &client);

    try channel.start();
    try std.testing.expectEqual(plugin.ChannelStatus.connected, channel.status);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
}

test "TelegramChannel start failure" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 401, .body = "{\"ok\":false}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = TelegramChannel.init(allocator, .{ .bot_token = "bad-token" }, &client);

    try channel.start();
    try std.testing.expectEqual(plugin.ChannelStatus.error_state, channel.status);
}

test "TelegramChannel sendText" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "{\"ok\":true}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = TelegramChannel.init(allocator, .{ .bot_token = "tok" }, &client);
    channel.status = .connected;

    try channel.sendText(.{ .chat_id = "12345", .content = "Hello!" });
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_url.?, "sendMessage") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_body.?, "Hello!") != null);
}

test "TelegramChannel sendText failure" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 400, .body = "{\"ok\":false}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = TelegramChannel.init(allocator, .{ .bot_token = "tok" }, &client);

    const result = channel.sendText(.{ .chat_id = "1", .content = "hi" });
    try std.testing.expectError(TelegramChannel.SendError.SendFailed, result);
}

test "TelegramChannel pollUpdates with message" {
    const allocator = std.testing.allocator;
    const update_json = "{\"ok\":true,\"result\":[{\"update_id\":100,\"message\":{\"text\":\"hello bot\",\"chat\":{\"id\":999,\"type\":\"private\"},\"from\":{\"id\":42,\"first_name\":\"User\"}}}]}";
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = update_json },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = TelegramChannel.init(allocator, .{ .bot_token = "tok" }, &client);

    const result = try channel.pollUpdates();
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("hello bot", result.?.content);
    try std.testing.expectEqualStrings("999", result.?.chat_id);
    try std.testing.expectEqualStrings("42", result.?.sender_id);
    try std.testing.expect(!result.?.is_group);
    try std.testing.expectEqual(@as(i64, 100), channel.last_update_id.?);
}

test "TelegramChannel pollUpdates empty" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "{\"ok\":true,\"result\":[]}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = TelegramChannel.init(allocator, .{ .bot_token = "tok" }, &client);

    const result = try channel.pollUpdates();
    try std.testing.expect(result == null);
}

test "TelegramChannel as PluginVTable" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "{\"ok\":true,\"result\":{\"id\":1}}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = TelegramChannel.init(allocator, .{ .bot_token = "tok" }, &client);

    var p = channel.asPlugin();
    try std.testing.expectEqual(plugin.ChannelType.telegram, p.getType());
    try std.testing.expectEqual(plugin.ChannelStatus.disconnected, p.getStatus());

    try p.start();
    try std.testing.expectEqual(plugin.ChannelStatus.connected, p.getStatus());

    p.stop();
    try std.testing.expectEqual(plugin.ChannelStatus.disconnected, p.getStatus());
}
