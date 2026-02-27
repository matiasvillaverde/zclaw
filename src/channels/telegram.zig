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

var update_id_buf: [32]u8 = undefined;

fn formatUpdateId(json: []const u8) []const u8 {
    const uid = extractUpdateId(json) orelse return "";
    var fbs = std.io.fixedBufferStream(&update_id_buf);
    std.fmt.format(fbs.writer(), "{d}", .{uid}) catch return "";
    return fbs.getWritten();
}

pub fn parseIncomingMessage(json: []const u8) ?plugin.IncomingMessage {
    const text = extractMessageText(json) orelse return null;
    const chat_id = extractChatId(json) orelse return null;
    const sender_id = extractFromId(json) orelse return null;

    return .{
        .channel = .telegram,
        .message_id = formatUpdateId(json),
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

test "parseIncomingMessage includes update_id as message_id" {
    const json = "{\"update_id\":12345,\"message\":{\"text\":\"Hi bot\",\"chat\":{\"id\":100,\"type\":\"private\"},\"from\":{\"id\":200,\"first_name\":\"Bob\"}}}";
    const msg = parseIncomingMessage(json).?;
    try std.testing.expectEqualStrings("12345", msg.message_id);
}

test "parseIncomingMessage missing update_id gives empty message_id" {
    const json = "{\"message\":{\"text\":\"Hi bot\",\"chat\":{\"id\":100,\"type\":\"private\"},\"from\":{\"id\":200,\"first_name\":\"Bob\"}}}";
    const msg = parseIncomingMessage(json).?;
    try std.testing.expectEqualStrings("", msg.message_id);
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

    // --- Polling Loop ---

    /// Callback type for handling incoming messages.
    /// Receives chat_id, sender_id, message text; returns response text or null.
    pub const MessageHandler = *const fn (chat_id: []const u8, sender_id: []const u8, text: []const u8) ?[]const u8;

    /// Run a continuous polling loop. Calls handler for each message and sends the response.
    /// Stops when `should_stop` is set to true or when an unrecoverable error occurs.
    /// `poll_interval_ms` controls the sleep between polls when no updates are received.
    pub fn startPolling(
        self: *TelegramChannel,
        handler: MessageHandler,
        should_stop: *std.atomic.Value(bool),
        poll_interval_ms: u32,
    ) void {
        // Verify the bot token first
        self.start() catch {
            self.status = .error_state;
            return;
        };

        if (self.status != .connected) return;

        while (!should_stop.load(.acquire)) {
            const poll_result = self.pollUpdates() catch {
                // Transient error — sleep and retry
                std.Thread.sleep(@as(u64, poll_interval_ms) * std.time.ns_per_ms);
                continue;
            };

            if (poll_result) |msg| {
                // Dispatch to handler
                const response = handler(msg.chat_id, msg.sender_id, msg.content);

                if (response) |resp_text| {
                    self.sendText(.{
                        .chat_id = msg.chat_id,
                        .content = resp_text,
                    }) catch {};
                }
            } else {
                // No updates — brief sleep before next poll
                std.Thread.sleep(@as(u64, poll_interval_ms) * std.time.ns_per_ms);
            }
        }

        self.status = .disconnected;
    }

    /// Start polling in a new thread. Returns the thread handle for joining later.
    pub fn startPollingThread(
        self: *TelegramChannel,
        handler: MessageHandler,
        should_stop: *std.atomic.Value(bool),
        poll_interval_ms: u32,
    ) !std.Thread {
        return std.Thread.spawn(.{}, pollingThreadFn, .{ self, handler, should_stop, poll_interval_ms });
    }

    fn pollingThreadFn(
        self: *TelegramChannel,
        handler: MessageHandler,
        should_stop: *std.atomic.Value(bool),
        poll_interval_ms: u32,
    ) void {
        self.startPolling(handler, should_stop, poll_interval_ms);
    }
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

// --- Integration Test: Telegram parse → route → session key ---

test "integration: telegram parse to route to session key" {
    const routing = @import("routing.zig");
    const access = @import("access.zig");

    // Real-ish Telegram webhook JSON
    const json =
        \\{"update_id":98765,"message":{"message_id":100,"from":{"id":42,"is_bot":false,"first_name":"Alice"},"chat":{"id":42,"type":"private"},"text":"Hello bot!"}}
    ;

    // Step 1: Parse incoming message
    const msg = parseIncomingMessage(json).?;
    try std.testing.expectEqual(plugin.ChannelType.telegram, msg.channel);
    try std.testing.expectEqualStrings("Hello bot!", msg.content);
    try std.testing.expectEqualStrings("42", msg.sender_id);
    try std.testing.expectEqualStrings("42", msg.chat_id);
    try std.testing.expectEqualStrings("98765", msg.message_id);
    try std.testing.expect(!msg.is_group);

    // Step 2: Check access policy
    const policy = access.AccessPolicy{};
    const decision = access.checkAccess(msg, policy);
    try std.testing.expectEqual(access.AccessDecision.allow, decision);

    // Step 3: Resolve session key
    var key_buf: [256]u8 = undefined;
    const session_key = try routing.resolveSessionKey(&key_buf, "main", msg);
    try std.testing.expectEqualStrings("agent:main:telegram:direct:42", session_key);
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

// ======================================================================
// Additional comprehensive tests
// ======================================================================

// --- URL Building Tests ---

test "buildApiUrl for getMe" {
    var buf: [512]u8 = undefined;
    const url = try buildApiUrl(&buf, .{ .bot_token = "123:ABC" }, "getMe");
    try std.testing.expectEqualStrings("https://api.telegram.org/bot123:ABC/getMe", url);
}

test "buildApiUrl for sendPhoto" {
    var buf: [512]u8 = undefined;
    const url = try buildApiUrl(&buf, .{ .bot_token = "tok" }, "sendPhoto");
    try std.testing.expectEqualStrings("https://api.telegram.org/bottok/sendPhoto", url);
}

test "buildApiUrl for sendDocument" {
    var buf: [512]u8 = undefined;
    const url = try buildApiUrl(&buf, .{ .bot_token = "tok" }, "sendDocument");
    try std.testing.expectEqualStrings("https://api.telegram.org/bottok/sendDocument", url);
}

test "buildApiUrl for sendVideo" {
    var buf: [512]u8 = undefined;
    const url = try buildApiUrl(&buf, .{ .bot_token = "tok" }, "sendVideo");
    try std.testing.expectEqualStrings("https://api.telegram.org/bottok/sendVideo", url);
}

test "buildApiUrl for deleteMessage" {
    var buf: [512]u8 = undefined;
    const url = try buildApiUrl(&buf, .{ .bot_token = "tok" }, "deleteMessage");
    try std.testing.expectEqualStrings("https://api.telegram.org/bottok/deleteMessage", url);
}

test "buildApiUrl for editMessageText" {
    var buf: [512]u8 = undefined;
    const url = try buildApiUrl(&buf, .{ .bot_token = "tok" }, "editMessageText");
    try std.testing.expectEqualStrings("https://api.telegram.org/bottok/editMessageText", url);
}

test "buildApiUrl for setWebhook" {
    var buf: [512]u8 = undefined;
    const url = try buildApiUrl(&buf, .{ .bot_token = "tok" }, "setWebhook");
    try std.testing.expectEqualStrings("https://api.telegram.org/bottok/setWebhook", url);
}

test "buildApiUrl custom base URL" {
    var buf: [512]u8 = undefined;
    const url = try buildApiUrl(&buf, .{ .bot_token = "tok", .api_url = "https://custom.api.org" }, "getMe");
    try std.testing.expectEqualStrings("https://custom.api.org/bottok/getMe", url);
}

test "buildApiUrl buffer too small" {
    var buf: [10]u8 = undefined;
    const result = buildApiUrl(&buf, .{ .bot_token = "123:ABC" }, "sendMessage");
    try std.testing.expectError(error.NoSpaceLeft, result);
}

// --- Send Message Body Tests ---

test "buildSendMessageBody with HTML parse_mode" {
    var buf: [4096]u8 = undefined;
    const body = try buildSendMessageBody(&buf, "12345", "<b>bold</b>", "HTML");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"parse_mode\":\"HTML\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":\"<b>bold</b>\"") != null);
}

test "buildSendMessageBody with MarkdownV2 parse_mode" {
    var buf: [4096]u8 = undefined;
    const body = try buildSendMessageBody(&buf, "12345", "hello", "MarkdownV2");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"parse_mode\":\"MarkdownV2\"") != null);
}

