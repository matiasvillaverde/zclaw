const std = @import("std");
const registry = @import("registry.zig");

// --- Policy Decision ---

pub const PolicyDecision = enum {
    allow,
    deny,
    ask, // Requires user approval

    pub fn label(self: PolicyDecision) []const u8 {
        return switch (self) {
            .allow => "allow",
            .deny => "deny",
            .ask => "ask",
        };
    }
};

// --- Policy Rule ---

pub const PolicyRule = struct {
    tool_pattern: []const u8, // Tool name or glob pattern (* for all)
    decision: PolicyDecision,
    reason: []const u8 = "",
};

// --- Policy Layer ---

pub const PolicyLayer = enum {
    global,
    agent,
    profile,
    provider,
    sandbox,

    pub fn label(self: PolicyLayer) []const u8 {
        return switch (self) {
            .global => "global",
            .agent => "agent",
            .profile => "profile",
            .provider => "provider",
            .sandbox => "sandbox",
        };
    }

    /// Priority order: higher number = evaluated later = overrides lower
    pub fn priority(self: PolicyLayer) u8 {
        return switch (self) {
            .global => 1,
            .provider => 2,
            .agent => 3,
            .profile => 4,
            .sandbox => 5,
        };
    }
};

// --- Policy Engine ---

pub const PolicyEngine = struct {
    rules: std.ArrayListUnmanaged(LayeredRule),
    allocator: std.mem.Allocator,

    const LayeredRule = struct {
        layer: PolicyLayer,
        rule: PolicyRule,
    };

    pub fn init(allocator: std.mem.Allocator) PolicyEngine {
        return .{
            .rules = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PolicyEngine) void {
        self.rules.deinit(self.allocator);
    }

    /// Add a policy rule at a specific layer.
    pub fn addRule(self: *PolicyEngine, layer: PolicyLayer, rule: PolicyRule) !void {
        try self.rules.append(self.allocator, .{
            .layer = layer,
            .rule = rule,
        });
    }

    /// Evaluate the policy for a specific tool.
    /// DENY always wins regardless of layer.
    /// Otherwise, highest priority layer's decision applies.
    pub fn evaluate(self: *const PolicyEngine, tool_name: []const u8) PolicyDecision {
        var best_decision: ?PolicyDecision = null;
        var best_priority: u8 = 0;
        var has_deny = false;

        for (self.rules.items) |lr| {
            if (!matchesPattern(lr.rule.tool_pattern, tool_name)) continue;

            // DENY always wins
            if (lr.rule.decision == .deny) {
                has_deny = true;
            }

            const prio = lr.layer.priority();
            if (best_decision == null or prio >= best_priority) {
                best_priority = prio;
                best_decision = lr.rule.decision;
            }
        }

        // Deny always wins
        if (has_deny) return .deny;

        return best_decision orelse .allow; // Default allow if no rules match
    }

    /// Get the reason for a denial.
    pub fn getDenyReason(self: *const PolicyEngine, tool_name: []const u8) ?[]const u8 {
        for (self.rules.items) |lr| {
            if (lr.rule.decision == .deny and matchesPattern(lr.rule.tool_pattern, tool_name)) {
                if (lr.rule.reason.len > 0) return lr.rule.reason;
            }
        }
        return null;
    }

    /// Get rule count.
    pub fn ruleCount(self: *const PolicyEngine) usize {
        return self.rules.items.len;
    }
};

/// Check if a pattern matches a tool name.
/// Supports: exact match, "*" (all), "prefix*" (prefix match)
fn matchesPattern(pattern: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (std.mem.eql(u8, pattern, name)) return true;

    // Prefix glob: "exec*" matches "exec_bash", "exec_process", etc.
    if (pattern.len > 0 and pattern[pattern.len - 1] == '*') {
        const prefix = pattern[0 .. pattern.len - 1];
        return std.mem.startsWith(u8, name, prefix);
    }

    return false;
}

// --- Built-in Policy Presets ---

/// Default policy: allow all tools except dangerous ones
pub fn defaultPolicy(allocator: std.mem.Allocator) !PolicyEngine {
    var engine = PolicyEngine.init(allocator);

    // Global: allow everything by default
    try engine.addRule(.global, .{ .tool_pattern = "*", .decision = .allow });

    return engine;
}

/// Sandbox policy: deny file writes and exec
pub fn sandboxPolicy(allocator: std.mem.Allocator) !PolicyEngine {
    var engine = PolicyEngine.init(allocator);

    try engine.addRule(.global, .{ .tool_pattern = "*", .decision = .allow });
    try engine.addRule(.sandbox, .{ .tool_pattern = "write", .decision = .deny, .reason = "sandboxed" });
    try engine.addRule(.sandbox, .{ .tool_pattern = "edit", .decision = .deny, .reason = "sandboxed" });
    try engine.addRule(.sandbox, .{ .tool_pattern = "exec", .decision = .deny, .reason = "sandboxed" });
    try engine.addRule(.sandbox, .{ .tool_pattern = "bash", .decision = .deny, .reason = "sandboxed" });
    try engine.addRule(.sandbox, .{ .tool_pattern = "apply_patch", .decision = .deny, .reason = "sandboxed" });

    return engine;
}

// --- Tests ---

test "PolicyDecision labels" {
    try std.testing.expectEqualStrings("allow", PolicyDecision.allow.label());
    try std.testing.expectEqualStrings("deny", PolicyDecision.deny.label());
    try std.testing.expectEqualStrings("ask", PolicyDecision.ask.label());
}

test "PolicyLayer labels and priority" {
    try std.testing.expectEqualStrings("global", PolicyLayer.global.label());
    try std.testing.expectEqualStrings("sandbox", PolicyLayer.sandbox.label());

    // Sandbox has highest priority
    try std.testing.expect(PolicyLayer.sandbox.priority() > PolicyLayer.global.priority());
    try std.testing.expect(PolicyLayer.agent.priority() > PolicyLayer.global.priority());
}

test "matchesPattern exact" {
    try std.testing.expect(matchesPattern("bash", "bash"));
    try std.testing.expect(!matchesPattern("bash", "read"));
}

test "matchesPattern wildcard" {
    try std.testing.expect(matchesPattern("*", "anything"));
    try std.testing.expect(matchesPattern("*", ""));
}

test "matchesPattern prefix" {
    try std.testing.expect(matchesPattern("exec*", "exec_bash"));
    try std.testing.expect(matchesPattern("exec*", "exec"));
    try std.testing.expect(!matchesPattern("exec*", "read"));
}

test "PolicyEngine basic allow" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    try engine.addRule(.global, .{ .tool_pattern = "*", .decision = .allow });

    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("bash"));
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("read"));
}

