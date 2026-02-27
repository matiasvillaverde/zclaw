const std = @import("std");

/// Credential security module.
/// File permission enforcement, credential masking,
/// constant-time comparison, and credential format validation.

pub const SecretError = error{ CredentialTooShort, CredentialTooLong, NoUppercase, NoLowercase, NoDigit, WeakCredential, CommonPassword };

pub const CredentialRequirements = struct {
    min_length: usize = 16,
    max_length: usize = 256,
    require_uppercase: bool = true,
    require_lowercase: bool = true,
    require_digit: bool = true,
    require_special: bool = false,
    reject_common: bool = true,
};

const default_requirements = CredentialRequirements{};

pub fn constantTimeEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |ac, bc| diff |= ac ^ bc;
    return diff == 0;
}

pub fn validateCredentialStrength(cred: []const u8, reqs: CredentialRequirements) SecretError!void {
    if (cred.len < reqs.min_length) return SecretError.CredentialTooShort;
    if (cred.len > reqs.max_length) return SecretError.CredentialTooLong;
    var has_upper = false;
    var has_lower = false;
    var has_digit = false;
    var has_special = false;
    for (cred) |c| {
        if (std.ascii.isUpper(c)) has_upper = true;
        if (std.ascii.isLower(c)) has_lower = true;
        if (std.ascii.isDigit(c)) has_digit = true;
        if (!std.ascii.isAlphanumeric(c)) has_special = true;
    }
    if (reqs.require_uppercase and !has_upper) return SecretError.NoUppercase;
    if (reqs.require_lowercase and !has_lower) return SecretError.NoLowercase;
    if (reqs.require_digit and !has_digit) return SecretError.NoDigit;
    if (reqs.require_special and !has_special) return SecretError.WeakCredential;
    if (reqs.reject_common and isCommonPassword(cred)) return SecretError.CommonPassword;
}

const common_passwords = [_][]const u8{
    "password", "12345678", "qwerty", "abc123", "monkey", "master",
    "dragon",   "111111",   "baseball", "iloveyou", "trustno1", "sunshine",
    "passw0rd", "shadow",   "123123",  "superman", "password1", "password123",
    "admin",    "letmein",  "welcome", "login",   "hello",   "football",
};

fn isCommonPassword(password: []const u8) bool {
    for (common_passwords) |common| {
        if (password.len == common.len) {
            var match = true;
            for (password, common) |pc, cc| {
                if (std.ascii.toLower(pc) != std.ascii.toLower(cc)) { match = false; break; }
            }
            if (match) return true;
        }
    }
    return false;
}

pub fn maskCredential(allocator: std.mem.Allocator, cred: []const u8) ![]u8 {
    if (cred.len <= 4) return try allocator.dupe(u8, "****");
    if (cred.len <= 8) {
        var result = try std.ArrayListUnmanaged(u8).initCapacity(allocator, cred.len);
        errdefer result.deinit(allocator);
        try result.append(allocator, cred[0]);
        for (0..cred.len - 2) |_| try result.append(allocator, '*');
        try result.append(allocator, cred[cred.len - 1]);
        return result.toOwnedSlice(allocator);
    }
    var result = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 12);
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, cred[0..2]);
    try result.appendSlice(allocator, "****");
    try result.appendSlice(allocator, cred[cred.len - 2 ..]);
    return result.toOwnedSlice(allocator);
}

pub const ApiKeyProvider = enum { anthropic, openai, google, github, slack_bot, slack_app, brave, unknown };

pub fn detectApiKeyProvider(key: []const u8) ApiKeyProvider {
    if (std.mem.startsWith(u8, key, "sk-ant-")) return .anthropic;
    if (std.mem.startsWith(u8, key, "sk-")) return .openai;
    if (std.mem.startsWith(u8, key, "AIza")) return .google;
    if (std.mem.startsWith(u8, key, "ghp_")) return .github;
    if (std.mem.startsWith(u8, key, "xoxb-")) return .slack_bot;
    if (std.mem.startsWith(u8, key, "xapp-")) return .slack_app;
    if (std.mem.startsWith(u8, key, "BSA")) return .brave;
    return .unknown;
}

