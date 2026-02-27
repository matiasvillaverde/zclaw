const std = @import("std");

// --- UI View ---

pub const View = enum {
    dashboard,
    chat,
    channels,
    sessions,
    memory,
    config,
    agents,
    logs,

    pub fn label(self: View) []const u8 {
        return switch (self) {
            .dashboard => "Dashboard",
            .chat => "Chat",
            .channels => "Channels",
            .sessions => "Sessions",
            .memory => "Memory",
            .config => "Config",
            .agents => "Agents",
            .logs => "Logs",
        };
    }

    pub fn path(self: View) []const u8 {
        return switch (self) {
            .dashboard => "/",
            .chat => "/chat",
            .channels => "/channels",
            .sessions => "/sessions",
            .memory => "/memory",
            .config => "/config",
            .agents => "/agents",
            .logs => "/logs",
        };
    }

    pub fn fromPath(p: []const u8) View {
        const map = std.StaticStringMap(View).initComptime(.{
            .{ "/", .dashboard },
            .{ "/chat", .chat },
            .{ "/channels", .channels },
            .{ "/sessions", .sessions },
            .{ "/memory", .memory },
            .{ "/config", .config },
            .{ "/agents", .agents },
            .{ "/logs", .logs },
        });
        return map.get(p) orelse .dashboard;
    }
};

// --- Connection State ---

pub const ConnectionState = enum {
    disconnected,
    connecting,
    authenticating,
    connected,
    error_state,

    pub fn label(self: ConnectionState) []const u8 {
        return switch (self) {
            .disconnected => "Disconnected",
            .connecting => "Connecting...",
            .authenticating => "Authenticating...",
            .connected => "Connected",
            .error_state => "Error",
        };
    }

    pub fn isOnline(self: ConnectionState) bool {
        return self == .connected;
    }
};

// --- Theme ---

pub const Theme = enum {
    light,
    dark,
    system,

    pub fn label(self: Theme) []const u8 {
        return switch (self) {
            .light => "Light",
            .dark => "Dark",
            .system => "System",
        };
    }
};

// --- Chat Message ---

pub const ChatRole = enum {
    user,
    assistant,
    system_msg,

    pub fn label(self: ChatRole) []const u8 {
        return switch (self) {
            .user => "user",
            .assistant => "assistant",
            .system_msg => "system",
        };
    }
};

pub const ChatMessage = struct {
    role: ChatRole,
    content: []const u8,
    timestamp_ms: i64 = 0,
    is_streaming: bool = false,
};

// --- Channel Info ---

pub const ChannelInfo = struct {
    name: []const u8,
    channel_type: []const u8,
    status: []const u8,
    is_connected: bool = false,
};

// --- Agent Info ---

pub const AgentInfo = struct {
    name: []const u8,
    model: []const u8,
    is_active: bool = false,
};

// --- App State ---

pub const AppState = struct {
    // Navigation
    current_view: View = .dashboard,

    // Connection
    connection: ConnectionState = .disconnected,
    gateway_url: []const u8 = "ws://localhost:18789",

    // UI
    theme: Theme = .system,
    sidebar_open: bool = true,

    // Counts (populated from gateway)
    channel_count: u32 = 0,
    session_count: u32 = 0,
    agent_count: u32 = 0,

    // Chat
    chat_message_count: u32 = 0,
    is_streaming: bool = false,

    // Version
    version: []const u8 = "0.1.0",

    pub fn navigateTo(self: *AppState, view: View) void {
        self.current_view = view;
    }

    pub fn toggleSidebar(self: *AppState) void {
        self.sidebar_open = !self.sidebar_open;
    }

    pub fn setConnected(self: *AppState) void {
        self.connection = .connected;
    }

    pub fn setDisconnected(self: *AppState) void {
        self.connection = .disconnected;
        self.channel_count = 0;
        self.session_count = 0;
    }

    pub fn setError(self: *AppState) void {
        self.connection = .error_state;
    }

    pub fn updateCounts(self: *AppState, channels: u32, sessions: u32, agents: u32) void {
        self.channel_count = channels;
        self.session_count = sessions;
        self.agent_count = agents;
    }
};

// --- State Serialization (for JSON output to JS) ---

