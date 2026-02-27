const std = @import("std");

// --- Security Audit ---
//
// Path traversal detection and safe binary allowlist.

/// Safe binary commands that are allowed in sandboxed execution.
pub const SAFE_BINARIES = [_][]const u8{
    "ls",     "cat",    "grep",   "find",   "head",
    "tail",   "wc",     "sort",   "uniq",   "cut",
    "sed",    "awk",    "tr",     "echo",   "printf",
    "date",   "env",    "pwd",    "whoami", "hostname",
    "git",    "python", "python3","node",   "zig",
    "cargo",  "go",     "make",   "cmake",  "npm",
    "yarn",   "pnpm",   "bun",    "deno",   "curl",
    "wget",   "jq",     "diff",   "patch",  "file",
    "stat",   "du",     "df",     "uname",  "id",
    "test",   "true",   "false",  "mkdir",  "cp",
    "mv",     "touch",  "chmod",  "basename","dirname",
};

/// Check if a path contains traversal sequences.
pub fn isPathTraversal(path: []const u8) bool {
    // Check for .. sequences
    if (std.mem.indexOf(u8, path, "..") != null) return true;
    // Check for null bytes
    if (std.mem.indexOf(u8, path, "\x00") != null) return true;
    return false;
}

/// Normalize a path by resolving . and removing trailing slashes.
pub fn normalizePath(path: []const u8, output: []u8) []const u8 {
    var fbs = std.io.fixedBufferStream(output);
    const writer = fbs.writer();
    var i: usize = 0;

    while (i < path.len) {
        if (path[i] == '/' and i + 1 < path.len and path[i + 1] == '/') {
            // Skip double slashes
            i += 1;
            continue;
        }
        if (path[i] == '/' and i + 1 < path.len and path[i + 1] == '.' and
            (i + 2 >= path.len or path[i + 2] == '/'))
        {
            // Skip /./
            i += 2;
            continue;
        }
        writer.writeByte(path[i]) catch break;
        i += 1;
    }

    var result = fbs.getWritten();
    // Remove trailing slash (unless root)
    if (result.len > 1 and result[result.len - 1] == '/') {
        result = result[0 .. result.len - 1];
    }

    return result;
}

/// Check if a path is within a base directory.
pub fn isWithinBase(path: []const u8, base: []const u8) bool {
    if (isPathTraversal(path)) return false;
    if (path.len < base.len) return false;

    // Check prefix
    if (!std.mem.startsWith(u8, path, base)) return false;

    // Must be exact match or followed by /
    if (path.len == base.len) return true;
    return path[base.len] == '/';
}

/// Extract the binary name from a command string.
pub fn extractBinaryName(command: []const u8) []const u8 {
    const trimmed = std.mem.trimLeft(u8, command, " \t");
    if (trimmed.len == 0) return "";

    // First, get the first argument (before any space)
    const space_pos = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    const first_arg = trimmed[0..space_pos];

    // Handle path prefixes (/usr/bin/git -> git)
    if (std.mem.lastIndexOf(u8, first_arg, "/")) |slash| {
        return first_arg[slash + 1 ..];
    }

    return first_arg;
}

/// Check if a command uses a safe binary.
pub fn isSafeBinary(command: []const u8) bool {
    const binary = extractBinaryName(command);
    if (binary.len == 0) return false;

    for (SAFE_BINARIES) |safe| {
        if (std.mem.eql(u8, binary, safe)) return true;
    }
    return false;
}

// --- Tests ---

test "isPathTraversal detects .." {
    try std.testing.expect(isPathTraversal("../etc/passwd"));
    try std.testing.expect(isPathTraversal("/home/user/../../etc/passwd"));
    try std.testing.expect(isPathTraversal(".."));
    try std.testing.expect(!isPathTraversal("/home/user/file.txt"));
    try std.testing.expect(!isPathTraversal("relative/path/file"));
}

test "isPathTraversal detects null bytes" {
    try std.testing.expect(isPathTraversal("/etc/passwd\x00.jpg"));
    try std.testing.expect(!isPathTraversal("/etc/passwd"));
}

test "normalizePath double slashes" {
    var buf: [256]u8 = undefined;
    const result = normalizePath("/home//user///file", &buf);
    try std.testing.expectEqualStrings("/home/user/file", result);
}

