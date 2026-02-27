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

// ======================================================================
// Additional comprehensive tests
// ======================================================================

// --- AccessMode Tests ---

test "AccessMode fromString denylist" {
    try std.testing.expectEqual(AccessMode.denylist, AccessMode.fromString("denylist").?);
}

test "AccessMode fromString case sensitive" {
    try std.testing.expect(AccessMode.fromString("Open") == null);
    try std.testing.expect(AccessMode.fromString("ALLOWLIST") == null);
}

test "AccessMode fromString empty" {
    try std.testing.expect(AccessMode.fromString("") == null);
}

test "AccessMode label denylist" {
    try std.testing.expectEqualStrings("denylist", AccessMode.denylist.label());
}

// --- AccessDecision Tests ---

test "AccessDecision label allow" {
    try std.testing.expectEqualStrings("allow", AccessDecision.allow.label());
}

test "AccessDecision label deny" {
    try std.testing.expectEqualStrings("deny", AccessDecision.deny.label());
}

test "AccessDecision label ignore" {
    try std.testing.expectEqualStrings("ignore", AccessDecision.ignore.label());
}

// --- DM Access Mode: Open ---

test "checkAccess DM open allows any user" {
    const users = [_][]const u8{ "user1", "user2", "user3" };
    for (users) |uid| {
        const msg = plugin.IncomingMessage{
            .channel = .telegram,
            .message_id = "1",
            .sender_id = uid,
            .chat_id = "c1",
            .content = "hi",
            .is_group = false,
        };
        const result = checkAccess(msg, .{});
        try std.testing.expectEqual(AccessDecision.allow, result);
    }
}

// --- DM Access Mode: Allowlist ---

test "checkAccess DM allowlist empty list denies all" {
    const empty = [_][]const u8{};
    const msg = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "1",
        .sender_id = "user123",
        .chat_id = "c1",
        .content = "hi",
        .is_group = false,
    };
    const result = checkAccess(msg, .{ .dm_mode = .allowlist, .allowed_users = &empty });
    try std.testing.expectEqual(AccessDecision.deny, result);
}

test "checkAccess DM allowlist multiple users - first match" {
    const allowed = [_][]const u8{ "user1", "user2", "user3" };
    const msg = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "1",
        .sender_id = "user1",
        .chat_id = "c1",
        .content = "hi",
        .is_group = false,
    };
    const result = checkAccess(msg, .{ .dm_mode = .allowlist, .allowed_users = &allowed });
    try std.testing.expectEqual(AccessDecision.allow, result);
}

test "checkAccess DM allowlist multiple users - last match" {
    const allowed = [_][]const u8{ "user1", "user2", "user3" };
    const msg = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "1",
        .sender_id = "user3",
        .chat_id = "c1",
        .content = "hi",
        .is_group = false,
    };
    const result = checkAccess(msg, .{ .dm_mode = .allowlist, .allowed_users = &allowed });
    try std.testing.expectEqual(AccessDecision.allow, result);
}

test "checkAccess DM allowlist partial match is denied" {
    const allowed = [_][]const u8{"user123"};
    const msg = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "1",
        .sender_id = "user12",
        .chat_id = "c1",
        .content = "hi",
        .is_group = false,
    };
    const result = checkAccess(msg, .{ .dm_mode = .allowlist, .allowed_users = &allowed });
    try std.testing.expectEqual(AccessDecision.deny, result);
}

test "checkAccess DM allowlist exact match required" {
    const allowed = [_][]const u8{"user"};
    const msg = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "1",
        .sender_id = "user123",
        .chat_id = "c1",
        .content = "hi",
        .is_group = false,
    };
    const result = checkAccess(msg, .{ .dm_mode = .allowlist, .allowed_users = &allowed });
    try std.testing.expectEqual(AccessDecision.deny, result);
}

// --- DM Access Mode: Denylist ---

test "checkAccess DM denylist empty list allows all" {
    const empty = [_][]const u8{};
    const msg = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "1",
        .sender_id = "anyone",
        .chat_id = "c1",
        .content = "hi",
        .is_group = false,
    };
    const result = checkAccess(msg, .{ .dm_mode = .denylist, .denied_users = &empty });
    try std.testing.expectEqual(AccessDecision.allow, result);
}

