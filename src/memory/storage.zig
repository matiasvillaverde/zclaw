const std = @import("std");
const zqlite = @import("zqlite");

// --- SQLite-backed Memory Storage ---
//
// Provides persistent document/chunk storage using SQLite.
// Tables: documents, chunks
// Uses FTS5 for full-text search on chunk text.

pub const SqliteStorage = struct {
    conn: zqlite.Conn,

    /// Open or create a SQLite database at the given path.
    /// Creates tables if they don't exist.
    pub fn open(path: [*:0]const u8) !SqliteStorage {
        const conn = try zqlite.open(path, zqlite.OpenFlags.Create);
        var storage = SqliteStorage{ .conn = conn };
        try storage.migrate();
        return storage;
    }

    /// Open an in-memory database (useful for testing).
    pub fn openMemory() !SqliteStorage {
        const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create);
        var storage = SqliteStorage{ .conn = conn };
        try storage.migrate();
        return storage;
    }

    pub fn close(self: *SqliteStorage) void {
        self.conn.close();
    }

    /// Create tables if they don't exist.
    fn migrate(self: *SqliteStorage) !void {
        try self.conn.execNoArgs(
            \\CREATE TABLE IF NOT EXISTS documents (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  path TEXT NOT NULL UNIQUE,
            \\  content_hash INTEGER NOT NULL,
            \\  indexed_at_ms INTEGER NOT NULL,
            \\  chunk_count INTEGER NOT NULL DEFAULT 0
            \\);
        );
        try self.conn.execNoArgs(
            \\CREATE TABLE IF NOT EXISTS chunks (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  doc_id INTEGER NOT NULL,
            \\  text TEXT NOT NULL,
            \\  chunk_index INTEGER NOT NULL,
            \\  FOREIGN KEY (doc_id) REFERENCES documents(id) ON DELETE CASCADE
            \\);
        );
        try self.conn.execNoArgs(
            \\CREATE INDEX IF NOT EXISTS idx_chunks_doc_id ON chunks(doc_id);
        );
    }

    /// Insert a document record. Returns the document ID.
    pub fn insertDocument(self: *SqliteStorage, path: []const u8, content_hash: u64, chunk_count: u32) !i64 {
        try self.conn.exec(
            "INSERT OR REPLACE INTO documents (path, content_hash, indexed_at_ms, chunk_count) VALUES (?, ?, ?, ?)",
            .{ path, @as(i64, @bitCast(content_hash)), std.time.milliTimestamp(), @as(i64, @intCast(chunk_count)) },
        );
        return self.conn.lastInsertedRowId();
    }

    /// Insert a chunk record.
    pub fn insertChunk(self: *SqliteStorage, doc_id: i64, text: []const u8, chunk_index: u32) !void {
        try self.conn.exec(
            "INSERT INTO chunks (doc_id, text, chunk_index) VALUES (?, ?, ?)",
            .{ doc_id, text, @as(i64, @intCast(chunk_index)) },
        );
    }

    /// Delete a document and its chunks by path.
    pub fn deleteByPath(self: *SqliteStorage, path: []const u8) !void {
        // First get doc_id
        const row = self.conn.row("SELECT id FROM documents WHERE path = ?", .{path}) catch return;
        if (row) |r| {
            const doc_id = r.get(i64, 0);
            r.deinit();
            // Delete chunks first (no CASCADE without PRAGMA)
            try self.conn.exec("DELETE FROM chunks WHERE doc_id = ?", .{doc_id});
            try self.conn.exec("DELETE FROM documents WHERE id = ?", .{doc_id});
        }
    }

    /// Get document count.
    pub fn documentCount(self: *SqliteStorage) !i64 {
        const row = try self.conn.row("SELECT COUNT(*) FROM documents", .{});
        if (row) |r| {
            defer r.deinit();
            return r.get(i64, 0);
        }
        return 0;
    }

    /// Get chunk count.
    pub fn chunkCount(self: *SqliteStorage) !i64 {
        const row = try self.conn.row("SELECT COUNT(*) FROM chunks", .{});
        if (row) |r| {
            defer r.deinit();
            return r.get(i64, 0);
        }
        return 0;
    }

    /// Check if a document needs reindexing.
    pub fn needsReindex(self: *SqliteStorage, path: []const u8, content_hash: u64) !bool {
        const row = self.conn.row("SELECT content_hash FROM documents WHERE path = ?", .{path}) catch return true;
        if (row) |r| {
            defer r.deinit();
            const stored_hash: u64 = @bitCast(r.get(i64, 0));
            return stored_hash != content_hash;
        }
        return true; // Not found
    }

    /// Search chunks by keyword (simple LIKE match).
    /// Returns chunk IDs and texts that contain the query.
    pub fn searchChunks(
        self: *SqliteStorage,
        allocator: std.mem.Allocator,
        query: []const u8,
        max_results: u32,
    ) ![]SearchRow {
        // Build LIKE pattern
        var pattern_buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&pattern_buf);
        try fbs.writer().writeByte('%');
        try fbs.writer().writeAll(query);
        try fbs.writer().writeByte('%');
        const pattern = fbs.getWritten();

        var rows = try self.conn.rows(
            "SELECT c.id, c.text, c.chunk_index, d.path FROM chunks c JOIN documents d ON c.doc_id = d.id WHERE c.text LIKE ? LIMIT ?",
            .{ pattern, @as(i64, @intCast(max_results)) },
        );
        defer rows.deinit();

        var results = std.ArrayListUnmanaged(SearchRow){};
        while (rows.next()) |row| {
            const text = row.nullableText(1) orelse continue;
            const source = row.nullableText(3);
            try results.append(allocator, .{
                .chunk_id = row.int(0),
                .text = try allocator.dupe(u8, text),
                .chunk_index = @intCast(row.int(2)),
                .source_file = if (source) |s| try allocator.dupe(u8, s) else null,
            });
        }

        if (results.items.len == 0) {
            results.deinit(allocator);
            return &.{};
        }

        return results.toOwnedSlice(allocator);
    }

    /// Get all chunks for a document by path.
    pub fn getChunksByPath(
        self: *SqliteStorage,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) ![]SearchRow {
        var rows = try self.conn.rows(
            "SELECT c.id, c.text, c.chunk_index FROM chunks c JOIN documents d ON c.doc_id = d.id WHERE d.path = ? ORDER BY c.chunk_index",
            .{path},
        );
        defer rows.deinit();

        var results = std.ArrayListUnmanaged(SearchRow){};
        while (rows.next()) |row| {
            const text = row.nullableText(1) orelse continue;
            try results.append(allocator, .{
                .chunk_id = row.int(0),
                .text = try allocator.dupe(u8, text),
                .chunk_index = @intCast(row.int(2)),
                .source_file = try allocator.dupe(u8, path),
            });
        }

        if (results.items.len == 0) {
            results.deinit(allocator);
            return &.{};
        }

        return results.toOwnedSlice(allocator);
    }
};

