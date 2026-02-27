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

var timestamp_buf: [32]u8 = undefined;

fn formatTimestamp(json: []const u8) []const u8 {
    const ts = extractTimestamp(json) orelse return "";
    var fbs = std.io.fixedBufferStream(&timestamp_buf);
    std.fmt.format(fbs.writer(), "{d}", .{ts}) catch return "";
    return fbs.getWritten();
}

pub fn parseIncomingMessage(json: []const u8) ?plugin.IncomingMessage {
    const body = extractMessageBody(json) orelse return null;
    const source = extractSourceNumber(json) orelse return null;

    const is_group = extractGroupId(json) != null;
    const chat_id = extractGroupId(json) orelse source;

    return .{
        .channel = .signal,
        .message_id = formatTimestamp(json),
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

test "parseIncomingMessage includes timestamp as message_id" {
    const json = "{\"envelope\":{\"sourceNumber\":\"+1234\",\"timestamp\":1700000000,\"dataMessage\":{\"message\":\"Hey\"}}}";
    const msg = parseIncomingMessage(json).?;
    try std.testing.expectEqualStrings("1700000000", msg.message_id);
}

test "parseIncomingMessage missing timestamp gives empty" {
    const json = "{\"envelope\":{\"sourceNumber\":\"+1234\",\"dataMessage\":{\"message\":\"Hey\"}}}";
    const msg = parseIncomingMessage(json).?;
    try std.testing.expectEqualStrings("", msg.message_id);
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

// ======================================================================
// Additional comprehensive tests
// ======================================================================

// --- JSON-RPC Request Builder Tests ---

test "buildJsonRpcRequest list_groups method" {
    var buf: [256]u8 = undefined;
    const req = try buildJsonRpcRequest(&buf, 10, "list_groups", null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"id\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"method\":\"list_groups\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"params\":") == null);
}

test "buildJsonRpcRequest ends with newline" {
    var buf: [256]u8 = undefined;
    const req = try buildJsonRpcRequest(&buf, 1, "receive", null);
    try std.testing.expect(std.mem.endsWith(u8, req, "\n"));
}

test "buildJsonRpcRequest with complex params" {
    var buf: [512]u8 = undefined;
    const req = try buildJsonRpcRequest(&buf, 3, "send", "{\"recipient\":[\"+1234\"],\"message\":\"hello\",\"attachments\":[\"file.png\"]}");
    try std.testing.expect(std.mem.indexOf(u8, req, "\"params\":{\"recipient\":[\"+1234\"]") != null);
}

test "buildJsonRpcRequest id zero" {
    var buf: [256]u8 = undefined;
    const req = try buildJsonRpcRequest(&buf, 0, "test", null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"id\":0") != null);
}

test "buildJsonRpcRequest large id" {
    var buf: [256]u8 = undefined;
    const req = try buildJsonRpcRequest(&buf, 999999, "test", null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"id\":999999") != null);
}

// --- Send Request Tests ---

test "buildSendRequest escapes quotes in message" {
    var buf: [512]u8 = undefined;
    const req = try buildSendRequest(&buf, 1, "+1234", "He said \"hello\"");
    try std.testing.expect(std.mem.indexOf(u8, req, "\\\"hello\\\"") != null);
}

test "buildSendRequest escapes newlines in message" {
    var buf: [512]u8 = undefined;
    const req = try buildSendRequest(&buf, 1, "+1234", "line1\nline2");
    try std.testing.expect(std.mem.indexOf(u8, req, "\\n") != null);
}

test "buildSendRequest international number" {
    var buf: [512]u8 = undefined;
    const req = try buildSendRequest(&buf, 2, "+4915112345678", "Hallo!");
    try std.testing.expect(std.mem.indexOf(u8, req, "+4915112345678") != null);
}

test "buildSendRequest ends with newline" {
    var buf: [512]u8 = undefined;
    const req = try buildSendRequest(&buf, 1, "+1234", "hi");
    try std.testing.expect(std.mem.endsWith(u8, req, "\n"));
}

// --- Receive Request Tests ---

test "buildReceiveRequest structure" {
    var buf: [256]u8 = undefined;
    const req = try buildReceiveRequest(&buf, 10);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"id\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"method\":\"receive\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"params\":") == null);
}

// --- CLI Args Tests ---