test "buildSendMessageBody escapes quotes in text" {
    var buf: [4096]u8 = undefined;
    const body = try buildSendMessageBody(&buf, "123", "He said \"hello\"", null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"hello\\\"") != null);
}

test "buildSendMessageBody escapes newlines" {
    var buf: [4096]u8 = undefined;
    const body = try buildSendMessageBody(&buf, "123", "line1\nline2", null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\n") != null);
}

test "buildSendMessageBody escapes backslash" {
    var buf: [4096]u8 = undefined;
    const body = try buildSendMessageBody(&buf, "123", "path\\to\\file", null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\\") != null);
}

test "buildSendMessageBody escapes tabs" {
    var buf: [4096]u8 = undefined;
    const body = try buildSendMessageBody(&buf, "123", "col1\tcol2", null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\t") != null);
}

test "buildSendMessageBody escapes carriage return" {
    var buf: [4096]u8 = undefined;
    const body = try buildSendMessageBody(&buf, "123", "line1\rline2", null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\r") != null);
}

test "buildSendMessageBody with negative chat_id" {
    var buf: [4096]u8 = undefined;
    const body = try buildSendMessageBody(&buf, "-1001234567890", "group msg", null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"chat_id\":\"-1001234567890\"") != null);
}

test "buildSendMessageBody empty text" {
    var buf: [4096]u8 = undefined;
    const body = try buildSendMessageBody(&buf, "123", "", null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":\"\"") != null);
}

// --- Get Updates Body Tests ---

test "buildGetUpdatesBody with large offset" {
    var buf: [256]u8 = undefined;
    const body = try buildGetUpdatesBody(&buf, 999999999, 60);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"offset\":999999999") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"timeout\":60") != null);
}

