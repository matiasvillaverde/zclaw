const std = @import("std");

// --- Markdown Processing ---
//
// Per-channel markdown rendering and stripping.

pub const RenderTarget = enum {
    telegram,
    discord,
    slack,
    plain,

    pub fn label(self: RenderTarget) []const u8 {
        return switch (self) {
            .telegram => "telegram",
            .discord => "discord",
            .slack => "slack",
            .plain => "plain",
        };
    }
};

/// Check if text contains any markdown formatting.
pub fn hasFormatting(text: []const u8) bool {
    for (text) |c| {
        switch (c) {
            '*', '_', '`', '#', '[', '>' => return true,
            else => {},
        }
    }
    return false;
}

/// Detect code fences in text. Returns true if the text contains ```.
pub fn detectCodeFences(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "```") != null;
}

/// Strip all markdown formatting, returning plain text.
pub fn stripMarkdown(input: []const u8, output: []u8) []const u8 {
    var fbs = std.io.fixedBufferStream(output);
    const writer = fbs.writer();
    var i: usize = 0;

    while (i < input.len) {
        const c = input[i];
        switch (c) {
            // Skip heading markers (# at start of line)
            '#' => {
                if (i == 0 or (i > 0 and input[i - 1] == '\n')) {
                    while (i < input.len and input[i] == '#') : (i += 1) {}
                    if (i < input.len and input[i] == ' ') i += 1;
                    continue;
                }
                writer.writeByte(c) catch break;
                i += 1;
            },
            // Skip bold/italic markers
            '*' => {
                i += 1;
                if (i < input.len and input[i] == '*') i += 1; // **bold**
            },
            '_' => {
                i += 1;
                if (i < input.len and input[i] == '_') i += 1; // __bold__
            },
            // Skip inline code backticks
            '`' => {
                if (i + 2 < input.len and input[i + 1] == '`' and input[i + 2] == '`') {
                    i += 3;
                    // Skip language identifier on the same line
                    while (i < input.len and input[i] != '\n') : (i += 1) {}
                    if (i < input.len) i += 1; // skip newline
                } else {
                    i += 1;
                }
            },
            // Skip link syntax [text](url) — keep text
            '[' => {
                i += 1;
                // Output the link text
                while (i < input.len and input[i] != ']') : (i += 1) {
                    writer.writeByte(input[i]) catch break;
                }
                if (i < input.len) i += 1; // skip ]
                // Skip (url)
                if (i < input.len and input[i] == '(') {
                    i += 1;
                    while (i < input.len and input[i] != ')') : (i += 1) {}
                    if (i < input.len) i += 1; // skip )
                }
            },
            // Skip blockquote markers
            '>' => {
                if (i == 0 or (i > 0 and input[i - 1] == '\n')) {
                    i += 1;
                    if (i < input.len and input[i] == ' ') i += 1;
                    continue;
                }
                writer.writeByte(c) catch break;
                i += 1;
            },
            else => {
                writer.writeByte(c) catch break;
                i += 1;
            },
        }
    }

    return fbs.getWritten();
}

/// Escape special characters for Telegram's MarkdownV2.
pub fn escapeForTelegram(input: []const u8, output: []u8) []const u8 {
    var fbs = std.io.fixedBufferStream(output);
    const writer = fbs.writer();

    for (input) |c| {
        switch (c) {
            '_', '*', '[', ']', '(', ')', '~', '>', '#', '+', '-', '=', '|', '{', '}', '.', '!' => {
                writer.writeByte('\\') catch break;
                writer.writeByte(c) catch break;
            },
            else => writer.writeByte(c) catch break,
        }
    }

    return fbs.getWritten();
}

