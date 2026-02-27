const std = @import("std");

// --- Compaction ---

/// Determines if message history needs compaction based on estimated token count.
/// Simple heuristic: ~4 characters per token.
pub fn needsCompaction(messages_bytes: usize, max_context_tokens: u32) bool {
    const estimated_tokens = messages_bytes / 4;
    // Compact when we're using more than 80% of context window
    const threshold = (max_context_tokens * 4) / 5;
    return estimated_tokens > threshold;
}

/// Estimate token count from byte length (~4 chars per token).
pub fn estimateTokens(text: []const u8) u32 {
    if (text.len == 0) return 0;
    return @intCast(@max(1, text.len / 4));
}

/// Build a compaction summary request.
/// This creates a prompt asking the model to summarize the conversation.
pub fn buildCompactionPrompt(buf: []u8, messages_preview: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    try writer.writeAll(
        \\Summarize the following conversation history in a concise paragraph.
        \\Focus on: key topics discussed, decisions made, important context,
        \\and any unresolved tasks. Keep it under 500 words.
        \\
        \\---
        \\
    );
    // Truncate if too long
    const max_preview = @min(messages_preview.len, 8000);
    try writer.writeAll(messages_preview[0..max_preview]);

    return fbs.getWritten();
}

/// Compaction entry for JSONL storage
pub const CompactionEntry = struct {
    summary: []const u8,
    original_message_count: u32,
    compacted_at_ms: i64,
    estimated_tokens_saved: u32,
};

/// Build a CompactionEntry
pub fn createEntry(
    summary: []const u8,
    original_count: u32,
    bytes_saved: usize,
) CompactionEntry {
    return .{
        .summary = summary,
        .original_message_count = original_count,
        .compacted_at_ms = std.time.milliTimestamp(),
        .estimated_tokens_saved = @intCast(bytes_saved / 4),
    };
}

/// Truncate message history from the front, keeping the last N messages.
/// Returns the index to start keeping messages from.
pub fn findCompactionCutoff(total_messages: usize, keep_recent: usize) usize {
    if (total_messages <= keep_recent) return 0;
    return total_messages - keep_recent;
}

// --- Tests ---

test "needsCompaction below threshold" {
    // 200k context window, 80% = 160k tokens = 640k bytes
    try std.testing.expect(!needsCompaction(100_000, 200_000));
}

test "needsCompaction above threshold" {
    // 200k context window, 80% = 160k tokens = 640k bytes
    try std.testing.expect(needsCompaction(700_000, 200_000));
}

test "needsCompaction at boundary" {
    // 1000 tokens context, 80% = 800 tokens = 3200 bytes
    // 3200 bytes / 4 = 800 tokens, threshold = 800, 800 > 800 = false
    try std.testing.expect(!needsCompaction(3200, 1000));
    // 3204 bytes / 4 = 801 tokens, 801 > 800 = true
    try std.testing.expect(needsCompaction(3204, 1000));
}

test "estimateTokens" {
    try std.testing.expectEqual(@as(u32, 0), estimateTokens(""));
    try std.testing.expectEqual(@as(u32, 1), estimateTokens("hi"));
    try std.testing.expectEqual(@as(u32, 2), estimateTokens("hello wo"));
    try std.testing.expectEqual(@as(u32, 25), estimateTokens("a" ** 100));
}

test "buildCompactionPrompt" {
    var buf: [16384]u8 = undefined;
    const prompt = try buildCompactionPrompt(&buf, "User: Hello\nAssistant: Hi there!");

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Summarize") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "User: Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Assistant: Hi there!") != null);
}

test "buildCompactionPrompt truncates long preview" {
    var buf: [16384]u8 = undefined;
    const long_text = "x" ** 10000;
    const prompt = try buildCompactionPrompt(&buf, long_text);

    // Should be truncated to ~8000 chars of preview
    try std.testing.expect(prompt.len < 9000);
}

test "createEntry" {
    const entry = createEntry("This is a summary", 50, 20000);
    try std.testing.expectEqualStrings("This is a summary", entry.summary);
    try std.testing.expectEqual(@as(u32, 50), entry.original_message_count);
    try std.testing.expectEqual(@as(u32, 5000), entry.estimated_tokens_saved);
    try std.testing.expect(entry.compacted_at_ms > 0);
}

