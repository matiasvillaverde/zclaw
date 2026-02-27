const std = @import("std");

/// Input validation and sanitization module.
/// Null byte rejection, control character stripping,
/// Unicode normalization, string length enforcement, and JSON escaping.

pub const ValidationError = error{
    ContainsNullByte,
    ContainsControlChars,
    ExceedsMaxLength,
    EmptyInput,
    InvalidUtf8,
    InvalidJsonString,
    MalformedEscape,
};

pub const Severity = enum { reject, strip, warn };

pub const ValidationOptions = struct {
    max_length: usize = 65536,
    allow_newlines: bool = true,
    allow_tabs: bool = true,
    null_byte_action: Severity = .reject,
    control_char_action: Severity = .strip,
    require_utf8: bool = true,
    trim_whitespace: bool = false,
};

const default_options = ValidationOptions{};

// ── Null byte detection ──

pub fn containsNullByte(input: []const u8) bool {
    for (input) |c| {
        if (c == 0) return true;
    }
    return false;
}

pub fn rejectNullBytes(input: []const u8) ValidationError!void {
    if (containsNullByte(input)) return ValidationError.ContainsNullByte;
}

// ── Control character detection & stripping ──

pub fn isControlChar(c: u8) bool {
    if (c < 0x20) return c != '\t' and c != '\n' and c != '\r';
    if (c == 0x7F) return true;
    if (c >= 0x80 and c <= 0x9F) return true;
    return false;
}

pub fn isControlCharStrict(c: u8) bool {
    if (c < 0x20 and c != '\t' and c != '\n' and c != '\r') return true;
    if (c == 0x7F) return true;
    return false;
}

pub fn containsControlChars(input: []const u8) bool {
    for (input) |c| {
        if (isControlChar(c)) return true;
    }
    return false;
}

pub fn stripControlChars(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = try std.ArrayListUnmanaged(u8).initCapacity(allocator, input.len);
    errdefer result.deinit(allocator);
    for (input) |c| {
        if (!isControlChar(c)) try result.append(allocator, c);
    }
    return result.toOwnedSlice(allocator);
}

pub fn stripControlCharsAllowNewlines(allocator: std.mem.Allocator, input: []const u8, opts: ValidationOptions) ![]u8 {
    var result = try std.ArrayListUnmanaged(u8).initCapacity(allocator, input.len);
    errdefer result.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c == '\r') {
            // CRLF → single LF, bare CR → LF (when newlines allowed)
            if (i + 1 < input.len and input[i + 1] == '\n') i += 1; // skip the \n, we output one \n
            if (opts.allow_newlines) try result.append(allocator, '\n');
            continue;
        }
        if (c == '\n') {
            if (opts.allow_newlines) try result.append(allocator, c);
            continue;
        }
        if (c == '\t') {
            if (opts.allow_tabs) try result.append(allocator, c);
            continue;
        }
        if (!isControlCharStrict(c)) {
            try result.append(allocator, c);
        }
    }
    return result.toOwnedSlice(allocator);
}

// ── UTF-8 validation ──

pub fn isValidUtf8(input: []const u8) bool {
    var i: usize = 0;
    while (i < input.len) {
        const byte = input[i];
        const len = utf8ByteLength(byte) catch return false;
        if (i + len > input.len) return false;
        for (1..len) |j| {
            if (input[i + j] & 0xC0 != 0x80) return false;
        }
        if (len == 2 and byte < 0xC2) return false;
        if (len == 3) {
            const cp = (@as(u32, byte & 0x0F) << 12) | (@as(u32, input[i + 1] & 0x3F) << 6) | @as(u32, input[i + 2] & 0x3F);
            if (cp < 0x800) return false;
            if (cp >= 0xD800 and cp <= 0xDFFF) return false;
        }
        if (len == 4) {
            const cp = (@as(u32, byte & 0x07) << 18) | (@as(u32, input[i + 1] & 0x3F) << 12) | (@as(u32, input[i + 2] & 0x3F) << 6) | @as(u32, input[i + 3] & 0x3F);
            if (cp < 0x10000 or cp > 0x10FFFF) return false;
        }
        i += len;
    }
    return true;
}

