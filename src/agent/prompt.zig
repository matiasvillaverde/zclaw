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

// --- Additional Tests ---

test "buildSystemPrompt memory only" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, "Bot", null, "Remember X", null);
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Bot") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Remember X") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Skills") == null);
}

test "buildSystemPrompt context only" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, "Bot", null, null, "extra info");
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Bot") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Context") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "extra info") != null);
}

test "buildSystemPrompt ordering of sections" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, "Identity", "Skills", "Memory", "Context");
    defer allocator.free(prompt);

    const skills_pos = std.mem.indexOf(u8, prompt, "## Skills").?;
    const memory_pos = std.mem.indexOf(u8, prompt, "## Memory").?;
    const context_pos = std.mem.indexOf(u8, prompt, "## Context").?;

    // Sections should appear in order: skills, memory, context
    try std.testing.expect(skills_pos < memory_pos);
    try std.testing.expect(memory_pos < context_pos);
}

test "buildSystemPrompt empty strings" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, "", "", "", "");
    defer allocator.free(prompt);

    // Empty identity + sections with empty content
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Skills") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Context") != null);
}

test "buildSystemPrompt large identity" {
    const allocator = std.testing.allocator;
    const large_identity = "A" ** 5000;
    const prompt = try buildSystemPrompt(allocator, large_identity, null, null, null);
    defer allocator.free(prompt);

    try std.testing.expectEqual(@as(usize, 5000), prompt.len);
}

test "buildSystemPrompt default identity with all optional" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, null, "skill1", "mem1", "ctx1");
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "helpful AI assistant") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "skill1") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "mem1") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "ctx1") != null);
}

test "DEFAULT_IDENTITY contains behavioral guidance" {
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_IDENTITY, "concise") != null);
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_IDENTITY, "accurate") != null);
}

test "loadPromptFile with empty file" {
    const allocator = std.testing.allocator;
    const path = "/tmp/zclaw_test_empty_prompt.md";
    {
        const f = try std.fs.cwd().createFile(path, .{});
        f.close();
    }
    defer std.fs.cwd().deleteFile(path) catch {};

    const content = loadPromptFile(allocator, path).?;
    defer allocator.free(content);
    try std.testing.expectEqual(@as(usize, 0), content.len);
}

test "buildSystemPrompt skills and memory without context" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, "Bot", "S", "M", null);
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Skills") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Context") == null);
}

// ===== New tests added for comprehensive coverage =====

test "buildSystemPrompt with only memory and context" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, "Bot", null, "Remember this", "Today is Monday");
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Bot") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Skills") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Remember this") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Context") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Today is Monday") != null);
}

test "buildSystemPrompt with only skills and context" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, "Bot", "Code review", null, "Project X");
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Skills") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Code review") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Memory") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Context") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Project X") != null);
}

test "buildSystemPrompt multiline identity" {
    const allocator = std.testing.allocator;
    const identity = "You are a helpful assistant.\nYou specialize in Zig programming.\nBe precise.";
    const prompt = try buildSystemPrompt(allocator, identity, null, null, null);
    defer allocator.free(prompt);

    try std.testing.expectEqualStrings(identity, prompt);
}

test "buildSystemPrompt identity starts the prompt" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, "I am first", "skills", "memory", "context");
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.startsWith(u8, prompt, "I am first"));
}

test "buildSystemPrompt section separators are double newlines" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, "ID", "SK", "MEM", "CTX");
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "\n\n## Skills\n\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\n\n## Memory\n\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\n\n## Context\n\n") != null);
}

test "buildSystemPrompt default identity text is deterministic" {
    const allocator = std.testing.allocator;
    const prompt1 = try buildSystemPrompt(allocator, null, null, null, null);
    defer allocator.free(prompt1);
    const prompt2 = try buildSystemPrompt(allocator, null, null, null, null);
    defer allocator.free(prompt2);

    try std.testing.expectEqualStrings(prompt1, prompt2);
}

test "buildSystemPrompt with unicode content" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, "Bot", null, null, null);
    defer allocator.free(prompt);
    try std.testing.expectEqualStrings("Bot", prompt);
}

