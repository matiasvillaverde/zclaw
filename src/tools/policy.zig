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

// --- Additional Tests ---

test "PolicyLayer all labels non-empty" {
    for (std.meta.tags(PolicyLayer)) |layer| {
        try std.testing.expect(layer.label().len > 0);
    }
}

test "PolicyLayer priority ordering" {
    try std.testing.expect(PolicyLayer.global.priority() < PolicyLayer.provider.priority());
    try std.testing.expect(PolicyLayer.provider.priority() < PolicyLayer.agent.priority());
    try std.testing.expect(PolicyLayer.agent.priority() < PolicyLayer.profile.priority());
    try std.testing.expect(PolicyLayer.profile.priority() < PolicyLayer.sandbox.priority());
}

test "PolicyLayer provider label" {
    try std.testing.expectEqualStrings("provider", PolicyLayer.provider.label());
}

test "PolicyLayer profile label" {
    try std.testing.expectEqualStrings("profile", PolicyLayer.profile.label());
}

test "PolicyLayer agent label" {
    try std.testing.expectEqualStrings("agent", PolicyLayer.agent.label());
}

test "matchesPattern empty pattern" {
    try std.testing.expect(!matchesPattern("", "bash"));
}

test "matchesPattern empty name" {
    try std.testing.expect(matchesPattern("*", ""));
}

test "matchesPattern prefix no match" {
    try std.testing.expect(!matchesPattern("file*", "exec_bash"));
}

test "matchesPattern exact with star at end" {
    try std.testing.expect(matchesPattern("exec*", "exec"));
}

test "PolicyEngine getDenyReason no reason" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    try engine.addRule(.sandbox, .{ .tool_pattern = "bash", .decision = .deny });
    // No reason set, but deny rule exists
    try std.testing.expect(engine.getDenyReason("bash") == null);
}

test "PolicyEngine multiple denies first reason" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    try engine.addRule(.global, .{ .tool_pattern = "bash", .decision = .deny, .reason = "global deny" });
    try engine.addRule(.sandbox, .{ .tool_pattern = "bash", .decision = .deny, .reason = "sandbox deny" });

    const reason = engine.getDenyReason("bash").?;
    try std.testing.expectEqualStrings("global deny", reason);
}

test "PolicyEngine ask does not override deny" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    try engine.addRule(.global, .{ .tool_pattern = "bash", .decision = .deny });
    try engine.addRule(.sandbox, .{ .tool_pattern = "bash", .decision = .ask });

    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate("bash"));
}

test "sandboxPolicy deny reasons" {
    const allocator = std.testing.allocator;
    var engine = try sandboxPolicy(allocator);
    defer engine.deinit();

    try std.testing.expectEqualStrings("sandboxed", engine.getDenyReason("bash").?);
    try std.testing.expectEqualStrings("sandboxed", engine.getDenyReason("write").?);
    try std.testing.expectEqualStrings("sandboxed", engine.getDenyReason("exec").?);
    try std.testing.expectEqualStrings("sandboxed", engine.getDenyReason("edit").?);
    try std.testing.expectEqualStrings("sandboxed", engine.getDenyReason("apply_patch").?);
}

test "sandboxPolicy ruleCount" {
    const allocator = std.testing.allocator;
    var engine = try sandboxPolicy(allocator);
    defer engine.deinit();

    try std.testing.expectEqual(@as(usize, 6), engine.ruleCount());
}

test "defaultPolicy ruleCount" {
    const allocator = std.testing.allocator;
    var engine = try defaultPolicy(allocator);
    defer engine.deinit();

    try std.testing.expectEqual(@as(usize, 1), engine.ruleCount());
}

test "PolicyRule defaults" {
    const rule = PolicyRule{ .tool_pattern = "*", .decision = .allow };
    try std.testing.expectEqualStrings("", rule.reason);
}

// === New Tests (batch 2) ===

test "matchesPattern exact match with underscores" {
    try std.testing.expect(matchesPattern("memory_search", "memory_search"));
    try std.testing.expect(!matchesPattern("memory_search", "memory_index"));
}