test "findCompactionCutoff" {
    try std.testing.expectEqual(@as(usize, 0), findCompactionCutoff(5, 10));
    try std.testing.expectEqual(@as(usize, 0), findCompactionCutoff(10, 10));
    try std.testing.expectEqual(@as(usize, 10), findCompactionCutoff(20, 10));
    try std.testing.expectEqual(@as(usize, 90), findCompactionCutoff(100, 10));
}

// --- Additional Tests ---

test "needsCompaction zero bytes" {
    try std.testing.expect(!needsCompaction(0, 200_000));
}

test "needsCompaction zero context window" {
    // 0 token context means threshold = 0, any bytes > 0 triggers compaction
    try std.testing.expect(needsCompaction(4, 0));
    try std.testing.expect(!needsCompaction(0, 0));
}

test "needsCompaction small context window" {
    // 100 tokens, threshold = 80 tokens = 320 bytes
    try std.testing.expect(!needsCompaction(320, 100));
    try std.testing.expect(needsCompaction(324, 100));
}

test "needsCompaction large content exactly at threshold" {
    // 10000 tokens, threshold = 8000 tokens = 32000 bytes
    try std.testing.expect(!needsCompaction(32000, 10000));
    try std.testing.expect(needsCompaction(32004, 10000));
}

test "estimateTokens single char" {
    try std.testing.expectEqual(@as(u32, 1), estimateTokens("a"));
}

test "estimateTokens exactly 4 chars" {
    try std.testing.expectEqual(@as(u32, 1), estimateTokens("abcd"));
}

test "estimateTokens large text" {
    const text = "a" ** 10000;
    try std.testing.expectEqual(@as(u32, 2500), estimateTokens(text));
}

test "estimateTokens 3 chars" {
    // 3 / 4 = 0, but max(1, 0) = 1
    try std.testing.expectEqual(@as(u32, 1), estimateTokens("abc"));
}

test "buildCompactionPrompt empty preview" {
    var buf: [16384]u8 = undefined;
    const prompt = try buildCompactionPrompt(&buf, "");
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Summarize") != null);
}

test "buildCompactionPrompt contains key instructions" {
    var buf: [16384]u8 = undefined;
    const prompt = try buildCompactionPrompt(&buf, "test");
    try std.testing.expect(std.mem.indexOf(u8, prompt, "key topics") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "decisions made") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "unresolved tasks") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "500 words") != null);
}

test "createEntry with zero bytes saved" {
    const entry = createEntry("No content removed", 0, 0);
    try std.testing.expectEqual(@as(u32, 0), entry.estimated_tokens_saved);
    try std.testing.expectEqual(@as(u32, 0), entry.original_message_count);
}

test "createEntry timestamp is recent" {
    const before = std.time.milliTimestamp();
    const entry = createEntry("summary", 10, 4000);
    const after = std.time.milliTimestamp();
    try std.testing.expect(entry.compacted_at_ms >= before);
    try std.testing.expect(entry.compacted_at_ms <= after);
}

test "createEntry token savings calculation" {
    // 8000 bytes / 4 = 2000 tokens
    const entry = createEntry("s", 25, 8000);
    try std.testing.expectEqual(@as(u32, 2000), entry.estimated_tokens_saved);
}

test "findCompactionCutoff zero messages" {
    try std.testing.expectEqual(@as(usize, 0), findCompactionCutoff(0, 10));
}

test "findCompactionCutoff keep one" {
    try std.testing.expectEqual(@as(usize, 99), findCompactionCutoff(100, 1));
}

test "findCompactionCutoff keep all" {
    try std.testing.expectEqual(@as(usize, 0), findCompactionCutoff(5, 5));
    try std.testing.expectEqual(@as(usize, 0), findCompactionCutoff(5, 100));
}

test "CompactionEntry struct fields" {
    const entry = CompactionEntry{
        .summary = "test",
        .original_message_count = 42,
        .compacted_at_ms = 12345,
        .estimated_tokens_saved = 500,
    };
    try std.testing.expectEqualStrings("test", entry.summary);
    try std.testing.expectEqual(@as(u32, 42), entry.original_message_count);
    try std.testing.expectEqual(@as(i64, 12345), entry.compacted_at_ms);
    try std.testing.expectEqual(@as(u32, 500), entry.estimated_tokens_saved);
}