test "buildGetUpdatesBody with zero timeout" {
    var buf: [256]u8 = undefined;
    const body = try buildGetUpdatesBody(&buf, null, 0);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"timeout\":0") != null);
}

// --- Update Parsing Tests ---

test "extractChatId negative group ID" {
    const json = "{\"message\":{\"chat\":{\"id\":-1001234567890,\"type\":\"supergroup\"}}}";
    try std.testing.expectEqualStrings("-1001234567890", extractChatId(json).?);
}

test "extractChatId missing chat object" {
    const json = "{\"message\":{\"text\":\"hello\"}}";
    try std.testing.expect(extractChatId(json) == null);
}

test "extractFromId missing from object" {
    const json = "{\"message\":{\"chat\":{\"id\":123}}}";
    try std.testing.expect(extractFromId(json) == null);
}

test "extractUpdateId large value" {
    const json = "{\"update_id\":987654321,\"message\":{}}";
    try std.testing.expectEqual(@as(i64, 987654321), extractUpdateId(json).?);
}

test "extractUpdateId missing" {
    const json = "{\"message\":{\"text\":\"hi\"}}";
    try std.testing.expect(extractUpdateId(json) == null);
}

test "extractFirstName missing" {
    const json = "{\"from\":{\"id\":1}}";
    try std.testing.expect(extractFirstName(json) == null);
}

test "extractFirstName with unicode" {
    const json = "{\"from\":{\"id\":1,\"first_name\":\"Test\"}}";
    try std.testing.expectEqualStrings("Test", extractFirstName(json).?);
}

test "extractMessageText with escaped quotes" {
    const json = "{\"message\":{\"text\":\"He said \\\"hello\\\"\"}}";
    // The parser stops at the first unescaped quote
    const result = extractMessageText(json);
    try std.testing.expect(result != null);
}

// --- Chat Type Detection ---

test "isGroupChat channel type" {
    const json = "{\"chat\":{\"type\":\"channel\"}}";
    // Channels are not detected as group by the current implementation
    try std.testing.expect(!isGroupChat(json));
}

test "isGroupChat no type field" {
    const json = "{\"chat\":{\"id\":123}}";
    try std.testing.expect(!isGroupChat(json));
}

test "isGroupChat empty json" {
    try std.testing.expect(!isGroupChat("{}"));
}

// --- Webhook Payload Parsing ---

