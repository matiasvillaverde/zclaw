const std = @import("std");

// --- Credential Scrubbing ---
//
// Pattern-based detection and redaction of API keys/tokens in output.

/// Known sensitive prefixes. If a token starts with any of these,
/// it's likely a credential that should be redacted.
pub const SENSITIVE_PREFIXES = [_][]const u8{
    "sk-ant-",
    "sk-",
    "gsk_",
    "Bearer ",
    "ghp_",
    "xoxb-",
    "xoxp-",
    "AKIA",
    "glpat-",
    "npm_",
};

const REDACTED = "[REDACTED]";

/// Check if input contains any sensitive patterns.
pub fn containsSensitive(input: []const u8) bool {
    for (SENSITIVE_PREFIXES) |prefix| {
        if (std.mem.indexOf(u8, input, prefix) != null) return true;
    }
    return false;
}

/// Scrub sensitive tokens from input into output buffer.
/// Returns the scrubbed text.
pub fn scrub(input: []const u8, output: []u8) []const u8 {
    var fbs = std.io.fixedBufferStream(output);
    const writer = fbs.writer();
    var i: usize = 0;

    while (i < input.len) {
        var matched = false;
        for (SENSITIVE_PREFIXES) |prefix| {
            if (i + prefix.len <= input.len and std.mem.eql(u8, input[i .. i + prefix.len], prefix)) {
                // Found a sensitive prefix — redact the token
                writer.writeAll(REDACTED) catch return fbs.getWritten();
                // Skip to end of token (whitespace, comma, quote, newline, or end)
                var j = i + prefix.len;
                while (j < input.len) : (j += 1) {
                    const c = input[j];
                    if (c == ' ' or c == '\n' or c == '\r' or c == '\t' or
                        c == ',' or c == '"' or c == '\'' or c == '}' or c == ']')
                    {
                        break;
                    }
                }
                i = j;
                matched = true;
                break;
            }
        }
        if (!matched) {
            writer.writeByte(input[i]) catch return fbs.getWritten();
            i += 1;
        }
    }

    return fbs.getWritten();
}

/// Scrub sensitive tokens, returning an allocated string.
pub fn scrubAlloc(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (!containsSensitive(input)) {
        return try allocator.dupe(u8, input);
    }

    var buf: [128 * 1024]u8 = undefined;
    const result = scrub(input, &buf);
    return try allocator.dupe(u8, result);
}

// --- Tests ---

test "containsSensitive positive" {
    try std.testing.expect(containsSensitive("my key is sk-ant-abc123xyz"));
    try std.testing.expect(containsSensitive("token: sk-abc123"));
    try std.testing.expect(containsSensitive("api_key: gsk_abcdef"));
    try std.testing.expect(containsSensitive("auth: Bearer eyJhb"));
    try std.testing.expect(containsSensitive("github: ghp_12345"));
    try std.testing.expect(containsSensitive("slack: xoxb-1234"));
    try std.testing.expect(containsSensitive("slack: xoxp-9999"));
}

test "containsSensitive negative" {
    try std.testing.expect(!containsSensitive("hello world"));
    try std.testing.expect(!containsSensitive("this is safe text"));
    try std.testing.expect(!containsSensitive("no secrets here"));
    try std.testing.expect(!containsSensitive(""));
}

test "scrub replaces sk-ant- token" {
    var buf: [1024]u8 = undefined;
    const result = scrub("key: sk-ant-abc123xyz456", &buf);
    try std.testing.expectEqualStrings("key: [REDACTED]", result);
}

test "scrub replaces sk- token" {
    var buf: [1024]u8 = undefined;
    const result = scrub("Authorization: sk-proj-abc123", &buf);
    try std.testing.expectEqualStrings("Authorization: [REDACTED]", result);
}

test "scrub replaces Bearer token" {
    var buf: [1024]u8 = undefined;
    const result = scrub("header: Bearer eyJhbGciOiJIUzI1NiJ9", &buf);
    try std.testing.expectEqualStrings("header: [REDACTED]", result);
}

test "scrub replaces gsk_ token" {
    var buf: [1024]u8 = undefined;
    const result = scrub("groq: gsk_abcdef123456", &buf);
    try std.testing.expectEqualStrings("groq: [REDACTED]", result);
}

test "scrub replaces ghp_ token" {
    var buf: [1024]u8 = undefined;
    const result = scrub("github_token=ghp_1234567890abcdef", &buf);
    try std.testing.expectEqualStrings("github_token=[REDACTED]", result);
}

test "scrub replaces multiple tokens" {
    var buf: [1024]u8 = undefined;
    const result = scrub("key1=sk-abc key2=gsk_xyz", &buf);
    try std.testing.expectEqualStrings("key1=[REDACTED] key2=[REDACTED]", result);
}

test "scrub preserves safe text" {
    var buf: [1024]u8 = undefined;
    const result = scrub("hello world", &buf);
    try std.testing.expectEqualStrings("hello world", result);
}

test "scrub empty input" {
    var buf: [1024]u8 = undefined;
    const result = scrub("", &buf);
    try std.testing.expectEqualStrings("", result);
}

test "scrub token at end of string" {
    var buf: [1024]u8 = undefined;
    const result = scrub("sk-test123", &buf);
    try std.testing.expectEqualStrings("[REDACTED]", result);
}

test "scrubAlloc with sensitive content" {
    const allocator = std.testing.allocator;
    const result = try scrubAlloc(allocator, "key: sk-ant-secret123");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("key: [REDACTED]", result);
}

test "scrubAlloc with safe content" {
    const allocator = std.testing.allocator;
    const result = try scrubAlloc(allocator, "safe text");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("safe text", result);
}

test "scrub xoxb slack token" {
    var buf: [1024]u8 = undefined;
    const result = scrub("slack: xoxb-123-456-abc", &buf);
    try std.testing.expectEqualStrings("slack: [REDACTED]", result);
}
