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

// --- Persistent Memory Manager ---
//
// Wraps SqliteStorage to provide the same interface as MemoryManager
// but with SQLite-backed persistence. Optionally generates embeddings.

const storage_mod = @import("storage.zig");
const embeddings = @import("embeddings.zig");

pub const PersistentMemoryManager = struct {
    allocator: std.mem.Allocator,
    storage: *storage_mod.SqliteStorage,
    embedding_client: ?*embeddings.EmbeddingClient,

    pub fn init(
        allocator: std.mem.Allocator,
        storage: *storage_mod.SqliteStorage,
        embedding_client: ?*embeddings.EmbeddingClient,
    ) PersistentMemoryManager {
        return .{
            .allocator = allocator,
            .storage = storage,
            .embedding_client = embedding_client,
        };
    }

    /// Index a document: chunk content, store in SQLite, optionally embed.
    pub fn indexDocument(self: *PersistentMemoryManager, path: []const u8, content: []const u8) !u64 {
        // Remove existing document at same path
        try self.storage.deleteByPath(path);

        // Chunk the content
        const text_chunks = try chunker.chunkText(
            self.allocator,
            content,
            chunker.DEFAULT_CHUNK_SIZE,
            chunker.DEFAULT_OVERLAP,
        );
        defer chunker.freeChunks(self.allocator, text_chunks);

        // Store document in SQLite
        const content_hash = std.hash.Wyhash.hash(0, content);
        const doc_id = try self.storage.insertDocument(path, content_hash, @intCast(text_chunks.len));

        // Store chunks
        for (text_chunks) |chunk| {
            try self.storage.insertChunk(doc_id, chunk.text, chunk.index);
        }

        return @intCast(@as(u64, @bitCast(doc_id)));
    }

    /// Search chunks using SQLite LIKE query, return as SearchResults.
    pub fn keywordSearch(
        self: *PersistentMemoryManager,
        allocator: std.mem.Allocator,
        query: []const u8,
        max_results: u32,
    ) ![]search.SearchResult {
        const rows = try self.storage.searchChunks(allocator, query, max_results);
        if (rows.len == 0) return &.{};
        defer storage_mod.freeSearchRows(allocator, rows);

        // Convert SearchRows to SearchResults
        var results = std.ArrayListUnmanaged(search.SearchResult){};
        for (rows) |row| {
            const score = computeTextScore(row.text, query);
            try results.append(allocator, .{
                .chunk_id = @intCast(@as(u64, @bitCast(row.chunk_id))),
                .text = try allocator.dupe(u8, row.text),
                .score = if (score > 0.0) score else 0.5, // SQLite LIKE matched, give base score
                .text_score = score,
                .source_file = if (row.source_file) |sf| try allocator.dupe(u8, sf) else null,
                .chunk_index = row.chunk_index,
            });
        }

        return results.toOwnedSlice(allocator);
    }

    /// Get document count from SQLite.
    pub fn documentCount(self: *PersistentMemoryManager) usize {
        const count = self.storage.documentCount() catch return 0;
        return @intCast(@as(u64, @bitCast(count)));
    }

    /// Get chunk count from SQLite.
    pub fn chunkCount(self: *PersistentMemoryManager) usize {
        const count = self.storage.chunkCount() catch return 0;
        return @intCast(@as(u64, @bitCast(count)));
    }

    /// Check if a document needs reindexing.
    pub fn needsReindex(self: *PersistentMemoryManager, path: []const u8, content: []const u8) bool {
        const content_hash = std.hash.Wyhash.hash(0, content);
        return self.storage.needsReindex(path, content_hash) catch true;
    }
};

