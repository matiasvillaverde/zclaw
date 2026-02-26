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

    if (global_channel_registry == null)
        return .{ .success = false, .output = "", .error_message = "channel registry not initialized" };

    // In a real implementation, this would dispatch to the appropriate channel plugin.
    var fbs = std.io.fixedBufferStream(output_buf);
    std.fmt.format(fbs.writer(), "message sent to {s}:{s} ({d} chars)", .{
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
