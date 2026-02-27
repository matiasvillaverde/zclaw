const std = @import("std");

// --- Message Chunking ---
//
// Split long messages respecting code fences and channel limits.

pub const TELEGRAM_LIMIT: usize = 4096;
pub const DISCORD_LIMIT: usize = 2000;
pub const SLACK_LIMIT: usize = 40000;

pub const ChannelTarget = enum {
    telegram,
    discord,
    slack,
    generic,

    pub fn maxLength(self: ChannelTarget) usize {
        return switch (self) {
            .telegram => TELEGRAM_LIMIT,
            .discord => DISCORD_LIMIT,
            .slack => SLACK_LIMIT,
            .generic => 4096,
        };
    }
};

/// Check if a position is inside an unclosed code fence.
pub fn isInsideCodeFence(content: []const u8, pos: usize) bool {
    var count: usize = 0;
    var i: usize = 0;
    while (i < pos and i < content.len) {
        if (i + 3 <= content.len and std.mem.eql(u8, content[i .. i + 3], "```")) {
            count += 1;
            i += 3;
        } else {
            i += 1;
        }
    }
    return (count % 2) != 0;
}

/// Find the best split point near the given position.
/// Preference: paragraph break > line break > space > hard cut.
pub fn findSplitPoint(content: []const u8, max_len: usize) usize {
    if (content.len <= max_len) return content.len;

    // Look for paragraph break (\n\n) near max_len
    const search_start = if (max_len > 200) max_len - 200 else 0;
    if (std.mem.lastIndexOf(u8, content[search_start..max_len], "\n\n")) |pos| {
        return search_start + pos + 2;
    }

    // Look for line break
    if (std.mem.lastIndexOf(u8, content[search_start..max_len], "\n")) |pos| {
        return search_start + pos + 1;
    }

    // Look for space
    const space_search = if (max_len > 50) max_len - 50 else 0;
    if (std.mem.lastIndexOf(u8, content[space_search..max_len], " ")) |pos| {
        return space_search + pos + 1;
    }

    // Hard cut
    return max_len;
}

/// Chunk a message into pieces that fit within the channel limit.
pub fn chunkMessage(allocator: std.mem.Allocator, content: []const u8, max_len: usize) ![][]const u8 {
    if (content.len == 0) {
        return &.{};
    }

    if (content.len <= max_len) {
        var chunks = try allocator.alloc([]const u8, 1);
        chunks[0] = try allocator.dupe(u8, content);
        return chunks;
    }

    var chunk_list = std.ArrayListUnmanaged([]const u8){};
    var pos: usize = 0;

    while (pos < content.len) {
        const remaining = content[pos..];
        if (remaining.len <= max_len) {
            try chunk_list.append(allocator, try allocator.dupe(u8, remaining));
            break;
        }

        var split = findSplitPoint(remaining, max_len);

        // If inside a code fence, try to find a split before the fence
        if (isInsideCodeFence(content, pos + split)) {
            // Look for the fence start
            if (std.mem.lastIndexOf(u8, remaining[0..split], "```")) |fence_pos| {
                if (fence_pos > 0) {
                    split = fence_pos;
                }
            }
        }

        try chunk_list.append(allocator, try allocator.dupe(u8, remaining[0..split]));
        pos += split;
    }

    return try chunk_list.toOwnedSlice(allocator);
}

/// Free chunks allocated by chunkMessage.
pub fn freeChunks(allocator: std.mem.Allocator, chunks: [][]const u8) void {
    for (chunks) |chunk| {
        allocator.free(chunk);
    }
    allocator.free(chunks);
}

// --- Tests ---

test "ChannelTarget maxLength" {
    try std.testing.expectEqual(@as(usize, 4096), ChannelTarget.telegram.maxLength());
    try std.testing.expectEqual(@as(usize, 2000), ChannelTarget.discord.maxLength());
    try std.testing.expectEqual(@as(usize, 40000), ChannelTarget.slack.maxLength());
}