test "matchesPattern prefix glob with underscores" {
    try std.testing.expect(matchesPattern("memory_*", "memory_search"));
    try std.testing.expect(matchesPattern("memory_*", "memory_index"));
    try std.testing.expect(!matchesPattern("memory_*", "web_fetch"));
}

test "matchesPattern single char prefix" {
    try std.testing.expect(matchesPattern("a*", "abc"));
    try std.testing.expect(matchesPattern("a*", "a"));
    try std.testing.expect(!matchesPattern("a*", "bc"));
}

test "matchesPattern just star literal" {
    // "*" matches everything, including empty string
    try std.testing.expect(matchesPattern("*", ""));
    try std.testing.expect(matchesPattern("*", "any_tool_name"));
    try std.testing.expect(matchesPattern("*", "a"));
}

test "PolicyEngine evaluate with wildcard allow and specific deny" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    try engine.addRule(.global, .{ .tool_pattern = "*", .decision = .allow });
    try engine.addRule(.agent, .{ .tool_pattern = "bash", .decision = .deny, .reason = "no bash" });
    try engine.addRule(.agent, .{ .tool_pattern = "exec*", .decision = .deny, .reason = "no exec" });

    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate("bash"));
    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate("exec_cmd"));
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("read"));
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("write"));
}

test "PolicyEngine multiple layers same decision" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    try engine.addRule(.global, .{ .tool_pattern = "read", .decision = .allow });
    try engine.addRule(.agent, .{ .tool_pattern = "read", .decision = .allow });
    try engine.addRule(.profile, .{ .tool_pattern = "read", .decision = .allow });

    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("read"));
}

test "PolicyEngine highest priority layer wins for non-deny" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    try engine.addRule(.global, .{ .tool_pattern = "tool", .decision = .allow });
    try engine.addRule(.agent, .{ .tool_pattern = "tool", .decision = .ask });
    try engine.addRule(.sandbox, .{ .tool_pattern = "tool", .decision = .allow });

    // sandbox has highest priority, so allow wins
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("tool"));
}

test "PolicyEngine deny at any layer blocks regardless" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    // Even if sandbox (highest) says allow, a global deny should still win
    try engine.addRule(.global, .{ .tool_pattern = "bash", .decision = .deny, .reason = "blocked" });
    try engine.addRule(.agent, .{ .tool_pattern = "bash", .decision = .allow });
    try engine.addRule(.profile, .{ .tool_pattern = "bash", .decision = .allow });
    try engine.addRule(.sandbox, .{ .tool_pattern = "bash", .decision = .allow });

    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate("bash"));
}

test "PolicyEngine getDenyReason returns first matching reason" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    try engine.addRule(.global, .{ .tool_pattern = "exec*", .decision = .deny, .reason = "exec is unsafe" });
    try engine.addRule(.sandbox, .{ .tool_pattern = "exec_bash", .decision = .deny, .reason = "sandbox blocks bash" });

    // First matching deny is returned
    const reason = engine.getDenyReason("exec_bash").?;
    try std.testing.expectEqualStrings("exec is unsafe", reason);
}

test "PolicyEngine getDenyReason for non-denied tool" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    try engine.addRule(.global, .{ .tool_pattern = "*", .decision = .allow });
    try engine.addRule(.sandbox, .{ .tool_pattern = "bash", .decision = .deny, .reason = "blocked" });

    // "read" is not denied
    try std.testing.expect(engine.getDenyReason("read") == null);
}

test "PolicyEngine evaluate with only ask rules" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    try engine.addRule(.global, .{ .tool_pattern = "*", .decision = .ask });

    try std.testing.expectEqual(PolicyDecision.ask, engine.evaluate("any_tool"));
}

test "PolicyEngine evaluate wildcard deny blocks everything" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    try engine.addRule(.global, .{ .tool_pattern = "*", .decision = .deny, .reason = "lockdown" });

    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate("bash"));
    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate("read"));
    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate("write"));
    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate("memory_search"));
}

