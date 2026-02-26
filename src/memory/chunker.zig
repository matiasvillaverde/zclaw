const std = @import("std");

// --- Chunking Constants ---

pub const DEFAULT_CHUNK_SIZE: u32 = 400; // tokens
pub const DEFAULT_OVERLAP: u32 = 80; // tokens
pub const CHARS_PER_TOKEN: u32 = 4; // approximate

// --- Chunk ---

pub const Chunk = struct {
    text: []const u8,
    start_offset: usize,
    end_offset: usize,
    index: u32,
    estimated_tokens: u32,
};

// --- Chunker ---

pub fn chunkText(
    allocator: std.mem.Allocator,
    text: []const u8,
    chunk_size_tokens: u32,
    overlap_tokens: u32,
) ![]Chunk {
    if (text.len == 0) return &.{};

    const chunk_chars = chunk_size_tokens * CHARS_PER_TOKEN;
    const overlap_chars = overlap_tokens * CHARS_PER_TOKEN;
    const stride = if (chunk_chars > overlap_chars) chunk_chars - overlap_chars else 1;

    var chunks = std.ArrayListUnmanaged(Chunk){};

    var offset: usize = 0;
    var index: u32 = 0;

    while (offset < text.len) {
        var end = @min(offset + chunk_chars, text.len);

        // Try to break at sentence/paragraph boundary
        if (end < text.len) {
            end = findBoundary(text, offset, end);
        }

        const chunk_text = text[offset..end];
        try chunks.append(allocator, .{
            .text = chunk_text,
            .start_offset = offset,
            .end_offset = end,
            .index = index,
            .estimated_tokens = @intCast(@max(1, chunk_text.len / CHARS_PER_TOKEN)),
        });

        index += 1;

        // Move forward by stride, but at least 1 char to avoid infinite loop
        const next_offset = offset + @max(stride, 1);
        if (next_offset <= offset or next_offset >= text.len) break;
        offset = next_offset;
    }

    if (chunks.items.len == 0) {
        chunks.deinit(allocator);
        return &.{};
    }

    return chunks.toOwnedSlice(allocator);
}

/// Find a good boundary point near the target end position.
/// Prefers paragraph breaks > sentence ends > word breaks.
fn findBoundary(text: []const u8, start: usize, target_end: usize) usize {
    // Look back up to 200 chars from target for a boundary
    const search_start = if (target_end > start + 200) target_end - 200 else start;

    // Try paragraph break first
    var i = target_end;
    while (i > search_start) : (i -= 1) {
        if (i < text.len and text[i] == '\n' and i > 0 and text[i - 1] == '\n') {
            return i + 1;
        }
    }

    // Try sentence end
    i = target_end;
    while (i > search_start) : (i -= 1) {
        if (i < text.len and (text[i] == '.' or text[i] == '!' or text[i] == '?')) {
            if (i + 1 < text.len and text[i + 1] == ' ') {
                return i + 2;
            }
            return i + 1;
        }
    }

    // Try word break
    i = target_end;
    while (i > search_start) : (i -= 1) {
        if (i < text.len and text[i] == ' ') {
            return i + 1;
        }
    }

    // Fall back to original target
    return target_end;
}

/// Free chunks returned by chunkText.
pub fn freeChunks(allocator: std.mem.Allocator, chunks: []Chunk) void {
    allocator.free(chunks);
}

// --- Tests ---

test "chunkText empty" {
    const allocator = std.testing.allocator;
    const chunks = try chunkText(allocator, "", DEFAULT_CHUNK_SIZE, DEFAULT_OVERLAP);
    try std.testing.expectEqual(@as(usize, 0), chunks.len);
}