test "isInsideCodeFence" {
    try std.testing.expect(!isInsideCodeFence("hello world", 5));
    try std.testing.expect(isInsideCodeFence("```code here", 10));
    try std.testing.expect(!isInsideCodeFence("```code```", 10));
    try std.testing.expect(isInsideCodeFence("before ```code", 12));
}

test "findSplitPoint within limit" {
    try std.testing.expectEqual(@as(usize, 5), findSplitPoint("hello", 100));
}

test "findSplitPoint at paragraph" {
    const text = "first paragraph\n\nsecond paragraph that is long enough";
    const split = findSplitPoint(text, 30);
    try std.testing.expect(split <= 30);
    try std.testing.expect(split == 17); // after \n\n
}

test "findSplitPoint at line" {
    const text = "line one\nline two is really long";
    const split = findSplitPoint(text, 20);
    try std.testing.expect(split <= 20);
    try std.testing.expect(split == 9); // after \n
}

test "findSplitPoint at space" {
    const text = "word1 word2 word3 word4";
    const split = findSplitPoint(text, 15);
    try std.testing.expect(split <= 15);
}

test "chunkMessage short text" {
    const allocator = std.testing.allocator;
    const chunks = try chunkMessage(allocator, "hello", 100);
    defer freeChunks(allocator, chunks);

    try std.testing.expectEqual(@as(usize, 1), chunks.len);
    try std.testing.expectEqualStrings("hello", chunks[0]);
}

test "chunkMessage empty" {
    const allocator = std.testing.allocator;
    const chunks = try chunkMessage(allocator, "", 100);
    try std.testing.expectEqual(@as(usize, 0), chunks.len);
}

test "chunkMessage splits long text" {
    const allocator = std.testing.allocator;
    const text = "a" ** 150;
    const chunks = try chunkMessage(allocator, text, 50);
    defer freeChunks(allocator, chunks);

    try std.testing.expect(chunks.len >= 3);
    var total: usize = 0;
    for (chunks) |chunk| {
        try std.testing.expect(chunk.len <= 50);
        total += chunk.len;
    }
    try std.testing.expectEqual(@as(usize, 150), total);
}

test "chunkMessage respects paragraph breaks" {
    const allocator = std.testing.allocator;
    const text = "First para with text.\n\nSecond para with more text.";
    const chunks = try chunkMessage(allocator, text, 30);
    defer freeChunks(allocator, chunks);

    try std.testing.expect(chunks.len >= 2);
    for (chunks) |chunk| {
        try std.testing.expect(chunk.len <= 30);
    }
}

test "freeChunks" {
    const allocator = std.testing.allocator;
    var chunks = try allocator.alloc([]const u8, 2);
    chunks[0] = try allocator.dupe(u8, "a");
    chunks[1] = try allocator.dupe(u8, "b");
    freeChunks(allocator, chunks);
}

// --- Additional Tests ---

test "ChannelTarget generic maxLength" {
    try std.testing.expectEqual(@as(usize, 4096), ChannelTarget.generic.maxLength());
}

test "isInsideCodeFence at start" {
    try std.testing.expect(!isInsideCodeFence("hello", 0));
}

test "isInsideCodeFence nested fences" {
    // Two open fences -- second one closes first
    const text = "```code```more```open";
    try std.testing.expect(isInsideCodeFence(text, 20));
}

test "isInsideCodeFence empty text" {
    try std.testing.expect(!isInsideCodeFence("", 0));
}

test "findSplitPoint hard cut when no breaks" {
    const text = "abcdefghijklmnopqrstuvwxyz";
    const split = findSplitPoint(text, 10);
    try std.testing.expectEqual(@as(usize, 10), split);
}

test "findSplitPoint very short max" {
    const text = "hello world";
    const split = findSplitPoint(text, 3);
    try std.testing.expectEqual(@as(usize, 3), split);
}