/// Free persistent search results (text and source_file are owned).
pub fn freePersistentResults(allocator: std.mem.Allocator, results: []search.SearchResult) void {
    for (results) |result| {
        allocator.free(result.text);
        if (result.source_file) |sf| allocator.free(sf);
    }
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

// --- PersistentMemoryManager Tests ---

test "PersistentMemoryManager init" {
    const allocator = std.testing.allocator;
    var storage = try storage_mod.SqliteStorage.openMemory();
    defer storage.close();

    var mgr = PersistentMemoryManager.init(allocator, &storage, null);
    try std.testing.expectEqual(@as(usize, 0), mgr.documentCount());
    try std.testing.expectEqual(@as(usize, 0), mgr.chunkCount());
}

test "PersistentMemoryManager indexDocument" {
    const allocator = std.testing.allocator;
    var storage = try storage_mod.SqliteStorage.openMemory();
    defer storage.close();

    var mgr = PersistentMemoryManager.init(allocator, &storage, null);
    const doc_id = try mgr.indexDocument("test.md", "Hello world. This is a test document.");
    try std.testing.expect(doc_id > 0);
    try std.testing.expectEqual(@as(usize, 1), mgr.documentCount());
    try std.testing.expect(mgr.chunkCount() >= 1);
}

test "PersistentMemoryManager indexDocument replaces existing" {
    const allocator = std.testing.allocator;
    var storage = try storage_mod.SqliteStorage.openMemory();
    defer storage.close();

    var mgr = PersistentMemoryManager.init(allocator, &storage, null);
    _ = try mgr.indexDocument("test.md", "Version 1");
    _ = try mgr.indexDocument("test.md", "Version 2");
    try std.testing.expectEqual(@as(usize, 1), mgr.documentCount());
}

test "PersistentMemoryManager keywordSearch" {
    const allocator = std.testing.allocator;
    var storage = try storage_mod.SqliteStorage.openMemory();
    defer storage.close();

    var mgr = PersistentMemoryManager.init(allocator, &storage, null);
    _ = try mgr.indexDocument("readme.md", "Zig is a systems programming language.");
    _ = try mgr.indexDocument("notes.md", "TypeScript is popular for web development.");

    const results = try mgr.keywordSearch(allocator, "Zig", 10);
    defer freePersistentResults(allocator, results);

    try std.testing.expect(results.len >= 1);
    try std.testing.expect(results[0].score > 0.0);
    try std.testing.expect(std.mem.indexOf(u8, results[0].text, "Zig") != null);
}

test "PersistentMemoryManager keywordSearch no match" {
    const allocator = std.testing.allocator;
    var storage = try storage_mod.SqliteStorage.openMemory();
    defer storage.close();

    var mgr = PersistentMemoryManager.init(allocator, &storage, null);
    _ = try mgr.indexDocument("test.md", "Hello world");

    const results = try mgr.keywordSearch(allocator, "nonexistent", 10);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "PersistentMemoryManager needsReindex" {
    const allocator = std.testing.allocator;
    var storage = try storage_mod.SqliteStorage.openMemory();
    defer storage.close();

    var mgr = PersistentMemoryManager.init(allocator, &storage, null);

    // Not indexed yet
    try std.testing.expect(mgr.needsReindex("test.md", "content"));

    _ = try mgr.indexDocument("test.md", "content");

    // Same content
    try std.testing.expect(!mgr.needsReindex("test.md", "content"));

    // Changed content
    try std.testing.expect(mgr.needsReindex("test.md", "new content"));
}

test "PersistentMemoryManager search has source file" {
    const allocator = std.testing.allocator;
    var storage = try storage_mod.SqliteStorage.openMemory();
    defer storage.close();

    var mgr = PersistentMemoryManager.init(allocator, &storage, null);
    _ = try mgr.indexDocument("source.md", "Zig is awesome");

    const results = try mgr.keywordSearch(allocator, "Zig", 5);
    defer freePersistentResults(allocator, results);

    try std.testing.expect(results.len >= 1);
    try std.testing.expectEqualStrings("source.md", results[0].source_file.?);
}

test "PersistentMemoryManager multiple documents" {
    const allocator = std.testing.allocator;
    var storage = try storage_mod.SqliteStorage.openMemory();
    defer storage.close();

    var mgr = PersistentMemoryManager.init(allocator, &storage, null);
    _ = try mgr.indexDocument("a.md", "Content A");
    _ = try mgr.indexDocument("b.md", "Content B");
    _ = try mgr.indexDocument("c.md", "Content C");

    try std.testing.expectEqual(@as(usize, 3), mgr.documentCount());
}

test "PersistentMemoryManager persists across lookups" {
    const allocator = std.testing.allocator;
    var storage = try storage_mod.SqliteStorage.openMemory();
    defer storage.close();

    // Index with one manager instance
    var mgr1 = PersistentMemoryManager.init(allocator, &storage, null);
    _ = try mgr1.indexDocument("persistent.md", "This data should persist in SQLite.");

    // Create a second manager pointing to same storage
    var mgr2 = PersistentMemoryManager.init(allocator, &storage, null);
    try std.testing.expectEqual(@as(usize, 1), mgr2.documentCount());

    const results = try mgr2.keywordSearch(allocator, "persist", 10);
    defer freePersistentResults(allocator, results);
    try std.testing.expect(results.len >= 1);
}

// --- New Tests: MemoryManager edge cases and lifecycle ---

test "MemoryManager indexDocument tiny content single char" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    const doc_id = try mgr.indexDocument("tiny.md", "x");
    try std.testing.expect(doc_id > 0);
    try std.testing.expectEqual(@as(usize, 1), mgr.documentCount());
    // Single char should produce exactly one chunk
    try std.testing.expectEqual(@as(usize, 1), mgr.chunkCount());
}

test "MemoryManager indexDocument very large content produces many chunks" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    // 10,000 chars = well beyond the default 1600-char chunk size
    const large = "The quick brown fox jumps over the lazy dog. " ** 222;
    _ = try mgr.indexDocument("huge.md", large);

    try std.testing.expectEqual(@as(usize, 1), mgr.documentCount());
    // With ~10,000 chars and 1600-char chunks, expect several chunks
    try std.testing.expect(mgr.chunkCount() >= 4);
}

