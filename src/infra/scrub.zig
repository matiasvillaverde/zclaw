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

// ===== Additional comprehensive tests =====

// --- containsSensitive extended ---

test "containsSensitive - AKIA prefix (AWS)" {
    try std.testing.expect(containsSensitive("aws_key: AKIA1234567890EXAMPLE"));
}

test "containsSensitive - glpat prefix (GitLab)" {
    try std.testing.expect(containsSensitive("gitlab: glpat-abcdef123456"));
}

test "containsSensitive - npm prefix" {
    try std.testing.expect(containsSensitive("npm token: npm_1234567890abcdef"));
}

test "containsSensitive - prefix at very start" {
    try std.testing.expect(containsSensitive("sk-abc123"));
    try std.testing.expect(containsSensitive("gsk_abc123"));
    try std.testing.expect(containsSensitive("ghp_abc123"));
    try std.testing.expect(containsSensitive("AKIA1234"));
    try std.testing.expect(containsSensitive("xoxb-1234"));
    try std.testing.expect(containsSensitive("xoxp-1234"));
    try std.testing.expect(containsSensitive("glpat-1234"));
    try std.testing.expect(containsSensitive("npm_1234"));
    try std.testing.expect(containsSensitive("Bearer token123"));
    try std.testing.expect(containsSensitive("sk-ant-xyz"));
}

test "containsSensitive - prefix at very end" {
    try std.testing.expect(containsSensitive("my key is sk-"));
    try std.testing.expect(containsSensitive("token: Bearer "));
}

test "containsSensitive - partial prefix no match" {
    try std.testing.expect(!containsSensitive("sk"));
    try std.testing.expect(!containsSensitive("gs"));
    try std.testing.expect(!containsSensitive("gh"));
    try std.testing.expect(!containsSensitive("AKI"));
    try std.testing.expect(!containsSensitive("xox"));
    try std.testing.expect(!containsSensitive("glpa"));
    try std.testing.expect(!containsSensitive("np"));
}

test "containsSensitive - mixed content with embedded token" {
    try std.testing.expect(containsSensitive("The API key is sk-proj-abc123 and it works"));
    try std.testing.expect(containsSensitive("{\"api_key\": \"sk-ant-secret123\"}"));
}

test "containsSensitive - multiple tokens in one string" {
    try std.testing.expect(containsSensitive("key1=sk-abc key2=ghp_xyz key3=gsk_123"));
}

// --- scrub extended ---

test "scrub - all prefix types individually" {
    var buf: [1024]u8 = undefined;

    // sk-ant- prefix
    try std.testing.expectEqualStrings("[REDACTED]", scrub("sk-ant-secret123", &buf));

    // sk- prefix
    try std.testing.expectEqualStrings("[REDACTED]", scrub("sk-proj-secret123", &buf));

    // gsk_ prefix
    try std.testing.expectEqualStrings("[REDACTED]", scrub("gsk_secret123", &buf));

    // Bearer prefix
    try std.testing.expectEqualStrings("[REDACTED]", scrub("Bearer eyJtoken", &buf));

    // ghp_ prefix
    try std.testing.expectEqualStrings("[REDACTED]", scrub("ghp_secret123", &buf));

    // xoxb- prefix
    try std.testing.expectEqualStrings("[REDACTED]", scrub("xoxb-secret123", &buf));

    // xoxp- prefix
    try std.testing.expectEqualStrings("[REDACTED]", scrub("xoxp-secret123", &buf));

    // AKIA prefix
    try std.testing.expectEqualStrings("[REDACTED]", scrub("AKIA1234567890AB", &buf));

    // glpat- prefix
    try std.testing.expectEqualStrings("[REDACTED]", scrub("glpat-secret123", &buf));

    // npm_ prefix
    try std.testing.expectEqualStrings("[REDACTED]", scrub("npm_secret123", &buf));
}

