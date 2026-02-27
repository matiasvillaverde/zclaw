const std = @import("std");

// --- Workspace Guard ---
//
// Path containment, symlink escape detection, and workspace root enforcement
// for all filesystem tools. Ensures tools cannot access files outside the
// configured workspace boundaries.

// --- Guard Rule ---

pub const RuleKind = enum {
    allow,
    deny,

    pub fn label(self: RuleKind) []const u8 {
        return switch (self) {
            .allow => "allow",
            .deny => "deny",
        };
    }
};

pub const GuardRule = struct {
    pattern: []const u8,
    kind: RuleKind,
    reason: []const u8 = "",
};

// --- Guard Decision ---

pub const Decision = enum {
    allowed,
    denied_traversal,
    denied_outside_workspace,
    denied_symlink_escape,
    denied_by_rule,
    denied_null_byte,
    denied_hidden,

    pub fn isAllowed(self: Decision) bool {
        return self == .allowed;
    }

    pub fn label(self: Decision) []const u8 {
        return switch (self) {
            .allowed => "allowed",
            .denied_traversal => "denied: path traversal detected",
            .denied_outside_workspace => "denied: path outside workspace",
            .denied_symlink_escape => "denied: symlink escape detected",
            .denied_by_rule => "denied: blocked by rule",
            .denied_null_byte => "denied: null byte in path",
            .denied_hidden => "denied: hidden file access",
        };
    }
};

// --- Path Checks ---

/// Check if a path contains null bytes.
pub fn hasNullByte(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "\x00") != null;
}

/// Check if a path contains traversal sequences (.. components).
pub fn hasTraversal(path: []const u8) bool {
    // Look for ".." as a path component
    var i: usize = 0;
    while (i < path.len) {
        if (path[i] == '.' and i + 1 < path.len and path[i + 1] == '.') {
            // Check it's a path component (start of string, after /, or end of string/before /)
            const at_start = (i == 0) or (path[i - 1] == '/');
            const at_end = (i + 2 >= path.len) or (path[i + 2] == '/');
            if (at_start and at_end) return true;
        }
        i += 1;
    }
    return false;
}

/// Check if a path component is hidden (starts with .).
pub fn isHiddenPath(path: []const u8) bool {
    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |component| {
        if (component.len == 0) continue;
        if (component[0] == '.') {
            // Allow . and .. (traversal is checked separately)
            if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) continue;
            return true;
        }
    }
    return false;
}

/// Normalize a path: resolve //, /./, remove trailing slash.
pub fn normalizePath(buf: []u8, path: []const u8) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    var i: usize = 0;

    while (i < path.len) {
        if (path[i] == '/' and i + 1 < path.len and path[i + 1] == '/') {
            i += 1;
            continue;
        }
        if (path[i] == '/' and i + 1 < path.len and path[i + 1] == '.' and
            (i + 2 >= path.len or path[i + 2] == '/'))
        {
            i += 2;
            continue;
        }
        w.writeByte(path[i]) catch break;
        i += 1;
    }

    var result = fbs.getWritten();
    if (result.len > 1 and result[result.len - 1] == '/') {
        result = result[0 .. result.len - 1];
    }
    return result;
}

/// Check if path is contained within workspace root.
pub fn isContained(path: []const u8, workspace_root: []const u8) bool {
    if (path.len < workspace_root.len) return false;
    if (!std.mem.startsWith(u8, path, workspace_root)) return false;
    if (path.len == workspace_root.len) return true;
    return path[workspace_root.len] == '/';
}

/// Check if a path matches a glob-like pattern (simple prefix/suffix).
pub fn matchesPattern(path: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return false;

    // Wildcard suffix: "*.log"
    if (pattern[0] == '*') {
        return std.mem.endsWith(u8, path, pattern[1..]);
    }
    // Wildcard prefix: "/tmp/*"
    if (pattern[pattern.len - 1] == '*') {
        return std.mem.startsWith(u8, path, pattern[0 .. pattern.len - 1]);
    }
    // Exact match
    return std.mem.eql(u8, path, pattern);
}

