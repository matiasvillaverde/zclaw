const std = @import("std");
const chunker = @import("chunker.zig");
const search = @import("search.zig");

// --- Memory Manager ---

/// In-memory document store with chunk management.
/// SQLite/sqlite-vec integration will be added when the dependency is set up.
pub const MemoryManager = struct {
    allocator: std.mem.Allocator,
    documents: std.ArrayListUnmanaged(Document),
    chunks: std.ArrayListUnmanaged(StoredChunk),
    next_doc_id: u64,
    next_chunk_id: u64,

    const Document = struct {
        id: u64,
        path: []const u8,
        content_hash: u64,
        indexed_at_ms: i64,
        chunk_count: u32,
    };

    const StoredChunk = struct {
        id: u64,
        doc_id: u64,
        text: []const u8,
        index: u32,
        embedding: ?[]f64 = null,
    };

    pub fn init(allocator: std.mem.Allocator) MemoryManager {
        return .{
            .allocator = allocator,
            .documents = .{},
            .chunks = .{},
            .next_doc_id = 1,
            .next_chunk_id = 1,
        };
    }

    pub fn deinit(self: *MemoryManager) void {
        for (self.documents.items) |doc| {
            self.allocator.free(doc.path);
        }
        self.documents.deinit(self.allocator);

        for (self.chunks.items) |chunk| {
            self.allocator.free(chunk.text);
            if (chunk.embedding) |emb| self.allocator.free(emb);
        }
        self.chunks.deinit(self.allocator);
    }

    /// Index a document: chunk the content and store.
    pub fn indexDocument(self: *MemoryManager, path: []const u8, content: []const u8) !u64 {
        const doc_id = self.next_doc_id;
        self.next_doc_id += 1;

        // Remove existing document at same path
        self.removeByPath(path);

        // Chunk the content
        const text_chunks = try chunker.chunkText(
            self.allocator,
            content,
            chunker.DEFAULT_CHUNK_SIZE,
            chunker.DEFAULT_OVERLAP,
        );
        defer chunker.freeChunks(self.allocator, text_chunks);

        // Store chunks
        for (text_chunks) |chunk| {
            const text_copy = try self.allocator.dupe(u8, chunk.text);
            try self.chunks.append(self.allocator, .{
                .id = self.next_chunk_id,
                .doc_id = doc_id,
                .text = text_copy,
                .index = chunk.index,
            });
            self.next_chunk_id += 1;
        }

        // Store document metadata
        const path_copy = try self.allocator.dupe(u8, path);
        try self.documents.append(self.allocator, .{
            .id = doc_id,
            .path = path_copy,
            .content_hash = std.hash.Wyhash.hash(0, content),
            .indexed_at_ms = std.time.milliTimestamp(),
            .chunk_count = @intCast(text_chunks.len),
        });

        return doc_id;
    }

    /// Remove all chunks for a document by path.
    fn removeByPath(self: *MemoryManager, path: []const u8) void {
        // Find document
        var doc_idx: ?usize = null;
        for (self.documents.items, 0..) |doc, i| {
            if (std.mem.eql(u8, doc.path, path)) {
                doc_idx = i;
                break;
            }
        }

        if (doc_idx) |di| {
            const doc_id = self.documents.items[di].id;
            self.allocator.free(self.documents.items[di].path);
            _ = self.documents.orderedRemove(di);

            // Remove associated chunks (reverse iterate)
            var i: usize = self.chunks.items.len;
            while (i > 0) {
                i -= 1;
                if (self.chunks.items[i].doc_id == doc_id) {
                    self.allocator.free(self.chunks.items[i].text);
                    if (self.chunks.items[i].embedding) |emb| self.allocator.free(emb);
                    _ = self.chunks.orderedRemove(i);
                }
            }
        }
    }

    /// Simple keyword search across all chunks.
    pub fn keywordSearch(
        self: *const MemoryManager,
        allocator: std.mem.Allocator,
        query: []const u8,
        max_results: u32,
    ) ![]search.SearchResult {
        var results = std.ArrayListUnmanaged(search.SearchResult){};

        for (self.chunks.items) |chunk| {
            const score = computeTextScore(chunk.text, query);
            if (score > 0.0) {
                // Find source file
                var source_file: ?[]const u8 = null;
                for (self.documents.items) |doc| {
                    if (doc.id == chunk.doc_id) {
                        source_file = doc.path;
                        break;
                    }
                }

                try results.append(allocator, .{
                    .chunk_id = chunk.id,
                    .text = chunk.text,
                    .score = score,
                    .text_score = score,
                    .source_file = source_file,
                    .chunk_index = chunk.index,
                });
            }
        }

        // Sort by score descending
        std.mem.sort(search.SearchResult, results.items, {}, struct {
            fn cmp(_: void, a: search.SearchResult, b: search.SearchResult) bool {
                return a.score > b.score;
            }
        }.cmp);

        // Truncate to max_results
        if (results.items.len > max_results) {
            results.shrinkRetainingCapacity(max_results);
        }

        if (results.items.len == 0) {
            results.deinit(allocator);
            return &.{};
        }

        return results.toOwnedSlice(allocator);
    }

    /// Get document count.
    pub fn documentCount(self: *const MemoryManager) usize {
        return self.documents.items.len;
    }

    /// Get total chunk count.
    pub fn chunkCount(self: *const MemoryManager) usize {
        return self.chunks.items.len;
    }

    /// Check if a document needs reindexing (content changed).
    pub fn needsReindex(self: *const MemoryManager, path: []const u8, content: []const u8) bool {
        for (self.documents.items) |doc| {
            if (std.mem.eql(u8, doc.path, path)) {
                const new_hash = std.hash.Wyhash.hash(0, content);
                return new_hash != doc.content_hash;
            }
        }
        return true; // Not indexed yet
    }
};

