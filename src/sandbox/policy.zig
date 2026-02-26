const std = @import("std");

// --- Sandbox Security Level ---

pub const SecurityLevel = enum {
    none, // No sandbox (trusted)
    basic, // Limited network, no host mounts
    strict, // No network, read-only workspace, limited commands
    paranoid, // No network, no mounts, minimal tools

    pub fn label(self: SecurityLevel) []const u8 {
        return switch (self) {
            .none => "none",
            .basic => "basic",
            .strict => "strict",
            .paranoid => "paranoid",
        };
    }

    pub fn fromString(s: []const u8) ?SecurityLevel {
        const map = std.StaticStringMap(SecurityLevel).initComptime(.{
            .{ "none", .none },
            .{ "basic", .basic },
            .{ "strict", .strict },
            .{ "paranoid", .paranoid },
        });
        return map.get(s);
    }
};

// --- Mount Mode ---

pub const MountMode = enum {
    none, // No workspace mount
    ro, // Read-only mount
    rw, // Read-write mount

    pub fn label(self: MountMode) []const u8 {
        return switch (self) {
            .none => "none",
            .ro => "ro",
            .rw => "rw",
        };
    }
};

// --- Network Access ---

pub const NetworkAccess = enum {
    full, // Unrestricted network
    limited, // Only allowed domains
    none, // No network access

    pub fn label(self: NetworkAccess) []const u8 {
        return switch (self) {
            .full => "full",
            .limited => "limited",
            .none => "none",
        };
    }
};

// --- Sandbox Policy ---

pub const SandboxPolicy = struct {
    level: SecurityLevel = .basic,
    mount_mode: MountMode = .rw,
    network: NetworkAccess = .limited,
    max_memory_mb: u32 = 512,
    max_cpu_percent: u32 = 100,
    max_runtime_seconds: u32 = 300, // 5 minutes
    allowed_commands: []const []const u8 = &.{},
    blocked_commands: []const []const u8 = &.{},
    allowed_domains: []const []const u8 = &.{},
};

// --- Policy Presets ---

pub const BASIC_POLICY = SandboxPolicy{
    .level = .basic,
    .mount_mode = .rw,
    .network = .limited,
    .max_memory_mb = 512,
    .max_cpu_percent = 100,
    .max_runtime_seconds = 300,
};

pub const STRICT_POLICY = SandboxPolicy{
    .level = .strict,
    .mount_mode = .ro,
    .network = .none,
    .max_memory_mb = 256,
    .max_cpu_percent = 50,
    .max_runtime_seconds = 60,
};

pub const PARANOID_POLICY = SandboxPolicy{
    .level = .paranoid,
    .mount_mode = .none,
    .network = .none,
    .max_memory_mb = 128,
    .max_cpu_percent = 25,
    .max_runtime_seconds = 30,
};

// --- Command Checking ---

pub const CommandDecision = enum {
    allow,
    deny,
    sandbox, // Run in sandbox

    pub fn label(self: CommandDecision) []const u8 {
        return switch (self) {
            .allow => "allow",
            .deny => "deny",
            .sandbox => "sandbox",
        };
    }
};

/// Check if a command is allowed under the given policy.
pub fn checkCommand(cmd: []const u8, pol: SandboxPolicy) CommandDecision {
    // Check blocked commands first (deny always wins)
    for (pol.blocked_commands) |blocked| {
        if (std.mem.eql(u8, blocked, cmd) or matchesPrefix(cmd, blocked)) {
            return .deny;
        }
    }

    // Check allowed commands
    if (pol.allowed_commands.len > 0) {
        for (pol.allowed_commands) |allowed| {
            if (std.mem.eql(u8, allowed, cmd) or matchesPrefix(cmd, allowed)) {
                return .allow;
            }
        }
        // If allowlist exists but command not in it, sandbox it
        return .sandbox;
    }

    // Default by security level
    return switch (pol.level) {
        .none => .allow,
        .basic => .sandbox,
        .strict => .sandbox,
        .paranoid => .deny,
    };
}