fn utf8ByteLength(first: u8) !u3 {
    if (first < 0x80) return 1;
    if (first >= 0xC0 and first < 0xE0) return 2;
    if (first >= 0xE0 and first < 0xF0) return 3;
    if (first >= 0xF0 and first < 0xF8) return 4;
    return error.InvalidUtf8;
}

// ── Unicode NFC normalization (basic) ──

pub fn normalizeUnicode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = try std.ArrayListUnmanaged(u8).initCapacity(allocator, input.len);
    errdefer result.deinit(allocator);
    var i: usize = 0;
    if (input.len >= 3 and input[0] == 0xEF and input[1] == 0xBB and input[2] == 0xBF) i = 3;
    while (i < input.len) {
        if (i + 1 < input.len and input[i] == '\r' and input[i + 1] == '\n') {
            try result.append(allocator, '\n');
            i += 2;
            continue;
        }
        if (input[i] == '\r') {
            try result.append(allocator, '\n');
            i += 1;
            continue;
        }
        // Strip zero-width chars (U+200B/C/D)
        if (i + 2 < input.len and input[i] == 0xE2 and input[i + 1] == 0x80 and (input[i + 2] >= 0x8B and input[i + 2] <= 0x8D)) {
            i += 3;
            continue;
        }
        // Strip mid-string BOM
        if (i + 2 < input.len and input[i] == 0xEF and input[i + 1] == 0xBB and input[i + 2] == 0xBF) {
            i += 3;
            continue;
        }
        try result.append(allocator, input[i]);
        i += 1;
    }
    return result.toOwnedSlice(allocator);
}

// ── JSON string escaping ──

pub fn jsonEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = try std.ArrayListUnmanaged(u8).initCapacity(allocator, input.len + 16);
    errdefer result.deinit(allocator);
    for (input) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            0x08 => try result.appendSlice(allocator, "\\b"),
            0x0C => try result.appendSlice(allocator, "\\f"),
            else => {
                if (c < 0x20) {
                    try result.appendSlice(allocator, "\\u00");
                    try result.append(allocator, hexDigit(c >> 4));
                    try result.append(allocator, hexDigit(c & 0x0F));
                } else {
                    try result.append(allocator, c);
                }
            },
        }
    }
    return result.toOwnedSlice(allocator);
}

fn hexDigit(v: u8) u8 {
    return if (v < 10) '0' + v else 'a' + v - 10;
}

pub fn jsonUnescape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = try std.ArrayListUnmanaged(u8).initCapacity(allocator, input.len);
    errdefer result.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            switch (input[i + 1]) {
                '"' => { try result.append(allocator, '"'); i += 2; },
                '\\' => { try result.append(allocator, '\\'); i += 2; },
                'n' => { try result.append(allocator, '\n'); i += 2; },
                'r' => { try result.append(allocator, '\r'); i += 2; },
                't' => { try result.append(allocator, '\t'); i += 2; },
                'b' => { try result.append(allocator, 0x08); i += 2; },
                'f' => { try result.append(allocator, 0x0C); i += 2; },
                '/' => { try result.append(allocator, '/'); i += 2; },
                'u' => {
                    if (i + 5 < input.len) {
                        const hex = input[i + 2 .. i + 6];
                        const cp = std.fmt.parseInt(u16, hex, 16) catch return ValidationError.MalformedEscape;
                        if (cp < 0x80) {
                            try result.append(allocator, @intCast(cp));
                        } else if (cp < 0x800) {
                            try result.append(allocator, @intCast(0xC0 | (cp >> 6)));
                            try result.append(allocator, @intCast(0x80 | (cp & 0x3F)));
                        } else {
                            try result.append(allocator, @intCast(0xE0 | (cp >> 12)));
                            try result.append(allocator, @intCast(0x80 | ((cp >> 6) & 0x3F)));
                            try result.append(allocator, @intCast(0x80 | (cp & 0x3F)));
                        }
                        i += 6;
                    } else return ValidationError.MalformedEscape;
                },
                else => { try result.append(allocator, input[i]); i += 1; },
            }
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice(allocator);
}