test "chunkMessage single char limit" {
    const allocator = std.testing.allocator;
    const chunks = try chunkMessage(allocator, "ab", 1);
    defer freeChunks(allocator, chunks);
    try std.testing.expect(chunks.len >= 2);
}

test "chunkMessage exact limit" {
    const allocator = std.testing.allocator;
    const chunks = try chunkMessage(allocator, "hello", 5);
    defer freeChunks(allocator, chunks);
    try std.testing.expectEqual(@as(usize, 1), chunks.len);
    try std.testing.expectEqualStrings("hello", chunks[0]);
}

test "chunkMessage one over limit" {
    const allocator = std.testing.allocator;
    const chunks = try chunkMessage(allocator, "hello!", 5);
    defer freeChunks(allocator, chunks);
    try std.testing.expect(chunks.len >= 2);
}

test "chunkMessage preserves all content" {
    const allocator = std.testing.allocator;
    const text = "The quick brown fox jumps over the lazy dog.";
    const chunks = try chunkMessage(allocator, text, 15);
    defer freeChunks(allocator, chunks);

    var total_len: usize = 0;
    for (chunks) |chunk| {
        total_len += chunk.len;
    }
    try std.testing.expectEqual(text.len, total_len);
}

test "chunkMessage code fence awareness" {
    const allocator = std.testing.allocator;
    const text = "Before\n```python\nprint('hello')\n```\nAfter some more text here.";
    const chunks = try chunkMessage(allocator, text, 30);
    defer freeChunks(allocator, chunks);

    try std.testing.expect(chunks.len >= 2);
}

test "TELEGRAM_LIMIT value" {
    try std.testing.expectEqual(@as(usize, 4096), TELEGRAM_LIMIT);
}

test "DISCORD_LIMIT value" {
    try std.testing.expectEqual(@as(usize, 2000), DISCORD_LIMIT);
}

test "SLACK_LIMIT value" {
    try std.testing.expectEqual(@as(usize, 40000), SLACK_LIMIT);
}

// ===== New tests added for comprehensive coverage =====

test "ChannelTarget all variants have maxLength" {
    const targets = [_]ChannelTarget{ .telegram, .discord, .slack, .generic };
    for (targets) |t| {
        try std.testing.expect(t.maxLength() > 0);
    }
}

test "ChannelTarget discord is smallest" {
    try std.testing.expect(ChannelTarget.discord.maxLength() < ChannelTarget.telegram.maxLength());
    try std.testing.expect(ChannelTarget.discord.maxLength() < ChannelTarget.slack.maxLength());
}

test "ChannelTarget slack is largest" {
    try std.testing.expect(ChannelTarget.slack.maxLength() > ChannelTarget.telegram.maxLength());
    try std.testing.expect(ChannelTarget.slack.maxLength() > ChannelTarget.discord.maxLength());
}

test "isInsideCodeFence multiple open close" {
    // open, close, open = inside
    const text = "```a```b```c";
    try std.testing.expect(isInsideCodeFence(text, 11));
}

test "isInsideCodeFence with language tag" {
    const text = "```python\ncode\n```";
    try std.testing.expect(isInsideCodeFence(text, 10)); // inside
    try std.testing.expect(!isInsideCodeFence(text, 18)); // after closing
}

test "isInsideCodeFence pos beyond content" {
    const text = "```code";
    try std.testing.expect(isInsideCodeFence(text, 100)); // pos > len
}

test "isInsideCodeFence exactly at triple backtick" {
    const text = "```";
    try std.testing.expect(isInsideCodeFence(text, 3));
}

test "isInsideCodeFence two complete fences" {
    const text = "```a```\n```b```";
    try std.testing.expect(!isInsideCodeFence(text, 8)); // between fences
}

test "findSplitPoint content shorter than max" {
    try std.testing.expectEqual(@as(usize, 3), findSplitPoint("abc", 100));
}

