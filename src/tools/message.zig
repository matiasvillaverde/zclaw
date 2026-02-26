const std = @import("std");
const registry = @import("registry.zig");

// --- Message Send Tool ---
//
// Agent-to-channel message sending via module-level channel registry.

const plugin_mod = @import("../channels/plugin.zig");

var global_channel_registry: ?*plugin_mod.ChannelRegistry = null;

/// Set the channel registry for message sending.
pub fn setChannelRegistry(reg: *plugin_mod.ChannelRegistry) void {
    global_channel_registry = reg;
}

/// Clear the channel registry reference.
pub fn clearChannelRegistry() void {
    global_channel_registry = null;
}

fn extractParam(json: []const u8, key: []const u8) ?[]const u8 {
    var prefix_buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&prefix_buf);
    fbs.writer().writeByte('"') catch return null;
    fbs.writer().writeAll(key) catch return null;
    fbs.writer().writeAll("\":\"") catch return null;
    const prefix = fbs.getWritten();

    const start = std.mem.indexOf(u8, json, prefix) orelse return null;
    const value_start = start + prefix.len;
    if (value_start >= json.len) return null;

    var i = value_start;
    while (i < json.len) : (i += 1) {
        if (json[i] == '"' and (i == value_start or json[i - 1] != '\\')) {
            return json[value_start..i];
        }
    }
    return null;
}

/// Message send tool handler.
/// Input: {"channel": "telegram", "chat_id": "12345", "content": "Hello"}
pub fn messageSendHandler(input_json: []const u8, output_buf: []u8) registry.ToolResult {
    const channel = extractParam(input_json, "channel") orelse
        return .{ .success = false, .output = "", .error_message = "missing 'channel' parameter" };

    const chat_id = extractParam(input_json, "chat_id") orelse
        return .{ .success = false, .output = "", .error_message = "missing 'chat_id' parameter" };

    const content = extractParam(input_json, "content") orelse
        return .{ .success = false, .output = "", .error_message = "missing 'content' parameter" };

    if (content.len == 0)
        return .{ .success = false, .output = "", .error_message = "empty content" };

    const reg = global_channel_registry orelse
        return .{ .success = false, .output = "", .error_message = "channel registry not initialized" };

    var plugin = reg.get(channel) orelse {
        var fbs = std.io.fixedBufferStream(output_buf);
        std.fmt.format(fbs.writer(), "channel '{s}' not found", .{channel}) catch {};
        return .{ .success = false, .output = "", .error_message = fbs.getWritten() };
    };

    plugin.sendText(.{ .chat_id = chat_id, .content = content }) catch {
        return .{ .success = false, .output = "", .error_message = "send failed" };
    };

    var fbs = std.io.fixedBufferStream(output_buf);
    std.fmt.format(fbs.writer(), "Message sent to {s}:{s} ({d} chars)", .{
        channel, chat_id, content.len,
    }) catch return .{ .success = false, .output = "", .error_message = "output buffer overflow" };

    return .{
        .success = true,
        .output = fbs.getWritten(),
    };
}

pub const BUILTIN_MESSAGE_SEND = registry.ToolDef{
    .name = "message_send",
    .description = "Send a message to a channel",
    .category = .message,
    .parameters_json = "{\"type\":\"object\",\"properties\":{\"channel\":{\"type\":\"string\"},\"chat_id\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"channel\",\"chat_id\",\"content\"]}",
};

/// Register message tools with the registry.
pub fn registerMessageTools(reg: *registry.ToolRegistry) !void {
    try reg.register(BUILTIN_MESSAGE_SEND, messageSendHandler);
}

// --- Test Mock Channel ---

const TestMockChannel = struct {
    status: plugin_mod.ChannelStatus = .connected,
    sent_count: u32 = 0,
    last_chat_id: ?[]const u8 = null,
    last_content: ?[]const u8 = null,
    should_fail: bool = false,

    const vtable = plugin_mod.PluginVTable{
        .start = startImpl,
        .stop = stopImpl,
        .send_text = sendTextImpl,
        .get_status = getStatusImpl,
        .get_type = getTypeImpl,
    };

    fn startImpl(ctx: *anyopaque) anyerror!void {
        const self: *TestMockChannel = @ptrCast(@alignCast(ctx));
        self.status = .connected;
    }

    fn stopImpl(ctx: *anyopaque) void {
        const self: *TestMockChannel = @ptrCast(@alignCast(ctx));
        self.status = .disconnected;
    }

    fn sendTextImpl(ctx: *anyopaque, msg: plugin_mod.OutgoingMessage) anyerror!void {
        const self: *TestMockChannel = @ptrCast(@alignCast(ctx));
        if (self.should_fail) return error.SendFailed;
        self.sent_count += 1;
        self.last_chat_id = msg.chat_id;
        self.last_content = msg.content;
    }

    fn getStatusImpl(ctx: *anyopaque) plugin_mod.ChannelStatus {
        const self: *const TestMockChannel = @ptrCast(@alignCast(ctx));
        return self.status;
    }

    fn getTypeImpl(_: *anyopaque) plugin_mod.ChannelType {
        return .telegram;
    }

    fn asPlugin(self: *TestMockChannel) plugin_mod.ChannelPlugin {
        return .{
            .vtable = &vtable,
            .ctx = @ptrCast(self),
        };
    }
};

// --- Tests ---