pub fn validateApiKeyFormat(key: []const u8) bool {
    if (key.len < 10) return false;
    for (key) |c| {
        if (c < 0x20 or c > 0x7E) return false;
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') return false;
    }
    return true;
}

pub fn isSecureFileMode(mode: u32) bool {
    return ((mode >> 3) & 0o7) == 0 and (mode & 0o7) == 0;
}

pub fn estimateEntropy(input: []const u8) f64 {
    if (input.len == 0) return 0;
    var freq = [_]u32{0} ** 256;
    for (input) |c| freq[c] += 1;
    var entropy: f64 = 0;
    const len_f: f64 = @floatFromInt(input.len);
    for (freq) |f| {
        if (f > 0) {
            const p: f64 = @as(f64, @floatFromInt(f)) / len_f;
            entropy -= p * @log2(p);
        }
    }
    return entropy;
}

pub fn hasMinimumEntropy(input: []const u8, min_bits: f64) bool {
    return estimateEntropy(input) >= min_bits;
}

pub fn isExpired(created_s: i64, now_s: i64, max_age_days: u32) bool {
    const max_s: i64 = @as(i64, @intCast(max_age_days)) * 86400;
    return now_s - created_s >= max_s;
}

pub fn daysUntilExpiry(created_s: i64, now_s: i64, max_age_days: u32) i64 {
    const max_s: i64 = @as(i64, @intCast(max_age_days)) * 86400;
    return @divTrunc(created_s + max_s - now_s, 86400);
}

// ── Tests ──

test "constantTimeEqual - equal" { try std.testing.expect(constantTimeEqual("hello", "hello")); }
test "constantTimeEqual - different" { try std.testing.expect(!constantTimeEqual("hello", "world")); }
test "constantTimeEqual - different lengths" { try std.testing.expect(!constantTimeEqual("short", "longer")); }
test "constantTimeEqual - empty" { try std.testing.expect(constantTimeEqual("", "")); }
test "constantTimeEqual - one empty" { try std.testing.expect(!constantTimeEqual("", "a")); }
test "constantTimeEqual - single byte diff" { try std.testing.expect(!constantTimeEqual("a", "b")); }
test "constantTimeEqual - same tokens" { try std.testing.expect(constantTimeEqual("sk-ant-abcdef12345", "sk-ant-abcdef12345")); }

test "validateCredentialStrength - strong" { try validateCredentialStrength("MyStr0ngP@ssw0rd!!", default_requirements); }
test "validateCredentialStrength - too short" { try std.testing.expectError(SecretError.CredentialTooShort, validateCredentialStrength("short", default_requirements)); }
test "validateCredentialStrength - too long" { try std.testing.expectError(SecretError.CredentialTooLong, validateCredentialStrength("a" ** 257, default_requirements)); }
test "validateCredentialStrength - no uppercase" { try std.testing.expectError(SecretError.NoUppercase, validateCredentialStrength("alllowercase12345678", default_requirements)); }
test "validateCredentialStrength - no lowercase" { try std.testing.expectError(SecretError.NoLowercase, validateCredentialStrength("ALLUPPERCASE12345678", default_requirements)); }
test "validateCredentialStrength - no digit" { try std.testing.expectError(SecretError.NoDigit, validateCredentialStrength("AllLettersNoDigitsHere", default_requirements)); }
test "validateCredentialStrength - common password" { try std.testing.expectError(SecretError.CommonPassword, validateCredentialStrength("password", .{ .min_length = 4, .require_uppercase = false, .require_digit = false })); }
test "validateCredentialStrength - exact min length" { try validateCredentialStrength("ExactLen16Chars!", .{ .min_length = 16 }); }
test "validateCredentialStrength - relaxed" { try validateCredentialStrength("anything", .{ .min_length = 4, .require_uppercase = false, .require_lowercase = false, .require_digit = false, .reject_common = false }); }