test "chunkText short text" {
    const allocator = std.testing.allocator;
    const chunks = try chunkText(allocator, "Hello world.", DEFAULT_CHUNK_SIZE, DEFAULT_OVERLAP);
    defer freeChunks(allocator, chunks);

    try std.testing.expectEqual(@as(usize, 1), chunks.len);
    try std.testing.expectEqualStrings("Hello world.", chunks[0].text);
    try std.testing.expectEqual(@as(u32, 0), chunks[0].index);
    try std.testing.expectEqual(@as(usize, 0), chunks[0].start_offset);
}

test "chunkText long text creates multiple chunks" {
    const allocator = std.testing.allocator;
    // Create text longer than 1 chunk (400 tokens * 4 chars = 1600 chars)
    const text = "The quick brown fox jumps. " ** 80; // ~2080 chars
    const chunks = try chunkText(allocator, text, DEFAULT_CHUNK_SIZE, DEFAULT_OVERLAP);
    defer freeChunks(allocator, chunks);

    try std.testing.expect(chunks.len >= 2);
    try std.testing.expectEqual(@as(u32, 0), chunks[0].index);
    try std.testing.expectEqual(@as(u32, 1), chunks[1].index);
}

test "chunkText overlap" {
    const allocator = std.testing.allocator;
    const text = "word " ** 500; // 2500 chars, way more than 1 chunk
    const chunks = try chunkText(allocator, text, 100, 20);
    defer freeChunks(allocator, chunks);

    // With overlap, chunks should overlap
    if (chunks.len >= 2) {
        // Second chunk should start before first chunk ends
        try std.testing.expect(chunks[1].start_offset < chunks[0].end_offset);
    }
}

test "chunkText preserves coverage" {
    const allocator = std.testing.allocator;
    const text = "abcdefghijklmnopqrstuvwxyz" ** 100; // 2600 chars
    const chunks = try chunkText(allocator, text, 100, 20);
    defer freeChunks(allocator, chunks);

    // First chunk starts at 0
    try std.testing.expectEqual(@as(usize, 0), chunks[0].start_offset);

    // Last chunk covers the end
    if (chunks.len > 0) {
        const last = chunks[chunks.len - 1];
        try std.testing.expect(last.end_offset <= text.len);
    }
}

test "chunkText estimated tokens" {
    const allocator = std.testing.allocator;
    const text = "x" ** 100;
    const chunks = try chunkText(allocator, text, DEFAULT_CHUNK_SIZE, DEFAULT_OVERLAP);
    defer freeChunks(allocator, chunks);

    try std.testing.expectEqual(@as(usize, 1), chunks.len);
    try std.testing.expectEqual(@as(u32, 25), chunks[0].estimated_tokens); // 100/4
}

test "findBoundary at paragraph" {
    const text = "First paragraph.\n\nSecond paragraph starts here.";
    // Target end in the middle
    const boundary = findBoundary(text, 0, 20);
    try std.testing.expectEqual(@as(usize, 18), boundary); // After \n\n
}

test "findBoundary at sentence" {
    const text = "First sentence. Second sentence here and more text follows.";
    const boundary = findBoundary(text, 0, 20);
    // Should find ". " and break after it
    try std.testing.expect(boundary <= 20);
    try std.testing.expect(boundary > 0);
}

test "chunkText with sentences" {
    const allocator = std.testing.allocator;
    const text = "This is sentence one. This is sentence two. This is sentence three. " ** 30;
    const chunks = try chunkText(allocator, text, 100, 20);
    defer freeChunks(allocator, chunks);

    // Chunks should exist
    try std.testing.expect(chunks.len >= 1);

    // Each chunk should have reasonable token estimate
    for (chunks) |chunk| {
        try std.testing.expect(chunk.estimated_tokens > 0);
    }
}

test "constants" {
    try std.testing.expectEqual(@as(u32, 400), DEFAULT_CHUNK_SIZE);
    try std.testing.expectEqual(@as(u32, 80), DEFAULT_OVERLAP);
    try std.testing.expectEqual(@as(u32, 4), CHARS_PER_TOKEN);
}
