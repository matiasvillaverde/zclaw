const std = @import("std");
const schema = @import("schema.zig");

// --- Severity & Issue Types ---

pub const Severity = enum {
    err,
    warning,
    hint,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
            .hint => "hint",
        };
    }
};

pub const Issue = struct {
    severity: Severity,
    path: []const u8,
    message: []const u8,
};

// --- Validation Mode ---

pub const Mode = enum {
    /// Lenient: only critical errors
    lenient,
    /// Strict: warnings promoted to errors, unknown fields flagged
    strict,
};

// --- Validation Result ---

/// Result of config validation. Stores issues using ArrayListUnmanaged.
/// Caller must call `deinit(allocator)` when done.
pub const ValidationResult = struct {
    ok: bool,
    issues: std.ArrayListUnmanaged(Issue),

    pub fn deinit(self: *ValidationResult, allocator: std.mem.Allocator) void {
        self.issues.deinit(allocator);
    }

    pub fn errorCount(self: *const ValidationResult) usize {
        var count: usize = 0;
        for (self.issues.items) |issue| {
            if (issue.severity == .err) count += 1;
        }
        return count;
    }

    pub fn warningCount(self: *const ValidationResult) usize {
        var count: usize = 0;
        for (self.issues.items) |issue| {
            if (issue.severity == .warning) count += 1;
        }
        return count;
    }

    /// Format all issues as a human-readable string.
    pub fn format(self: *const ValidationResult, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);

        for (self.issues.items) |issue| {
            try buf.appendSlice(allocator, "[");
            try buf.appendSlice(allocator, issue.severity.label());
            try buf.appendSlice(allocator, "] ");
            try buf.appendSlice(allocator, issue.path);
            try buf.appendSlice(allocator, ": ");
            try buf.appendSlice(allocator, issue.message);
            try buf.appendSlice(allocator, "\n");
        }

        return try allocator.dupe(u8, buf.items);
    }
};

// --- Validator ---

/// Validates a Config struct, collecting all issues.
/// In strict mode, warnings are promoted to errors and additional checks run.
pub fn validateConfig(allocator: std.mem.Allocator, config: *const schema.Config, mode: Mode) !ValidationResult {
    var issues: std.ArrayListUnmanaged(Issue) = .{};
    errdefer issues.deinit(allocator);

    // --- Gateway checks ---

    // Port must be > 0
    if (config.gateway.port == 0) {
        try issues.append(allocator, .{
            .severity = .err,
            .path = "gateway.port",
            .message = "port must be greater than 0",
        });
    }

    // Port in privileged range
    if (config.gateway.port > 0 and config.gateway.port < 1024) {
        const sev: Severity = if (mode == .strict) .err else .warning;
        try issues.append(allocator, .{
            .severity = sev,
            .path = "gateway.port",
            .message = "port is in the privileged range (1-1023)",
        });
    }

    // Custom bind requires custom_bind_host
    if (config.gateway.bind == .custom and config.gateway.custom_bind_host == null) {
        try issues.append(allocator, .{
            .severity = .err,
            .path = "gateway.custom_bind_host",
            .message = "custom_bind_host required when bind mode is 'custom'",
        });
    }

    // --- Auth checks ---

    // Token auth requires token
    if (config.gateway.auth.mode == .token and config.gateway.auth.token == null) {
        try issues.append(allocator, .{
            .severity = .err,
            .path = "gateway.auth.token",
            .message = "token required when auth mode is 'token'",
        });
    }

    // Token should not be empty
    if (config.gateway.auth.mode == .token) {
        if (config.gateway.auth.token) |tok| {
            if (tok.len == 0) {
                try issues.append(allocator, .{
                    .severity = .err,
                    .path = "gateway.auth.token",
                    .message = "auth token must not be empty",
                });
            }
        }
    }

    // Password auth requires password
    if (config.gateway.auth.mode == .password and config.gateway.auth.password == null) {
        try issues.append(allocator, .{
            .severity = .err,
            .path = "gateway.auth.password",
            .message = "password required when auth mode is 'password'",
        });
    }

    // Password should not be empty
    if (config.gateway.auth.mode == .password) {
        if (config.gateway.auth.password) |pw| {
            if (pw.len == 0) {
                try issues.append(allocator, .{
                    .severity = .err,
                    .path = "gateway.auth.password",
                    .message = "auth password must not be empty",
                });
            }
        }
    }

    // --- Reload checks ---

    if (config.gateway.reload.debounce_ms == 0) {
        const sev: Severity = if (mode == .strict) .err else .warning;
        try issues.append(allocator, .{
            .severity = sev,
            .path = "gateway.reload.debounce_ms",
            .message = "debounce_ms of 0 may cause excessive reloads",
        });
    }

    // --- Logging checks ---

    if (config.logging.file) |f| {
        if (f.len == 0) {
            try issues.append(allocator, .{
                .severity = .err,
                .path = "logging.file",
                .message = "log file path must not be empty when specified",
            });
        }
    }

    if (config.logging.max_file_bytes) |max| {
        if (max == 0) {
            const sev: Severity = if (mode == .strict) .err else .warning;
            try issues.append(allocator, .{
                .severity = sev,
                .path = "logging.max_file_bytes",
                .message = "max_file_bytes of 0 disables log rotation",
            });
        }
    }

    // --- Agents checks ---

    // Check for duplicate agent IDs
    const agents = config.agents.list;
    for (agents, 0..) |agent_a, i| {
        for (agents[i + 1 ..], 0..) |agent_b, j_offset| {
            _ = j_offset;
            if (std.mem.eql(u8, agent_a.id, agent_b.id)) {
                try issues.append(allocator, .{
                    .severity = .err,
                    .path = "agents.list",
                    .message = "duplicate agent id found",
                });
                break;
            }
        }
    }

    // Strict mode: agent must have a model
    if (mode == .strict) {
        for (agents) |agent| {
            if (agent.model == null) {
                try issues.append(allocator, .{
                    .severity = .warning,
                    .path = "agents.list",
                    .message = "agent has no model configured (will use default)",
                });
            }
        }
    }

    // --- Determine overall ok status ---
    var has_error = false;
    for (issues.items) |issue| {
        if (issue.severity == .err) {
            has_error = true;
            break;
        }
    }

    return .{
        .ok = !has_error,
        .issues = issues,
    };
}