test "messageSendHandler missing channel" {
    var buf: [4096]u8 = undefined;
    const result = messageSendHandler("{\"chat_id\":\"1\",\"content\":\"hi\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("missing 'channel' parameter", result.error_message.?);
}

test "messageSendHandler missing chat_id" {
    var buf: [4096]u8 = undefined;
    const result = messageSendHandler("{\"channel\":\"telegram\",\"content\":\"hi\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("missing 'chat_id' parameter", result.error_message.?);
}

test "messageSendHandler missing content" {
    var buf: [4096]u8 = undefined;
    const result = messageSendHandler("{\"channel\":\"telegram\",\"chat_id\":\"1\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("missing 'content' parameter", result.error_message.?);
}

test "messageSendHandler empty content" {
    var buf: [4096]u8 = undefined;
    const result = messageSendHandler("{\"channel\":\"telegram\",\"chat_id\":\"1\",\"content\":\"\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("empty content", result.error_message.?);
}

test "messageSendHandler no registry" {
    clearChannelRegistry();
    var buf: [4096]u8 = undefined;
    const result = messageSendHandler("{\"channel\":\"telegram\",\"chat_id\":\"1\",\"content\":\"hello\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("channel registry not initialized", result.error_message.?);
}

test "registerMessageTools" {
    const allocator = std.testing.allocator;
    var reg = registry.ToolRegistry.init(allocator);
    defer reg.deinit();

    try registerMessageTools(&reg);
    try std.testing.expectEqual(@as(usize, 1), reg.count());
    try std.testing.expect(reg.get("message_send") != null);
}

test "BUILTIN_MESSAGE_SEND definition" {
    try std.testing.expectEqualStrings("message_send", BUILTIN_MESSAGE_SEND.name);
    try std.testing.expectEqual(registry.ToolCategory.message, BUILTIN_MESSAGE_SEND.category);
    try std.testing.expect(BUILTIN_MESSAGE_SEND.parameters_json != null);
}

test "setChannelRegistry and clearChannelRegistry" {
    clearChannelRegistry();
    try std.testing.expect(global_channel_registry == null);
}

test "messageSendHandler dispatches to channel" {
    const allocator = std.testing.allocator;
    var chan_reg = plugin_mod.ChannelRegistry.init(allocator);
    defer chan_reg.deinit();

    var mock_channel = TestMockChannel{};
    try chan_reg.register("telegram", mock_channel.asPlugin());

    setChannelRegistry(&chan_reg);
    defer clearChannelRegistry();

    var buf: [4096]u8 = undefined;
    const result = messageSendHandler("{\"channel\":\"telegram\",\"chat_id\":\"12345\",\"content\":\"Hello there!\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u32, 1), mock_channel.sent_count);
    try std.testing.expectEqualStrings("12345", mock_channel.last_chat_id.?);
    try std.testing.expectEqualStrings("Hello there!", mock_channel.last_content.?);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Message sent to telegram:12345") != null);
}

test "messageSendHandler unknown channel" {
    const allocator = std.testing.allocator;
    var chan_reg = plugin_mod.ChannelRegistry.init(allocator);
    defer chan_reg.deinit();

    setChannelRegistry(&chan_reg);
    defer clearChannelRegistry();

    var buf: [4096]u8 = undefined;
    const result = messageSendHandler("{\"channel\":\"nonexistent\",\"chat_id\":\"1\",\"content\":\"hi\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_message.?, "not found") != null);
}

// --- Integration Test: message send → real TelegramChannel dispatch ---

test "integration: messageSendHandler with real TelegramChannel" {
    const http_client_mod = @import("../infra/http_client.zig");
    const telegram = @import("../channels/telegram.zig");

    const allocator = std.testing.allocator;

    // Mock HTTP transport for Telegram API
    const responses = [_]http_client_mod.MockTransport.MockResponse{
        .{ .status = 200, .body = "{\"ok\":true,\"result\":{\"message_id\":1}}" },
    };
    var mock = http_client_mod.MockTransport.init(&responses);
    var client = http_client_mod.HttpClient.init(allocator, mock.transport());

    // Real TelegramChannel
    var tg_channel = telegram.TelegramChannel.init(allocator, .{ .bot_token = "test-bot-token" }, &client);
    tg_channel.status = .connected;

    // Register in ChannelRegistry
    var chan_reg = plugin_mod.ChannelRegistry.init(allocator);
    defer chan_reg.deinit();
    try chan_reg.register("telegram", tg_channel.asPlugin());

    setChannelRegistry(&chan_reg);
    defer clearChannelRegistry();

    // Send via handler
    var buf: [4096]u8 = undefined;
    const result = messageSendHandler("{\"channel\":\"telegram\",\"chat_id\":\"99999\",\"content\":\"Integration test!\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Message sent to telegram:99999") != null);

    // Verify mock HTTP was called with correct Telegram API URL
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
}

test "messageSendHandler send failure" {
    const allocator = std.testing.allocator;
    var chan_reg = plugin_mod.ChannelRegistry.init(allocator);
    defer chan_reg.deinit();

    var mock_channel = TestMockChannel{ .should_fail = true };
    try chan_reg.register("telegram", mock_channel.asPlugin());

    setChannelRegistry(&chan_reg);
    defer clearChannelRegistry();

    var buf: [4096]u8 = undefined;
    const result = messageSendHandler("{\"channel\":\"telegram\",\"chat_id\":\"1\",\"content\":\"hi\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("send failed", result.error_message.?);
}
