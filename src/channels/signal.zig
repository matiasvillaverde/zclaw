const std = @import("std");
const plugin = @import("plugin.zig");

// --- Signal CLI Bridge Constants ---

pub const DEFAULT_SIGNAL_CLI = "signal-cli";
pub const JSON_RPC_MODE = "jsonRpc";

// --- Signal Config ---

pub const SignalConfig = struct {
    phone_number: []const u8,
    signal_cli_path: []const u8 = DEFAULT_SIGNAL_CLI,
    config_dir: ?[]const u8 = null,
    trust_all_keys: bool = false,
};

// --- Signal Message Types ---

pub const SignalMessageType = enum {
    text,
    attachment,
    reaction,
    receipt,
    typing,
    group_update,

    pub fn label(self: SignalMessageType) []const u8 {
        return switch (self) {
            .text => "text",
            .attachment => "attachment",
            .reaction => "reaction",
            .receipt => "receipt",
            .typing => "typing",
            .group_update => "group_update",
        };
    }

    pub fn fromString(s: []const u8) ?SignalMessageType {
        const map = std.StaticStringMap(SignalMessageType).initComptime(.{
            .{ "text", .text },
            .{ "attachment", .attachment },
            .{ "reaction", .reaction },
            .{ "receipt", .receipt },
            .{ "typing", .typing },
            .{ "group_update", .group_update },
        });
        return map.get(s);
    }
};

// --- JSON-RPC Request Builder ---

pub fn buildJsonRpcRequest(buf: []u8, id: u32, method: []const u8, params: ?[]const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.fmt.format(w, "{d}", .{id});
    try w.writeAll(",\"method\":\"");
    try w.writeAll(method);
    try w.writeAll("\"");
    if (params) |p| {
        try w.writeAll(",\"params\":");
        try w.writeAll(p);
    }
    try w.writeAll("}\n");
    return fbs.getWritten();
}

pub fn buildSendRequest(buf: []u8, id: u32, recipient: []const u8, message: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.fmt.format(w, "{d}", .{id});
    try w.writeAll(",\"method\":\"send\",\"params\":{\"recipient\":[\"");
    try w.writeAll(recipient);
    try w.writeAll("\"],\"message\":\"");
    try writeJsonEscaped(w, message);
    try w.writeAll("\"}}\n");
    return fbs.getWritten();
}

pub fn buildReceiveRequest(buf: []u8, id: u32) ![]const u8 {
    return buildJsonRpcRequest(buf, id, "receive", null);
}

// --- CLI Command Builder ---

pub fn buildCliArgs(buf: []u8, config: SignalConfig, command: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll(config.signal_cli_path);
    if (config.config_dir) |dir| {
        try w.writeAll(" --config ");
        try w.writeAll(dir);
    }
    if (config.trust_all_keys) {
        try w.writeAll(" --trust-new-identities always");
    }
    try w.writeAll(" -u ");
    try w.writeAll(config.phone_number);
    try w.writeAll(" ");
    try w.writeAll(command);
    return fbs.getWritten();
}

// --- Response Parsing ---

pub fn extractMessageBody(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"message\":\"");
}

pub fn extractSourceNumber(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"sourceNumber\":\"");
}

pub fn extractGroupId(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"groupId\":\"");
}

pub fn extractTimestamp(json: []const u8) ?i64 {
    return extractJsonNumber(json, "\"timestamp\":");
}

pub fn extractSourceName(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"sourceName\":\"");
}

pub fn extractJsonRpcId(json: []const u8) ?i64 {
    return extractJsonNumber(json, "\"id\":");
}

pub fn extractJsonRpcError(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"message\":\"");
}

pub fn isJsonRpcError(json: []const u8) bool {
    return std.mem.indexOf(u8, json, "\"error\":{") != null;
}

// --- Incoming Message Parser ---

pub fn parseIncomingMessage(json: []const u8) ?plugin.IncomingMessage {
    const body = extractMessageBody(json) orelse return null;
    const source = extractSourceNumber(json) orelse return null;

    const is_group = extractGroupId(json) != null;
    const chat_id = extractGroupId(json) orelse source;

    return .{
        .channel = .signal,
        .message_id = "", // Signal uses timestamp as ID
        .sender_id = source,
        .sender_name = extractSourceName(json),
        .chat_id = chat_id,
        .content = body,
        .is_group = is_group,
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
    if (json[value_start] == 'n') return null;
    var end = value_start;
    while (end < json.len and (json[end] >= '0' and json[end] <= '9')) : (end += 1) {}
    if (end == value_start) return null;
    return std.fmt.parseInt(i64, json[value_start..end], 10) catch null;
}

// --- Tests ---

test "buildJsonRpcRequest" {
    var buf: [256]u8 = undefined;
    const req = try buildJsonRpcRequest(&buf, 1, "receive", null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"method\":\"receive\"") != null);
}

test "buildJsonRpcRequest with params" {
    var buf: [256]u8 = undefined;
    const req = try buildJsonRpcRequest(&buf, 2, "send", "{\"recipient\":[\"+1234\"]}");
    try std.testing.expect(std.mem.indexOf(u8, req, "\"params\":") != null);
}

