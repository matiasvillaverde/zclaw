const std = @import("std");
const plugin = @import("plugin.zig");

// --- Access Mode ---

pub const AccessMode = enum {
    open, // Anyone can message
    allowlist, // Only allowed users
    denylist, // Everyone except denied users

    pub fn label(self: AccessMode) []const u8 {
        return switch (self) {
            .open => "open",
            .allowlist => "allowlist",
            .denylist => "denylist",
        };
    }

    pub fn fromString(s: []const u8) ?AccessMode {
        const map = std.StaticStringMap(AccessMode).initComptime(.{
            .{ "open", .open },
            .{ "allowlist", .allowlist },
            .{ "denylist", .denylist },
        });
        return map.get(s);
    }
};

// --- Group Mode ---

pub const GroupMode = enum {
    disabled, // Don't respond in groups
    mention_only, // Only respond when mentioned
    always, // Always respond in groups

    pub fn label(self: GroupMode) []const u8 {
        return switch (self) {
            .disabled => "disabled",
            .mention_only => "mention_only",
            .always => "always",
        };
    }
};

// --- Access Policy ---

pub const AccessPolicy = struct {
    dm_mode: AccessMode = .open,
    group_mode: GroupMode = .mention_only,
    allowed_users: []const []const u8 = &.{},
    denied_users: []const []const u8 = &.{},
    allowed_groups: []const []const u8 = &.{},
    bot_username: ?[]const u8 = null,
};

// --- Access Check ---

pub const AccessDecision = enum {
    allow,
    deny,
    ignore, // Don't respond but don't error

    pub fn label(self: AccessDecision) []const u8 {
        return switch (self) {
            .allow => "allow",
            .deny => "deny",
            .ignore => "ignore",
        };
    }
};

/// Check if an incoming message should be processed.
pub fn checkAccess(msg: plugin.IncomingMessage, policy: AccessPolicy) AccessDecision {
    if (msg.is_group) {
        return checkGroupAccess(msg, policy);
    } else {
        return checkDmAccess(msg, policy);
    }
}

fn checkDmAccess(msg: plugin.IncomingMessage, policy: AccessPolicy) AccessDecision {
    return switch (policy.dm_mode) {
        .open => .allow,
        .allowlist => {
            for (policy.allowed_users) |user| {
                if (std.mem.eql(u8, user, msg.sender_id)) return .allow;
            }
            return .deny;
        },
        .denylist => {
            for (policy.denied_users) |user| {
                if (std.mem.eql(u8, user, msg.sender_id)) return .deny;
            }
            return .allow;
        },
    };
}

fn checkGroupAccess(msg: plugin.IncomingMessage, policy: AccessPolicy) AccessDecision {
    return switch (policy.group_mode) {
        .disabled => .ignore,
        .always => {
            // Check if group is allowed
            if (policy.allowed_groups.len > 0) {
                for (policy.allowed_groups) |group| {
                    if (std.mem.eql(u8, group, msg.chat_id)) return .allow;
                }
                return .ignore;
            }
            return .allow;
        },
        .mention_only => {
            // Check if bot is mentioned in content
            if (policy.bot_username) |bot_name| {
                if (isMentioned(msg.content, bot_name)) return .allow;
            }
            return .ignore;
        },
    };
}