// ── Length validation ──

pub fn validateLength(input: []const u8, max: usize) ValidationError!void {
    if (input.len > max) return ValidationError.ExceedsMaxLength;
}

pub fn validateNonEmpty(input: []const u8) ValidationError!void {
    if (input.len == 0) return ValidationError.EmptyInput;
}

// ── Combined validation pipeline ──

pub fn validateInput(input: []const u8, opts: ValidationOptions) ValidationError!void {
    if (input.len > opts.max_length) return ValidationError.ExceedsMaxLength;
    if (opts.null_byte_action == .reject) try rejectNullBytes(input);
    if (opts.control_char_action == .reject) {
        if (containsControlChars(input)) return ValidationError.ContainsControlChars;
    }
    if (opts.require_utf8) {
        if (!isValidUtf8(input)) return ValidationError.InvalidUtf8;
    }
}

/// Full sanitization pipeline: validate, strip, normalize. Returns owned slice.
pub fn sanitizeInput(allocator: std.mem.Allocator, input: []const u8, opts: ValidationOptions) ![]u8 {
    const bounded = if (input.len > opts.max_length) input[0..opts.max_length] else input;
    var stage1: []u8 = undefined;
    var owns_stage1 = false;
    if (opts.null_byte_action == .reject) {
        try rejectNullBytes(bounded);
        stage1 = @constCast(bounded);
    } else if (opts.null_byte_action == .strip) {
        stage1 = try stripBytes(allocator, bounded, 0);
        owns_stage1 = true;
    } else {
        stage1 = @constCast(bounded);
    }
    defer if (owns_stage1) allocator.free(stage1);
    const stage2 = try stripControlCharsAllowNewlines(allocator, stage1, opts);
    defer allocator.free(stage2);
    const stage3 = try normalizeUnicode(allocator, stage2);
    if (opts.trim_whitespace) {
        const trimmed = std.mem.trim(u8, stage3, " \t\n\r");
        if (trimmed.len != stage3.len) {
            const final = try allocator.dupe(u8, trimmed);
            allocator.free(stage3);
            return final;
        }
    }
    return stage3;
}

fn stripBytes(allocator: std.mem.Allocator, input: []const u8, byte: u8) ![]u8 {
    var result = try std.ArrayListUnmanaged(u8).initCapacity(allocator, input.len);
    errdefer result.deinit(allocator);
    for (input) |c| {
        if (c != byte) try result.append(allocator, c);
    }
    return result.toOwnedSlice(allocator);
}

// ── URL scheme validation ──

pub fn isAllowedUrlScheme(url: []const u8) bool {
    var buf: [8]u8 = .{0} ** 8;
    const len = @min(url.len, 8);
    for (0..len) |i| buf[i] = std.ascii.toLower(url[i]);
    return std.mem.startsWith(u8, &buf, "http://") or std.mem.startsWith(u8, &buf, "https://");
}

// ── Constant-time comparison ──

pub fn constantTimeEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |ac, bc| diff |= ac ^ bc;
    return diff == 0;
}

// ── Tests ──