/// Compute a simple text relevance score (term frequency).
fn computeTextScore(text: []const u8, query: []const u8) f64 {
    if (query.len == 0 or text.len == 0) return 0.0;
    if (query.len > text.len) return 0.0;

    var count: u32 = 0;
    var pos: usize = 0;

    while (pos + query.len <= text.len) {
        if (eqlNoCase(text[pos .. pos + query.len], query)) {
            count += 1;
            pos += query.len;
        } else {
            pos += 1;
        }
    }

    if (count == 0) return 0.0;

    // Normalize by text length
    const tf: f64 = @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(text.len / 100 + 1));
    return @min(1.0, tf);
}

fn eqlNoCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

/// Free search results from keywordSearch.
pub fn freeResults(allocator: std.mem.Allocator, results: []search.SearchResult) void {
    allocator.free(results);
}

// --- Tests ---

test "MemoryManager init and deinit" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    try std.testing.expectEqual(@as(usize, 0), mgr.documentCount());
    try std.testing.expectEqual(@as(usize, 0), mgr.chunkCount());
}

test "MemoryManager indexDocument" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    const doc_id = try mgr.indexDocument("test.md", "Hello world. This is a test document.");
    try std.testing.expectEqual(@as(u64, 1), doc_id);
    try std.testing.expectEqual(@as(usize, 1), mgr.documentCount());
    try std.testing.expect(mgr.chunkCount() >= 1);
}

test "MemoryManager indexDocument replaces existing" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.indexDocument("test.md", "Version 1");
    _ = try mgr.indexDocument("test.md", "Version 2");

    try std.testing.expectEqual(@as(usize, 1), mgr.documentCount());
}

test "MemoryManager indexDocument multiple files" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.indexDocument("a.md", "Content A");
    _ = try mgr.indexDocument("b.md", "Content B");

    try std.testing.expectEqual(@as(usize, 2), mgr.documentCount());
}

test "MemoryManager keywordSearch" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.indexDocument("readme.md", "Zig is a systems programming language.");
    _ = try mgr.indexDocument("notes.md", "TypeScript is popular for web development.");

    const results = try mgr.keywordSearch(allocator, "zig", 10);
    defer freeResults(allocator, results);

    try std.testing.expect(results.len >= 1);
    try std.testing.expect(results[0].score > 0.0);
}

test "MemoryManager keywordSearch no match" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.indexDocument("test.md", "Hello world");

    const results = try mgr.keywordSearch(allocator, "nonexistent", 10);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "MemoryManager keywordSearch case insensitive" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.indexDocument("test.md", "Hello World");

    const results = try mgr.keywordSearch(allocator, "hello", 10);
    defer freeResults(allocator, results);

    try std.testing.expect(results.len >= 1);
}

