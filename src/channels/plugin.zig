const std = @import("std");

// --- Channel Types ---

pub const ChannelType = enum {
    webchat,
    telegram,
    discord,
    slack,
    whatsapp,
    signal,
    matrix,

    pub fn label(self: ChannelType) []const u8 {
        return switch (self) {
            .webchat => "webchat",
            .telegram => "telegram",
            .discord => "discord",
            .slack => "slack",
            .whatsapp => "whatsapp",
            .signal => "signal",
            .matrix => "matrix",
        };
    }

    pub fn fromString(s: []const u8) ?ChannelType {
        const map = std.StaticStringMap(ChannelType).initComptime(.{
            .{ "webchat", .webchat },
            .{ "telegram", .telegram },
            .{ "discord", .discord },
            .{ "slack", .slack },
            .{ "whatsapp", .whatsapp },
            .{ "signal", .signal },
            .{ "matrix", .matrix },
        });
        return map.get(s);
    }
};

// --- Channel Status ---

pub const ChannelStatus = enum {
    disconnected,
    connecting,
    connected,
    error_state,

    pub fn label(self: ChannelStatus) []const u8 {
        return switch (self) {
            .disconnected => "disconnected",
            .connecting => "connecting",
            .connected => "connected",
            .error_state => "error",
        };
    }
};

// --- Message Types ---

pub const MessageType = enum {
    text,
    image,
    file,
    audio,
    video,
    location,
    sticker,

    pub fn label(self: MessageType) []const u8 {
        return switch (self) {
            .text => "text",
            .image => "image",
            .file => "file",
            .audio => "audio",
            .video => "video",
            .location => "location",
            .sticker => "sticker",
        };
    }
};

// --- Incoming Message ---

pub const IncomingMessage = struct {
    channel: ChannelType,
    message_id: []const u8,
    sender_id: []const u8,
    sender_name: ?[]const u8 = null,
    chat_id: []const u8,
    content: []const u8,
    message_type: MessageType = .text,
    is_group: bool = false,
    reply_to_id: ?[]const u8 = null,
    timestamp_ms: i64 = 0,
};

// --- Outgoing Message ---

pub const OutgoingMessage = struct {
    chat_id: []const u8,
    content: []const u8,
    message_type: MessageType = .text,
    reply_to_id: ?[]const u8 = null,
    parse_mode: ?[]const u8 = null, // "markdown", "html", etc.
};

// --- Channel Plugin Interface ---

pub const PluginVTable = struct {
    start: *const fn (ctx: *anyopaque) anyerror!void,
    stop: *const fn (ctx: *anyopaque) void,
    send_text: *const fn (ctx: *anyopaque, msg: OutgoingMessage) anyerror!void,
    get_status: *const fn (ctx: *anyopaque) ChannelStatus,
    get_type: *const fn (ctx: *anyopaque) ChannelType,
};

pub const ChannelPlugin = struct {
    vtable: *const PluginVTable,
    ctx: *anyopaque,

    pub fn start(self: *ChannelPlugin) !void {
        return self.vtable.start(self.ctx);
    }

    pub fn stop(self: *ChannelPlugin) void {
        self.vtable.stop(self.ctx);
    }

    pub fn sendText(self: *ChannelPlugin, msg: OutgoingMessage) !void {
        return self.vtable.send_text(self.ctx, msg);
    }

    pub fn getStatus(self: *ChannelPlugin) ChannelStatus {
        return self.vtable.get_status(self.ctx);
    }

    pub fn getType(self: *ChannelPlugin) ChannelType {
        return self.vtable.get_type(self.ctx);
    }
};

// --- Channel Registry ---