pub fn serializeState(buf: []u8, state: *const AppState) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("{\"view\":\"");
    try w.writeAll(state.current_view.label());
    try w.writeAll("\",\"connection\":\"");
    try w.writeAll(state.connection.label());
    try w.writeAll("\",\"theme\":\"");
    try w.writeAll(state.theme.label());
    try w.writeAll("\",\"sidebar\":");
    try w.writeAll(if (state.sidebar_open) "true" else "false");
    try w.writeAll(",\"channels\":");
    try std.fmt.format(w, "{d}", .{state.channel_count});
    try w.writeAll(",\"sessions\":");
    try std.fmt.format(w, "{d}", .{state.session_count});
    try w.writeAll(",\"agents\":");
    try std.fmt.format(w, "{d}", .{state.agent_count});
    try w.writeAll(",\"version\":\"");
    try w.writeAll(state.version);
    try w.writeAll("\"}");
    return fbs.getWritten();
}

// --- Tests ---

test "View labels and paths" {
    try std.testing.expectEqualStrings("Dashboard", View.dashboard.label());
    try std.testing.expectEqualStrings("/chat", View.chat.path());
    try std.testing.expectEqualStrings("/", View.dashboard.path());
    try std.testing.expectEqual(View.chat, View.fromPath("/chat"));
    try std.testing.expectEqual(View.dashboard, View.fromPath("/"));
    try std.testing.expectEqual(View.dashboard, View.fromPath("/unknown"));
}

test "ConnectionState" {
    try std.testing.expectEqualStrings("Connected", ConnectionState.connected.label());
    try std.testing.expect(ConnectionState.connected.isOnline());
    try std.testing.expect(!ConnectionState.disconnected.isOnline());
    try std.testing.expect(!ConnectionState.connecting.isOnline());
    try std.testing.expect(!ConnectionState.error_state.isOnline());
}

test "Theme labels" {
    try std.testing.expectEqualStrings("Light", Theme.light.label());
    try std.testing.expectEqualStrings("Dark", Theme.dark.label());
    try std.testing.expectEqualStrings("System", Theme.system.label());
}

test "ChatRole labels" {
    try std.testing.expectEqualStrings("user", ChatRole.user.label());
    try std.testing.expectEqualStrings("assistant", ChatRole.assistant.label());
}

test "AppState defaults" {
    const state = AppState{};
    try std.testing.expectEqual(View.dashboard, state.current_view);
    try std.testing.expectEqual(ConnectionState.disconnected, state.connection);
    try std.testing.expect(state.sidebar_open);
    try std.testing.expectEqual(@as(u32, 0), state.channel_count);
}

test "AppState navigateTo" {
    var state = AppState{};
    state.navigateTo(.chat);
    try std.testing.expectEqual(View.chat, state.current_view);
    state.navigateTo(.memory);
    try std.testing.expectEqual(View.memory, state.current_view);
}

test "AppState toggleSidebar" {
    var state = AppState{};
    try std.testing.expect(state.sidebar_open);
    state.toggleSidebar();
    try std.testing.expect(!state.sidebar_open);
    state.toggleSidebar();
    try std.testing.expect(state.sidebar_open);
}

test "AppState connection lifecycle" {
    var state = AppState{};
    try std.testing.expectEqual(ConnectionState.disconnected, state.connection);

    state.connection = .connecting;
    try std.testing.expectEqual(ConnectionState.connecting, state.connection);

    state.setConnected();
    try std.testing.expectEqual(ConnectionState.connected, state.connection);

    state.updateCounts(3, 5, 2);
    try std.testing.expectEqual(@as(u32, 3), state.channel_count);
    try std.testing.expectEqual(@as(u32, 5), state.session_count);
    try std.testing.expectEqual(@as(u32, 2), state.agent_count);

    state.setDisconnected();
    try std.testing.expectEqual(ConnectionState.disconnected, state.connection);
    try std.testing.expectEqual(@as(u32, 0), state.channel_count);
}

test "AppState setError" {
    var state = AppState{};
    state.setError();
    try std.testing.expectEqual(ConnectionState.error_state, state.connection);
}

test "serializeState" {
    var state = AppState{};
    state.setConnected();
    state.updateCounts(2, 3, 1);

    var buf: [1024]u8 = undefined;
    const json = try serializeState(&buf, &state);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"view\":\"Dashboard\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"connection\":\"Connected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"channels\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sessions\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"agents\":1") != null);
}

test "serializeState sidebar false" {
    var state = AppState{};
    state.toggleSidebar();

    var buf: [1024]u8 = undefined;
    const json = try serializeState(&buf, &state);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sidebar\":false") != null);
}

test "ChatMessage struct" {
    const msg = ChatMessage{
        .role = .user,
        .content = "Hello",
        .timestamp_ms = 1000,
    };
    try std.testing.expectEqualStrings("Hello", msg.content);
    try std.testing.expect(!msg.is_streaming);
}