/// Check if a bot username is mentioned in the message content.
fn isMentioned(content: []const u8, bot_username: []const u8) bool {
    // Check for @username pattern
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] == '@') {
            const start = i + 1;
            if (start + bot_username.len <= content.len) {
                if (eqlNoCase(content[start .. start + bot_username.len], bot_username)) {
                    // Check that it's a word boundary
                    const after = start + bot_username.len;
                    if (after >= content.len or !std.ascii.isAlphanumeric(content[after])) {
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

fn eqlNoCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

// --- Tests ---

test "AccessMode labels and fromString" {
    try std.testing.expectEqualStrings("open", AccessMode.open.label());
    try std.testing.expectEqualStrings("allowlist", AccessMode.allowlist.label());
    try std.testing.expectEqual(AccessMode.open, AccessMode.fromString("open").?);
    try std.testing.expectEqual(@as(?AccessMode, null), AccessMode.fromString("unknown"));
}

test "GroupMode labels" {
    try std.testing.expectEqualStrings("disabled", GroupMode.disabled.label());
    try std.testing.expectEqualStrings("mention_only", GroupMode.mention_only.label());
    try std.testing.expectEqualStrings("always", GroupMode.always.label());
}

test "checkAccess DM open" {
    const msg = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "1",
        .sender_id = "user123",
        .chat_id = "chat1",
        .content = "hello",
        .is_group = false,
    };
    const result = checkAccess(msg, .{});
    try std.testing.expectEqual(AccessDecision.allow, result);
}

test "checkAccess DM allowlist - allowed" {
    const allowed = [_][]const u8{"user123"};
    const msg = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "1",
        .sender_id = "user123",
        .chat_id = "chat1",
        .content = "hello",
        .is_group = false,
    };
    const result = checkAccess(msg, .{ .dm_mode = .allowlist, .allowed_users = &allowed });
    try std.testing.expectEqual(AccessDecision.allow, result);
}

test "checkAccess DM allowlist - denied" {
    const allowed = [_][]const u8{"user999"};
    const msg = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "1",
        .sender_id = "user123",
        .chat_id = "chat1",
        .content = "hello",
        .is_group = false,
    };
    const result = checkAccess(msg, .{ .dm_mode = .allowlist, .allowed_users = &allowed });
    try std.testing.expectEqual(AccessDecision.deny, result);
}

test "checkAccess DM denylist - denied" {
    const denied = [_][]const u8{"user123"};
    const msg = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "1",
        .sender_id = "user123",
        .chat_id = "chat1",
        .content = "hello",
        .is_group = false,
    };
    const result = checkAccess(msg, .{ .dm_mode = .denylist, .denied_users = &denied });
    try std.testing.expectEqual(AccessDecision.deny, result);
}

test "checkAccess DM denylist - allowed" {
    const denied = [_][]const u8{"user999"};
    const msg = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "1",
        .sender_id = "user123",
        .chat_id = "chat1",
        .content = "hello",
        .is_group = false,
    };
    const result = checkAccess(msg, .{ .dm_mode = .denylist, .denied_users = &denied });
    try std.testing.expectEqual(AccessDecision.allow, result);
}

test "checkAccess group disabled" {
    const msg = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "1",
        .sender_id = "user123",
        .chat_id = "group1",
        .content = "hello",
        .is_group = true,
    };
    const result = checkAccess(msg, .{ .group_mode = .disabled });
    try std.testing.expectEqual(AccessDecision.ignore, result);
}

test "checkAccess group always" {
    const msg = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "1",
        .sender_id = "user123",
        .chat_id = "group1",
        .content = "hello",
        .is_group = true,
    };
    const result = checkAccess(msg, .{ .group_mode = .always });
    try std.testing.expectEqual(AccessDecision.allow, result);
}

test "checkAccess group mention_only - mentioned" {
    const msg = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "1",
        .sender_id = "user123",
        .chat_id = "group1",
        .content = "hey @mybot what's up?",
        .is_group = true,
    };
    const result = checkAccess(msg, .{ .group_mode = .mention_only, .bot_username = "mybot" });
    try std.testing.expectEqual(AccessDecision.allow, result);
}

test "checkAccess group mention_only - not mentioned" {
    const msg = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "1",
        .sender_id = "user123",
        .chat_id = "group1",
        .content = "hey everyone",
        .is_group = true,
    };
    const result = checkAccess(msg, .{ .group_mode = .mention_only, .bot_username = "mybot" });
    try std.testing.expectEqual(AccessDecision.ignore, result);
}

test "isMentioned" {
    try std.testing.expect(isMentioned("hello @mybot", "mybot"));
    try std.testing.expect(isMentioned("@mybot hello", "mybot"));
    try std.testing.expect(isMentioned("hey @MyBot what", "mybot")); // case insensitive
    try std.testing.expect(!isMentioned("hello world", "mybot"));
    try std.testing.expect(!isMentioned("@mybot123", "mybot")); // partial match
}

test "checkAccess group allowed_groups" {
    const groups = [_][]const u8{"group-ok"};
    const msg_ok = plugin.IncomingMessage{
        .channel = .discord,
        .message_id = "1",
        .sender_id = "u1",
        .chat_id = "group-ok",
        .content = "hello",
        .is_group = true,
    };
    const msg_bad = plugin.IncomingMessage{
        .channel = .discord,
        .message_id = "2",
        .sender_id = "u1",
        .chat_id = "group-bad",
        .content = "hello",
        .is_group = true,
    };
    const policy = AccessPolicy{ .group_mode = .always, .allowed_groups = &groups };
    try std.testing.expectEqual(AccessDecision.allow, checkAccess(msg_ok, policy));
    try std.testing.expectEqual(AccessDecision.ignore, checkAccess(msg_bad, policy));
}