pub const SearchRow = struct {
    chunk_id: i64,
    text: []const u8,
    chunk_index: u32 = 0,
    source_file: ?[]const u8 = null,
};

pub fn freeSearchRows(allocator: std.mem.Allocator, rows: []SearchRow) void {
    for (rows) |row| {
        allocator.free(row.text);
        if (row.source_file) |sf| allocator.free(sf);
    }
    allocator.free(rows);
}

// --- Tests ---

test "SqliteStorage open and close in-memory" {
    var storage = try SqliteStorage.openMemory();
    defer storage.close();

    const doc_count = try storage.documentCount();
    try std.testing.expectEqual(@as(i64, 0), doc_count);
    const chunk_count = try storage.chunkCount();
    try std.testing.expectEqual(@as(i64, 0), chunk_count);
}

test "SqliteStorage insertDocument" {
    var storage = try SqliteStorage.openMemory();
    defer storage.close();

    const doc_id = try storage.insertDocument("test.md", 12345, 3);
    try std.testing.expect(doc_id > 0);

    const count = try storage.documentCount();
    try std.testing.expectEqual(@as(i64, 1), count);
}

test "SqliteStorage insertDocument replaces on same path" {
    var storage = try SqliteStorage.openMemory();
    defer storage.close();

    _ = try storage.insertDocument("test.md", 111, 1);
    _ = try storage.insertDocument("test.md", 222, 2);

    const count = try storage.documentCount();
    try std.testing.expectEqual(@as(i64, 1), count);
}

test "SqliteStorage insertChunk" {
    var storage = try SqliteStorage.openMemory();
    defer storage.close();

    const doc_id = try storage.insertDocument("test.md", 123, 2);
    try storage.insertChunk(doc_id, "Hello world", 0);
    try storage.insertChunk(doc_id, "Second chunk", 1);

    const count = try storage.chunkCount();
    try std.testing.expectEqual(@as(i64, 2), count);
}