test "containsNullByte - detects null in middle" { try std.testing.expect(containsNullByte("hello\x00world")); }
test "containsNullByte - detects null at start" { try std.testing.expect(containsNullByte("\x00hello")); }
test "containsNullByte - detects null at end" { try std.testing.expect(containsNullByte("hello\x00")); }
test "containsNullByte - clean string" { try std.testing.expect(!containsNullByte("hello world")); }
test "containsNullByte - empty string" { try std.testing.expect(!containsNullByte("")); }
test "rejectNullBytes - rejects" { try std.testing.expectError(ValidationError.ContainsNullByte, rejectNullBytes("ab\x00c")); }
test "rejectNullBytes - accepts clean" { try rejectNullBytes("clean string"); }
test "isControlChar - NUL" { try std.testing.expect(isControlChar(0x00)); }
test "isControlChar - SOH" { try std.testing.expect(isControlChar(0x01)); }
test "isControlChar - BEL" { try std.testing.expect(isControlChar(0x07)); }
test "isControlChar - tab allowed" { try std.testing.expect(!isControlChar('\t')); }
test "isControlChar - newline allowed" { try std.testing.expect(!isControlChar('\n')); }
test "isControlChar - CR allowed" { try std.testing.expect(!isControlChar('\r')); }
test "isControlChar - DEL" { try std.testing.expect(isControlChar(0x7F)); }
test "isControlChar - C1 range 0x80" { try std.testing.expect(isControlChar(0x80)); }
test "isControlChar - C1 range 0x9F" { try std.testing.expect(isControlChar(0x9F)); }
test "isControlChar - space not control" { try std.testing.expect(!isControlChar(' ')); }
test "isControlChar - printable A" { try std.testing.expect(!isControlChar('A')); }
test "isControlChar - tilde" { try std.testing.expect(!isControlChar('~')); }
test "containsControlChars - finds BEL" { try std.testing.expect(containsControlChars("hello\x07world")); }
test "containsControlChars - clean with newlines" { try std.testing.expect(!containsControlChars("hello\nworld\ttab")); }
test "containsControlChars - empty" { try std.testing.expect(!containsControlChars("")); }

test "stripControlChars - removes BEL and NUL" {
    const a = std.testing.allocator;
    const r = try stripControlChars(a, "he\x00ll\x07o");
    defer a.free(r);
    try std.testing.expectEqualStrings("hello", r);
}
test "stripControlChars - preserves tabs and newlines" {
    const a = std.testing.allocator;
    const r = try stripControlChars(a, "hello\tworld\n");
    defer a.free(r);
    try std.testing.expectEqualStrings("hello\tworld\n", r);
}
test "stripControlChars - removes DEL" {
    const a = std.testing.allocator;
    const r = try stripControlChars(a, "abc\x7Fdef");
    defer a.free(r);
    try std.testing.expectEqualStrings("abcdef", r);
}
test "stripControlChars - empty input" {
    const a = std.testing.allocator;
    const r = try stripControlChars(a, "");
    defer a.free(r);
    try std.testing.expectEqualStrings("", r);
}
test "stripControlCharsAllowNewlines - strips CR" {
    const a = std.testing.allocator;
    const r = try stripControlCharsAllowNewlines(a, "hello\r\nworld\rend", .{});
    defer a.free(r);
    try std.testing.expectEqualStrings("hello\nworld\nend", r);
}
test "stripControlCharsAllowNewlines - no newlines mode" {
    const a = std.testing.allocator;
    const r = try stripControlCharsAllowNewlines(a, "hello\nworld", .{ .allow_newlines = false });
    defer a.free(r);
    try std.testing.expectEqualStrings("helloworld", r);
}
test "stripControlCharsAllowNewlines - no tabs mode" {
    const a = std.testing.allocator;
    const r = try stripControlCharsAllowNewlines(a, "hello\tworld", .{ .allow_tabs = false });
    defer a.free(r);
    try std.testing.expectEqualStrings("helloworld", r);
}

test "isValidUtf8 - ASCII" { try std.testing.expect(isValidUtf8("hello world")); }
test "isValidUtf8 - empty" { try std.testing.expect(isValidUtf8("")); }
test "isValidUtf8 - two-byte" { try std.testing.expect(isValidUtf8("caf\xC3\xA9")); }
test "isValidUtf8 - three-byte CJK" { try std.testing.expect(isValidUtf8("\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e")); }
test "isValidUtf8 - four-byte emoji" { try std.testing.expect(isValidUtf8("\xf0\x9f\x8e\x89")); }
test "isValidUtf8 - invalid continuation" { try std.testing.expect(!isValidUtf8(&[_]u8{ 0xC0, 0x00 })); }
test "isValidUtf8 - truncated sequence" { try std.testing.expect(!isValidUtf8(&[_]u8{0xE0})); }
test "isValidUtf8 - overlong 2-byte" { try std.testing.expect(!isValidUtf8(&[_]u8{ 0xC0, 0xAF })); }
test "isValidUtf8 - surrogate pair rejected" { try std.testing.expect(!isValidUtf8(&[_]u8{ 0xED, 0xA0, 0x80 })); }
test "isValidUtf8 - max valid codepoint" { try std.testing.expect(isValidUtf8(&[_]u8{ 0xF4, 0x8F, 0xBF, 0xBF })); }
test "isValidUtf8 - beyond U+10FFFF" { try std.testing.expect(!isValidUtf8(&[_]u8{ 0xF4, 0x90, 0x80, 0x80 })); }

