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

// --- Additional Tests ---

test "stripMarkdown italic underscores" {
    var buf: [1024]u8 = undefined;
    const result = stripMarkdown("_italic_ text", &buf);
    try std.testing.expectEqualStrings("italic text", result);
}

test "stripMarkdown double underscores" {
    var buf: [1024]u8 = undefined;
    const result = stripMarkdown("__bold__ text", &buf);
    try std.testing.expectEqualStrings("bold text", result);
}

test "stripMarkdown empty" {
    var buf: [1024]u8 = undefined;
    const result = stripMarkdown("", &buf);
    try std.testing.expectEqualStrings("", result);
}

test "stripMarkdown multiple headings" {
    var buf: [1024]u8 = undefined;
    const result = stripMarkdown("## Second\n### Third", &buf);
    try std.testing.expect(std.mem.indexOf(u8, result, "Second") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Third") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "#") == null);
}

test "stripMarkdown inline code" {
    var buf: [1024]u8 = undefined;
    const result = stripMarkdown("use `code` here", &buf);
    try std.testing.expectEqualStrings("use code here", result);
}

test "stripMarkdown blockquote mid-text" {
    var buf: [1024]u8 = undefined;
    // > at beginning of text
    const result = stripMarkdown("> quoted line", &buf);
    try std.testing.expectEqualStrings("quoted line", result);
}

test "escapeForTelegram plain text unchanged" {
    var buf: [1024]u8 = undefined;
    const result = escapeForTelegram("hello world", &buf);
    try std.testing.expectEqualStrings("hello world", result);
}

test "escapeForTelegram all special chars" {
    var buf: [1024]u8 = undefined;
    const result = escapeForTelegram("~>#+=-|{}.!", &buf);
    try std.testing.expectEqualStrings("\\~\\>\\#\\+\\=\\-\\|\\{\\}\\.\\!", result);
}

test "escapeForTelegram parentheses" {
    var buf: [1024]u8 = undefined;
    const result = escapeForTelegram("(test)", &buf);
    try std.testing.expectEqualStrings("\\(test\\)", result);
}

test "render telegram escapes" {
    var buf: [1024]u8 = undefined;
    const result = render("hello_world", &buf, .telegram);
    try std.testing.expectEqualStrings("hello\\_world", result);
}

test "render slack passthrough" {
    var buf: [1024]u8 = undefined;
    const result = render("**bold** text", &buf, .slack);
    try std.testing.expectEqualStrings("**bold** text", result);
}

test "hasFormatting with numbers and punctuation" {
    try std.testing.expect(!hasFormatting("12345"));
    try std.testing.expect(!hasFormatting("hello, world!"));
    try std.testing.expect(!hasFormatting("no formatting (really)"));
}

test "detectCodeFences double backtick not a fence" {
    try std.testing.expect(!detectCodeFences("`` not a fence ``"));
}

test "stripMarkdown preserves link text discards url" {
    var buf: [1024]u8 = undefined;
    const result = stripMarkdown("See [docs](https://example.com) for more", &buf);
    try std.testing.expectEqualStrings("See docs for more", result);
}

// ===== New tests added for comprehensive coverage =====

test "RenderTarget all labels non-empty" {
    const targets = [_]RenderTarget{ .telegram, .discord, .slack, .plain };
    for (targets) |t| {
        try std.testing.expect(t.label().len > 0);
    }
}

test "hasFormatting single star" {
    try std.testing.expect(hasFormatting("*"));
}

test "hasFormatting single underscore" {
    try std.testing.expect(hasFormatting("_"));
}

test "hasFormatting single backtick" {
    try std.testing.expect(hasFormatting("`"));
}

test "hasFormatting single hash" {
    try std.testing.expect(hasFormatting("#"));
}

test "hasFormatting single bracket" {
    try std.testing.expect(hasFormatting("["));
}

test "hasFormatting single greater than" {
    try std.testing.expect(hasFormatting(">"));
}

test "hasFormatting with mixed content" {
    try std.testing.expect(hasFormatting("Hello *world*!"));
    try std.testing.expect(hasFormatting("Check [this] out"));
}

test "hasFormatting digits and punctuation only" {
    try std.testing.expect(!hasFormatting("123.456"));
    try std.testing.expect(!hasFormatting("hello, world."));
    try std.testing.expect(!hasFormatting("@mention"));
}

test "detectCodeFences at start of text" {
    try std.testing.expect(detectCodeFences("```\ncode\n```"));
}

test "detectCodeFences at end of text" {
    try std.testing.expect(detectCodeFences("text before ```"));
}

test "detectCodeFences empty string" {
    try std.testing.expect(!detectCodeFences(""));
}

test "stripMarkdown h3 heading" {
    var buf: [1024]u8 = undefined;
    const result = stripMarkdown("### Third Level", &buf);
    try std.testing.expectEqualStrings("Third Level", result);
}

test "stripMarkdown mixed formatting" {
    var buf: [1024]u8 = undefined;
    const result = stripMarkdown("**bold** and _italic_ and `code`", &buf);
    try std.testing.expectEqualStrings("bold and italic and code", result);
}

test "stripMarkdown multiple links" {
    var buf: [1024]u8 = undefined;
    const result = stripMarkdown("[a](http://a.com) and [b](http://b.com)", &buf);
    try std.testing.expectEqualStrings("a and b", result);
}

test "stripMarkdown blockquote at newline" {
    var buf: [1024]u8 = undefined;
    const result = stripMarkdown("text\n> quoted", &buf);
    try std.testing.expectEqualStrings("text\nquoted", result);
}

test "stripMarkdown heading at newline" {
    var buf: [1024]u8 = undefined;
    const result = stripMarkdown("text\n# Heading", &buf);
    try std.testing.expectEqualStrings("text\nHeading", result);
}

test "stripMarkdown code fence with language" {
    var buf: [1024]u8 = undefined;
    const result = stripMarkdown("```javascript\nconsole.log('hi');\n```", &buf);
    try std.testing.expectEqualStrings("console.log('hi');\n", result);
}

test "stripMarkdown single asterisk not bold" {
    var buf: [1024]u8 = undefined;
    const result = stripMarkdown("a*b", &buf);
    // Single * is treated as italic marker, stripped
    try std.testing.expectEqualStrings("ab", result);
}

test "escapeForTelegram empty string" {
    var buf: [1024]u8 = undefined;
    const result = escapeForTelegram("", &buf);
    try std.testing.expectEqualStrings("", result);
}

test "escapeForTelegram numbers unchanged" {
    var buf: [1024]u8 = undefined;
    const result = escapeForTelegram("12345", &buf);
    try std.testing.expectEqualStrings("12345", result);
}

test "escapeForTelegram dot escape" {
    var buf: [1024]u8 = undefined;
    const result = escapeForTelegram("v1.0", &buf);
    try std.testing.expectEqualStrings("v1\\.0", result);
}

test "escapeForTelegram exclamation escape" {
    var buf: [1024]u8 = undefined;
    const result = escapeForTelegram("Hello!", &buf);
    try std.testing.expectEqualStrings("Hello\\!", result);
}

test "render plain removes formatting" {
    var buf: [1024]u8 = undefined;
    const result = render("# Heading\n**bold** and `code`", &buf, .plain);
    try std.testing.expect(std.mem.indexOf(u8, result, "#") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "**") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "`") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Heading") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "bold") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "code") != null);
}