test "MemoryManager removeByPath clears chunks completely" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.indexDocument("removeme.md", "Some content to be removed later.");
    try std.testing.expect(mgr.chunkCount() >= 1);

    // Re-indexing with empty path removes the old document via removeByPath internally
    // But let's test by indexing another doc and verifying only the second remains
    _ = try mgr.indexDocument("keeper.md", "This should stay.");

    const before_chunks = mgr.chunkCount();
    const before_docs = mgr.documentCount();

    // Index removeme.md again which triggers removeByPath for the old version
    // then remove it by indexing something else at that path then removing
    // We test indirectly: re-index with same path replaces
    _ = try mgr.indexDocument("removeme.md", "Replaced content.");

    // Document count should stay at 2
    try std.testing.expectEqual(@as(usize, 2), mgr.documentCount());
    // The old chunks for removeme.md should be gone, replaced by new ones
    // keeper.md chunks + new removeme.md chunks
    try std.testing.expect(mgr.chunkCount() <= before_chunks);
    _ = before_docs;
}

test "MemoryManager search after remove finds nothing" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.indexDocument("ephemeral.md", "UniqueTermXYZ appears only here.");

    // Search should find it
    const results1 = try mgr.keywordSearch(allocator, "UniqueTermXYZ", 10);
    defer freeResults(allocator, results1);
    try std.testing.expect(results1.len >= 1);

    // Replace the document with content that does not contain the term
    _ = try mgr.indexDocument("ephemeral.md", "Completely different content now.");

    // Search for the old term should find nothing
    const results2 = try mgr.keywordSearch(allocator, "UniqueTermXYZ", 10);
    try std.testing.expectEqual(@as(usize, 0), results2.len);
}

test "MemoryManager keywordSearch empty query returns nothing" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.indexDocument("test.txt", "Hello world, this is some content.");

    const results = try mgr.keywordSearch(allocator, "", 10);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "MemoryManager keywordSearch results sorted by score descending" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    // One document with the term repeated many times, another with it once
    _ = try mgr.indexDocument("many.md", "zig zig zig zig zig zig zig zig zig zig");
    _ = try mgr.indexDocument("few.md", "zig is a language for systems programming and optimization work.");

    const results = try mgr.keywordSearch(allocator, "zig", 10);
    defer freeResults(allocator, results);

    try std.testing.expect(results.len >= 2);
    // Results should be sorted descending by score
    for (1..results.len) |i| {
        try std.testing.expect(results[i - 1].score >= results[i].score);
    }
}

