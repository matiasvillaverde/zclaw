const std = @import("std");

// --- System Prompt Builder ---

/// Builds the system prompt from identity, skills, and memory files.
/// Returns allocated string that caller must free.
pub fn buildSystemPrompt(
    allocator: std.mem.Allocator,
    identity: ?[]const u8,
    skills: ?[]const u8,
    memory: ?[]const u8,
    extra_context: ?[]const u8,
) ![]const u8 {
    var parts = std.ArrayListUnmanaged(u8){};
    defer parts.deinit(allocator);

    // Identity section (required)
    if (identity) |id| {
        try parts.appendSlice(allocator, id);
    } else {
        try parts.appendSlice(allocator, DEFAULT_IDENTITY);
    }

    // Skills section
    if (skills) |sk| {
        try parts.appendSlice(allocator, "\n\n## Skills\n\n");
        try parts.appendSlice(allocator, sk);
    }

    // Memory section
    if (memory) |mem| {
        try parts.appendSlice(allocator, "\n\n## Memory\n\n");
        try parts.appendSlice(allocator, mem);
    }

    // Extra context
    if (extra_context) |ctx| {
        try parts.appendSlice(allocator, "\n\n## Context\n\n");
        try parts.appendSlice(allocator, ctx);
    }

    return try allocator.dupe(u8, parts.items);
}

pub const DEFAULT_IDENTITY =
    \\You are a helpful AI assistant. You are running as an agent in the zclaw gateway.
    \\Follow user instructions carefully. Be concise and accurate.
;

/// Load a prompt file from disk. Returns null if file doesn't exist.
pub fn loadPromptFile(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    return file.readToEndAlloc(allocator, 1024 * 1024) catch null;
}

/// Build system prompt from agent directory structure.
/// Looks for IDENTITY.md, SKILLS.md, MEMORY.md in the agent dir.
pub fn buildFromAgentDir(
    allocator: std.mem.Allocator,
    agent_dir: []const u8,
) ![]const u8 {
    var path_buf: [4096]u8 = undefined;

    const identity = blk: {
        const path = std.fmt.bufPrint(&path_buf, "{s}/IDENTITY.md", .{agent_dir}) catch break :blk null;
        break :blk loadPromptFile(allocator, path);
    };
    defer if (identity) |id| allocator.free(id);

    const skills = blk: {
        const path = std.fmt.bufPrint(&path_buf, "{s}/SKILLS.md", .{agent_dir}) catch break :blk null;
        break :blk loadPromptFile(allocator, path);
    };
    defer if (skills) |sk| allocator.free(sk);

    const memory = blk: {
        const path = std.fmt.bufPrint(&path_buf, "{s}/MEMORY.md", .{agent_dir}) catch break :blk null;
        break :blk loadPromptFile(allocator, path);
    };
    defer if (memory) |mem| allocator.free(mem);

    return buildSystemPrompt(allocator, identity, skills, memory, null);
}

// --- Tests ---

test "buildSystemPrompt with all parts" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(
        allocator,
        "I am TestBot.",
        "I can search and answer.",
        "User prefers short answers.",
        "Current date: 2024-01-01",
    );
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "I am TestBot.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Skills") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "I can search and answer.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "User prefers short answers.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Context") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Current date: 2024-01-01") != null);
}

test "buildSystemPrompt with defaults" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, null, null, null, null);
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "helpful AI assistant") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Skills") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Memory") == null);
}

test "buildSystemPrompt identity only" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, "Custom identity", null, null, null);
    defer allocator.free(prompt);

    try std.testing.expectEqualStrings("Custom identity", prompt);
}

test "buildSystemPrompt with skills only" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, "Bot", "Can code", null, null);
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Bot") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Skills") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Can code") != null);
}

test "loadPromptFile nonexistent" {
    const allocator = std.testing.allocator;
    const result = loadPromptFile(allocator, "/nonexistent/path/IDENTITY.md");
    try std.testing.expect(result == null);
}

test "loadPromptFile from tmp" {
    const allocator = std.testing.allocator;
    const path = "/tmp/zclaw_test_identity.md";

    // Write test file
    {
        const f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        try f.writeAll("Test identity content");
    }
    defer std.fs.cwd().deleteFile(path) catch {};

    const content = loadPromptFile(allocator, path).?;
    defer allocator.free(content);
    try std.testing.expectEqualStrings("Test identity content", content);
}

test "buildFromAgentDir nonexistent" {
    const allocator = std.testing.allocator;
    const prompt = try buildFromAgentDir(allocator, "/nonexistent/agent/dir");
    defer allocator.free(prompt);

    // Should fall back to default identity
    try std.testing.expect(std.mem.indexOf(u8, prompt, "helpful AI assistant") != null);
}

test "buildFromAgentDir with identity file" {
    const allocator = std.testing.allocator;
    const dir = "/tmp/zclaw_test_agent";

    // Create agent dir and files
    std.fs.cwd().makePath(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};

    {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/IDENTITY.md", .{dir});
        const f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        try f.writeAll("I am a test agent.");
    }

    const prompt = try buildFromAgentDir(allocator, dir);
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "I am a test agent.") != null);
}

test "DEFAULT_IDENTITY content" {
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_IDENTITY, "helpful AI assistant") != null);
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_IDENTITY, "zclaw") != null);
}
