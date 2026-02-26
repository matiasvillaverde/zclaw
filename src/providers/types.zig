const std = @import("std");

// --- Content Block Types ---

pub const ContentType = enum {
    text,
    image,
    tool_use,
    tool_result,
    thinking,

    pub fn label(self: ContentType) []const u8 {
        return switch (self) {
            .text => "text",
            .image => "image",
            .tool_use => "tool_use",
            .tool_result => "tool_result",
            .thinking => "thinking",
        };
    }

    pub fn fromString(s: []const u8) ?ContentType {
        const map = std.StaticStringMap(ContentType).initComptime(.{
            .{ "text", .text },
            .{ "image", .image },
            .{ "tool_use", .tool_use },
            .{ "tool_result", .tool_result },
            .{ "thinking", .thinking },
        });
        return map.get(s);
    }
};

// --- Message Role ---

pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn label(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }

    pub fn fromString(s: []const u8) ?Role {
        const map = std.StaticStringMap(Role).initComptime(.{
            .{ "system", .system },
            .{ "user", .user },
            .{ "assistant", .assistant },
            .{ "tool", .tool },
            .{ "function", .tool }, // Legacy OpenAI alias
        });
        return map.get(s);
    }
};

// --- Stop Reason ---

pub const StopReason = enum {
    end_turn,
    tool_use,
    max_tokens,
    stop_sequence,
    content_filter,
    @"error",

    pub fn label(self: StopReason) []const u8 {
        return switch (self) {
            .end_turn => "end_turn",
            .tool_use => "tool_use",
            .max_tokens => "max_tokens",
            .stop_sequence => "stop_sequence",
            .content_filter => "content_filter",
            .@"error" => "error",
        };
    }

    pub fn fromString(s: []const u8) ?StopReason {
        const map = std.StaticStringMap(StopReason).initComptime(.{
            .{ "end_turn", .end_turn },
            .{ "stop", .end_turn }, // OpenAI alias
            .{ "tool_use", .tool_use },
            .{ "tool_calls", .tool_use }, // OpenAI alias
            .{ "max_tokens", .max_tokens },
            .{ "length", .max_tokens }, // OpenAI alias
            .{ "stop_sequence", .stop_sequence },
            .{ "content_filter", .content_filter },
            .{ "error", .@"error" },
        });
        return map.get(s);
    }
};

// --- Provider API Type ---

pub const ApiType = enum {
    anthropic_messages,
    openai_completions,
    google_genai,
    ollama,

    pub fn label(self: ApiType) []const u8 {
        return switch (self) {
            .anthropic_messages => "anthropic-messages",
            .openai_completions => "openai-completions",
            .google_genai => "google-genai",
            .ollama => "ollama",
        };
    }

    pub fn fromString(s: []const u8) ?ApiType {
        const map = std.StaticStringMap(ApiType).initComptime(.{
            .{ "anthropic-messages", .anthropic_messages },
            .{ "openai-completions", .openai_completions },
            .{ "google-genai", .google_genai },
            .{ "ollama", .ollama },
        });
        return map.get(s);
    }
};

// --- Model Definition ---

pub const ModelDef = struct {
    id: []const u8,
    name: []const u8 = "",
    api: ApiType = .anthropic_messages,
    provider: []const u8 = "anthropic",
    base_url: ?[]const u8 = null,
    context_window: u32 = 200_000,
    max_tokens: u32 = 4096,
    reasoning: bool = false,
};

// --- Usage Tracking ---

pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,

    pub fn totalTokens(self: Usage) u64 {
        return self.input_tokens + self.output_tokens;
    }

    pub fn add(self: *Usage, other: Usage) void {
        self.input_tokens += other.input_tokens;
        self.output_tokens += other.output_tokens;
        self.cache_read_tokens += other.cache_read_tokens;
        self.cache_write_tokens += other.cache_write_tokens;
    }
};

// --- Tool Definition ---

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8 = "",
    parameters_json: ?[]const u8 = null, // JSON Schema as raw string
};

// --- Stream Event ---

pub const StreamEventType = enum {
    start,
    text_delta,
    tool_call_start,
    tool_call_delta,
    tool_call_end,
    stop,
    usage,
    @"error",
};

pub const StreamEvent = struct {
    event_type: StreamEventType,
    text: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    tool_input_delta: ?[]const u8 = null,
    stop_reason: ?StopReason = null,
    usage: ?Usage = null,
    error_message: ?[]const u8 = null,
};

// --- Request Config ---

pub const RequestConfig = struct {
    model: []const u8,
    system_prompt: ?[]const u8 = null,
    max_tokens: u32 = 4096,
    temperature: ?f32 = null,
    stream: bool = true,
    api_key: []const u8 = "",
    base_url: ?[]const u8 = null,
};

// --- Tests ---

test "ContentType labels and fromString" {
    try std.testing.expectEqualStrings("text", ContentType.text.label());
    try std.testing.expectEqualStrings("tool_use", ContentType.tool_use.label());
    try std.testing.expectEqual(ContentType.text, ContentType.fromString("text").?);
    try std.testing.expectEqual(ContentType.tool_result, ContentType.fromString("tool_result").?);
    try std.testing.expectEqual(@as(?ContentType, null), ContentType.fromString("unknown"));
}