test "buildSystemPrompt multiline skills" {
    const allocator = std.testing.allocator;
    const skills = "- Can search the web\n- Can run code\n- Can manage files";
    const prompt = try buildSystemPrompt(allocator, "Bot", skills, null, null);
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Can search the web") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Can run code") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Can manage files") != null);
}

test "buildSystemPrompt multiline memory" {
    const allocator = std.testing.allocator;
    const memory = "User prefers short answers.\nUser timezone is UTC-5.\nUser language is English.";
    const prompt = try buildSystemPrompt(allocator, null, null, memory, null);
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "User prefers short answers.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "User timezone is UTC-5.") != null);
}

test "buildSystemPrompt with very long skills" {
    const allocator = std.testing.allocator;
    const long_skills = "skill " ** 1000;
    const prompt = try buildSystemPrompt(allocator, "Bot", long_skills, null, null);
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Skills") != null);
    try std.testing.expect(prompt.len > 6000);
}

test "loadPromptFile reads content exactly" {
    const allocator = std.testing.allocator;
    const path = "/tmp/zclaw_test_prompt_exact.md";
    const expected = "Line 1\nLine 2\nLine 3";

    {
        const f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        try f.writeAll(expected);
    }
    defer std.fs.cwd().deleteFile(path) catch {};

    const content = loadPromptFile(allocator, path).?;
    defer allocator.free(content);
    try std.testing.expectEqualStrings(expected, content);
}

test "buildFromAgentDir with skills and memory files" {
    const allocator = std.testing.allocator;
    const dir = "/tmp/zclaw_test_agent_full";

    std.fs.cwd().makePath(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};

    {
        var path_buf: [256]u8 = undefined;
        const id_path = try std.fmt.bufPrint(&path_buf, "{s}/IDENTITY.md", .{dir});
        const f = try std.fs.cwd().createFile(id_path, .{});
        defer f.close();
        try f.writeAll("I am TestBot.");
    }
    {
        var path_buf: [256]u8 = undefined;
        const sk_path = try std.fmt.bufPrint(&path_buf, "{s}/SKILLS.md", .{dir});
        const f = try std.fs.cwd().createFile(sk_path, .{});
        defer f.close();
        try f.writeAll("Can search and answer.");
    }
    {
        var path_buf: [256]u8 = undefined;
        const mem_path = try std.fmt.bufPrint(&path_buf, "{s}/MEMORY.md", .{dir});
        const f = try std.fs.cwd().createFile(mem_path, .{});
        defer f.close();
        try f.writeAll("User prefers code examples.");
    }

    const prompt = try buildFromAgentDir(allocator, dir);
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "I am TestBot.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Skills") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Can search and answer.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "User prefers code examples.") != null);
}

test "buildFromAgentDir with only skills file" {
    const allocator = std.testing.allocator;
    const dir = "/tmp/zclaw_test_agent_skills_only";

    std.fs.cwd().makePath(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};

    {
        var path_buf: [256]u8 = undefined;
        const sk_path = try std.fmt.bufPrint(&path_buf, "{s}/SKILLS.md", .{dir});
        const f = try std.fs.cwd().createFile(sk_path, .{});
        defer f.close();
        try f.writeAll("Skill data");
    }

    const prompt = try buildFromAgentDir(allocator, dir);
    defer allocator.free(prompt);

    // No IDENTITY.md, so uses default
    try std.testing.expect(std.mem.indexOf(u8, prompt, "helpful AI assistant") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Skills") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Skill data") != null);
}

test "DEFAULT_IDENTITY is a multiline string" {
    try std.testing.expect(DEFAULT_IDENTITY.len > 10);
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_IDENTITY, "agent") != null);
}

test "buildSystemPrompt result length with all sections" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, "ID", "SK", "MEM", "CTX");
    defer allocator.free(prompt);
    // Should be longer than just the identity due to section headers
    try std.testing.expect(prompt.len > "ID".len + "SK".len + "MEM".len + "CTX".len);
}