test "scrub - token terminated by various delimiters" {
    var buf: [1024]u8 = undefined;

    // space
    try std.testing.expectEqualStrings("[REDACTED] next", scrub("sk-abc123 next", &buf));

    // newline
    try std.testing.expectEqualStrings("[REDACTED]\nnext", scrub("sk-abc123\nnext", &buf));

    // tab
    try std.testing.expectEqualStrings("[REDACTED]\tnext", scrub("sk-abc123\tnext", &buf));

    // comma
    try std.testing.expectEqualStrings("[REDACTED],next", scrub("sk-abc123,next", &buf));

    // double quote
    try std.testing.expectEqualStrings("[REDACTED]\"next", scrub("sk-abc123\"next", &buf));

    // single quote
    try std.testing.expectEqualStrings("[REDACTED]'next", scrub("sk-abc123'next", &buf));

    // closing brace
    try std.testing.expectEqualStrings("[REDACTED]}next", scrub("sk-abc123}next", &buf));

    // closing bracket
    try std.testing.expectEqualStrings("[REDACTED]]next", scrub("sk-abc123]next", &buf));

    // carriage return
    try std.testing.expectEqualStrings("[REDACTED]\rnext", scrub("sk-abc123\rnext", &buf));
}

test "scrub - token in JSON structure" {
    var buf: [1024]u8 = undefined;
    const result = scrub("{\"api_key\": \"sk-ant-secret123\"}", &buf);
    try std.testing.expectEqualStrings("{\"api_key\": \"[REDACTED]\"}", result);
}