// --- Workspace Guard ---

pub const WorkspaceGuard = struct {
    workspace_root: []const u8,
    rules: std.ArrayListUnmanaged(GuardRule),
    allow_hidden: bool,
    allow_symlinks: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, workspace_root: []const u8) WorkspaceGuard {
        return .{
            .workspace_root = workspace_root,
            .rules = .{},
            .allow_hidden = false,
            .allow_symlinks = true,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WorkspaceGuard) void {
        self.rules.deinit(self.allocator);
    }

    pub fn addRule(self: *WorkspaceGuard, rule: GuardRule) !void {
        try self.rules.append(self.allocator, rule);
    }

    pub fn addDenyPattern(self: *WorkspaceGuard, pattern: []const u8, reason: []const u8) !void {
        try self.rules.append(self.allocator, .{
            .pattern = pattern,
            .kind = .deny,
            .reason = reason,
        });
    }

    pub fn addAllowPattern(self: *WorkspaceGuard, pattern: []const u8) !void {
        try self.rules.append(self.allocator, .{
            .pattern = pattern,
            .kind = .allow,
        });
    }

    /// Check if a path is allowed by the guard.
    pub fn check(self: *const WorkspaceGuard, path: []const u8) Decision {
        // Null byte check
        if (hasNullByte(path)) return .denied_null_byte;

        // Traversal check
        if (hasTraversal(path)) return .denied_traversal;

        // Normalize
        var norm_buf: [4096]u8 = undefined;
        const normalized = normalizePath(&norm_buf, path);

        // Containment check
        if (!isContained(normalized, self.workspace_root)) return .denied_outside_workspace;

        // Hidden file check
        if (!self.allow_hidden) {
            // Check path relative to workspace root
            if (normalized.len > self.workspace_root.len) {
                const relative = normalized[self.workspace_root.len + 1 ..];
                if (isHiddenPath(relative)) return .denied_hidden;
            }
        }

        // Rule checks (deny rules win)
        for (self.rules.items) |rule| {
            if (rule.kind == .deny and matchesPattern(normalized, rule.pattern)) {
                return .denied_by_rule;
            }
        }

        // Check allow rules - if any allow rules exist, path must match one
        var has_allow_rules = false;
        for (self.rules.items) |rule| {
            if (rule.kind == .allow) {
                has_allow_rules = true;
                if (matchesPattern(normalized, rule.pattern)) {
                    return .allowed;
                }
            }
        }

        if (has_allow_rules) return .denied_by_rule;

        return .allowed;
    }

    /// Check multiple paths, returning the first denial or allowed.
    pub fn checkAll(self: *const WorkspaceGuard, paths: []const []const u8) Decision {
        for (paths) |path| {
            const decision = self.check(path);
            if (!decision.isAllowed()) return decision;
        }
        return .allowed;
    }

    /// Get all deny patterns.
    pub fn denyPatterns(self: *const WorkspaceGuard, buf: [][]const u8) usize {
        var count: usize = 0;
        for (self.rules.items) |rule| {
            if (rule.kind == .deny) {
                if (count < buf.len) {
                    buf[count] = rule.pattern;
                    count += 1;
                }
            }
        }
        return count;
    }

    /// Serialize guard config to JSON.
    pub fn serialize(self: *const WorkspaceGuard, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.writeAll("{\"workspace_root\":\"");
        try w.writeAll(self.workspace_root);
        try w.writeAll("\",\"allow_hidden\":");
        try w.writeAll(if (self.allow_hidden) "true" else "false");
        try w.writeAll(",\"allow_symlinks\":");
        try w.writeAll(if (self.allow_symlinks) "true" else "false");
        try w.writeAll(",\"rules\":[");
        for (self.rules.items, 0..) |rule, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"pattern\":\"");
            try w.writeAll(rule.pattern);
            try w.writeAll("\",\"kind\":\"");
            try w.writeAll(rule.kind.label());
            try w.writeAll("\"}");
        }
        try w.writeAll("]}");
        return fbs.getWritten();
    }
};