test "render discord preserves all markdown" {
    var buf: [1024]u8 = undefined;
    const input = "# Title\n**bold** _italic_ `code` [link](url)";
    const result = render(input, &buf, .discord);
    try std.testing.expectEqualStrings(input, result);
}

test "render slack preserves all markdown" {
    var buf: [1024]u8 = undefined;
    const input = "# Title\n**bold** _italic_ `code` [link](url)";
    const result = render(input, &buf, .slack);
    try std.testing.expectEqualStrings(input, result);
}

test "render telegram escapes all special chars" {
    var buf: [1024]u8 = undefined;
    const result = render("Hello!", &buf, .telegram);
    try std.testing.expectEqualStrings("Hello\\!", result);
}

test "render plain empty string" {
    var buf: [1024]u8 = undefined;
    const result = render("", &buf, .plain);
    try std.testing.expectEqualStrings("", result);
}

test "render discord empty string" {
    var buf: [1024]u8 = undefined;
    const result = render("", &buf, .discord);
    try std.testing.expectEqualStrings("", result);
}

test "render telegram empty string" {
    var buf: [1024]u8 = undefined;
    const result = render("", &buf, .telegram);
    try std.testing.expectEqualStrings("", result);
}

test "stripMarkdown plain text with numbers" {
    var buf: [1024]u8 = undefined;
    const result = stripMarkdown("Version 2.0 released", &buf);
    try std.testing.expectEqualStrings("Version 2.0 released", result);
}

test "stripMarkdown nested bold and italic" {
    var buf: [1024]u8 = undefined;
    const result = stripMarkdown("***bold italic***", &buf);
    // *** = ** + * (2 stars stripped then 1 star stripped)
    try std.testing.expectEqualStrings("bold italic", result);
}

test "stripMarkdown link with no url part" {
    var buf: [1024]u8 = undefined;
    // [text] without (url) -- should output the text inside brackets
    const result = stripMarkdown("[just brackets]", &buf);
    try std.testing.expectEqualStrings("just brackets", result);
}

test "escapeForTelegram preserves unicode text" {
    var buf: [1024]u8 = undefined;
    const result = escapeForTelegram("Hello \xC3\xA9\xC3\xA0\xC3\xBC", &buf);
    // Unicode bytes are not special chars, should pass through unchanged
    try std.testing.expectEqualStrings("Hello \xC3\xA9\xC3\xA0\xC3\xBC", result);
}

test "render plain strips nested markdown in paragraph" {
    var buf: [2048]u8 = undefined;
    const input = "# Title\n\n**Bold text** with _emphasis_ and `inline code`.\n\n> A blockquote\n\n[Link](http://example.com)";
    const result = render(input, &buf, .plain);
    // No markdown markers should remain
    try std.testing.expect(std.mem.indexOf(u8, result, "#") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "**") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "`") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "[") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "](") == null);
    // Actual text content should be preserved
    try std.testing.expect(std.mem.indexOf(u8, result, "Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Bold text") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "emphasis") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "inline code") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "A blockquote") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Link") != null);
}

test "render telegram escapes markdown link syntax" {
    var buf: [1024]u8 = undefined;
    const result = render("[click](http://example.com)", &buf, .telegram);
    // Telegram escaping should escape [, ], (, )
    try std.testing.expect(std.mem.indexOf(u8, result, "\\[") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\\]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\\(") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\\)") != null);
}