/// Render markdown for a specific target.
pub fn render(input: []const u8, output: []u8, target: RenderTarget) []const u8 {
    return switch (target) {
        .plain => stripMarkdown(input, output),
        .telegram => escapeForTelegram(input, output),
        .discord => blk: {
            // Discord supports markdown natively, pass through
            const len = @min(input.len, output.len);
            @memcpy(output[0..len], input[0..len]);
            break :blk output[0..len];
        },
        .slack => blk: {
            // Slack uses mrkdwn, pass through (mostly compatible)
            const len = @min(input.len, output.len);
            @memcpy(output[0..len], input[0..len]);
            break :blk output[0..len];
        },
    };
}

// --- Tests ---

test "hasFormatting detects markdown" {
    try std.testing.expect(hasFormatting("**bold**"));
    try std.testing.expect(hasFormatting("_italic_"));
    try std.testing.expect(hasFormatting("`code`"));
    try std.testing.expect(hasFormatting("# heading"));
    try std.testing.expect(hasFormatting("[link](url)"));
    try std.testing.expect(hasFormatting("> quote"));
}

test "hasFormatting plain text" {
    try std.testing.expect(!hasFormatting("hello world"));
    try std.testing.expect(!hasFormatting("no formatting here"));
    try std.testing.expect(!hasFormatting(""));
}

test "detectCodeFences" {
    try std.testing.expect(detectCodeFences("```\ncode\n```"));
    try std.testing.expect(detectCodeFences("text ```code``` text"));
    try std.testing.expect(!detectCodeFences("no fences here"));
    try std.testing.expect(!detectCodeFences("single ` backtick"));
}

test "stripMarkdown bold" {
    var buf: [1024]u8 = undefined;
    const result = stripMarkdown("hello **world**", &buf);
    try std.testing.expectEqualStrings("hello world", result);
}

test "stripMarkdown headings" {
    var buf: [1024]u8 = undefined;
    const result = stripMarkdown("# Heading\ntext", &buf);
    try std.testing.expectEqualStrings("Heading\ntext", result);
}

test "stripMarkdown links" {
    var buf: [1024]u8 = undefined;
    const result = stripMarkdown("[click here](https://example.com)", &buf);
    try std.testing.expectEqualStrings("click here", result);
}

test "stripMarkdown code fences" {
    var buf: [1024]u8 = undefined;
    const result = stripMarkdown("```python\nprint('hi')\n```", &buf);
    try std.testing.expectEqualStrings("print('hi')\n", result);
}

test "stripMarkdown blockquote" {
    var buf: [1024]u8 = undefined;
    const result = stripMarkdown("> quoted text", &buf);
    try std.testing.expectEqualStrings("quoted text", result);
}

test "stripMarkdown plain text passthrough" {
    var buf: [1024]u8 = undefined;
    const result = stripMarkdown("plain text", &buf);
    try std.testing.expectEqualStrings("plain text", result);
}

test "escapeForTelegram" {
    var buf: [1024]u8 = undefined;
    const result = escapeForTelegram("hello_world", &buf);
    try std.testing.expectEqualStrings("hello\\_world", result);
}

test "escapeForTelegram special chars" {
    var buf: [1024]u8 = undefined;
    const result = escapeForTelegram("a*b[c]d", &buf);
    try std.testing.expectEqualStrings("a\\*b\\[c\\]d", result);
}

test "render plain" {
    var buf: [1024]u8 = undefined;
    const result = render("**bold** text", &buf, .plain);
    try std.testing.expectEqualStrings("bold text", result);
}

test "render discord passthrough" {
    var buf: [1024]u8 = undefined;
    const result = render("**bold** text", &buf, .discord);
    try std.testing.expectEqualStrings("**bold** text", result);
}

test "RenderTarget labels" {
    try std.testing.expectEqualStrings("telegram", RenderTarget.telegram.label());
    try std.testing.expectEqualStrings("discord", RenderTarget.discord.label());
    try std.testing.expectEqualStrings("slack", RenderTarget.slack.label());
    try std.testing.expectEqualStrings("plain", RenderTarget.plain.label());
}