test "findSplitPoint prefers paragraph over line break" {
    const text = "a\nb\n\nc";
    // Within 6 chars, there's a \n\n at position 3
    const split = findSplitPoint(text, 5);
    try std.testing.expectEqual(@as(usize, 5), split);
}

test "findSplitPoint at max_len 1" {
    const text = "abc";
    const split = findSplitPoint(text, 1);
    try std.testing.expectEqual(@as(usize, 1), split);
}

test "findSplitPoint with only spaces" {
    const text = "a b c d e f g h i j";
    const split = findSplitPoint(text, 10);
    try std.testing.expect(split <= 10);
    try std.testing.expect(split > 0);
}

test "chunkMessage with newlines at discord limit" {
    const allocator = std.testing.allocator;
    const text = "Line one\nLine two\nLine three\n" ** 100;
    const chunks = try chunkMessage(allocator, text, DISCORD_LIMIT);
    defer freeChunks(allocator, chunks);

    for (chunks) |chunk| {
        try std.testing.expect(chunk.len <= DISCORD_LIMIT);
    }
}

test "chunkMessage single character text" {
    const allocator = std.testing.allocator;
    const chunks = try chunkMessage(allocator, "x", 100);
    defer freeChunks(allocator, chunks);

    try std.testing.expectEqual(@as(usize, 1), chunks.len);
    try std.testing.expectEqualStrings("x", chunks[0]);
}

test "chunkMessage two characters limit one" {
    const allocator = std.testing.allocator;
    const chunks = try chunkMessage(allocator, "xy", 1);
    defer freeChunks(allocator, chunks);

    try std.testing.expectEqual(@as(usize, 2), chunks.len);
    try std.testing.expectEqualStrings("x", chunks[0]);
    try std.testing.expectEqualStrings("y", chunks[1]);
}

test "chunkMessage preserves total content with paragraphs" {
    const allocator = std.testing.allocator;
    const text = "Para one text.\n\nPara two text.\n\nPara three.";
    const chunks = try chunkMessage(allocator, text, 20);
    defer freeChunks(allocator, chunks);

    var total_len: usize = 0;
    for (chunks) |chunk| {
        total_len += chunk.len;
    }
    try std.testing.expectEqual(text.len, total_len);
}

test "chunkMessage large text many chunks" {
    const allocator = std.testing.allocator;
    const text = "word " ** 500; // 2500 chars
    const chunks = try chunkMessage(allocator, text, 100);
    defer freeChunks(allocator, chunks);

    try std.testing.expect(chunks.len >= 25);
    var total_len: usize = 0;
    for (chunks) |chunk| {
        try std.testing.expect(chunk.len <= 100);
        total_len += chunk.len;
    }
    try std.testing.expectEqual(text.len, total_len);
}

test "chunkMessage with code fence in middle" {
    const allocator = std.testing.allocator;
    const text = "Before text.\n```\ncode line 1\ncode line 2\n```\nAfter text.";
    const chunks = try chunkMessage(allocator, text, 25);
    defer freeChunks(allocator, chunks);

    try std.testing.expect(chunks.len >= 2);
}

test "chunkMessage exact multiple of limit" {
    const allocator = std.testing.allocator;
    const text = "a" ** 100;
    const chunks = try chunkMessage(allocator, text, 50);
    defer freeChunks(allocator, chunks);

    try std.testing.expectEqual(@as(usize, 2), chunks.len);
    try std.testing.expectEqual(@as(usize, 50), chunks[0].len);
    try std.testing.expectEqual(@as(usize, 50), chunks[1].len);
}

test "freeChunks with single chunk" {
    const allocator = std.testing.allocator;
    var chunks = try allocator.alloc([]const u8, 1);
    chunks[0] = try allocator.dupe(u8, "only");
    freeChunks(allocator, chunks);
}

test "freeChunks with empty array" {
    const allocator = std.testing.allocator;
    const chunks = try allocator.alloc([]const u8, 0);
    freeChunks(allocator, chunks);
}