test "checkAccess DM denylist multiple denials" {
    const denied = [_][]const u8{ "spam1", "spam2", "spam3" };
    const msg_blocked = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "1",
        .sender_id = "spam2",
        .chat_id = "c1",
        .content = "buy now!",
        .is_group = false,
    };
    const msg_ok = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "2",
        .sender_id = "regular_user",
        .chat_id = "c1",
        .content = "hello",
        .is_group = false,
    };
    const policy = AccessPolicy{ .dm_mode = .denylist, .denied_users = &denied };
    try std.testing.expectEqual(AccessDecision.deny, checkAccess(msg_blocked, policy));
    try std.testing.expectEqual(AccessDecision.allow, checkAccess(msg_ok, policy));
}

// --- Group Access Mode: Disabled ---

test "checkAccess group disabled ignores any group" {
    const msg = plugin.IncomingMessage{
        .channel = .discord,
        .message_id = "1",
        .sender_id = "u1",
        .chat_id = "group-any",
        .content = "hello @bot",
        .is_group = true,
    };
    const result = checkAccess(msg, .{ .group_mode = .disabled });
    try std.testing.expectEqual(AccessDecision.ignore, result);
}

// --- Group Access Mode: Always ---

test "checkAccess group always with no group restrictions" {
    const msg = plugin.IncomingMessage{
        .channel = .discord,
        .message_id = "1",
        .sender_id = "u1",
        .chat_id = "any-group",
        .content = "hello",
        .is_group = true,
    };
    const result = checkAccess(msg, .{ .group_mode = .always });
    try std.testing.expectEqual(AccessDecision.allow, result);
}

test "checkAccess group always with allowed_groups - multiple" {
    const groups = [_][]const u8{ "group-a", "group-b", "group-c" };
    const policy = AccessPolicy{ .group_mode = .always, .allowed_groups = &groups };

    const msg_a = plugin.IncomingMessage{
        .channel = .discord,
        .message_id = "1",
        .sender_id = "u1",
        .chat_id = "group-b",
        .content = "hello",
        .is_group = true,
    };
    try std.testing.expectEqual(AccessDecision.allow, checkAccess(msg_a, policy));

    const msg_bad = plugin.IncomingMessage{
        .channel = .discord,
        .message_id = "2",
        .sender_id = "u1",
        .chat_id = "group-d",
        .content = "hello",
        .is_group = true,
    };
    try std.testing.expectEqual(AccessDecision.ignore, checkAccess(msg_bad, policy));
}

test "checkAccess group always with empty allowed_groups allows all" {
    const empty = [_][]const u8{};
    const msg = plugin.IncomingMessage{
        .channel = .discord,
        .message_id = "1",
        .sender_id = "u1",
        .chat_id = "any-group",
        .content = "hello",
        .is_group = true,
    };
    const result = checkAccess(msg, .{ .group_mode = .always, .allowed_groups = &empty });
    try std.testing.expectEqual(AccessDecision.allow, result);
}

// --- Group Access Mode: Mention Only ---

test "checkAccess group mention_only - @bot at end" {
    const msg = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "1",
        .sender_id = "u1",
        .chat_id = "g1",
        .content = "can you help @zclaw",
        .is_group = true,
    };
    const result = checkAccess(msg, .{ .group_mode = .mention_only, .bot_username = "zclaw" });
    try std.testing.expectEqual(AccessDecision.allow, result);
}

test "checkAccess group mention_only - @bot at start" {
    const msg = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "1",
        .sender_id = "u1",
        .chat_id = "g1",
        .content = "@zclaw help me",
        .is_group = true,
    };
    const result = checkAccess(msg, .{ .group_mode = .mention_only, .bot_username = "zclaw" });
    try std.testing.expectEqual(AccessDecision.allow, result);
}

test "checkAccess group mention_only - no bot_username configured" {
    const msg = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "1",
        .sender_id = "u1",
        .chat_id = "g1",
        .content = "@zclaw help",
        .is_group = true,
    };
    const result = checkAccess(msg, .{ .group_mode = .mention_only });
    try std.testing.expectEqual(AccessDecision.ignore, result);
}

test "checkAccess group mention_only - bot name in text without @" {
    const msg = plugin.IncomingMessage{
        .channel = .telegram,
        .message_id = "1",
        .sender_id = "u1",
        .chat_id = "g1",
        .content = "hey zclaw help me",
        .is_group = true,
    };
    const result = checkAccess(msg, .{ .group_mode = .mention_only, .bot_username = "zclaw" });
    try std.testing.expectEqual(AccessDecision.ignore, result);
}