test "parseIncomingMessage full webhook payload" {
    const json =
        \\{"update_id":123456789,"message":{"message_id":42,"from":{"id":12345678,"is_bot":false,"first_name":"Alice","last_name":"Smith","username":"alice_s","language_code":"en"},"chat":{"id":12345678,"first_name":"Alice","last_name":"Smith","username":"alice_s","type":"private"},"date":1700000000,"text":"/start"}}
    ;
    const msg = parseIncomingMessage(json).?;
    try std.testing.expectEqual(plugin.ChannelType.telegram, msg.channel);
    try std.testing.expectEqualStrings("/start", msg.content);
    try std.testing.expectEqualStrings("12345678", msg.sender_id);
    try std.testing.expectEqualStrings("12345678", msg.chat_id);
    try std.testing.expect(!msg.is_group);
    try std.testing.expectEqualStrings("123456789", msg.message_id);
}

test "parseIncomingMessage supergroup message" {
    const json =
        \\{"update_id":100,"message":{"text":"hey all","chat":{"id":-1001234,"type":"supergroup","title":"My Group"},"from":{"id":555,"first_name":"Bob"}}}
    ;
    const msg = parseIncomingMessage(json).?;
    try std.testing.expect(msg.is_group);
    try std.testing.expectEqualStrings("-1001234", msg.chat_id);
    try std.testing.expectEqualStrings("hey all", msg.content);
}

test "parseIncomingMessage missing chat_id returns null" {
    const json = "{\"message\":{\"text\":\"hello\",\"from\":{\"id\":1}}}";
    try std.testing.expect(parseIncomingMessage(json) == null);
}

test "parseIncomingMessage missing from returns null" {
    const json = "{\"message\":{\"text\":\"hello\",\"chat\":{\"id\":1}}}";
    try std.testing.expect(parseIncomingMessage(json) == null);
}

test "parseIncomingMessage photo message has no text" {
    const json =
        \\{"update_id":200,"message":{"photo":[{"file_id":"abc"}],"chat":{"id":1,"type":"private"},"from":{"id":2}}}
    ;
    try std.testing.expect(parseIncomingMessage(json) == null);
}

test "parseIncomingMessage edited_message is not parsed" {
    // The parser only looks for "text" key, not the edited wrapper
    const json =
        \\{"update_id":300,"edited_message":{"chat":{"id":1,"type":"private"},"from":{"id":2}}}
    ;
    try std.testing.expect(parseIncomingMessage(json) == null);
}

// --- TelegramConfig Tests ---

test "TelegramConfig custom values" {
    const config = TelegramConfig{
        .bot_token = "123:ABC",
        .api_url = "https://custom.api",
        .poll_timeout = 60,
        .allowed_updates = "message,callback_query",
    };
    try std.testing.expectEqualStrings("123:ABC", config.bot_token);
    try std.testing.expectEqualStrings("https://custom.api", config.api_url);
    try std.testing.expectEqual(@as(u32, 60), config.poll_timeout);
    try std.testing.expectEqualStrings("message,callback_query", config.allowed_updates);
}

// --- TelegramChannel Advanced Tests ---

test "TelegramChannel stop sets disconnected" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{};
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = TelegramChannel.init(allocator, .{ .bot_token = "tok" }, &client);
    channel.status = .connected;

    var p = channel.asPlugin();
    p.stop();
    try std.testing.expectEqual(plugin.ChannelStatus.disconnected, channel.status);
}

test "TelegramChannel pollUpdates group message" {
    const allocator = std.testing.allocator;
    const update_json = "{\"ok\":true,\"result\":[{\"update_id\":200,\"message\":{\"text\":\"group hello\",\"chat\":{\"id\":-100123,\"type\":\"group\"},\"from\":{\"id\":77}}}]}";
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = update_json },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = TelegramChannel.init(allocator, .{ .bot_token = "tok" }, &client);

    const result = try channel.pollUpdates();
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("group hello", result.?.content);
    try std.testing.expect(result.?.is_group);
    try std.testing.expectEqual(@as(i64, 200), channel.last_update_id.?);
}