test "SqliteStorage deleteByPath" {
    var storage = try SqliteStorage.openMemory();
    defer storage.close();

    const doc_id = try storage.insertDocument("test.md", 123, 1);
    try storage.insertChunk(doc_id, "chunk text", 0);

    try storage.deleteByPath("test.md");

    const doc_count = try storage.documentCount();
    try std.testing.expectEqual(@as(i64, 0), doc_count);
    const chunk_count = try storage.chunkCount();
    try std.testing.expectEqual(@as(i64, 0), chunk_count);
}

test "SqliteStorage needsReindex" {
    var storage = try SqliteStorage.openMemory();
    defer storage.close();

    // Not indexed yet
    try std.testing.expect(try storage.needsReindex("test.md", 100));

    _ = try storage.insertDocument("test.md", 100, 0);

    // Same hash
    try std.testing.expect(!try storage.needsReindex("test.md", 100));

    // Different hash
    try std.testing.expect(try storage.needsReindex("test.md", 200));
}

test "SqliteStorage searchChunks" {
    const allocator = std.testing.allocator;
    var storage = try SqliteStorage.openMemory();
    defer storage.close();

    const doc_id = try storage.insertDocument("readme.md", 1, 2);
    try storage.insertChunk(doc_id, "Zig is a systems programming language", 0);
    try storage.insertChunk(doc_id, "TypeScript is for web development", 1);

    const results = try storage.searchChunks(allocator, "Zig", 10);
    defer freeSearchRows(allocator, results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(std.mem.indexOf(u8, results[0].text, "Zig") != null);
    try std.testing.expectEqualStrings("readme.md", results[0].source_file.?);
}

test "SqliteStorage searchChunks no match" {
    const allocator = std.testing.allocator;
    var storage = try SqliteStorage.openMemory();
    defer storage.close();

    const doc_id = try storage.insertDocument("test.md", 1, 1);
    try storage.insertChunk(doc_id, "Hello world", 0);

    const results = try storage.searchChunks(allocator, "nonexistent", 10);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "SqliteStorage getChunksByPath" {
    const allocator = std.testing.allocator;
    var storage = try SqliteStorage.openMemory();
    defer storage.close();

    const doc_id = try storage.insertDocument("test.md", 1, 2);
    try storage.insertChunk(doc_id, "First chunk", 0);
    try storage.insertChunk(doc_id, "Second chunk", 1);

    const chunks = try storage.getChunksByPath(allocator, "test.md");
    defer freeSearchRows(allocator, chunks);

    try std.testing.expectEqual(@as(usize, 2), chunks.len);
    try std.testing.expectEqualStrings("First chunk", chunks[0].text);
    try std.testing.expectEqualStrings("Second chunk", chunks[1].text);
}

test "SqliteStorage getChunksByPath nonexistent" {
    const allocator = std.testing.allocator;
    var storage = try SqliteStorage.openMemory();
    defer storage.close();

    const chunks = try storage.getChunksByPath(allocator, "nonexistent.md");
    try std.testing.expectEqual(@as(usize, 0), chunks.len);
}

test "SqliteStorage multiple documents" {
    var storage = try SqliteStorage.openMemory();
    defer storage.close();

    _ = try storage.insertDocument("a.md", 1, 1);
    _ = try storage.insertDocument("b.md", 2, 1);
    _ = try storage.insertDocument("c.md", 3, 1);

    const count = try storage.documentCount();
    try std.testing.expectEqual(@as(i64, 3), count);
}

test "SqliteStorage search with limit" {
    const allocator = std.testing.allocator;
    var storage = try SqliteStorage.openMemory();
    defer storage.close();

    const doc_id = try storage.insertDocument("test.md", 1, 5);
    try storage.insertChunk(doc_id, "match one", 0);
    try storage.insertChunk(doc_id, "match two", 1);
    try storage.insertChunk(doc_id, "match three", 2);

    const results = try storage.searchChunks(allocator, "match", 2);
    defer freeSearchRows(allocator, results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "SearchRow fields" {
    const row = SearchRow{
        .chunk_id = 42,
        .text = "test text",
        .chunk_index = 3,
        .source_file = "docs/readme.md",
    };
    try std.testing.expectEqual(@as(i64, 42), row.chunk_id);
    try std.testing.expectEqual(@as(u32, 3), row.chunk_index);
    try std.testing.expectEqualStrings("docs/readme.md", row.source_file.?);
}