// --- Mention Detection Tests ---

test "isMentioned @ in middle of message" {
    try std.testing.expect(isMentioned("hey @bot what do you think?", "bot"));
}

test "isMentioned @ at very end" {
    try std.testing.expect(isMentioned("hello @bot", "bot"));
}

test "isMentioned @ at very start" {
    try std.testing.expect(isMentioned("@bot", "bot"));
}

test "isMentioned case insensitive mixed case" {
    try std.testing.expect(isMentioned("Hey @BoT help", "bot"));
}

test "isMentioned case insensitive uppercase" {
    try std.testing.expect(isMentioned("HEY @BOT", "bot"));
}

test "isMentioned partial match is rejected - suffix" {
    try std.testing.expect(!isMentioned("@botmaster help", "bot"));
}

test "isMentioned empty content" {
    try std.testing.expect(!isMentioned("", "bot"));
}

test "isMentioned @ only" {
    try std.testing.expect(!isMentioned("@", "bot"));
}

test "isMentioned multiple @ signs, second matches" {
    try std.testing.expect(isMentioned("email@test hey @bot help", "bot"));
}

test "isMentioned with underscore in name" {
    try std.testing.expect(isMentioned("hey @my_bot help", "my_bot"));
}

test "isMentioned with numbers in name boundary" {
    try std.testing.expect(!isMentioned("@bot123", "bot"));
}

test "isMentioned followed by punctuation" {
    try std.testing.expect(isMentioned("@bot, help me", "bot"));
}

test "isMentioned followed by exclamation" {
    try std.testing.expect(isMentioned("@bot! do something", "bot"));
}

test "isMentioned followed by period" {
    try std.testing.expect(isMentioned("Thanks @bot.", "bot"));
}

// --- Cross-Channel Access Tests ---

test "checkAccess works with all channel types for DM" {
    const channels = [_]plugin.ChannelType{ .telegram, .discord, .slack, .whatsapp, .signal, .matrix, .webchat };
    for (channels) |ch| {
        const msg = plugin.IncomingMessage{
            .channel = ch,
            .message_id = "1",
            .sender_id = "u1",
            .chat_id = "c1",
            .content = "hi",
            .is_group = false,
        };
        const result = checkAccess(msg, .{});
        try std.testing.expectEqual(AccessDecision.allow, result);
    }
}

test "checkAccess works with all channel types for group" {
    const channels = [_]plugin.ChannelType{ .telegram, .discord, .slack, .whatsapp, .signal, .matrix };
    for (channels) |ch| {
        const msg = plugin.IncomingMessage{
            .channel = ch,
            .message_id = "1",
            .sender_id = "u1",
            .chat_id = "g1",
            .content = "hi",
            .is_group = true,
        };
        // Default group_mode is mention_only with no bot name => ignore
        const result = checkAccess(msg, .{});
        try std.testing.expectEqual(AccessDecision.ignore, result);
    }
}

// --- Policy Defaults ---

test "AccessPolicy defaults" {
    const policy = AccessPolicy{};
    try std.testing.expectEqual(AccessMode.open, policy.dm_mode);
    try std.testing.expectEqual(GroupMode.mention_only, policy.group_mode);
    try std.testing.expectEqual(@as(usize, 0), policy.allowed_users.len);
    try std.testing.expectEqual(@as(usize, 0), policy.denied_users.len);
    try std.testing.expectEqual(@as(usize, 0), policy.allowed_groups.len);
    try std.testing.expect(policy.bot_username == null);
}

// --- eqlNoCase Tests ---

test "eqlNoCase equal" {
    try std.testing.expect(eqlNoCase("hello", "hello"));
}

test "eqlNoCase different case" {
    try std.testing.expect(eqlNoCase("Hello", "hello"));
    try std.testing.expect(eqlNoCase("HELLO", "hello"));
}

test "eqlNoCase different length" {
    try std.testing.expect(!eqlNoCase("hi", "hello"));
}

test "eqlNoCase empty strings" {
    try std.testing.expect(eqlNoCase("", ""));
}

test "eqlNoCase different strings" {
    try std.testing.expect(!eqlNoCase("abc", "xyz"));
}