test "normalizeUnicode - CRLF to LF" {
    const a = std.testing.allocator;
    const r = try normalizeUnicode(a, "hello\r\nworld");
    defer a.free(r);
    try std.testing.expectEqualStrings("hello\nworld", r);
}
test "normalizeUnicode - bare CR to LF" {
    const a = std.testing.allocator;
    const r = try normalizeUnicode(a, "hello\rworld");
    defer a.free(r);
    try std.testing.expectEqualStrings("hello\nworld", r);
}
test "normalizeUnicode - strips BOM at start" {
    const a = std.testing.allocator;
    const r = try normalizeUnicode(a, "\xEF\xBB\xBFhello");
    defer a.free(r);
    try std.testing.expectEqualStrings("hello", r);
}
test "normalizeUnicode - strips zero-width space" {
    const a = std.testing.allocator;
    const r = try normalizeUnicode(a, "hello\xE2\x80\x8Bworld");
    defer a.free(r);
    try std.testing.expectEqualStrings("helloworld", r);
}
test "normalizeUnicode - strips ZWNJ" {
    const a = std.testing.allocator;
    const r = try normalizeUnicode(a, "a\xE2\x80\x8Cb");
    defer a.free(r);
    try std.testing.expectEqualStrings("ab", r);
}
test "normalizeUnicode - strips ZWJ" {
    const a = std.testing.allocator;
    const r = try normalizeUnicode(a, "a\xE2\x80\x8Db");
    defer a.free(r);
    try std.testing.expectEqualStrings("ab", r);
}
test "normalizeUnicode - empty" {
    const a = std.testing.allocator;
    const r = try normalizeUnicode(a, "");
    defer a.free(r);
    try std.testing.expectEqualStrings("", r);
}
test "normalizeUnicode - multiple CRLFs" {
    const a = std.testing.allocator;
    const r = try normalizeUnicode(a, "a\r\nb\r\nc\r\n");
    defer a.free(r);
    try std.testing.expectEqualStrings("a\nb\nc\n", r);
}

test "jsonEscape - quotes" {
    const a = std.testing.allocator;
    const r = try jsonEscape(a, "say \"hello\"");
    defer a.free(r);
    try std.testing.expectEqualStrings("say \\\"hello\\\"", r);
}
test "jsonEscape - backslash" {
    const a = std.testing.allocator;
    const r = try jsonEscape(a, "path\\to\\file");
    defer a.free(r);
    try std.testing.expectEqualStrings("path\\\\to\\\\file", r);
}
test "jsonEscape - newline" {
    const a = std.testing.allocator;
    const r = try jsonEscape(a, "line1\nline2");
    defer a.free(r);
    try std.testing.expectEqualStrings("line1\\nline2", r);
}
test "jsonEscape - tab" {
    const a = std.testing.allocator;
    const r = try jsonEscape(a, "col1\tcol2");
    defer a.free(r);
    try std.testing.expectEqualStrings("col1\\tcol2", r);
}
test "jsonEscape - backspace" {
    const a = std.testing.allocator;
    const r = try jsonEscape(a, "a\x08b");
    defer a.free(r);
    try std.testing.expectEqualStrings("a\\bb", r);
}
test "jsonEscape - form feed" {
    const a = std.testing.allocator;
    const r = try jsonEscape(a, "a\x0Cb");
    defer a.free(r);
    try std.testing.expectEqualStrings("a\\fb", r);
}
test "jsonEscape - low control char as unicode escape" {
    const a = std.testing.allocator;
    const r = try jsonEscape(a, "a\x01b");
    defer a.free(r);
    try std.testing.expectEqualStrings("a\\u0001b", r);
}
test "jsonEscape - NUL as unicode escape" {
    const a = std.testing.allocator;
    const r = try jsonEscape(a, &[_]u8{ 'a', 0, 'b' });
    defer a.free(r);
    try std.testing.expectEqualStrings("a\\u0000b", r);
}
test "jsonEscape - safe string unchanged" {
    const a = std.testing.allocator;
    const r = try jsonEscape(a, "hello world");
    defer a.free(r);
    try std.testing.expectEqualStrings("hello world", r);
}
test "jsonEscape - empty" {
    const a = std.testing.allocator;
    const r = try jsonEscape(a, "");
    defer a.free(r);
    try std.testing.expectEqualStrings("", r);
}