test "ChannelInfo struct" {
    const ch = ChannelInfo{
        .name = "telegram",
        .channel_type = "telegram",
        .status = "connected",
        .is_connected = true,
    };
    try std.testing.expectEqualStrings("telegram", ch.name);
    try std.testing.expect(ch.is_connected);
}

test "AgentInfo struct" {
    const agent = AgentInfo{
        .name = "default",
        .model = "claude-sonnet",
        .is_active = true,
    };
    try std.testing.expectEqualStrings("default", agent.name);
    try std.testing.expect(agent.is_active);
}

test "View all paths" {
    const views = [_]View{ .dashboard, .chat, .channels, .sessions, .memory, .config, .agents, .logs };
    for (views) |v| {
        const p = v.path();
        try std.testing.expect(p.len > 0);
        try std.testing.expectEqual(v, View.fromPath(p));
    }
}

// --- Additional Tests ---

test "View all labels non-empty" {
    for (std.meta.tags(View)) |v| {
        try std.testing.expect(v.label().len > 0);
    }
}

test "View fromPath unknown returns dashboard" {
    try std.testing.expectEqual(View.dashboard, View.fromPath("/nonexistent"));
    try std.testing.expectEqual(View.dashboard, View.fromPath(""));
}

test "View specific labels" {
    try std.testing.expectEqualStrings("Chat", View.chat.label());
    try std.testing.expectEqualStrings("Channels", View.channels.label());
    try std.testing.expectEqualStrings("Sessions", View.sessions.label());
    try std.testing.expectEqualStrings("Memory", View.memory.label());
    try std.testing.expectEqualStrings("Config", View.config.label());
    try std.testing.expectEqualStrings("Agents", View.agents.label());
    try std.testing.expectEqualStrings("Logs", View.logs.label());
}

test "ConnectionState all labels non-empty" {
    for (std.meta.tags(ConnectionState)) |cs| {
        try std.testing.expect(cs.label().len > 0);
    }
}

test "ConnectionState authenticating not online" {
    try std.testing.expect(!ConnectionState.authenticating.isOnline());
}

test "ConnectionState authenticating label" {
    try std.testing.expectEqualStrings("Authenticating...", ConnectionState.authenticating.label());
}

test "ConnectionState connecting label" {
    try std.testing.expectEqualStrings("Connecting...", ConnectionState.connecting.label());
}

test "ChatRole system_msg label" {
    try std.testing.expectEqualStrings("system", ChatRole.system_msg.label());
}

test "ChatMessage defaults" {
    const msg = ChatMessage{ .role = .assistant, .content = "test" };
    try std.testing.expectEqual(@as(i64, 0), msg.timestamp_ms);
    try std.testing.expect(!msg.is_streaming);
}

test "ChatMessage streaming" {
    const msg = ChatMessage{ .role = .user, .content = "hello", .is_streaming = true };
    try std.testing.expect(msg.is_streaming);
}

test "ChannelInfo defaults" {
    const ch = ChannelInfo{ .name = "test", .channel_type = "web", .status = "idle" };
    try std.testing.expect(!ch.is_connected);
}

test "AgentInfo defaults" {
    const agent = AgentInfo{ .name = "default", .model = "gpt-4" };
    try std.testing.expect(!agent.is_active);
}

test "AppState default gateway_url" {
    const state = AppState{};
    try std.testing.expectEqualStrings("ws://localhost:18789", state.gateway_url);
}

test "AppState default theme" {
    const state = AppState{};
    try std.testing.expectEqual(Theme.system, state.theme);
}

test "AppState default version" {
    const state = AppState{};
    try std.testing.expectEqualStrings("0.1.0", state.version);
}

test "AppState setDisconnected resets counts" {
    var state = AppState{};
    state.updateCounts(5, 10, 3);
    state.setDisconnected();
    try std.testing.expectEqual(@as(u32, 0), state.channel_count);
    try std.testing.expectEqual(@as(u32, 0), state.session_count);
    // agent_count is NOT reset by setDisconnected
}

test "AppState navigateTo all views" {
    var state = AppState{};
    const views = [_]View{ .dashboard, .chat, .channels, .sessions, .memory, .config, .agents, .logs };
    for (views) |v| {
        state.navigateTo(v);
        try std.testing.expectEqual(v, state.current_view);
    }
}

test "serializeState theme and version" {
    const state = AppState{};
    var buf: [1024]u8 = undefined;
    const json = try serializeState(&buf, &state);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"theme\":\"System\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"version\":\"0.1.0\"") != null);
}

test "serializeState disconnected" {
    const state = AppState{};
    var buf: [1024]u8 = undefined;
    const json = try serializeState(&buf, &state);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"connection\":\"Disconnected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sidebar\":true") != null);
}