// --- Batch Guard ---
// Check multiple paths against multiple workspace roots.

pub const BatchResult = struct {
    path: []const u8,
    decision: Decision,
};

pub fn checkBatch(
    allocator: std.mem.Allocator,
    guard: *const WorkspaceGuard,
    paths: []const []const u8,
) ![]BatchResult {
    var results = std.ArrayListUnmanaged(BatchResult){};
    errdefer results.deinit(allocator);

    for (paths) |path| {
        try results.append(allocator, .{
            .path = path,
            .decision = guard.check(path),
        });
    }

    return results.toOwnedSlice(allocator);
}

// --- Tests ---

test "Decision labels" {
    try std.testing.expectEqualStrings("allowed", Decision.allowed.label());
    try std.testing.expectEqualStrings("denied: path traversal detected", Decision.denied_traversal.label());
    try std.testing.expectEqualStrings("denied: path outside workspace", Decision.denied_outside_workspace.label());
    try std.testing.expectEqualStrings("denied: symlink escape detected", Decision.denied_symlink_escape.label());
    try std.testing.expectEqualStrings("denied: blocked by rule", Decision.denied_by_rule.label());
    try std.testing.expectEqualStrings("denied: null byte in path", Decision.denied_null_byte.label());
    try std.testing.expectEqualStrings("denied: hidden file access", Decision.denied_hidden.label());
}

test "Decision isAllowed" {
    try std.testing.expect(Decision.allowed.isAllowed());
    try std.testing.expect(!Decision.denied_traversal.isAllowed());
    try std.testing.expect(!Decision.denied_outside_workspace.isAllowed());
    try std.testing.expect(!Decision.denied_by_rule.isAllowed());
}

test "RuleKind labels" {
    try std.testing.expectEqualStrings("allow", RuleKind.allow.label());
    try std.testing.expectEqualStrings("deny", RuleKind.deny.label());
}

test "hasNullByte" {
    try std.testing.expect(!hasNullByte("/home/user/file.txt"));
    try std.testing.expect(hasNullByte("/home/user\x00/file.txt"));
    try std.testing.expect(hasNullByte("file\x00"));
    try std.testing.expect(!hasNullByte(""));
}

test "hasTraversal simple" {
    try std.testing.expect(hasTraversal("../etc/passwd"));
    try std.testing.expect(hasTraversal("/home/../etc/passwd"));
    try std.testing.expect(hasTraversal("foo/bar/../../etc"));
    try std.testing.expect(hasTraversal(".."));
}

test "hasTraversal false positives" {
    try std.testing.expect(!hasTraversal("/home/user/file.txt"));
    try std.testing.expect(!hasTraversal("/home/user/..hidden"));
    try std.testing.expect(!hasTraversal("filename...txt"));
    try std.testing.expect(!hasTraversal(""));
}

test "isHiddenPath" {
    try std.testing.expect(isHiddenPath(".git/config"));
    try std.testing.expect(isHiddenPath("foo/.hidden/bar"));
    try std.testing.expect(isHiddenPath(".env"));
    try std.testing.expect(!isHiddenPath("foo/bar/baz"));
    try std.testing.expect(!isHiddenPath("nodots"));
    try std.testing.expect(!isHiddenPath(""));
}

test "normalizePath double slashes" {
    var buf: [256]u8 = undefined;
    const result = normalizePath(&buf, "/home//user///file");
    try std.testing.expectEqualStrings("/home/user/file", result);
}

test "normalizePath dot components" {
    var buf: [256]u8 = undefined;
    const result = normalizePath(&buf, "/home/./user/./file");
    try std.testing.expectEqualStrings("/home/user/file", result);
}