test "jsonUnescape - quotes" {
    const a = std.testing.allocator;
    const r = try jsonUnescape(a, "say \\\"hello\\\"");
    defer a.free(r);
    try std.testing.expectEqualStrings("say \"hello\"", r);
}
test "jsonUnescape - backslash" {
    const a = std.testing.allocator;
    const r = try jsonUnescape(a, "path\\\\file");
    defer a.free(r);
    try std.testing.expectEqualStrings("path\\file", r);
}
test "jsonUnescape - unicode A" {
    const a = std.testing.allocator;
    const r = try jsonUnescape(a, "\\u0041");
    defer a.free(r);
    try std.testing.expectEqualStrings("A", r);
}
test "jsonUnescape - unicode non-ASCII" {
    const a = std.testing.allocator;
    const r = try jsonUnescape(a, "\\u00E9");
    defer a.free(r);
    try std.testing.expectEqualStrings("\xC3\xA9", r);
}
test "jsonUnescape - forward slash" {
    const a = std.testing.allocator;
    const r = try jsonUnescape(a, "a\\/b");
    defer a.free(r);
    try std.testing.expectEqualStrings("a/b", r);
}
test "jsonUnescape - malformed unicode" {
    try std.testing.expectError(ValidationError.MalformedEscape, jsonUnescape(std.testing.allocator, "\\u00"));
}
test "jsonEscape then jsonUnescape roundtrip" {
    const a = std.testing.allocator;
    const original = "hello \"world\" \\ \n \t \x01";
    const escaped = try jsonEscape(a, original);
    defer a.free(escaped);
    const unescaped = try jsonUnescape(a, escaped);
    defer a.free(unescaped);
    try std.testing.expectEqualStrings(original, unescaped);
}
test "jsonUnescape - CJK unicode" {
    const a = std.testing.allocator;
    const r = try jsonUnescape(a, "\\u4F60\\u597D");
    defer a.free(r);
    try std.testing.expectEqualStrings("\xe4\xbd\xa0\xe5\xa5\xbd", r);
}

test "validateLength - within limit" { try validateLength("hello", 10); }
test "validateLength - at limit" { try validateLength("hello", 5); }
test "validateLength - exceeds" { try std.testing.expectError(ValidationError.ExceedsMaxLength, validateLength("hello world", 5)); }
test "validateNonEmpty - non-empty" { try validateNonEmpty("x"); }
test "validateNonEmpty - empty" { try std.testing.expectError(ValidationError.EmptyInput, validateNonEmpty("")); }
test "validateInput - clean input" { try validateInput("hello world", default_options); }
test "validateInput - rejects null" { try std.testing.expectError(ValidationError.ContainsNullByte, validateInput("he\x00llo", default_options)); }
test "validateInput - rejects too long" { try std.testing.expectError(ValidationError.ExceedsMaxLength, validateInput("toolong", .{ .max_length = 5 })); }
test "validateInput - rejects invalid UTF-8" { try std.testing.expectError(ValidationError.InvalidUtf8, validateInput(&[_]u8{ 0xC0, 0xAF }, default_options)); }
test "validateInput - allows emoji" { try validateInput("Hello \xf0\x9f\x8c\x8d", default_options); }

