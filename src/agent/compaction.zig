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