test "maskCredential - short" {
    const a = std.testing.allocator;
    const r = try maskCredential(a, "abc");
    defer a.free(r);
    try std.testing.expectEqualStrings("****", r);
}
test "maskCredential - medium" {
    const a = std.testing.allocator;
    const r = try maskCredential(a, "abcdef");
    defer a.free(r);
    try std.testing.expectEqual(@as(u8, 'a'), r[0]);
    try std.testing.expectEqual(@as(u8, 'f'), r[r.len - 1]);
}
test "maskCredential - long" {
    const a = std.testing.allocator;
    const r = try maskCredential(a, "sk-ant-abcdef123456");
    defer a.free(r);
    try std.testing.expectEqualStrings("sk****56", r);
}
test "maskCredential - empty" {
    const a = std.testing.allocator;
    const r = try maskCredential(a, "");
    defer a.free(r);
    try std.testing.expectEqualStrings("****", r);
}

test "detectApiKeyProvider - anthropic" { try std.testing.expectEqual(ApiKeyProvider.anthropic, detectApiKeyProvider("sk-ant-abc123")); }
test "detectApiKeyProvider - openai" { try std.testing.expectEqual(ApiKeyProvider.openai, detectApiKeyProvider("sk-abc123")); }
test "detectApiKeyProvider - google" { try std.testing.expectEqual(ApiKeyProvider.google, detectApiKeyProvider("AIzaSyAbc123")); }
test "detectApiKeyProvider - github" { try std.testing.expectEqual(ApiKeyProvider.github, detectApiKeyProvider("ghp_abc123")); }
test "detectApiKeyProvider - slack bot" { try std.testing.expectEqual(ApiKeyProvider.slack_bot, detectApiKeyProvider("xoxb-123-abc")); }
test "detectApiKeyProvider - unknown" { try std.testing.expectEqual(ApiKeyProvider.unknown, detectApiKeyProvider("some-random-key")); }

test "validateApiKeyFormat - valid" { try std.testing.expect(validateApiKeyFormat("sk-ant-abc123def456")); }
test "validateApiKeyFormat - too short" { try std.testing.expect(!validateApiKeyFormat("short")); }
test "validateApiKeyFormat - contains space" { try std.testing.expect(!validateApiKeyFormat("sk-ant-abc 123def456")); }
test "validateApiKeyFormat - contains newline" { try std.testing.expect(!validateApiKeyFormat("sk-ant-abc\n123def456")); }

test "isSecureFileMode - 0600" { try std.testing.expect(isSecureFileMode(0o600)); }
test "isSecureFileMode - 0400" { try std.testing.expect(isSecureFileMode(0o400)); }
test "isSecureFileMode - 0644 insecure" { try std.testing.expect(!isSecureFileMode(0o644)); }
test "isSecureFileMode - 0777 insecure" { try std.testing.expect(!isSecureFileMode(0o777)); }

test "estimateEntropy - empty" { try std.testing.expectEqual(@as(f64, 0), estimateEntropy("")); }
test "estimateEntropy - single char repeated" { try std.testing.expectEqual(@as(f64, 0), estimateEntropy("aaaa")); }
test "estimateEntropy - two chars" { try std.testing.expect(estimateEntropy("ab") > 0.9); }
test "estimateEntropy - random higher than repetitive" { try std.testing.expect(estimateEntropy("aB3$fG7!kL") > estimateEntropy("aaaaaaaaaa")); }
test "hasMinimumEntropy - high" { try std.testing.expect(hasMinimumEntropy("aB3$fG7!kL9#mN2@", 3.0)); }
test "hasMinimumEntropy - low" { try std.testing.expect(!hasMinimumEntropy("aaaaaaaaaa", 2.0)); }

test "isExpired - not expired" { try std.testing.expect(!isExpired(1000000, 1000000 + 86400, 90)); }
test "isExpired - expired" { try std.testing.expect(isExpired(1000000, 1000000 + 90 * 86400, 90)); }
test "daysUntilExpiry - 89 remaining" { try std.testing.expectEqual(@as(i64, 89), daysUntilExpiry(0, 86400, 90)); }
test "daysUntilExpiry - expired" { try std.testing.expect(daysUntilExpiry(0, 91 * 86400, 90) < 0); }
test "daysUntilExpiry - exact" { try std.testing.expectEqual(@as(i64, 0), daysUntilExpiry(0, 90 * 86400, 90)); }