test "normalizePath dot segments" {
    var buf: [256]u8 = undefined;
    const result = normalizePath("/home/./user/./file", &buf);
    try std.testing.expectEqualStrings("/home/user/file", result);
}

test "normalizePath trailing slash" {
    var buf: [256]u8 = undefined;
    const result = normalizePath("/home/user/", &buf);
    try std.testing.expectEqualStrings("/home/user", result);
}

test "normalizePath root" {
    var buf: [256]u8 = undefined;
    const result = normalizePath("/", &buf);
    try std.testing.expectEqualStrings("/", result);
}

test "isWithinBase valid paths" {
    try std.testing.expect(isWithinBase("/workspace/project/file.txt", "/workspace/project"));
    try std.testing.expect(isWithinBase("/workspace/project", "/workspace/project"));
    try std.testing.expect(isWithinBase("/workspace/project/sub/deep", "/workspace"));
}

test "isWithinBase invalid paths" {
    try std.testing.expect(!isWithinBase("/etc/passwd", "/workspace"));
    try std.testing.expect(!isWithinBase("../escape", "/workspace"));
    try std.testing.expect(!isWithinBase("/workspace2/file", "/workspace"));
}

test "extractBinaryName simple" {
    try std.testing.expectEqualStrings("ls", extractBinaryName("ls -la"));
    try std.testing.expectEqualStrings("git", extractBinaryName("git status"));
    try std.testing.expectEqualStrings("python3", extractBinaryName("python3 script.py"));
}

test "extractBinaryName with path" {
    try std.testing.expectEqualStrings("git", extractBinaryName("/usr/bin/git status"));
    try std.testing.expectEqualStrings("ls", extractBinaryName("/bin/ls"));
}

test "extractBinaryName with leading whitespace" {
    try std.testing.expectEqualStrings("echo", extractBinaryName("  echo hello"));
}

test "extractBinaryName empty" {
    try std.testing.expectEqualStrings("", extractBinaryName(""));
    try std.testing.expectEqualStrings("", extractBinaryName("   "));
}

test "isSafeBinary allowed" {
    try std.testing.expect(isSafeBinary("ls -la"));
    try std.testing.expect(isSafeBinary("git status"));
    try std.testing.expect(isSafeBinary("python3 script.py"));
    try std.testing.expect(isSafeBinary("zig build"));
    try std.testing.expect(isSafeBinary("cargo test"));
    try std.testing.expect(isSafeBinary("node app.js"));
    try std.testing.expect(isSafeBinary("/usr/bin/git pull"));
}

test "isSafeBinary blocked" {
    // Verify extractBinaryName works correctly first
    try std.testing.expectEqualStrings("rm", extractBinaryName("rm -rf /"));
    try std.testing.expectEqualStrings("sudo", extractBinaryName("sudo apt install"));
    try std.testing.expectEqualStrings("shutdown", extractBinaryName("shutdown -h now"));
    try std.testing.expectEqualStrings("dd", extractBinaryName("dd if=/dev/zero of=/dev/sda"));
    try std.testing.expectEqualStrings("", extractBinaryName(""));

    // Now verify they're not in the safe list
    try std.testing.expect(!isSafeBinary("rm -rf /"));
    try std.testing.expect(!isSafeBinary("sudo apt install"));
    try std.testing.expect(!isSafeBinary("shutdown -h now"));
    try std.testing.expect(!isSafeBinary("dd if=/dev/zero"));
    try std.testing.expect(!isSafeBinary(""));
}

// === New Tests (batch 3) ===

test "path traversal detection with encoded dots" {
    // URL-encoded dots (%2e) are literal bytes in the string - isPathTraversal
    // looks for ".." which covers the decoded form. The encoded form "%2e%2e"
    // does not contain ".." so it should not be detected at byte level,
    // but if decoded first it would. Test the raw detection:
    try std.testing.expect(!isPathTraversal("%2e%2e/etc/passwd"));
    // However, the actual ".." sequence is always detected
    try std.testing.expect(isPathTraversal("../etc/passwd"));
    try std.testing.expect(isPathTraversal("/foo/%2e%2e/../etc/passwd"));
}