test "buildCliArgs with all options" {
    var buf: [512]u8 = undefined;
    const args = try buildCliArgs(&buf, .{
        .phone_number = "+15551234567",
        .signal_cli_path = "/usr/local/bin/signal-cli",
        .config_dir = "/home/user/.config/signal",
        .trust_all_keys = true,
    }, "send");
    try std.testing.expect(std.mem.indexOf(u8, args, "/usr/local/bin/signal-cli") != null);
    try std.testing.expect(std.mem.indexOf(u8, args, "--config /home/user/.config/signal") != null);
    try std.testing.expect(std.mem.indexOf(u8, args, "--trust-new-identities always") != null);
    try std.testing.expect(std.mem.indexOf(u8, args, "-u +15551234567") != null);
    try std.testing.expect(std.mem.indexOf(u8, args, "send") != null);
}

test "buildCliArgs without optional flags" {
    var buf: [512]u8 = undefined;
    const args = try buildCliArgs(&buf, .{ .phone_number = "+1" }, "receive");
    try std.testing.expect(std.mem.indexOf(u8, args, "--config") == null);
    try std.testing.expect(std.mem.indexOf(u8, args, "--trust-new-identities") == null);
}

test "buildCliArgs custom signal_cli_path" {
    var buf: [512]u8 = undefined;
    const args = try buildCliArgs(&buf, .{
        .phone_number = "+1",
        .signal_cli_path = "/opt/signal/signal-cli-0.12.0/bin/signal-cli",
    }, "daemon");
    try std.testing.expect(std.mem.startsWith(u8, args, "/opt/signal/signal-cli-0.12.0/bin/signal-cli"));
}

test "buildCliArgs register command" {
    var buf: [512]u8 = undefined;
    const args = try buildCliArgs(&buf, .{ .phone_number = "+15559999999" }, "register");
    try std.testing.expect(std.mem.endsWith(u8, args, "register"));
}

test "buildCliArgs link command" {
    var buf: [512]u8 = undefined;
    const args = try buildCliArgs(&buf, .{ .phone_number = "+1" }, "link");
    try std.testing.expect(std.mem.endsWith(u8, args, "link"));
}

// --- Response Parsing Tests ---

test "extractMessageBody from data message" {
    const json = "{\"envelope\":{\"source\":\"+1234\",\"dataMessage\":{\"timestamp\":1700000000,\"message\":\"Hello!\",\"expiresInSeconds\":0}}}";
    try std.testing.expectEqualStrings("Hello!", extractMessageBody(json).?);
}

test "extractMessageBody missing" {
    const json = "{\"envelope\":{\"source\":\"+1234\"}}";
    try std.testing.expect(extractMessageBody(json) == null);
}

test "extractSourceNumber international" {
    const json = "{\"envelope\":{\"sourceNumber\":\"+4915112345678\"}}";
    try std.testing.expectEqualStrings("+4915112345678", extractSourceNumber(json).?);
}

test "extractSourceNumber missing" {
    const json = "{\"envelope\":{\"timestamp\":123}}";
    try std.testing.expect(extractSourceNumber(json) == null);
}

test "extractGroupId base64 encoded" {
    const json = "{\"envelope\":{\"dataMessage\":{\"groupId\":\"ABCDEF1234567890==\"}}}";
    try std.testing.expectEqualStrings("ABCDEF1234567890==", extractGroupId(json).?);
}

test "extractTimestamp large value" {
    const json = "{\"envelope\":{\"timestamp\":1700000000000}}";
    try std.testing.expectEqual(@as(i64, 1700000000000), extractTimestamp(json).?);
}

test "extractTimestamp missing" {
    const json = "{\"envelope\":{\"sourceNumber\":\"+1\"}}";
    try std.testing.expect(extractTimestamp(json) == null);
}

test "extractSourceName with spaces" {
    const json = "{\"envelope\":{\"sourceName\":\"John Doe Smith\"}}";
    try std.testing.expectEqualStrings("John Doe Smith", extractSourceName(json).?);
}

test "extractSourceName missing" {
    const json = "{\"envelope\":{\"sourceNumber\":\"+1\"}}";
    try std.testing.expect(extractSourceName(json) == null);
}

test "extractJsonRpcId" {
    const json = "{\"jsonrpc\":\"2.0\",\"id\":42,\"result\":{}}";
    try std.testing.expectEqual(@as(i64, 42), extractJsonRpcId(json).?);
}

test "extractJsonRpcId zero" {
    const json = "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{}}";
    try std.testing.expectEqual(@as(i64, 0), extractJsonRpcId(json).?);
}

test "extractJsonRpcError message" {
    const json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-1,\"message\":\"User not registered\"}}";
    try std.testing.expectEqualStrings("User not registered", extractJsonRpcError(json).?);
}