test "PolicyEngine ruleCount after multiple adds" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    try engine.addRule(.global, .{ .tool_pattern = "*", .decision = .allow });
    try engine.addRule(.agent, .{ .tool_pattern = "bash", .decision = .deny });
    try engine.addRule(.profile, .{ .tool_pattern = "exec*", .decision = .ask });
    try engine.addRule(.sandbox, .{ .tool_pattern = "write", .decision = .deny });

    try std.testing.expectEqual(@as(usize, 4), engine.ruleCount());
}

test "PolicyDecision label completeness" {
    // All variants have distinct non-empty labels
    const decisions = [_]PolicyDecision{ .allow, .deny, .ask };
    for (decisions, 0..) |d1, i| {
        try std.testing.expect(d1.label().len > 0);
        for (decisions[i + 1 ..]) |d2| {
            try std.testing.expect(!std.mem.eql(u8, d1.label(), d2.label()));
        }
    }
}

test "PolicyLayer priority values are unique" {
    const layers = std.meta.tags(PolicyLayer);
    for (layers, 0..) |l1, i| {
        for (layers[i + 1 ..]) |l2| {
            try std.testing.expect(l1.priority() != l2.priority());
        }
    }
}

test "PolicyLayer global has lowest priority" {
    const layers = std.meta.tags(PolicyLayer);
    for (layers) |l| {
        try std.testing.expect(PolicyLayer.global.priority() <= l.priority());
    }
}

test "PolicyLayer sandbox has highest priority" {
    const layers = std.meta.tags(PolicyLayer);
    for (layers) |l| {
        try std.testing.expect(PolicyLayer.sandbox.priority() >= l.priority());
    }
}

test "sandboxPolicy allows read and search" {
    const allocator = std.testing.allocator;
    var engine = try sandboxPolicy(allocator);
    defer engine.deinit();

    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("read"));
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("memory_search"));
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("web_fetch"));
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("web_search"));
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("list_dir"));
}

test "sandboxPolicy denies all dangerous tools" {
    const allocator = std.testing.allocator;
    var engine = try sandboxPolicy(allocator);
    defer engine.deinit();

    const denied = [_][]const u8{ "write", "edit", "exec", "bash", "apply_patch" };
    for (denied) |tool| {
        try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate(tool));
    }
}

test "defaultPolicy allows everything" {
    const allocator = std.testing.allocator;
    var engine = try defaultPolicy(allocator);
    defer engine.deinit();

    const tools = [_][]const u8{ "bash", "read", "write", "exec", "memory_search", "web_fetch", "apply_patch", "edit" };
    for (tools) |tool| {
        try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate(tool));
    }
}

test "PolicyEngine empty pattern only matches empty name" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    try engine.addRule(.global, .{ .tool_pattern = "", .decision = .deny });

    // Empty pattern matches empty name via exact match
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("bash"));
    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate(""));
}

test "PolicyRule with reason" {
    const rule = PolicyRule{ .tool_pattern = "bash", .decision = .deny, .reason = "dangerous command execution" };
    try std.testing.expectEqualStrings("bash", rule.tool_pattern);
    try std.testing.expectEqual(PolicyDecision.deny, rule.decision);
    try std.testing.expectEqualStrings("dangerous command execution", rule.reason);
}

test "PolicyEngine multiple prefix patterns" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    try engine.addRule(.global, .{ .tool_pattern = "*", .decision = .allow });
    try engine.addRule(.agent, .{ .tool_pattern = "file_*", .decision = .ask });
    try engine.addRule(.agent, .{ .tool_pattern = "exec_*", .decision = .deny });

    try std.testing.expectEqual(PolicyDecision.ask, engine.evaluate("file_read"));
    try std.testing.expectEqual(PolicyDecision.ask, engine.evaluate("file_write"));
    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate("exec_bash"));
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("memory_search"));
}

// === New Tests (batch 3) ===

test "deny wins over allow at same layer" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    // Both rules at agent layer: allow via wildcard, deny via exact match
    try engine.addRule(.agent, .{ .tool_pattern = "*", .decision = .allow });
    try engine.addRule(.agent, .{ .tool_pattern = "bash", .decision = .deny, .reason = "explicitly denied" });

    // Deny wins regardless
    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate("bash"));
    // Others still allowed
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("read"));
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("write"));
}