pub const ChannelRegistry = struct {
    channels: std.StringHashMapUnmanaged(ChannelPlugin),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ChannelRegistry {
        return .{
            .channels = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ChannelRegistry) void {
        self.channels.deinit(self.allocator);
    }

    pub fn register(self: *ChannelRegistry, name: []const u8, plugin: ChannelPlugin) !void {
        try self.channels.put(self.allocator, name, plugin);
    }

    pub fn get(self: *const ChannelRegistry, name: []const u8) ?ChannelPlugin {
        return self.channels.get(name);
    }

    pub fn count(self: *const ChannelRegistry) usize {
        return self.channels.count();
    }

    pub fn stopAll(self: *ChannelRegistry) void {
        var iter = self.channels.valueIterator();
        while (iter.next()) |plugin| {
            plugin.stop();
        }
    }
};

// --- Tests ---

test "ChannelType labels and fromString" {
    try std.testing.expectEqualStrings("webchat", ChannelType.webchat.label());
    try std.testing.expectEqualStrings("telegram", ChannelType.telegram.label());
    try std.testing.expectEqualStrings("discord", ChannelType.discord.label());

    try std.testing.expectEqual(ChannelType.webchat, ChannelType.fromString("webchat").?);
    try std.testing.expectEqual(ChannelType.telegram, ChannelType.fromString("telegram").?);
    try std.testing.expectEqual(@as(?ChannelType, null), ChannelType.fromString("unknown"));
}

test "ChannelStatus labels" {
    try std.testing.expectEqualStrings("disconnected", ChannelStatus.disconnected.label());
    try std.testing.expectEqualStrings("connected", ChannelStatus.connected.label());
    try std.testing.expectEqualStrings("error", ChannelStatus.error_state.label());
}

test "MessageType labels" {
    try std.testing.expectEqualStrings("text", MessageType.text.label());
    try std.testing.expectEqualStrings("image", MessageType.image.label());
}

test "IncomingMessage" {
    const msg = IncomingMessage{
        .channel = .telegram,
        .message_id = "123",
        .sender_id = "user456",
        .sender_name = "John",
        .chat_id = "chat789",
        .content = "Hello bot!",
        .is_group = false,
    };
    try std.testing.expectEqual(ChannelType.telegram, msg.channel);
    try std.testing.expectEqualStrings("Hello bot!", msg.content);
    try std.testing.expect(!msg.is_group);
}

test "OutgoingMessage" {
    const msg = OutgoingMessage{
        .chat_id = "chat123",
        .content = "Hello user!",
        .parse_mode = "markdown",
    };
    try std.testing.expectEqualStrings("chat123", msg.chat_id);
    try std.testing.expectEqualStrings("markdown", msg.parse_mode.?);
}

// Mock channel for testing
const MockChannel = struct {
    status: ChannelStatus = .disconnected,
    channel_type: ChannelType = .webchat,
    sent_count: u32 = 0,

    const vtable = PluginVTable{
        .start = mockStart,
        .stop = mockStop,
        .send_text = mockSendText,
        .get_status = mockGetStatus,
        .get_type = mockGetType,
    };

    fn mockStart(ctx: *anyopaque) anyerror!void {
        const self: *MockChannel = @ptrCast(@alignCast(ctx));
        self.status = .connected;
    }

    fn mockStop(ctx: *anyopaque) void {
        const self: *MockChannel = @ptrCast(@alignCast(ctx));
        self.status = .disconnected;
    }

    fn mockSendText(ctx: *anyopaque, _: OutgoingMessage) anyerror!void {
        const self: *MockChannel = @ptrCast(@alignCast(ctx));
        self.sent_count += 1;
    }

    fn mockGetStatus(ctx: *anyopaque) ChannelStatus {
        const self: *const MockChannel = @ptrCast(@alignCast(ctx));
        return self.status;
    }

    fn mockGetType(ctx: *anyopaque) ChannelType {
        const self: *const MockChannel = @ptrCast(@alignCast(ctx));
        return self.channel_type;
    }

    fn asPlugin(self: *MockChannel) ChannelPlugin {
        return .{
            .vtable = &vtable,
            .ctx = @ptrCast(self),
        };
    }
};

test "ChannelPlugin via mock" {
    var mock = MockChannel{};
    var plugin = mock.asPlugin();

    try std.testing.expectEqual(ChannelStatus.disconnected, plugin.getStatus());
    try std.testing.expectEqual(ChannelType.webchat, plugin.getType());

    try plugin.start();
    try std.testing.expectEqual(ChannelStatus.connected, plugin.getStatus());

    try plugin.sendText(.{ .chat_id = "1", .content = "hi" });
    try std.testing.expectEqual(@as(u32, 1), mock.sent_count);

    plugin.stop();
    try std.testing.expectEqual(ChannelStatus.disconnected, plugin.getStatus());
}

test "ChannelRegistry" {
    const allocator = std.testing.allocator;
    var registry = ChannelRegistry.init(allocator);
    defer registry.deinit();

    var mock = MockChannel{};
    try registry.register("webchat", mock.asPlugin());
    try std.testing.expectEqual(@as(usize, 1), registry.count());

    var chan = registry.get("webchat").?;
    try std.testing.expectEqual(ChannelType.webchat, chan.getType());
}

// ======================================================================
// Additional comprehensive tests
// ======================================================================

// --- ChannelType Tests ---

test "ChannelType all labels" {
    try std.testing.expectEqualStrings("webchat", ChannelType.webchat.label());
    try std.testing.expectEqualStrings("telegram", ChannelType.telegram.label());
    try std.testing.expectEqualStrings("discord", ChannelType.discord.label());
    try std.testing.expectEqualStrings("slack", ChannelType.slack.label());
    try std.testing.expectEqualStrings("whatsapp", ChannelType.whatsapp.label());
    try std.testing.expectEqualStrings("signal", ChannelType.signal.label());
    try std.testing.expectEqualStrings("matrix", ChannelType.matrix.label());
}

test "ChannelType fromString all types" {
    try std.testing.expectEqual(ChannelType.webchat, ChannelType.fromString("webchat").?);
    try std.testing.expectEqual(ChannelType.telegram, ChannelType.fromString("telegram").?);
    try std.testing.expectEqual(ChannelType.discord, ChannelType.fromString("discord").?);
    try std.testing.expectEqual(ChannelType.slack, ChannelType.fromString("slack").?);
    try std.testing.expectEqual(ChannelType.whatsapp, ChannelType.fromString("whatsapp").?);
    try std.testing.expectEqual(ChannelType.signal, ChannelType.fromString("signal").?);
    try std.testing.expectEqual(ChannelType.matrix, ChannelType.fromString("matrix").?);
}

test "ChannelType fromString case sensitive" {
    try std.testing.expect(ChannelType.fromString("Webchat") == null);
    try std.testing.expect(ChannelType.fromString("TELEGRAM") == null);
    try std.testing.expect(ChannelType.fromString("Discord") == null);
}

test "ChannelType fromString empty string" {
    try std.testing.expect(ChannelType.fromString("") == null);
}

test "ChannelType label roundtrip" {
    const types = [_]ChannelType{ .webchat, .telegram, .discord, .slack, .whatsapp, .signal, .matrix };
    for (types) |t| {
        const label_str = t.label();
        const parsed = ChannelType.fromString(label_str).?;
        try std.testing.expectEqual(t, parsed);
    }
}

// --- ChannelStatus Tests ---

test "ChannelStatus all labels" {
    try std.testing.expectEqualStrings("disconnected", ChannelStatus.disconnected.label());
    try std.testing.expectEqualStrings("connecting", ChannelStatus.connecting.label());
    try std.testing.expectEqualStrings("connected", ChannelStatus.connected.label());
    try std.testing.expectEqualStrings("error", ChannelStatus.error_state.label());
}

// --- MessageType Tests ---

test "MessageType all labels" {
    try std.testing.expectEqualStrings("text", MessageType.text.label());
    try std.testing.expectEqualStrings("image", MessageType.image.label());
    try std.testing.expectEqualStrings("file", MessageType.file.label());
    try std.testing.expectEqualStrings("audio", MessageType.audio.label());
    try std.testing.expectEqualStrings("video", MessageType.video.label());
    try std.testing.expectEqualStrings("location", MessageType.location.label());
    try std.testing.expectEqualStrings("sticker", MessageType.sticker.label());
}

// --- IncomingMessage Tests ---

test "IncomingMessage defaults" {
    const msg = IncomingMessage{
        .channel = .webchat,
        .message_id = "1",
        .sender_id = "u1",
        .chat_id = "c1",
        .content = "hi",
    };
    try std.testing.expect(msg.sender_name == null);
    try std.testing.expectEqual(MessageType.text, msg.message_type);
    try std.testing.expect(!msg.is_group);
    try std.testing.expect(msg.reply_to_id == null);
    try std.testing.expectEqual(@as(i64, 0), msg.timestamp_ms);
}

test "IncomingMessage all fields" {
    const msg = IncomingMessage{
        .channel = .telegram,
        .message_id = "msg123",
        .sender_id = "user456",
        .sender_name = "Alice",
        .chat_id = "chat789",
        .content = "Hello!",
        .message_type = .image,
        .is_group = true,
        .reply_to_id = "msg100",
        .timestamp_ms = 1700000000000,
    };
    try std.testing.expectEqual(ChannelType.telegram, msg.channel);
    try std.testing.expectEqualStrings("msg123", msg.message_id);
    try std.testing.expectEqualStrings("Alice", msg.sender_name.?);
    try std.testing.expectEqual(MessageType.image, msg.message_type);
    try std.testing.expect(msg.is_group);
    try std.testing.expectEqualStrings("msg100", msg.reply_to_id.?);
    try std.testing.expectEqual(@as(i64, 1700000000000), msg.timestamp_ms);
}

// --- OutgoingMessage Tests ---

test "OutgoingMessage defaults" {
    const msg = OutgoingMessage{
        .chat_id = "c1",
        .content = "hi",
    };
    try std.testing.expectEqual(MessageType.text, msg.message_type);
    try std.testing.expect(msg.reply_to_id == null);
    try std.testing.expect(msg.parse_mode == null);
}

test "OutgoingMessage all fields" {
    const msg = OutgoingMessage{
        .chat_id = "chat123",
        .content = "Reply here",
        .message_type = .file,
        .reply_to_id = "original-msg",
        .parse_mode = "html",
    };
    try std.testing.expectEqualStrings("chat123", msg.chat_id);
    try std.testing.expectEqualStrings("Reply here", msg.content);
    try std.testing.expectEqual(MessageType.file, msg.message_type);
    try std.testing.expectEqualStrings("original-msg", msg.reply_to_id.?);
    try std.testing.expectEqualStrings("html", msg.parse_mode.?);
}

// --- MockChannel Tests ---

test "MockChannel start and stop lifecycle" {
    var mock = MockChannel{};
    try std.testing.expectEqual(ChannelStatus.disconnected, mock.status);

    var p = mock.asPlugin();
    try p.start();
    try std.testing.expectEqual(ChannelStatus.connected, mock.status);

    try p.sendText(.{ .chat_id = "1", .content = "msg1" });
    try p.sendText(.{ .chat_id = "2", .content = "msg2" });
    try std.testing.expectEqual(@as(u32, 2), mock.sent_count);

    p.stop();
    try std.testing.expectEqual(ChannelStatus.disconnected, mock.status);
}

test "MockChannel type query" {
    var mock = MockChannel{ .channel_type = .telegram };
    var p = mock.asPlugin();
    try std.testing.expectEqual(ChannelType.telegram, p.getType());
}

test "MockChannel type discord" {
    var mock = MockChannel{ .channel_type = .discord };
    var p = mock.asPlugin();
    try std.testing.expectEqual(ChannelType.discord, p.getType());
}

// --- ChannelRegistry Tests ---

test "ChannelRegistry register multiple" {
    const allocator = std.testing.allocator;
    var registry = ChannelRegistry.init(allocator);
    defer registry.deinit();

    var mock_tg = MockChannel{ .channel_type = .telegram };
    var mock_dc = MockChannel{ .channel_type = .discord };
    var mock_sl = MockChannel{ .channel_type = .slack };

    try registry.register("telegram", mock_tg.asPlugin());
    try registry.register("discord", mock_dc.asPlugin());
    try registry.register("slack", mock_sl.asPlugin());

    try std.testing.expectEqual(@as(usize, 3), registry.count());
}

test "ChannelRegistry get unknown returns null" {
    const allocator = std.testing.allocator;
    var registry = ChannelRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expect(registry.get("nonexistent") == null);
}

test "ChannelRegistry get registered channel" {
    const allocator = std.testing.allocator;
    var registry = ChannelRegistry.init(allocator);
    defer registry.deinit();

    var mock = MockChannel{ .channel_type = .signal };
    try registry.register("signal", mock.asPlugin());

    var ch = registry.get("signal").?;
    try std.testing.expectEqual(ChannelType.signal, ch.getType());
}

test "ChannelRegistry stopAll stops all channels" {
    const allocator = std.testing.allocator;
    var registry = ChannelRegistry.init(allocator);
    defer registry.deinit();

    var mock1 = MockChannel{ .status = .connected, .channel_type = .telegram };
    var mock2 = MockChannel{ .status = .connected, .channel_type = .discord };

    try registry.register("telegram", mock1.asPlugin());
    try registry.register("discord", mock2.asPlugin());

    registry.stopAll();

    try std.testing.expectEqual(ChannelStatus.disconnected, mock1.status);
    try std.testing.expectEqual(ChannelStatus.disconnected, mock2.status);
}

test "ChannelRegistry register overwrites same key" {
    const allocator = std.testing.allocator;
    var registry = ChannelRegistry.init(allocator);
    defer registry.deinit();

    var mock1 = MockChannel{ .channel_type = .telegram };
    var mock2 = MockChannel{ .channel_type = .discord };

    try registry.register("channel", mock1.asPlugin());
    try registry.register("channel", mock2.asPlugin());

    try std.testing.expectEqual(@as(usize, 1), registry.count());
    var ch = registry.get("channel").?;
    try std.testing.expectEqual(ChannelType.discord, ch.getType());
}

test "ChannelRegistry empty count" {
    const allocator = std.testing.allocator;
    var registry = ChannelRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 0), registry.count());
}

test "ChannelRegistry stopAll on empty registry" {
    const allocator = std.testing.allocator;
    var registry = ChannelRegistry.init(allocator);
    defer registry.deinit();

    registry.stopAll(); // Should not crash
}

// --- PluginVTable Tests ---

test "PluginVTable methods via channel plugin" {
    var mock = MockChannel{};
    var p = mock.asPlugin();

    // Test all vtable methods
    try std.testing.expectEqual(ChannelStatus.disconnected, p.getStatus());
    try std.testing.expectEqual(ChannelType.webchat, p.getType());

    try p.start();
    try std.testing.expectEqual(ChannelStatus.connected, p.getStatus());

    try p.sendText(.{ .chat_id = "test", .content = "test" });
    try std.testing.expectEqual(@as(u32, 1), mock.sent_count);

    p.stop();
    try std.testing.expectEqual(ChannelStatus.disconnected, p.getStatus());
}