test "sanitizeInput - strips null and control" {
    const a = std.testing.allocator;
    const r = try sanitizeInput(a, "he\x00ll\x07o\r\nworld", .{ .null_byte_action = .strip });
    defer a.free(r);
    try std.testing.expectEqualStrings("hello\nworld", r);
}
test "sanitizeInput - enforces max length" {
    const a = std.testing.allocator;
    const r = try sanitizeInput(a, "hello world", .{ .max_length = 5, .null_byte_action = .strip });
    defer a.free(r);
    try std.testing.expect(r.len <= 5);
}
test "sanitizeInput - trims whitespace" {
    const a = std.testing.allocator;
    const r = try sanitizeInput(a, "  hello  ", .{ .trim_whitespace = true });
    defer a.free(r);
    try std.testing.expectEqualStrings("hello", r);
}
test "sanitizeInput - rejects null in reject mode" {
    try std.testing.expectError(ValidationError.ContainsNullByte, sanitizeInput(std.testing.allocator, "he\x00llo", default_options));
}

test "isAllowedUrlScheme - http" { try std.testing.expect(isAllowedUrlScheme("http://example.com")); }
test "isAllowedUrlScheme - https" { try std.testing.expect(isAllowedUrlScheme("https://example.com")); }
test "isAllowedUrlScheme - HTTP uppercase" { try std.testing.expect(isAllowedUrlScheme("HTTP://example.com")); }
test "isAllowedUrlScheme - ftp rejected" { try std.testing.expect(!isAllowedUrlScheme("ftp://example.com")); }
test "isAllowedUrlScheme - file rejected" { try std.testing.expect(!isAllowedUrlScheme("file:///etc/passwd")); }
test "isAllowedUrlScheme - javascript rejected" { try std.testing.expect(!isAllowedUrlScheme("javascript:alert(1)")); }
test "isAllowedUrlScheme - data rejected" { try std.testing.expect(!isAllowedUrlScheme("data:text/html,<h1>hi</h1>")); }
test "isAllowedUrlScheme - empty rejected" { try std.testing.expect(!isAllowedUrlScheme("")); }

test "constantTimeEqual - equal" { try std.testing.expect(constantTimeEqual("hello", "hello")); }
test "constantTimeEqual - not equal" { try std.testing.expect(!constantTimeEqual("hello", "world")); }
test "constantTimeEqual - different lengths" { try std.testing.expect(!constantTimeEqual("short", "longer")); }
test "constantTimeEqual - empty" { try std.testing.expect(constantTimeEqual("", "")); }
test "constantTimeEqual - single byte diff" { try std.testing.expect(!constantTimeEqual("a", "b")); }

test "utf8ByteLength - ASCII" { try std.testing.expectEqual(@as(u3, 1), try utf8ByteLength('A')); }
test "utf8ByteLength - two-byte" { try std.testing.expectEqual(@as(u3, 2), try utf8ByteLength(0xC2)); }
test "utf8ByteLength - three-byte" { try std.testing.expectEqual(@as(u3, 3), try utf8ByteLength(0xE0)); }
test "utf8ByteLength - four-byte" { try std.testing.expectEqual(@as(u3, 4), try utf8ByteLength(0xF0)); }
test "utf8ByteLength - invalid" { try std.testing.expectError(error.InvalidUtf8, utf8ByteLength(0xFF)); }
test "hexDigit - 0" { try std.testing.expectEqual(@as(u8, '0'), hexDigit(0)); }
test "hexDigit - 9" { try std.testing.expectEqual(@as(u8, '9'), hexDigit(9)); }
test "hexDigit - a" { try std.testing.expectEqual(@as(u8, 'a'), hexDigit(10)); }
test "hexDigit - f" { try std.testing.expectEqual(@as(u8, 'f'), hexDigit(15)); }
test "isControlCharStrict - allows high bytes" {
    try std.testing.expect(!isControlCharStrict(0xA0));
    try std.testing.expect(!isControlCharStrict(0xFF));
}