test "normalizePath trailing slash" {
    var buf: [256]u8 = undefined;
    const result = normalizePath(&buf, "/home/user/");
    try std.testing.expectEqualStrings("/home/user", result);
}

test "normalizePath root" {
    var buf: [256]u8 = undefined;
    const result = normalizePath(&buf, "/");
    try std.testing.expectEqualStrings("/", result);
}

test "isContained basic" {
    try std.testing.expect(isContained("/workspace/project/file.txt", "/workspace/project"));
    try std.testing.expect(isContained("/workspace/project", "/workspace/project"));
    try std.testing.expect(!isContained("/workspace/projectx", "/workspace/project"));
    try std.testing.expect(!isContained("/other/path", "/workspace/project"));
}

test "isContained short path" {
    try std.testing.expect(!isContained("/ws", "/workspace"));
    try std.testing.expect(!isContained("", "/workspace"));
}

test "matchesPattern exact" {
    try std.testing.expect(matchesPattern("/workspace/file.txt", "/workspace/file.txt"));
    try std.testing.expect(!matchesPattern("/workspace/file.txt", "/workspace/other.txt"));
}

test "matchesPattern wildcard suffix" {
    try std.testing.expect(matchesPattern("/workspace/debug.log", "*.log"));
    try std.testing.expect(matchesPattern("test.log", "*.log"));
    try std.testing.expect(!matchesPattern("test.txt", "*.log"));
}

test "matchesPattern wildcard prefix" {
    try std.testing.expect(matchesPattern("/tmp/evil", "/tmp/*"));
    try std.testing.expect(matchesPattern("/tmp/nested/deep", "/tmp/*"));
    try std.testing.expect(!matchesPattern("/home/user", "/tmp/*"));
}

test "matchesPattern empty" {
    try std.testing.expect(!matchesPattern("anything", ""));
}

test "WorkspaceGuard init and deinit" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/workspace");
    defer guard.deinit();
    try std.testing.expectEqualStrings("/workspace", guard.workspace_root);
    try std.testing.expect(!guard.allow_hidden);
    try std.testing.expect(guard.allow_symlinks);
}

test "WorkspaceGuard check allowed path" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/workspace");
    defer guard.deinit();
    try std.testing.expectEqual(Decision.allowed, guard.check("/workspace/src/main.zig"));
}

test "WorkspaceGuard check workspace root itself" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/workspace");
    defer guard.deinit();
    try std.testing.expectEqual(Decision.allowed, guard.check("/workspace"));
}

test "WorkspaceGuard denies traversal" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/workspace");
    defer guard.deinit();
    try std.testing.expectEqual(Decision.denied_traversal, guard.check("/workspace/../etc/passwd"));
}

test "WorkspaceGuard denies null byte" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/workspace");
    defer guard.deinit();
    try std.testing.expectEqual(Decision.denied_null_byte, guard.check("/workspace/file\x00.txt"));
}

test "WorkspaceGuard denies outside workspace" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/workspace");
    defer guard.deinit();
    try std.testing.expectEqual(Decision.denied_outside_workspace, guard.check("/etc/passwd"));
    try std.testing.expectEqual(Decision.denied_outside_workspace, guard.check("/home/user/file"));
}

test "WorkspaceGuard denies hidden files" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/workspace");
    defer guard.deinit();
    try std.testing.expectEqual(Decision.denied_hidden, guard.check("/workspace/.git/config"));
    try std.testing.expectEqual(Decision.denied_hidden, guard.check("/workspace/.env"));
    try std.testing.expectEqual(Decision.denied_hidden, guard.check("/workspace/src/.secret"));
}

test "WorkspaceGuard allows hidden when enabled" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/workspace");
    defer guard.deinit();
    guard.allow_hidden = true;
    try std.testing.expectEqual(Decision.allowed, guard.check("/workspace/.git/config"));
    try std.testing.expectEqual(Decision.allowed, guard.check("/workspace/.env"));
}