test "empty policy allows all" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    // No rules added at all
    try std.testing.expectEqual(@as(usize, 0), engine.ruleCount());
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("bash"));
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("exec"));
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("write"));
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("read"));
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("anything_at_all"));
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate(""));
}

test "category-level deny with prefix pattern" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    // Allow everything by default
    try engine.addRule(.global, .{ .tool_pattern = "*", .decision = .allow });
    // Deny entire "exec" category using prefix pattern
    try engine.addRule(.agent, .{ .tool_pattern = "exec*", .decision = .deny, .reason = "execution blocked" });

    // All exec-prefixed tools denied
    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate("exec"));
    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate("exec_bash"));
    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate("exec_python"));
    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate("exec_node"));

    // Non-exec tools remain allowed
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("read"));
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("write"));
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("memory_search"));

    // Verify deny reasons
    try std.testing.expectEqualStrings("execution blocked", engine.getDenyReason("exec_bash").?);
    try std.testing.expect(engine.getDenyReason("read") == null);
}

test "tool-specific override in denied category" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    // Global allows all
    try engine.addRule(.global, .{ .tool_pattern = "*", .decision = .allow });
    // Agent denies all file tools
    try engine.addRule(.agent, .{ .tool_pattern = "file_*", .decision = .deny, .reason = "file ops blocked" });
    // Profile (higher priority) allows file_read specifically
    try engine.addRule(.profile, .{ .tool_pattern = "file_read", .decision = .allow });

    // file_read: has both deny (from agent layer) and allow (from profile layer)
    // But deny always wins regardless of layer priority
    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate("file_read"));

    // file_write: only deny from agent
    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate("file_write"));

    // non-file tools: allowed
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("bash"));
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("memory_search"));
}

test "multiple policies compose - most restrictive wins" {
    const allocator = std.testing.allocator;
    var engine = PolicyEngine.init(allocator);
    defer engine.deinit();

    // Chain of policies at different layers
    // Global: allow everything
    try engine.addRule(.global, .{ .tool_pattern = "*", .decision = .allow });
    // Provider: ask for exec tools
    try engine.addRule(.provider, .{ .tool_pattern = "exec*", .decision = .ask });
    // Agent: deny bash specifically
    try engine.addRule(.agent, .{ .tool_pattern = "bash", .decision = .deny, .reason = "agent blocks bash" });
    // Profile: ask for write
    try engine.addRule(.profile, .{ .tool_pattern = "write", .decision = .ask });
    // Sandbox: deny edit
    try engine.addRule(.sandbox, .{ .tool_pattern = "edit", .decision = .deny, .reason = "sandbox blocks edit" });

    // bash: denied by agent (deny always wins)
    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate("bash"));
    // edit: denied by sandbox
    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate("edit"));
    // exec_python: ask from provider (no deny present, highest matching layer with non-deny is agent wildcard=allow, but provider has exec* ask - agent layer has higher priority, default from global is allow, so agent's * allow at prio 3 > provider's exec* ask at prio 2)
    // Actually: global * allow (prio 1), provider exec* ask (prio 2), so highest prio matching is provider at prio 2... but global * also matches at prio 1. Provider at prio 2 wins.
    // Wait - let's trace evaluate: for "exec_python"
    // - global * allow (prio 1) -> best_prio=1, best=allow
    // - provider exec* ask (prio 2) -> prio 2 >= 1, best_prio=2, best=ask
    // No deny. Result: ask
    try std.testing.expectEqual(PolicyDecision.ask, engine.evaluate("exec_python"));
    // write: global allow (1), profile ask (4). Profile wins: ask
    try std.testing.expectEqual(PolicyDecision.ask, engine.evaluate("write"));
    // read: only global allow matches
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("read"));
    // memory_search: only global allow matches
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate("memory_search"));

    // Verify reasons
    try std.testing.expectEqualStrings("agent blocks bash", engine.getDenyReason("bash").?);
    try std.testing.expectEqualStrings("sandbox blocks edit", engine.getDenyReason("edit").?);
    try std.testing.expect(engine.getDenyReason("read") == null);
}