test "buildSendRequest" {
    var buf: [512]u8 = undefined;
    const req = try buildSendRequest(&buf, 1, "+1234567890", "Hello Signal!");
    try std.testing.expect(std.mem.indexOf(u8, req, "\"method\":\"send\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "+1234567890") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Hello Signal!") != null);
}

test "buildReceiveRequest" {
    var buf: [256]u8 = undefined;
    const req = try buildReceiveRequest(&buf, 5);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"method\":\"receive\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"id\":5") != null);
}

test "buildCliArgs basic" {
    var buf: [512]u8 = undefined;
    const args = try buildCliArgs(&buf, .{ .phone_number = "+1234567890" }, "receive");
    try std.testing.expect(std.mem.indexOf(u8, args, "signal-cli") != null);
    try std.testing.expect(std.mem.indexOf(u8, args, "+1234567890") != null);
    try std.testing.expect(std.mem.indexOf(u8, args, "receive") != null);
}

test "buildCliArgs with config_dir" {
    var buf: [512]u8 = undefined;
    const args = try buildCliArgs(&buf, .{ .phone_number = "+1", .config_dir = "/etc/signal" }, "send");
    try std.testing.expect(std.mem.indexOf(u8, args, "--config /etc/signal") != null);
}

test "buildCliArgs with trust_all" {
    var buf: [512]u8 = undefined;
    const args = try buildCliArgs(&buf, .{ .phone_number = "+1", .trust_all_keys = true }, "receive");
    try std.testing.expect(std.mem.indexOf(u8, args, "--trust-new-identities always") != null);
}

test "extractMessageBody" {
    const json = "{\"envelope\":{\"dataMessage\":{\"message\":\"Hello from Signal\"}}}";
    try std.testing.expectEqualStrings("Hello from Signal", extractMessageBody(json).?);
}

test "extractSourceNumber" {
    const json = "{\"envelope\":{\"sourceNumber\":\"+1234567890\"}}";
    try std.testing.expectEqualStrings("+1234567890", extractSourceNumber(json).?);
}

test "extractGroupId" {
    const json = "{\"envelope\":{\"dataMessage\":{\"groupId\":\"group-abc-123\"}}}";
    try std.testing.expectEqualStrings("group-abc-123", extractGroupId(json).?);
}

test "extractGroupId missing" {
    const json = "{\"envelope\":{\"sourceNumber\":\"+1\"}}";
    try std.testing.expect(extractGroupId(json) == null);
}

test "extractTimestamp" {
    const json = "{\"envelope\":{\"timestamp\":1234567890}}";
    try std.testing.expectEqual(@as(i64, 1234567890), extractTimestamp(json).?);
}

test "extractSourceName" {
    const json = "{\"envelope\":{\"sourceName\":\"Alice\"}}";
    try std.testing.expectEqualStrings("Alice", extractSourceName(json).?);
}

test "isJsonRpcError true" {
    const json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-1,\"message\":\"Failed\"}}";
    try std.testing.expect(isJsonRpcError(json));
}

test "isJsonRpcError false" {
    const json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}";
    try std.testing.expect(!isJsonRpcError(json));
}

test "parseIncomingMessage DM" {
    const json = "{\"envelope\":{\"sourceNumber\":\"+1234\",\"sourceName\":\"Bob\",\"dataMessage\":{\"message\":\"Hey\"}}}";
    const msg = parseIncomingMessage(json).?;
    try std.testing.expectEqual(plugin.ChannelType.signal, msg.channel);
    try std.testing.expectEqualStrings("Hey", msg.content);
    try std.testing.expectEqualStrings("+1234", msg.sender_id);
    try std.testing.expect(!msg.is_group);
}

test "parseIncomingMessage group" {
    const json = "{\"envelope\":{\"sourceNumber\":\"+1234\",\"dataMessage\":{\"message\":\"Hi group\",\"groupId\":\"g1\"}}}";
    const msg = parseIncomingMessage(json).?;
    try std.testing.expect(msg.is_group);
    try std.testing.expectEqualStrings("g1", msg.chat_id);
}

test "parseIncomingMessage no body" {
    const json = "{\"envelope\":{\"sourceNumber\":\"+1234\"}}";
    try std.testing.expect(parseIncomingMessage(json) == null);
}

test "SignalMessageType fromString and label" {
    try std.testing.expectEqual(SignalMessageType.text, SignalMessageType.fromString("text").?);
    try std.testing.expectEqualStrings("reaction", SignalMessageType.reaction.label());
    try std.testing.expectEqual(@as(?SignalMessageType, null), SignalMessageType.fromString("xyz"));
}

test "SignalConfig defaults" {
    const config = SignalConfig{ .phone_number = "+1" };
    try std.testing.expectEqualStrings(DEFAULT_SIGNAL_CLI, config.signal_cli_path);
    try std.testing.expect(config.config_dir == null);
    try std.testing.expect(!config.trust_all_keys);
}