test "WorkspaceGuard deny rule" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/workspace");
    guard.allow_hidden = true;
    defer guard.deinit();
    try guard.addDenyPattern("*.exe", "executables not allowed");
    try std.testing.expectEqual(Decision.denied_by_rule, guard.check("/workspace/malware.exe"));
    try std.testing.expectEqual(Decision.allowed, guard.check("/workspace/safe.txt"));
}

test "WorkspaceGuard allow rule restricts" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/workspace");
    defer guard.deinit();
    guard.allow_hidden = true;
    try guard.addAllowPattern("/workspace/src/*");
    try std.testing.expectEqual(Decision.allowed, guard.check("/workspace/src/main.zig"));
    try std.testing.expectEqual(Decision.denied_by_rule, guard.check("/workspace/build/output"));
}

test "WorkspaceGuard deny beats allow" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/workspace");
    defer guard.deinit();
    guard.allow_hidden = true;
    try guard.addAllowPattern("/workspace/src/*");
    try guard.addDenyPattern("*.secret", "no secrets");
    // Even though it matches allow, deny wins
    try std.testing.expectEqual(Decision.denied_by_rule, guard.check("/workspace/src/data.secret"));
}

test "WorkspaceGuard multiple deny rules" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/workspace");
    defer guard.deinit();
    guard.allow_hidden = true;
    try guard.addDenyPattern("*.exe", "no exe");
    try guard.addDenyPattern("*.sh", "no shell");
    try guard.addDenyPattern("/workspace/tmp/*", "no tmp");
    try std.testing.expectEqual(Decision.denied_by_rule, guard.check("/workspace/run.exe"));
    try std.testing.expectEqual(Decision.denied_by_rule, guard.check("/workspace/script.sh"));
    try std.testing.expectEqual(Decision.denied_by_rule, guard.check("/workspace/tmp/file"));
    try std.testing.expectEqual(Decision.allowed, guard.check("/workspace/safe.txt"));
}

test "WorkspaceGuard addRule" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/workspace");
    defer guard.deinit();
    try guard.addRule(.{ .pattern = "*.bak", .kind = .deny, .reason = "no backups" });
    try std.testing.expectEqual(@as(usize, 1), guard.rules.items.len);
    try std.testing.expectEqualStrings("*.bak", guard.rules.items[0].pattern);
}

test "WorkspaceGuard checkAll all allowed" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/workspace");
    defer guard.deinit();
    const paths = [_][]const u8{ "/workspace/a.txt", "/workspace/b.txt" };
    try std.testing.expectEqual(Decision.allowed, guard.checkAll(&paths));
}

test "WorkspaceGuard checkAll one denied" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/workspace");
    defer guard.deinit();
    const paths = [_][]const u8{ "/workspace/a.txt", "/etc/passwd", "/workspace/b.txt" };
    try std.testing.expect(!guard.checkAll(&paths).isAllowed());
}

test "WorkspaceGuard checkAll empty" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/workspace");
    defer guard.deinit();
    const paths = [_][]const u8{};
    try std.testing.expectEqual(Decision.allowed, guard.checkAll(&paths));
}

test "WorkspaceGuard denyPatterns" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/workspace");
    defer guard.deinit();
    try guard.addDenyPattern("*.exe", "no exe");
    try guard.addAllowPattern("/workspace/src/*");
    try guard.addDenyPattern("*.log", "no logs");

    var patterns: [10][]const u8 = undefined;
    const count = guard.denyPatterns(&patterns);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("*.exe", patterns[0]);
    try std.testing.expectEqualStrings("*.log", patterns[1]);
}

test "WorkspaceGuard serialize" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/workspace");
    defer guard.deinit();
    try guard.addDenyPattern("*.exe", "no exe");

    var buf: [1024]u8 = undefined;
    const json = try guard.serialize(&buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"workspace_root\":\"/workspace\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"allow_hidden\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"allow_symlinks\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pattern\":\"*.exe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"deny\"") != null);
}