/// Quick validation: returns true if config is valid, false otherwise.
pub fn isValid(allocator: std.mem.Allocator, config: *const schema.Config) bool {
    var result = validateConfig(allocator, config, .lenient) catch return false;
    defer result.deinit(allocator);
    return result.ok;
}

// --- Tests ---

test "validate default config in lenient mode" {
    const allocator = std.testing.allocator;
    const config = schema.defaultConfig();
    var result = try validateConfig(allocator, &config, .lenient);
    defer result.deinit(allocator);
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(usize, 0), result.errorCount());
}

test "validate default config in strict mode" {
    const allocator = std.testing.allocator;
    const config = schema.defaultConfig();
    var result = try validateConfig(allocator, &config, .strict);
    defer result.deinit(allocator);
    // Default config has no agents, so no strict agent warnings
    try std.testing.expect(result.ok);
}

test "validate rejects port 0" {
    const allocator = std.testing.allocator;
    var config = schema.defaultConfig();
    config.gateway.port = 0;
    var result = try validateConfig(allocator, &config, .lenient);
    defer result.deinit(allocator);
    try std.testing.expect(!result.ok);
    try std.testing.expect(result.errorCount() > 0);
    try std.testing.expectEqualStrings("gateway.port", result.issues.items[0].path);
}

test "validate warns on privileged port in lenient mode" {
    const allocator = std.testing.allocator;
    var config = schema.defaultConfig();
    config.gateway.port = 80;
    var result = try validateConfig(allocator, &config, .lenient);
    defer result.deinit(allocator);
    // Warning only, so still ok
    try std.testing.expect(result.ok);
    try std.testing.expect(result.warningCount() > 0);
}

test "validate errors on privileged port in strict mode" {
    const allocator = std.testing.allocator;
    var config = schema.defaultConfig();
    config.gateway.port = 80;
    var result = try validateConfig(allocator, &config, .strict);
    defer result.deinit(allocator);
    try std.testing.expect(!result.ok);
    try std.testing.expect(result.errorCount() > 0);
}

test "validate token auth without token" {
    const allocator = std.testing.allocator;
    var config = schema.defaultConfig();
    config.gateway.auth.mode = .token;
    config.gateway.auth.token = null;
    var result = try validateConfig(allocator, &config, .lenient);
    defer result.deinit(allocator);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("gateway.auth.token", result.issues.items[0].path);
}

test "validate token auth with empty token" {
    const allocator = std.testing.allocator;
    var config = schema.defaultConfig();
    config.gateway.auth.mode = .token;
    config.gateway.auth.token = "";
    var result = try validateConfig(allocator, &config, .lenient);
    defer result.deinit(allocator);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("gateway.auth.token", result.issues.items[0].path);
    try std.testing.expectEqualStrings("auth token must not be empty", result.issues.items[0].message);
}