test "Role labels and fromString" {
    try std.testing.expectEqualStrings("system", Role.system.label());
    try std.testing.expectEqualStrings("user", Role.user.label());
    try std.testing.expectEqualStrings("assistant", Role.assistant.label());
    try std.testing.expectEqualStrings("tool", Role.tool.label());

    try std.testing.expectEqual(Role.system, Role.fromString("system").?);
    try std.testing.expectEqual(Role.user, Role.fromString("user").?);
    try std.testing.expectEqual(Role.assistant, Role.fromString("assistant").?);
    try std.testing.expectEqual(Role.tool, Role.fromString("tool").?);
    // Legacy alias
    try std.testing.expectEqual(Role.tool, Role.fromString("function").?);
    try std.testing.expectEqual(@as(?Role, null), Role.fromString("unknown"));
}

test "StopReason labels and fromString" {
    try std.testing.expectEqualStrings("end_turn", StopReason.end_turn.label());
    try std.testing.expectEqualStrings("tool_use", StopReason.tool_use.label());
    try std.testing.expectEqualStrings("max_tokens", StopReason.max_tokens.label());

    // OpenAI aliases
    try std.testing.expectEqual(StopReason.end_turn, StopReason.fromString("stop").?);
    try std.testing.expectEqual(StopReason.tool_use, StopReason.fromString("tool_calls").?);
    try std.testing.expectEqual(StopReason.max_tokens, StopReason.fromString("length").?);
}

test "ApiType labels and fromString" {
    try std.testing.expectEqualStrings("anthropic-messages", ApiType.anthropic_messages.label());
    try std.testing.expectEqualStrings("openai-completions", ApiType.openai_completions.label());
    try std.testing.expectEqual(ApiType.anthropic_messages, ApiType.fromString("anthropic-messages").?);
    try std.testing.expectEqual(ApiType.openai_completions, ApiType.fromString("openai-completions").?);
    try std.testing.expectEqual(@as(?ApiType, null), ApiType.fromString("unknown"));
}

test "Usage tracking" {
    var usage = Usage{};
    try std.testing.expectEqual(@as(u64, 0), usage.totalTokens());

    usage.add(.{ .input_tokens = 100, .output_tokens = 50 });
    try std.testing.expectEqual(@as(u64, 150), usage.totalTokens());
    try std.testing.expectEqual(@as(u64, 100), usage.input_tokens);

    usage.add(.{ .input_tokens = 50, .output_tokens = 25, .cache_read_tokens = 10 });
    try std.testing.expectEqual(@as(u64, 225), usage.totalTokens());
    try std.testing.expectEqual(@as(u64, 10), usage.cache_read_tokens);
}

test "ModelDef defaults" {
    const model = ModelDef{ .id = "claude-3-5-sonnet" };
    try std.testing.expectEqualStrings("claude-3-5-sonnet", model.id);
    try std.testing.expectEqual(ApiType.anthropic_messages, model.api);
    try std.testing.expectEqual(@as(u32, 200_000), model.context_window);
    try std.testing.expectEqual(@as(u32, 4096), model.max_tokens);
    try std.testing.expect(!model.reasoning);
}

test "StreamEvent types" {
    const evt = StreamEvent{
        .event_type = .text_delta,
        .text = "Hello",
    };
    try std.testing.expectEqual(StreamEventType.text_delta, evt.event_type);
    try std.testing.expectEqualStrings("Hello", evt.text.?);
    try std.testing.expect(evt.tool_call_id == null);
}

test "StreamEvent tool call" {
    const evt = StreamEvent{
        .event_type = .tool_call_start,
        .tool_call_id = "call_abc123",
        .tool_name = "bash",
    };
    try std.testing.expectEqual(StreamEventType.tool_call_start, evt.event_type);
    try std.testing.expectEqualStrings("call_abc123", evt.tool_call_id.?);
    try std.testing.expectEqualStrings("bash", evt.tool_name.?);
}

test "StreamEvent error" {
    const evt = StreamEvent{
        .event_type = .@"error",
        .error_message = "rate limited",
    };
    try std.testing.expectEqual(StreamEventType.@"error", evt.event_type);
    try std.testing.expectEqualStrings("rate limited", evt.error_message.?);
}

test "RequestConfig defaults" {
    const cfg = RequestConfig{ .model = "gpt-4" };
    try std.testing.expectEqualStrings("gpt-4", cfg.model);
    try std.testing.expectEqual(@as(u32, 4096), cfg.max_tokens);
    try std.testing.expect(cfg.stream);
    try std.testing.expect(cfg.base_url == null);
}

test "ToolDefinition" {
    const tool = ToolDefinition{
        .name = "bash",
        .description = "Execute commands",
        .parameters_json = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}}}",
    };
    try std.testing.expectEqualStrings("bash", tool.name);
    try std.testing.expect(tool.parameters_json != null);
}