test "TelegramChannel pollUpdates updates offset" {
    const allocator = std.testing.allocator;
    const resp1 = "{\"ok\":true,\"result\":[{\"update_id\":100,\"message\":{\"text\":\"m1\",\"chat\":{\"id\":1,\"type\":\"private\"},\"from\":{\"id\":2}}}]}";
    const resp2 = "{\"ok\":true,\"result\":[{\"update_id\":101,\"message\":{\"text\":\"m2\",\"chat\":{\"id\":1,\"type\":\"private\"},\"from\":{\"id\":2}}}]}";
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = resp1 },
        .{ .status = 200, .body = resp2 },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = TelegramChannel.init(allocator, .{ .bot_token = "tok" }, &client);

    _ = try channel.pollUpdates();
    try std.testing.expectEqual(@as(i64, 100), channel.last_update_id.?);

    _ = try channel.pollUpdates();
    try std.testing.expectEqual(@as(i64, 101), channel.last_update_id.?);
}

test "TelegramChannel pollUpdates HTTP error returns null" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 500, .body = "{\"ok\":false}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = TelegramChannel.init(allocator, .{ .bot_token = "tok" }, &client);

    const result = try channel.pollUpdates();
    try std.testing.expect(result == null);
}

test "TelegramChannel sendText with parse_mode" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "{\"ok\":true}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = TelegramChannel.init(allocator, .{ .bot_token = "tok" }, &client);

    try channel.sendText(.{ .chat_id = "123", .content = "**bold**", .parse_mode = "Markdown" });
    try std.testing.expect(std.mem.indexOf(u8, mock.last_body.?, "parse_mode") != null);
}

// --- Polling Loop Tests ---

fn echoHandler(_: []const u8, _: []const u8, text: []const u8) ?[]const u8 {
    // Return the same text as the response (echo)
    return text;
}

fn nullHandler(_: []const u8, _: []const u8, _: []const u8) ?[]const u8 {
    return null;
}

test "TelegramChannel startPolling processes message and stops" {
    const allocator = std.testing.allocator;
    // Response 1: getMe (start verification)
    // Response 2: getUpdates returns a message
    // Response 3: sendMessage for the echo reply
    // Response 4: getUpdates returns empty (loop will sleep then check should_stop)
    const update_json = "{\"ok\":true,\"result\":[{\"update_id\":500,\"message\":{\"text\":\"ping\",\"chat\":{\"id\":42,\"type\":\"private\"},\"from\":{\"id\":7}}}]}";
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "{\"ok\":true,\"result\":{\"id\":1,\"is_bot\":true}}" }, // getMe
        .{ .status = 200, .body = update_json }, // getUpdates
        .{ .status = 200, .body = "{\"ok\":true}" }, // sendMessage
        .{ .status = 200, .body = "{\"ok\":true,\"result\":[]}" }, // getUpdates (empty)
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = TelegramChannel.init(allocator, .{ .bot_token = "test-bot" }, &client);

    var should_stop = std.atomic.Value(bool).init(false);

    // Start polling in a thread
    const thread = try channel.startPollingThread(echoHandler, &should_stop, 10);

    // Wait for the mock to be exhausted (all responses consumed)
    var wait_count: u32 = 0;
    while (mock.call_count < 4 and wait_count < 100) : (wait_count += 1) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // Signal stop
    should_stop.store(true, .release);
    thread.join();

    // Verify: getMe + getUpdates + sendMessage + getUpdates = 4 calls
    try std.testing.expect(mock.call_count >= 3); // At least getMe + getUpdates + sendMessage
    try std.testing.expectEqual(@as(i64, 500), channel.last_update_id.?);
    try std.testing.expectEqual(plugin.ChannelStatus.disconnected, channel.status);
}

test "TelegramChannel startPolling stops immediately on auth failure" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 401, .body = "{\"ok\":false}" }, // getMe fails
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = TelegramChannel.init(allocator, .{ .bot_token = "bad-token" }, &client);

    var should_stop = std.atomic.Value(bool).init(false);
    const thread = try channel.startPollingThread(echoHandler, &should_stop, 10);

    // Should exit quickly due to auth failure
    thread.join();

    try std.testing.expectEqual(plugin.ChannelStatus.error_state, channel.status);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count); // Only getMe was called
}