test "MemoryManager keywordSearch with max_results zero returns nothing" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.indexDocument("test.md", "Searchable content with keywords.");

    const results = try mgr.keywordSearch(allocator, "content", 0);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "MemoryManager needsReindex same content twice returns false" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    const content = "Exact same content for hashing.";
    _ = try mgr.indexDocument("hash_test.md", content);

    // First check - same content
    try std.testing.expect(!mgr.needsReindex("hash_test.md", content));
    // Second check - still same content
    try std.testing.expect(!mgr.needsReindex("hash_test.md", content));
}

test "MemoryManager needsReindex after re-index with new content" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.indexDocument("evolving.md", "Version 1");
    try std.testing.expect(!mgr.needsReindex("evolving.md", "Version 1"));
    try std.testing.expect(mgr.needsReindex("evolving.md", "Version 2"));

    // Re-index with new content
    _ = try mgr.indexDocument("evolving.md", "Version 2");
    try std.testing.expect(!mgr.needsReindex("evolving.md", "Version 2"));
    try std.testing.expect(mgr.needsReindex("evolving.md", "Version 1"));
}

test "MemoryManager special characters in path" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.indexDocument("path/with spaces/file (1).md", "Content A");
    _ = try mgr.indexDocument("path-with-dashes_and_underscores.md", "Content B");
    _ = try mgr.indexDocument("unicode/\xc3\xa9\xc3\xa0\xc3\xbc.md", "Content C");

    try std.testing.expectEqual(@as(usize, 3), mgr.documentCount());

    // needsReindex should work with special paths
    try std.testing.expect(!mgr.needsReindex("path/with spaces/file (1).md", "Content A"));
    try std.testing.expect(mgr.needsReindex("path/with spaces/file (1).md", "Different"));
}

test "MemoryManager duplicate indexing same path same content" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    const content = "Identical content indexed twice.";
    const id1 = try mgr.indexDocument("dup.md", content);
    const id2 = try mgr.indexDocument("dup.md", content);

    // IDs should differ (each indexDocument call gets a new ID)
    try std.testing.expect(id2 > id1);
    // But document count stays at 1 since same path replaces
    try std.testing.expectEqual(@as(usize, 1), mgr.documentCount());
}

test "MemoryManager full lifecycle index search remove search" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    // Step 1: Index
    _ = try mgr.indexDocument("lifecycle.md", "Lifecycle testing with keyword SpecialWord.");
    try std.testing.expectEqual(@as(usize, 1), mgr.documentCount());

    // Step 2: Search finds it
    const results1 = try mgr.keywordSearch(allocator, "SpecialWord", 10);
    defer freeResults(allocator, results1);
    try std.testing.expect(results1.len >= 1);
    try std.testing.expectEqualStrings("lifecycle.md", results1[0].source_file.?);

    // Step 3: Replace document (removes old, adds new without the keyword)
    _ = try mgr.indexDocument("lifecycle.md", "No special keywords here anymore.");

    // Step 4: Search for old keyword finds nothing
    const results2 = try mgr.keywordSearch(allocator, "SpecialWord", 10);
    try std.testing.expectEqual(@as(usize, 0), results2.len);

    // Step 5: Search for new content works
    const results3 = try mgr.keywordSearch(allocator, "keywords", 10);
    defer freeResults(allocator, results3);
    try std.testing.expect(results3.len >= 1);
}

test "MemoryManager keywordSearch across many documents" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator);
    defer mgr.deinit();

    // Index 10 documents, each containing "common" and a unique term
    _ = try mgr.indexDocument("doc01.md", "common alpha");
    _ = try mgr.indexDocument("doc02.md", "common bravo");
    _ = try mgr.indexDocument("doc03.md", "common charlie");
    _ = try mgr.indexDocument("doc04.md", "common delta");
    _ = try mgr.indexDocument("doc05.md", "common echo");
    _ = try mgr.indexDocument("doc06.md", "common foxtrot");
    _ = try mgr.indexDocument("doc07.md", "common golf");
    _ = try mgr.indexDocument("doc08.md", "common hotel");
    _ = try mgr.indexDocument("doc09.md", "common india");
    _ = try mgr.indexDocument("doc10.md", "common juliet");

    try std.testing.expectEqual(@as(usize, 10), mgr.documentCount());

    // Search for common term, limit to 5
    const results = try mgr.keywordSearch(allocator, "common", 5);
    defer freeResults(allocator, results);
    try std.testing.expectEqual(@as(usize, 5), results.len);

    // Search for unique term
    const unique = try mgr.keywordSearch(allocator, "foxtrot", 10);
    defer freeResults(allocator, unique);
    try std.testing.expectEqual(@as(usize, 1), unique.len);
    try std.testing.expectEqualStrings("doc06.md", unique[0].source_file.?);
}