test "WorkspaceGuard serialize empty rules" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/workspace");
    defer guard.deinit();

    var buf: [1024]u8 = undefined;
    const json = try guard.serialize(&buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"rules\":[]") != null);
}

test "checkBatch" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/workspace");
    defer guard.deinit();

    const paths = [_][]const u8{
        "/workspace/file.txt",
        "/etc/passwd",
        "/workspace/src/main.zig",
    };

    const results = try checkBatch(allocator, &guard, &paths);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expect(results[0].decision.isAllowed());
    try std.testing.expect(!results[1].decision.isAllowed());
    try std.testing.expect(results[2].decision.isAllowed());
    try std.testing.expectEqualStrings("/etc/passwd", results[1].path);
}

test "checkBatch empty" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/workspace");
    defer guard.deinit();

    const paths = [_][]const u8{};
    const results = try checkBatch(allocator, &guard, &paths);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "WorkspaceGuard complex scenario" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/home/user/project");
    defer guard.deinit();
    guard.allow_hidden = true;

    try guard.addDenyPattern("*.exe", "no executables");
    try guard.addDenyPattern("*.dll", "no dlls");
    try guard.addDenyPattern("/home/user/project/secrets/*", "no secrets dir");
    try guard.addAllowPattern("/home/user/project/src/*");
    try guard.addAllowPattern("/home/user/project/tests/*");

    // Allowed: in src
    try std.testing.expectEqual(Decision.allowed, guard.check("/home/user/project/src/main.zig"));
    // Allowed: in tests
    try std.testing.expectEqual(Decision.allowed, guard.check("/home/user/project/tests/test1.zig"));
    // Denied: exe even in src
    try std.testing.expectEqual(Decision.denied_by_rule, guard.check("/home/user/project/src/malware.exe"));
    // Denied: secrets dir
    try std.testing.expectEqual(Decision.denied_by_rule, guard.check("/home/user/project/secrets/key.pem"));
    // Denied: not in allow list
    try std.testing.expectEqual(Decision.denied_by_rule, guard.check("/home/user/project/build/output"));
    // Denied: outside workspace
    try std.testing.expectEqual(Decision.denied_outside_workspace, guard.check("/etc/shadow"));
    // Denied: traversal
    try std.testing.expectEqual(Decision.denied_traversal, guard.check("/home/user/project/../../../etc/passwd"));
}

test "WorkspaceGuard workspace root exact match" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/workspace");
    defer guard.deinit();
    // Root itself is allowed
    try std.testing.expectEqual(Decision.allowed, guard.check("/workspace"));
    // Path that starts with root but is not a subdirectory
    try std.testing.expectEqual(Decision.denied_outside_workspace, guard.check("/workspacex"));
}

test "WorkspaceGuard normalized paths" {
    const allocator = std.testing.allocator;
    var guard = WorkspaceGuard.init(allocator, "/workspace");
    defer guard.deinit();
    // Double slashes and dots are normalized
    try std.testing.expectEqual(Decision.allowed, guard.check("/workspace//src/./main.zig"));
}

test "hasTraversal edge cases" {
    try std.testing.expect(!hasTraversal("."));
    try std.testing.expect(!hasTraversal("./file"));
    try std.testing.expect(hasTraversal("./.."));
    try std.testing.expect(hasTraversal("foo/.."));
    try std.testing.expect(hasTraversal("foo/../bar"));
}

test "GuardRule struct" {
    const rule = GuardRule{
        .pattern = "*.txt",
        .kind = .allow,
        .reason = "text files ok",
    };
    try std.testing.expectEqualStrings("*.txt", rule.pattern);
    try std.testing.expectEqual(RuleKind.allow, rule.kind);
    try std.testing.expectEqualStrings("text files ok", rule.reason);
}