/// Check if a domain is allowed for network access.
pub fn checkDomain(domain: []const u8, pol: SandboxPolicy) bool {
    return switch (pol.network) {
        .full => true,
        .none => false,
        .limited => {
            if (pol.allowed_domains.len == 0) return true; // No restrictions specified
            for (pol.allowed_domains) |allowed| {
                if (std.mem.eql(u8, allowed, domain)) return true;
                // Check subdomain match
                if (std.mem.endsWith(u8, domain, allowed)) {
                    if (domain.len > allowed.len and domain[domain.len - allowed.len - 1] == '.') {
                        return true;
                    }
                }
            }
            return false;
        },
    };
}

fn matchesPrefix(cmd: []const u8, pattern: []const u8) bool {
    if (pattern.len > 0 and pattern[pattern.len - 1] == '*') {
        return std.mem.startsWith(u8, cmd, pattern[0 .. pattern.len - 1]);
    }
    return false;
}

/// Get policy for a security level.
pub fn policyForLevel(level: SecurityLevel) SandboxPolicy {
    return switch (level) {
        .none => .{ .level = .none, .network = .full, .mount_mode = .rw },
        .basic => BASIC_POLICY,
        .strict => STRICT_POLICY,
        .paranoid => PARANOID_POLICY,
    };
}

// --- Serialize Policy ---

pub fn serializePolicy(buf: []u8, pol: *const SandboxPolicy) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("{\"level\":\"");
    try w.writeAll(pol.level.label());
    try w.writeAll("\",\"mount\":\"");
    try w.writeAll(pol.mount_mode.label());
    try w.writeAll("\",\"network\":\"");
    try w.writeAll(pol.network.label());
    try w.writeAll("\",\"max_memory_mb\":");
    try std.fmt.format(w, "{d}", .{pol.max_memory_mb});
    try w.writeAll(",\"max_runtime_seconds\":");
    try std.fmt.format(w, "{d}", .{pol.max_runtime_seconds});
    try w.writeAll("}");
    return fbs.getWritten();
}

// --- Tests ---

test "SecurityLevel labels and fromString" {
    try std.testing.expectEqualStrings("basic", SecurityLevel.basic.label());
    try std.testing.expectEqualStrings("strict", SecurityLevel.strict.label());
    try std.testing.expectEqual(SecurityLevel.paranoid, SecurityLevel.fromString("paranoid").?);
    try std.testing.expectEqual(@as(?SecurityLevel, null), SecurityLevel.fromString("xyz"));
}

test "MountMode labels" {
    try std.testing.expectEqualStrings("none", MountMode.none.label());
    try std.testing.expectEqualStrings("ro", MountMode.ro.label());
    try std.testing.expectEqualStrings("rw", MountMode.rw.label());
}

test "NetworkAccess labels" {
    try std.testing.expectEqualStrings("full", NetworkAccess.full.label());
    try std.testing.expectEqualStrings("limited", NetworkAccess.limited.label());
    try std.testing.expectEqualStrings("none", NetworkAccess.none.label());
}

test "SandboxPolicy defaults" {
    const pol = SandboxPolicy{};
    try std.testing.expectEqual(SecurityLevel.basic, pol.level);
    try std.testing.expectEqual(MountMode.rw, pol.mount_mode);
    try std.testing.expectEqual(@as(u32, 512), pol.max_memory_mb);
}

test "checkCommand no security" {
    const pol = SandboxPolicy{ .level = .none };
    try std.testing.expectEqual(CommandDecision.allow, checkCommand("rm -rf /", pol));
}

test "checkCommand basic level" {
    try std.testing.expectEqual(CommandDecision.sandbox, checkCommand("ls", BASIC_POLICY));
}

test "checkCommand paranoid denies all" {
    try std.testing.expectEqual(CommandDecision.deny, checkCommand("echo hello", PARANOID_POLICY));
}

test "checkCommand blocked" {
    const blocked = [_][]const u8{ "rm", "dd" };
    const pol = SandboxPolicy{ .blocked_commands = &blocked };
    try std.testing.expectEqual(CommandDecision.deny, checkCommand("rm", pol));
    try std.testing.expectEqual(CommandDecision.deny, checkCommand("dd", pol));
    try std.testing.expectEqual(CommandDecision.sandbox, checkCommand("ls", pol));
}