test "validate token auth with valid token" {
    const allocator = std.testing.allocator;
    var config = schema.defaultConfig();
    config.gateway.auth.mode = .token;
    config.gateway.auth.token = "my-secret";
    var result = try validateConfig(allocator, &config, .lenient);
    defer result.deinit(allocator);
    try std.testing.expect(result.ok);
}

test "validate password auth without password" {
    const allocator = std.testing.allocator;
    var config = schema.defaultConfig();
    config.gateway.auth.mode = .password;
    config.gateway.auth.password = null;
    var result = try validateConfig(allocator, &config, .lenient);
    defer result.deinit(allocator);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("gateway.auth.password", result.issues.items[0].path);
}

test "validate password auth with empty password" {
    const allocator = std.testing.allocator;
    var config = schema.defaultConfig();
    config.gateway.auth.mode = .password;
    config.gateway.auth.password = "";
    var result = try validateConfig(allocator, &config, .lenient);
    defer result.deinit(allocator);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("auth password must not be empty", result.issues.items[0].message);
}

test "validate custom bind without host" {
    const allocator = std.testing.allocator;
    var config = schema.defaultConfig();
    config.gateway.bind = .custom;
    config.gateway.custom_bind_host = null;
    var result = try validateConfig(allocator, &config, .lenient);
    defer result.deinit(allocator);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("gateway.custom_bind_host", result.issues.items[0].path);
}

test "validate custom bind with host" {
    const allocator = std.testing.allocator;
    var config = schema.defaultConfig();
    config.gateway.bind = .custom;
    config.gateway.custom_bind_host = "192.168.1.1";
    var result = try validateConfig(allocator, &config, .lenient);
    defer result.deinit(allocator);
    try std.testing.expect(result.ok);
}

test "validate debounce_ms zero warning" {
    const allocator = std.testing.allocator;
    var config = schema.defaultConfig();
    config.gateway.reload.debounce_ms = 0;
    var result = try validateConfig(allocator, &config, .lenient);
    defer result.deinit(allocator);
    // Warning only
    try std.testing.expect(result.ok);
    try std.testing.expect(result.warningCount() > 0);
}

test "validate debounce_ms zero strict" {
    const allocator = std.testing.allocator;
    var config = schema.defaultConfig();
    config.gateway.reload.debounce_ms = 0;
    var result = try validateConfig(allocator, &config, .strict);
    defer result.deinit(allocator);
    try std.testing.expect(!result.ok);
}

test "validate empty log file path" {
    const allocator = std.testing.allocator;
    var config = schema.defaultConfig();
    config.logging.file = "";
    var result = try validateConfig(allocator, &config, .lenient);
    defer result.deinit(allocator);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("logging.file", result.issues.items[0].path);
}

test "validate max_file_bytes zero" {
    const allocator = std.testing.allocator;
    var config = schema.defaultConfig();
    config.logging.max_file_bytes = 0;
    var result = try validateConfig(allocator, &config, .lenient);
    defer result.deinit(allocator);
    try std.testing.expect(result.ok);
    try std.testing.expect(result.warningCount() > 0);
}

test "isValid returns true for default config" {
    const allocator = std.testing.allocator;
    const config = schema.defaultConfig();
    try std.testing.expect(isValid(allocator, &config));
}

test "isValid returns false for port 0" {
    const allocator = std.testing.allocator;
    var config = schema.defaultConfig();
    config.gateway.port = 0;
    try std.testing.expect(!isValid(allocator, &config));
}

test "ValidationResult format" {
    const allocator = std.testing.allocator;
    var config = schema.defaultConfig();
    config.gateway.port = 0;
    var result = try validateConfig(allocator, &config, .lenient);
    defer result.deinit(allocator);

    const formatted = try result.format(allocator);
    defer allocator.free(formatted);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "[error]") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "gateway.port") != null);
}

test "Severity labels" {
    try std.testing.expectEqualStrings("error", Severity.err.label());
    try std.testing.expectEqualStrings("warning", Severity.warning.label());
    try std.testing.expectEqualStrings("hint", Severity.hint.label());
}

test "multiple issues collected" {
    const allocator = std.testing.allocator;
    var config = schema.defaultConfig();
    config.gateway.port = 0;
    config.gateway.auth.mode = .token;
    config.gateway.auth.token = null;
    var result = try validateConfig(allocator, &config, .lenient);
    defer result.deinit(allocator);
    try std.testing.expect(!result.ok);
    // Should have at least 2 errors: port 0 + missing token
    try std.testing.expect(result.errorCount() >= 2);
}