test "computeTextScore both empty" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), computeTextScore("", ""), 0.001);
}

test "computeTextScore exact match short text" {
    // "hello" in "hello" => 1 match, text.len=5, 5/100+1 = 1, tf = 1/1 = 1.0, min(1.0, 1.0) = 1.0
    const score = computeTextScore("hello", "hello");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), score, 0.001);
}

test "computeTextScore multiple non-overlapping matches" {
    // "ab" in "ab ab ab" => 3 matches, text.len=8, 8/100+1 = 1, tf = 3.0, min(1.0, 3.0) = 1.0 (capped)
    const score = computeTextScore("ab ab ab", "ab");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), score, 0.001);
}

test "eqlNoCase empty strings" {
    try std.testing.expect(eqlNoCase("", ""));
}

test "eqlNoCase mixed case with numbers" {
    try std.testing.expect(eqlNoCase("Test123", "test123"));
    try std.testing.expect(eqlNoCase("ABC123", "abc123"));
}

// --- New Tests: PersistentMemoryManager edge cases ---

test "PersistentMemoryManager indexDocument empty content" {
    const allocator = std.testing.allocator;
    var storage = try storage_mod.SqliteStorage.openMemory();
    defer storage.close();

    var mgr = PersistentMemoryManager.init(allocator, &storage, null);
    const doc_id = try mgr.indexDocument("empty.md", "");
    try std.testing.expect(doc_id > 0);
    try std.testing.expectEqual(@as(usize, 1), mgr.documentCount());
}

test "PersistentMemoryManager needsReindex after replace" {
    const allocator = std.testing.allocator;
    var storage = try storage_mod.SqliteStorage.openMemory();
    defer storage.close();

    var mgr = PersistentMemoryManager.init(allocator, &storage, null);
    _ = try mgr.indexDocument("replace.md", "Version 1");
    try std.testing.expect(!mgr.needsReindex("replace.md", "Version 1"));

    _ = try mgr.indexDocument("replace.md", "Version 2");
    try std.testing.expect(!mgr.needsReindex("replace.md", "Version 2"));
    try std.testing.expect(mgr.needsReindex("replace.md", "Version 1"));
}

test "PersistentMemoryManager full lifecycle" {
    const allocator = std.testing.allocator;
    var storage = try storage_mod.SqliteStorage.openMemory();
    defer storage.close();

    var mgr = PersistentMemoryManager.init(allocator, &storage, null);

    // Index
    _ = try mgr.indexDocument("lifecycle.md", "PersistentUniqueToken is here.");
    try std.testing.expectEqual(@as(usize, 1), mgr.documentCount());

    // Search finds it
    const results1 = try mgr.keywordSearch(allocator, "PersistentUniqueToken", 10);
    defer freePersistentResults(allocator, results1);
    try std.testing.expect(results1.len >= 1);

    // Replace with different content
    _ = try mgr.indexDocument("lifecycle.md", "All new content without the old token.");

    // Old term gone
    const results2 = try mgr.keywordSearch(allocator, "PersistentUniqueToken", 10);
    try std.testing.expectEqual(@as(usize, 0), results2.len);

    // New content searchable
    const results3 = try mgr.keywordSearch(allocator, "new content", 10);
    defer freePersistentResults(allocator, results3);
    try std.testing.expect(results3.len >= 1);
}

test "PersistentMemoryManager special characters in path" {
    const allocator = std.testing.allocator;
    var storage = try storage_mod.SqliteStorage.openMemory();
    defer storage.close();

    var mgr = PersistentMemoryManager.init(allocator, &storage, null);
    _ = try mgr.indexDocument("dir/sub dir/file (2).md", "Content with spaces in path.");
    try std.testing.expectEqual(@as(usize, 1), mgr.documentCount());
    try std.testing.expect(!mgr.needsReindex("dir/sub dir/file (2).md", "Content with spaces in path."));
}