test "TelegramChannel startPolling with null handler skips reply" {
    const allocator = std.testing.allocator;
    const update_json = "{\"ok\":true,\"result\":[{\"update_id\":600,\"message\":{\"text\":\"hello\",\"chat\":{\"id\":10,\"type\":\"private\"},\"from\":{\"id\":20}}}]}";
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "{\"ok\":true,\"result\":{\"id\":1,\"is_bot\":true}}" }, // getMe
        .{ .status = 200, .body = update_json }, // getUpdates
        // No sendMessage expected since handler returns null
        .{ .status = 200, .body = "{\"ok\":true,\"result\":[]}" }, // getUpdates (empty)
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = TelegramChannel.init(allocator, .{ .bot_token = "tok" }, &client);

    var should_stop = std.atomic.Value(bool).init(false);
    const thread = try channel.startPollingThread(nullHandler, &should_stop, 10);

    var wait_count: u32 = 0;
    while (mock.call_count < 3 and wait_count < 100) : (wait_count += 1) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    should_stop.store(true, .release);
    thread.join();

    // getMe + getUpdates + getUpdates(empty) = 3 calls, no sendMessage
    try std.testing.expect(mock.call_count >= 2);
    try std.testing.expectEqual(@as(i64, 600), channel.last_update_id.?);
}

test "MessageHandler type is correct" {
    // Verify the handler type compiles and works
    const handler: TelegramChannel.MessageHandler = echoHandler;
    const result = handler("chat", "sender", "hello");
    try std.testing.expectEqualStrings("hello", result.?);

    const null_handler: TelegramChannel.MessageHandler = nullHandler;
    const null_result = null_handler("chat", "sender", "hello");
    try std.testing.expect(null_result == null);
}

// ======================================================================
// New meaningful tests
// ======================================================================

test "pollUpdates returns null on empty response body" {
    // When the API returns an empty result array, pollUpdates should return null
    // and leave last_update_id unchanged.
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "{\"ok\":true,\"result\":[]}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = TelegramChannel.init(allocator, .{ .bot_token = "tok" }, &client);

    const result = try channel.pollUpdates();
    try std.testing.expect(result == null);
    // last_update_id should remain null since no update was processed
    try std.testing.expect(channel.last_update_id == null);
}

test "pollUpdates with network error returns null for non-200 status" {
    // When the Telegram API returns a non-200 status (e.g. 502), pollUpdates
    // should return null rather than crashing.
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 502, .body = "Bad Gateway" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = TelegramChannel.init(allocator, .{ .bot_token = "tok" }, &client);

    const result = try channel.pollUpdates();
    try std.testing.expect(result == null);
    // Verify no state was mutated
    try std.testing.expect(channel.last_update_id == null);
}

test "TelegramChannel sendText with HTML parse_mode verifies body content" {
    // When sending a message with HTML parse_mode, the body must include the
    // parse_mode field set to "HTML".
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "{\"ok\":true}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = TelegramChannel.init(allocator, .{ .bot_token = "tok" }, &client);
    channel.status = .connected;

    try channel.sendText(.{
        .chat_id = "12345",
        .content = "<b>bold</b> and <i>italic</i>",
        .parse_mode = "HTML",
    });
    try std.testing.expect(mock.last_body != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_body.?, "\"parse_mode\":\"HTML\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_body.?, "<b>bold</b>") != null);
}

test "parseIncomingMessage with group chat type" {
    // A message from a group chat should have is_group = true.
    const json =
        \\{"update_id":500,"message":{"text":"group msg","chat":{"id":-1009876,"type":"group","title":"Dev Chat"},"from":{"id":42,"first_name":"Eve"}}}
    ;
    const msg = parseIncomingMessage(json).?;
    try std.testing.expect(msg.is_group);
    try std.testing.expectEqualStrings("group msg", msg.content);
    try std.testing.expectEqualStrings("-1009876", msg.chat_id);
    try std.testing.expectEqualStrings("42", msg.sender_id);
    try std.testing.expectEqual(plugin.ChannelType.telegram, msg.channel);
}

test "parseIncomingMessage with missing text field returns null" {
    // A message without a text field (e.g. sticker, photo) should return null.
    const json =
        \\{"update_id":600,"message":{"sticker":{"file_id":"sticker123"},"chat":{"id":1,"type":"private"},"from":{"id":2,"first_name":"Bob"}}}
    ;
    try std.testing.expect(parseIncomingMessage(json) == null);
}

test "buildGetUpdatesBody with large offset near i64 max" {
    // Verify that large offset values are serialized correctly without overflow.
    var buf: [512]u8 = undefined;
    const large_offset: i64 = 9_223_372_036_854_775_000; // near i64 max
    const body = try buildGetUpdatesBody(&buf, large_offset, 30);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"offset\":9223372036854775000") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"timeout\":30") != null);
}