test "PolicyEngine deny always wins" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    // Global allows, but agent denies
    try engine.addRule(.global, .{ .tool_pattern = "*", .decision = .allow });
    try engine.addRule(.agent, .{ .tool_pattern = "bash", .decision = .deny, .reason = "too dangerous" });

    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate("bash"));
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("read")); // Not denied
}

test "PolicyEngine deny from lower layer still wins" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    // Global denies, agent allows - deny should still win
    try engine.addRule(.global, .{ .tool_pattern = "bash", .decision = .deny });
    try engine.addRule(.agent, .{ .tool_pattern = "bash", .decision = .allow });

    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate("bash"));
}

test "PolicyEngine ask decision" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    try engine.addRule(.global, .{ .tool_pattern = "*", .decision = .allow });
    try engine.addRule(.profile, .{ .tool_pattern = "exec*", .decision = .ask });

    // Profile layer has higher priority than global
    try std.testing.expectEqual(PolicyDecision.ask, engine.evaluate("exec_bash"));
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("read"));
}

test "PolicyEngine getDenyReason" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    try engine.addRule(.sandbox, .{ .tool_pattern = "bash", .decision = .deny, .reason = "sandboxed environment" });

    try std.testing.expectEqualStrings("sandboxed environment", engine.getDenyReason("bash").?);
    try std.testing.expect(engine.getDenyReason("read") == null);
}

test "PolicyEngine no rules defaults to allow" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("anything"));
}

test "defaultPolicy" {
    const allocator = std.testing.allocator;
    var engine = try defaultPolicy(allocator);
    defer engine.deinit();

    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("bash"));
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("read"));
}

test "sandboxPolicy" {
    const allocator = std.testing.allocator;
    var engine = try sandboxPolicy(allocator);
    defer engine.deinit();

    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate("bash"));
    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate("write"));
    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate("exec"));
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("read"));
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("memory_search"));
}

test "PolicyEngine multiple rules same tool" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    try engine.addRule(.global, .{ .tool_pattern = "bash", .decision = .allow });
    try engine.addRule(.agent, .{ .tool_pattern = "bash", .decision = .ask });

    // Agent layer has higher priority, so ask should win
    try std.testing.expectEqual(PolicyDecision.ask, engine.evaluate("bash"));
}

test "PolicyEngine ruleCount" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    try std.testing.expectEqual(@as(usize, 0), engine.ruleCount());
    try engine.addRule(.global, .{ .tool_pattern = "*", .decision = .allow });
    try std.testing.expectEqual(@as(usize, 1), engine.ruleCount());
}