test "path traversal with null byte" {
    try std.testing.expect(isPathTraversal("file\x00.txt"));
    try std.testing.expect(isPathTraversal("/etc/passwd\x00.jpg"));
    try std.testing.expect(isPathTraversal("\x00"));
    try std.testing.expect(isPathTraversal("normal/path/\x00hidden"));
    // Clean path without null byte should pass
    try std.testing.expect(!isPathTraversal("file.txt"));
}

test "safe binary allowlist" {
    // Common binaries that should be in the allowlist
    try std.testing.expect(isSafeBinary("ls"));
    try std.testing.expect(isSafeBinary("cat file.txt"));
    try std.testing.expect(isSafeBinary("git status"));
    try std.testing.expect(isSafeBinary("grep -r pattern ."));
    try std.testing.expect(isSafeBinary("find . -name '*.zig'"));
    try std.testing.expect(isSafeBinary("head -n 10 file"));
    try std.testing.expect(isSafeBinary("tail -f log.txt"));
    try std.testing.expect(isSafeBinary("wc -l file"));
    try std.testing.expect(isSafeBinary("sort data.csv"));
    try std.testing.expect(isSafeBinary("echo hello"));
    try std.testing.expect(isSafeBinary("python3 script.py"));
    try std.testing.expect(isSafeBinary("node app.js"));
    try std.testing.expect(isSafeBinary("zig build"));
    try std.testing.expect(isSafeBinary("cargo test"));
    try std.testing.expect(isSafeBinary("curl https://example.com"));
    try std.testing.expect(isSafeBinary("jq '.data' response.json"));
    try std.testing.expect(isSafeBinary("mkdir -p dir/sub"));
    try std.testing.expect(isSafeBinary("cp src dst"));
    try std.testing.expect(isSafeBinary("mv old new"));
    try std.testing.expect(isSafeBinary("touch newfile"));
    try std.testing.expect(isSafeBinary("chmod 644 file"));
}

test "unsafe binary detection" {
    try std.testing.expect(!isSafeBinary("rm -rf /"));
    try std.testing.expect(!isSafeBinary("dd if=/dev/zero of=/dev/sda"));
    try std.testing.expect(!isSafeBinary("mkfs.ext4 /dev/sda1"));
    try std.testing.expect(!isSafeBinary("sudo rm -rf /"));
    try std.testing.expect(!isSafeBinary("shutdown -h now"));
    try std.testing.expect(!isSafeBinary("reboot"));
    try std.testing.expect(!isSafeBinary("kill -9 1"));
    try std.testing.expect(!isSafeBinary("fdisk /dev/sda"));
    try std.testing.expect(!isSafeBinary("mount /dev/sda1 /mnt"));
    try std.testing.expect(!isSafeBinary("chown root:root /etc/passwd"));
    try std.testing.expect(!isSafeBinary("iptables -F"));
}

test "path traversal with symlink-like paths" {
    // /tmp/../etc/shadow contains ".."
    try std.testing.expect(isPathTraversal("/tmp/../etc/shadow"));
    try std.testing.expect(isPathTraversal("/var/log/../../../etc/passwd"));
    try std.testing.expect(isPathTraversal("/home/user/../../root/.ssh/id_rsa"));
    // Clean paths that do not traverse
    try std.testing.expect(!isPathTraversal("/tmp/myfile.txt"));
    try std.testing.expect(!isPathTraversal("/etc/shadow"));
}

test "nested traversal" {
    // Multiple levels of traversal
    try std.testing.expect(isPathTraversal("foo/../../bar"));
    try std.testing.expect(isPathTraversal("a/b/c/../../../d"));
    try std.testing.expect(isPathTraversal("../../../../../../etc/passwd"));
    try std.testing.expect(isPathTraversal("deep/path/../../../../root"));
    // Single level still detected
    try std.testing.expect(isPathTraversal("one/../two"));
}

test "Windows-style traversal" {
    // Backslash traversal: "..\\..\\" contains ".." so it's detected
    try std.testing.expect(isPathTraversal("..\\..\\windows\\system32"));
    try std.testing.expect(isPathTraversal("..\\etc\\passwd"));
    try std.testing.expect(isPathTraversal("foo\\..\\bar\\..\\secret"));
    // Mixed forward/backward slashes
    try std.testing.expect(isPathTraversal("foo/..\\bar"));
    try std.testing.expect(isPathTraversal("..\\../etc/passwd"));
}