test "TelegramChannel start failure sets error_state on auth failure" {
    // When getMe returns 401 (unauthorized), the channel status should be
    // set to error_state and no further requests should be made.
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 401, .body = "{\"ok\":false,\"error_code\":401,\"description\":\"Unauthorized\"}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = TelegramChannel.init(allocator, .{ .bot_token = "invalid-token-123" }, &client);

    try channel.start();
    try std.testing.expectEqual(plugin.ChannelStatus.error_state, channel.status);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
}

test "multiple sequential pollUpdates track offset correctly" {
    // After processing updates sequentially, last_update_id should reflect
    // the most recent update_id.
    const allocator = std.testing.allocator;
    const resp1 = "{\"ok\":true,\"result\":[{\"update_id\":1000,\"message\":{\"text\":\"first\",\"chat\":{\"id\":1,\"type\":\"private\"},\"from\":{\"id\":2}}}]}";
    const resp2 = "{\"ok\":true,\"result\":[{\"update_id\":1001,\"message\":{\"text\":\"second\",\"chat\":{\"id\":1,\"type\":\"private\"},\"from\":{\"id\":2}}}]}";
    const resp3 = "{\"ok\":true,\"result\":[{\"update_id\":1002,\"message\":{\"text\":\"third\",\"chat\":{\"id\":1,\"type\":\"private\"},\"from\":{\"id\":2}}}]}";
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = resp1 },
        .{ .status = 200, .body = resp2 },
        .{ .status = 200, .body = resp3 },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var channel = TelegramChannel.init(allocator, .{ .bot_token = "tok" }, &client);

    // First poll
    const r1 = try channel.pollUpdates();
    try std.testing.expect(r1 != null);
    try std.testing.expectEqualStrings("first", r1.?.content);
    try std.testing.expectEqual(@as(i64, 1000), channel.last_update_id.?);

    // Second poll: offset tracking
    const r2 = try channel.pollUpdates();
    try std.testing.expect(r2 != null);
    try std.testing.expectEqualStrings("second", r2.?.content);
    try std.testing.expectEqual(@as(i64, 1001), channel.last_update_id.?);

    // Third poll: offset tracking
    const r3 = try channel.pollUpdates();
    try std.testing.expect(r3 != null);
    try std.testing.expectEqualStrings("third", r3.?.content);
    try std.testing.expectEqual(@as(i64, 1002), channel.last_update_id.?);

    // Verify all 3 requests were made
    try std.testing.expectEqual(@as(usize, 3), mock.call_count);
}

test "parseIncomingMessage extracts first_name into sender_name" {
    // The parser should correctly extract the from.first_name field
    // and set it as sender_name on the IncomingMessage.
    const json =
        \\{"update_id":700,"message":{"text":"hello","chat":{"id":55,"type":"private"},"from":{"id":99,"first_name":"Zara"}}}
    ;
    const msg = parseIncomingMessage(json).?;
    try std.testing.expect(msg.sender_name != null);
    try std.testing.expectEqualStrings("Zara", msg.sender_name.?);
}

test "buildApiUrl for sendPhoto and editMessageText endpoints" {
    // Verify that buildApiUrl correctly generates URLs for various Telegram
    // API endpoints beyond sendMessage/getUpdates.
    var buf: [512]u8 = undefined;
    const config = TelegramConfig{ .bot_token = "123:ABCDEF" };

    const photo_url = try buildApiUrl(&buf, config, "sendPhoto");
    try std.testing.expectEqualStrings("https://api.telegram.org/bot123:ABCDEF/sendPhoto", photo_url);

    const edit_url = try buildApiUrl(&buf, config, "editMessageText");
    try std.testing.expectEqualStrings("https://api.telegram.org/bot123:ABCDEF/editMessageText", edit_url);

    const del_url = try buildApiUrl(&buf, config, "deleteWebhook");
    try std.testing.expectEqualStrings("https://api.telegram.org/bot123:ABCDEF/deleteWebhook", del_url);

    const info_url = try buildApiUrl(&buf, config, "getWebhookInfo");
    try std.testing.expectEqualStrings("https://api.telegram.org/bot123:ABCDEF/getWebhookInfo", info_url);
}