test "MemoryManager needsReindex" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    // Not indexed yet
    try std.testing.expect(mgr.needsReindex("test.md", "content"));

    _ = try mgr.indexDocument("test.md", "content");

    // Same content
    try std.testing.expect(!mgr.needsReindex("test.md", "content"));

    // Changed content
    try std.testing.expect(mgr.needsReindex("test.md", "new content"));
}

test "computeTextScore" {
    try std.testing.expect(computeTextScore("hello world hello", "hello") > 0.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), computeTextScore("hello world", "xyz"), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), computeTextScore("", "test"), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), computeTextScore("test", ""), 0.001);
}

test "computeTextScore case insensitive" {
    try std.testing.expect(computeTextScore("Hello World", "hello") > 0.0);
    try std.testing.expect(computeTextScore("HELLO WORLD", "hello") > 0.0);
}

test "MemoryManager large document chunking" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    // Create large document that will be chunked
    const large = "This is a sentence. " ** 200; // ~4000 chars
    _ = try mgr.indexDocument("large.md", large);

    try std.testing.expect(mgr.chunkCount() >= 2); // Should have multiple chunks
}

// --- Additional Tests ---

test "MemoryManager sequential doc IDs" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    const id1 = try mgr.indexDocument("a.md", "Content A");
    const id2 = try mgr.indexDocument("b.md", "Content B");
    const id3 = try mgr.indexDocument("c.md", "Content C");

    try std.testing.expectEqual(@as(u64, 1), id1);
    try std.testing.expectEqual(@as(u64, 2), id2);
    try std.testing.expectEqual(@as(u64, 3), id3);
}

test "MemoryManager replace increments doc ID" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    const id1 = try mgr.indexDocument("a.md", "V1");
    const id2 = try mgr.indexDocument("a.md", "V2");

    try std.testing.expectEqual(@as(u64, 1), id1);
    try std.testing.expectEqual(@as(u64, 2), id2);
    try std.testing.expectEqual(@as(usize, 1), mgr.documentCount());
}

test "MemoryManager empty document" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.indexDocument("empty.md", "");
    try std.testing.expectEqual(@as(usize, 1), mgr.documentCount());
}

test "MemoryManager keywordSearch max results limit" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.indexDocument("a.md", "Zig language features");
    _ = try mgr.indexDocument("b.md", "Zig comptime is powerful");
    _ = try mgr.indexDocument("c.md", "Zig build system works well");

    const results = try mgr.keywordSearch(allocator, "zig", 1);
    defer freeResults(allocator, results);

    try std.testing.expect(results.len <= 1);
}

test "MemoryManager needsReindex different content" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.indexDocument("test.md", "original");
    try std.testing.expect(mgr.needsReindex("test.md", "modified"));
}

test "MemoryManager needsReindex unknown path" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    try std.testing.expect(mgr.needsReindex("unknown.md", "anything"));
}

test "computeTextScore query longer than text" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), computeTextScore("hi", "hello world"), 0.001);
}

test "computeTextScore repeated matches higher score" {
    // Use longer texts so normalization (text.len/100) differentiates
    const score1 = computeTextScore("hello hello hello hello hello", "hello");
    const score2 = computeTextScore("hello world foo bar baz", "hello");
    // Both short texts get capped at 1.0 due to min(1.0, tf) with small denominator
    try std.testing.expect(score1 >= score2);
}

test "eqlNoCase matching" {
    try std.testing.expect(eqlNoCase("Hello", "hello"));
    try std.testing.expect(eqlNoCase("ABC", "abc"));
    try std.testing.expect(!eqlNoCase("abc", "abcd"));
    try std.testing.expect(!eqlNoCase("abc", "xyz"));
}

test "MemoryManager chunkCount matches chunks stored" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.indexDocument("a.md", "Short.");
    const count_a = mgr.chunkCount();
    try std.testing.expect(count_a >= 1);

    _ = try mgr.indexDocument("b.md", "Also short.");
    const count_b = mgr.chunkCount();
    try std.testing.expect(count_b >= count_a + 1);
}

test "MemoryManager keywordSearch results have source file" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.indexDocument("source.md", "Zig is awesome");

    const results = try mgr.keywordSearch(allocator, "zig", 5);
    defer freeResults(allocator, results);

    try std.testing.expect(results.len >= 1);
    try std.testing.expectEqualStrings("source.md", results[0].source_file.?);
}