test "extractJsonRpcError missing" {
    const json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}";
    // extractJsonRpcError looks for "message" key which is also in error responses
    // In success responses there's no "message" field so it should return null
    try std.testing.expect(extractJsonRpcError(json) == null);
}

test "isJsonRpcError with nested error object" {
    const json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"}}";
    try std.testing.expect(isJsonRpcError(json));
}

test "isJsonRpcError success response" {
    const json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"timestamp\":123}}";
    try std.testing.expect(!isJsonRpcError(json));
}

// --- Incoming Message Parser Tests ---

test "parseIncomingMessage full envelope" {
    const json = "{\"envelope\":{\"sourceNumber\":\"+15551234567\",\"sourceName\":\"Alice\",\"timestamp\":1700000001,\"dataMessage\":{\"message\":\"Hi from Signal!\",\"groupId\":null}}}";
    const msg = parseIncomingMessage(json).?;
    try std.testing.expectEqual(plugin.ChannelType.signal, msg.channel);
    try std.testing.expectEqualStrings("Hi from Signal!", msg.content);
    try std.testing.expectEqualStrings("+15551234567", msg.sender_id);
    try std.testing.expectEqualStrings("Alice", msg.sender_name.?);
    try std.testing.expect(!msg.is_group);
}

test "parseIncomingMessage group with group ID as chat_id" {
    const json = "{\"envelope\":{\"sourceNumber\":\"+1234\",\"dataMessage\":{\"message\":\"Group hello\",\"groupId\":\"group-abc\"}}}";
    const msg = parseIncomingMessage(json).?;
    try std.testing.expect(msg.is_group);
    try std.testing.expectEqualStrings("group-abc", msg.chat_id);
    try std.testing.expectEqualStrings("+1234", msg.sender_id);
}

test "parseIncomingMessage DM uses source as chat_id" {
    const json = "{\"envelope\":{\"sourceNumber\":\"+5551234\",\"dataMessage\":{\"message\":\"DM\"}}}";
    const msg = parseIncomingMessage(json).?;
    try std.testing.expect(!msg.is_group);
    try std.testing.expectEqualStrings("+5551234", msg.chat_id);
}

test "parseIncomingMessage reaction only has no message body" {
    const json = "{\"envelope\":{\"sourceNumber\":\"+1234\",\"dataMessage\":{\"reaction\":{\"emoji\":\"👍\",\"targetTimestamp\":123}}}}";
    try std.testing.expect(parseIncomingMessage(json) == null);
}

test "parseIncomingMessage receipt only has no message body" {
    const json = "{\"envelope\":{\"sourceNumber\":\"+1234\",\"receiptMessage\":{\"type\":\"DELIVERY\",\"timestamps\":[123]}}}";
    try std.testing.expect(parseIncomingMessage(json) == null);
}

test "parseIncomingMessage typing indicator has no message body" {
    const json = "{\"envelope\":{\"sourceNumber\":\"+1234\",\"typingMessage\":{\"action\":\"STARTED\"}}}";
    try std.testing.expect(parseIncomingMessage(json) == null);
}

// --- SignalMessageType Tests ---

test "SignalMessageType all types roundtrip" {
    const types = [_]SignalMessageType{ .text, .attachment, .reaction, .receipt, .typing, .group_update };
    for (types) |t| {
        const label_str = t.label();
        const parsed = SignalMessageType.fromString(label_str).?;
        try std.testing.expectEqual(t, parsed);
    }
}

test "SignalMessageType fromString case sensitive" {
    try std.testing.expect(SignalMessageType.fromString("Text") == null);
    try std.testing.expect(SignalMessageType.fromString("RECEIPT") == null);
}

test "SignalMessageType fromString empty" {
    try std.testing.expect(SignalMessageType.fromString("") == null);
}

// --- SignalConfig Tests ---

test "SignalConfig with all fields" {
    const config = SignalConfig{
        .phone_number = "+15551234567",
        .signal_cli_path = "/usr/local/bin/signal-cli",
        .config_dir = "/home/user/.config/signal",
        .trust_all_keys = true,
    };
    try std.testing.expectEqualStrings("+15551234567", config.phone_number);
    try std.testing.expectEqualStrings("/usr/local/bin/signal-cli", config.signal_cli_path);
    try std.testing.expectEqualStrings("/home/user/.config/signal", config.config_dir.?);
    try std.testing.expect(config.trust_all_keys);
}