test "checkCommand allowed" {
    const allowed = [_][]const u8{ "ls", "cat", "echo" };
    const pol = SandboxPolicy{ .allowed_commands = &allowed };
    try std.testing.expectEqual(CommandDecision.allow, checkCommand("ls", pol));
    try std.testing.expectEqual(CommandDecision.allow, checkCommand("cat", pol));
    try std.testing.expectEqual(CommandDecision.sandbox, checkCommand("rm", pol));
}

test "checkCommand blocked beats allowed" {
    const allowed = [_][]const u8{ "ls", "rm" };
    const blocked = [_][]const u8{"rm"};
    const pol = SandboxPolicy{ .allowed_commands = &allowed, .blocked_commands = &blocked };
    try std.testing.expectEqual(CommandDecision.deny, checkCommand("rm", pol));
    try std.testing.expectEqual(CommandDecision.allow, checkCommand("ls", pol));
}

test "checkCommand prefix matching" {
    const blocked = [_][]const u8{"rm*"};
    const pol = SandboxPolicy{ .blocked_commands = &blocked };
    try std.testing.expectEqual(CommandDecision.deny, checkCommand("rm -rf", pol));
    try std.testing.expectEqual(CommandDecision.deny, checkCommand("rmdir", pol));
}

test "checkDomain full access" {
    const pol = SandboxPolicy{ .network = .full };
    try std.testing.expect(checkDomain("anything.com", pol));
}

test "checkDomain no access" {
    const pol = SandboxPolicy{ .network = .none };
    try std.testing.expect(!checkDomain("google.com", pol));
}

test "checkDomain limited with allowlist" {
    const domains = [_][]const u8{ "api.openai.com", "api.anthropic.com" };
    const pol = SandboxPolicy{ .network = .limited, .allowed_domains = &domains };
    try std.testing.expect(checkDomain("api.openai.com", pol));
    try std.testing.expect(checkDomain("api.anthropic.com", pol));
    try std.testing.expect(!checkDomain("evil.com", pol));
}

test "checkDomain limited no restrictions" {
    const pol = SandboxPolicy{ .network = .limited };
    try std.testing.expect(checkDomain("anything.com", pol));
}

test "policyForLevel" {
    const basic = policyForLevel(.basic);
    try std.testing.expectEqual(SecurityLevel.basic, basic.level);

    const strict = policyForLevel(.strict);
    try std.testing.expectEqual(MountMode.ro, strict.mount_mode);
    try std.testing.expectEqual(NetworkAccess.none, strict.network);

    const paranoid = policyForLevel(.paranoid);
    try std.testing.expectEqual(MountMode.none, paranoid.mount_mode);
}

test "serializePolicy" {
    var buf: [512]u8 = undefined;
    const json = try serializePolicy(&buf, &STRICT_POLICY);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"level\":\"strict\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mount\":\"ro\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"network\":\"none\"") != null);
}

test "BASIC_POLICY values" {
    try std.testing.expectEqual(SecurityLevel.basic, BASIC_POLICY.level);
    try std.testing.expectEqual(@as(u32, 300), BASIC_POLICY.max_runtime_seconds);
}

test "STRICT_POLICY values" {
    try std.testing.expectEqual(@as(u32, 256), STRICT_POLICY.max_memory_mb);
    try std.testing.expectEqual(@as(u32, 50), STRICT_POLICY.max_cpu_percent);
}

test "PARANOID_POLICY values" {
    try std.testing.expectEqual(@as(u32, 128), PARANOID_POLICY.max_memory_mb);
    try std.testing.expectEqual(@as(u32, 30), PARANOID_POLICY.max_runtime_seconds);
}

test "CommandDecision labels" {
    try std.testing.expectEqualStrings("allow", CommandDecision.allow.label());
    try std.testing.expectEqualStrings("deny", CommandDecision.deny.label());
    try std.testing.expectEqualStrings("sandbox", CommandDecision.sandbox.label());
}