// ===== New tests added for comprehensive coverage =====

test "needsCompaction just under threshold" {
    // 500 tokens context, threshold = 400 tokens = 1600 bytes
    // 1600 bytes / 4 = 400 tokens, 400 > 400 = false
    try std.testing.expect(!needsCompaction(1600, 500));
}

test "needsCompaction just over threshold" {
    // 500 tokens context, threshold = 400 tokens = 1600 bytes
    // 1604 bytes / 4 = 401 tokens, 401 > 400 = true
    try std.testing.expect(needsCompaction(1604, 500));
}

test "needsCompaction with very large context" {
    // 1M tokens context window
    try std.testing.expect(!needsCompaction(0, 1_000_000));
    try std.testing.expect(!needsCompaction(3_200_000, 1_000_000));
    try std.testing.expect(needsCompaction(3_200_004, 1_000_000));
}

test "needsCompaction small messages in big context" {
    // Small messages (100 bytes) in 200k context - never needs compaction
    try std.testing.expect(!needsCompaction(100, 200_000));
}

test "estimateTokens five chars" {
    // 5 / 4 = 1
    try std.testing.expectEqual(@as(u32, 1), estimateTokens("hello"));
}

test "estimateTokens eight chars" {
    // 8 / 4 = 2
    try std.testing.expectEqual(@as(u32, 2), estimateTokens("12345678"));
}

test "estimateTokens twelve chars" {
    // 12 / 4 = 3
    try std.testing.expectEqual(@as(u32, 3), estimateTokens("123456789012"));
}

test "estimateTokens two chars gives minimum 1" {
    try std.testing.expectEqual(@as(u32, 1), estimateTokens("ab"));
}

test "buildCompactionPrompt buffer too small" {
    var buf: [10]u8 = undefined;
    const result = buildCompactionPrompt(&buf, "some text");
    try std.testing.expectError(error.NoSpaceLeft, result);
}

test "buildCompactionPrompt preserves short preview exactly" {
    var buf: [16384]u8 = undefined;
    const preview = "Short preview text";
    const prompt = try buildCompactionPrompt(&buf, preview);
    try std.testing.expect(std.mem.indexOf(u8, prompt, preview) != null);
}

test "buildCompactionPrompt exactly 8000 char preview" {
    var buf: [16384]u8 = undefined;
    const preview = "a" ** 8000;
    const prompt = try buildCompactionPrompt(&buf, preview);
    // All 8000 chars should be included (max_preview = min(8000, 8000) = 8000)
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Summarize") != null);
}

test "createEntry large values" {
    const entry = createEntry("Long summary", 10000, 1_000_000);
    try std.testing.expectEqual(@as(u32, 10000), entry.original_message_count);
    try std.testing.expectEqual(@as(u32, 250_000), entry.estimated_tokens_saved);
}

test "createEntry with 1 byte saved" {
    // 1 byte / 4 = 0 tokens saved
    const entry = createEntry("s", 1, 1);
    try std.testing.expectEqual(@as(u32, 0), entry.estimated_tokens_saved);
}

test "createEntry with 4 bytes saved" {
    // 4 bytes / 4 = 1 token saved
    const entry = createEntry("s", 1, 4);
    try std.testing.expectEqual(@as(u32, 1), entry.estimated_tokens_saved);
}

test "findCompactionCutoff keep zero" {
    // keep_recent = 0, should cut all messages
    try std.testing.expectEqual(@as(usize, 10), findCompactionCutoff(10, 0));
}

test "findCompactionCutoff one message keep one" {
    try std.testing.expectEqual(@as(usize, 0), findCompactionCutoff(1, 1));
}

test "findCompactionCutoff two messages keep one" {
    try std.testing.expectEqual(@as(usize, 1), findCompactionCutoff(2, 1));
}

test "findCompactionCutoff large numbers" {
    try std.testing.expectEqual(@as(usize, 9950), findCompactionCutoff(10000, 50));
}
