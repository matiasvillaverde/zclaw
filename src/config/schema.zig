const std = @import("std");

// --- Core configuration types ---

pub const LogLevel = enum {
    silent,
    fatal,
    err,
    warn,
    info,
    debug,
    trace,

    pub fn label(self: LogLevel) []const u8 {
        return switch (self) {
            .silent => "silent",
            .fatal => "fatal",
            .err => "error",
            .warn => "warn",
            .info => "info",
            .debug => "debug",
            .trace => "trace",
        };
    }
};

pub const ConsoleStyle = enum {
    pretty,
    compact,
    json,
};

pub const GatewayMode = enum {
    local,
    remote,
};

pub const GatewayBindMode = enum {
    auto,
    lan,
    loopback,
    custom,
    tailnet,
};

pub const AuthMode = enum {
    none,
    token,
    password,
    trusted_proxy,
};

pub const ReloadMode = enum {
    off,
    restart,
    hot,
    hybrid,
};

// --- Sub-configurations ---

pub const LoggingConfig = struct {
    level: LogLevel = .info,
    console_level: ?LogLevel = null,
    console_style: ConsoleStyle = .pretty,
    file: ?[]const u8 = null,
    max_file_bytes: ?u64 = null,
    redact_sensitive: enum { off, tools } = .tools,
};

pub const AuthConfig = struct {
    mode: AuthMode = .none,
    token: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

pub const ReloadConfig = struct {
    mode: ReloadMode = .hybrid,
    debounce_ms: u32 = 300,
};

pub const GatewayConfig = struct {
    port: u16 = 18789,
    mode: GatewayMode = .local,
    bind: GatewayBindMode = .auto,
    custom_bind_host: ?[]const u8 = null,
    auth: AuthConfig = .{},
    reload: ReloadConfig = .{},
};

pub const SessionConfig = struct {
    main_key: []const u8 = "main",
};

pub const MemoryBackend = enum {
    builtin,
    qmd,
};

pub const MemoryConfig = struct {
    backend: MemoryBackend = .builtin,
    citations: enum { auto, on, off } = .auto,
};

pub const MetaConfig = struct {
    last_touched_version: ?[]const u8 = null,
    last_touched_at: ?[]const u8 = null,
};

// --- Agent Configuration ---

pub const AgentConfig = struct {
    id: []const u8 = "main",
    name: ?[]const u8 = null,
    model: ?[]const u8 = null,
    model_provider: ?[]const u8 = null,
    working_directory: ?[]const u8 = null,
};

pub const AgentsConfig = struct {
    default_agent: []const u8 = "main",
    list: []const AgentConfig = &.{},
};

// --- Root Configuration ---

pub const Config = struct {
    meta: MetaConfig = .{},
    logging: LoggingConfig = .{},
    gateway: GatewayConfig = .{},
    session: SessionConfig = .{},
    memory: MemoryConfig = .{},
    agents: AgentsConfig = .{},

    pub fn getPort(self: *const Config) u16 {
        return self.gateway.port;
    }
};

/// Returns a default configuration
pub fn defaultConfig() Config {
    return .{};
}

// --- Validation ---

pub const ValidationIssue = struct {
    path: []const u8,
    message: []const u8,
};

pub const ValidationResult = struct {
    ok: bool,
    issues: []const ValidationIssue,
};

pub fn validate(config: *const Config) ValidationResult {
    // Port validation
    if (config.gateway.port == 0) {
        return .{
            .ok = false,
            .issues = &.{.{
                .path = "gateway.port",
                .message = "port must be greater than 0",
            }},
        };
    }

    // Auth: token mode requires a token
    if (config.gateway.auth.mode == .token and config.gateway.auth.token == null) {
        return .{
            .ok = false,
            .issues = &.{.{
                .path = "gateway.auth.token",
                .message = "token required when auth mode is 'token'",
            }},
        };
    }

    // Auth: password mode requires a password
    if (config.gateway.auth.mode == .password and config.gateway.auth.password == null) {
        return .{
            .ok = false,
            .issues = &.{.{
                .path = "gateway.auth.password",
                .message = "password required when auth mode is 'password'",
            }},
        };
    }

    return .{ .ok = true, .issues = &.{} };
}

// --- Tests ---

test "defaultConfig has expected defaults" {
    const config = defaultConfig();
    try std.testing.expectEqual(@as(u16, 18789), config.gateway.port);
    try std.testing.expectEqual(GatewayMode.local, config.gateway.mode);
    try std.testing.expectEqual(LogLevel.info, config.logging.level);
    try std.testing.expectEqual(ConsoleStyle.pretty, config.logging.console_style);
    try std.testing.expectEqual(AuthMode.none, config.gateway.auth.mode);
    try std.testing.expectEqual(ReloadMode.hybrid, config.gateway.reload.mode);
    try std.testing.expectEqual(@as(u32, 300), config.gateway.reload.debounce_ms);
    try std.testing.expectEqual(MemoryBackend.builtin, config.memory.backend);
    try std.testing.expectEqualStrings("main", config.session.main_key);
    try std.testing.expectEqualStrings("main", config.agents.default_agent);
}

test "validate passes for default config" {
    const config = defaultConfig();
    const result = validate(&config);
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(usize, 0), result.issues.len);
}

test "validate rejects port 0" {
    var config = defaultConfig();
    config.gateway.port = 0;
    const result = validate(&config);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("gateway.port", result.issues[0].path);
}

test "validate rejects token auth without token" {
    var config = defaultConfig();
    config.gateway.auth.mode = .token;
    config.gateway.auth.token = null;
    const result = validate(&config);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("gateway.auth.token", result.issues[0].path);
}

test "validate accepts token auth with token" {
    var config = defaultConfig();
    config.gateway.auth.mode = .token;
    config.gateway.auth.token = "my-secret";
    const result = validate(&config);
    try std.testing.expect(result.ok);
}

test "validate rejects password auth without password" {
    var config = defaultConfig();
    config.gateway.auth.mode = .password;
    config.gateway.auth.password = null;
    const result = validate(&config);
    try std.testing.expect(!result.ok);
}

test "Config.getPort returns configured port" {
    var config = defaultConfig();
    try std.testing.expectEqual(@as(u16, 18789), config.getPort());
    config.gateway.port = 9999;
    try std.testing.expectEqual(@as(u16, 9999), config.getPort());
}

test "LogLevel.label" {
    try std.testing.expectEqualStrings("silent", LogLevel.silent.label());
    try std.testing.expectEqualStrings("info", LogLevel.info.label());
    try std.testing.expectEqualStrings("error", LogLevel.err.label());
}