test "scrub - token in JSON array" {
    var buf: [1024]u8 = undefined;
    const result = scrub("[\"sk-secret1\", \"sk-secret2\"]", &buf);
    // After "sk-secret1" we hit quote, so it becomes [REDACTED]", " then sk-secret2 hits quote too
    try std.testing.expect(std.mem.indexOf(u8, result, "[REDACTED]") != null);
    // Count occurrences of [REDACTED]
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOf(u8, result[pos..], "[REDACTED]")) |idx| {
        count += 1;
        pos += idx + "[REDACTED]".len;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "scrub - multiple tokens separated by spaces" {
    var buf: [1024]u8 = undefined;
    const result = scrub("first=sk-abc second=ghp_xyz third=gsk_123", &buf);
    try std.testing.expectEqualStrings("first=[REDACTED] second=[REDACTED] third=[REDACTED]", result);
}

test "scrub - three tokens in a row" {
    var buf: [1024]u8 = undefined;
    const result = scrub("sk-a sk-b sk-c", &buf);
    try std.testing.expectEqualStrings("[REDACTED] [REDACTED] [REDACTED]", result);
}

test "scrub - token at very start of string" {
    var buf: [1024]u8 = undefined;
    const result = scrub("sk-secret123 and more text", &buf);
    try std.testing.expectEqualStrings("[REDACTED] and more text", result);
}

test "scrub - token at very end of string" {
    var buf: [1024]u8 = undefined;
    const result = scrub("the key is sk-secret123", &buf);
    try std.testing.expectEqualStrings("the key is [REDACTED]", result);
}

test "scrub - only token, nothing else" {
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("[REDACTED]", scrub("sk-abc123", &buf));
    try std.testing.expectEqualStrings("[REDACTED]", scrub("ghp_abc123", &buf));
    try std.testing.expectEqualStrings("[REDACTED]", scrub("gsk_abc123", &buf));
}

test "scrub - text that looks similar but is not a prefix" {
    var buf: [1024]u8 = undefined;
    // "isk-" does not start with "sk-" so should be safe... wait, actually "sk-" appears at index 1
    // But the code checks from each position, so "isk-abc" at i=1 matches "sk-"
    const result = scrub("isk-abc", &buf);
    // i=0: 'i' doesn't match any prefix
    // i=1: "sk-abc" matches "sk-", so it gets redacted
    try std.testing.expectEqualStrings("i[REDACTED]", result);
}

test "scrub - very long token" {
    var buf: [2048]u8 = undefined;
    const long_token = "sk-" ++ "a" ** 500;
    const result = scrub(long_token, &buf);
    try std.testing.expectEqualStrings("[REDACTED]", result);
}

test "scrub - very long safe text" {
    var buf: [2048]u8 = undefined;
    const safe_text = "hello " ** 100;
    const result = scrub(safe_text, &buf);
    try std.testing.expectEqualStrings(safe_text, result);
}

test "scrub - sk-ant- takes priority over sk-" {
    var buf: [1024]u8 = undefined;
    // "sk-ant-" is checked before "sk-" in the prefix list
    const result = scrub("sk-ant-abcdef", &buf);
    try std.testing.expectEqualStrings("[REDACTED]", result);
}

test "scrub - Bearer with space is the prefix" {
    var buf: [1024]u8 = undefined;
    // "Bearer " includes the space, so "Bearer" alone without space should not match
    const result = scrub("Authorization: Bearer eyJabc123", &buf);
    try std.testing.expectEqualStrings("Authorization: [REDACTED]", result);
}

test "scrub - AKIA without full match" {
    var buf: [1024]u8 = undefined;
    // "AKIA" is 4 chars, any string starting with AKIA matches
    const result = scrub("key=AKIA1234567890ABCDEF", &buf);
    try std.testing.expectEqualStrings("key=[REDACTED]", result);
}

test "scrub - output buffer exactly right size" {
    var buf: [10]u8 = undefined;
    const result = scrub("[REDACTED]", &buf);
    // "[REDACTED]" is 10 chars, no sensitive content, so it just copies
    try std.testing.expectEqualStrings("[REDACTED]", result);
}

test "scrub - output buffer too small truncates" {
    var buf: [5]u8 = undefined;
    const result = scrub("hello world this is long", &buf);
    try std.testing.expectEqualStrings("hello", result);
}

test "scrub - token with unicode characters after prefix" {
    var buf: [1024]u8 = undefined;
    const result = scrub("sk-\xc3\xa9\xc3\xa0\xc3\xbc end", &buf);
    // Unicode bytes are not delimiters, so the token extends until space
    try std.testing.expectEqualStrings("[REDACTED] end", result);
}

test "scrub - consecutive prefixes without space" {
    var buf: [1024]u8 = undefined;
    // After redacting first sk-, the next char is delimiter quote
    const result = scrub("\"sk-abc\"\"sk-def\"", &buf);
    try std.testing.expect(std.mem.indexOf(u8, result, "[REDACTED]") != null);
}

test "scrub - newlines between tokens" {
    var buf: [1024]u8 = undefined;
    const result = scrub("sk-abc\nsk-def\nsk-ghi", &buf);
    try std.testing.expectEqualStrings("[REDACTED]\n[REDACTED]\n[REDACTED]", result);
}

test "scrubAlloc - multiple tokens" {
    const allocator = std.testing.allocator;
    const result = try scrubAlloc(allocator, "keys: sk-abc ghp_xyz");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("keys: [REDACTED] [REDACTED]", result);
}

test "scrubAlloc - empty string" {
    const allocator = std.testing.allocator;
    const result = try scrubAlloc(allocator, "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "scrubAlloc - no sensitive content returns copy" {
    const allocator = std.testing.allocator;
    const input = "perfectly safe text with no secrets";
    const result = try scrubAlloc(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
    // Verify it's actually a copy (different pointer)
    try std.testing.expect(result.ptr != input.ptr);
}

test "scrub - xoxp slack token" {
    var buf: [1024]u8 = undefined;
    const result = scrub("xoxp-123-456-789-abc", &buf);
    try std.testing.expectEqualStrings("[REDACTED]", result);
}

test "scrub - glpat GitLab token" {
    var buf: [1024]u8 = undefined;
    const result = scrub("deploy: glpat-abcdef123456ghij", &buf);
    try std.testing.expectEqualStrings("deploy: [REDACTED]", result);
}

test "scrub - npm token" {
    var buf: [1024]u8 = undefined;
    const result = scrub("NPM_TOKEN=npm_abcdef123456", &buf);
    try std.testing.expectEqualStrings("NPM_TOKEN=[REDACTED]", result);
}

test "scrub - multiple different token types" {
    var buf: [2048]u8 = undefined;
    const input = "anthropic=sk-ant-abc openai=sk-xyz groq=gsk_123 github=ghp_tok slack=xoxb-tok aws=AKIA1234";
    const result = scrub(input, &buf);
    try std.testing.expectEqualStrings("anthropic=[REDACTED] openai=[REDACTED] groq=[REDACTED] github=[REDACTED] slack=[REDACTED] aws=[REDACTED]", result);
}

test "SENSITIVE_PREFIXES count" {
    try std.testing.expectEqual(@as(usize, 10), SENSITIVE_PREFIXES.len);
}
