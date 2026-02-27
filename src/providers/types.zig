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

// =====================================================
// Additional comprehensive tests
// =====================================================

// --- ContentType exhaustive tests ---

test "ContentType.label for every variant" {
    try std.testing.expectEqualStrings("text", ContentType.text.label());
    try std.testing.expectEqualStrings("image", ContentType.image.label());
    try std.testing.expectEqualStrings("tool_use", ContentType.tool_use.label());
    try std.testing.expectEqualStrings("tool_result", ContentType.tool_result.label());
    try std.testing.expectEqualStrings("thinking", ContentType.thinking.label());
}

test "ContentType.fromString for every variant" {
    try std.testing.expectEqual(ContentType.text, ContentType.fromString("text").?);
    try std.testing.expectEqual(ContentType.image, ContentType.fromString("image").?);
    try std.testing.expectEqual(ContentType.tool_use, ContentType.fromString("tool_use").?);
    try std.testing.expectEqual(ContentType.tool_result, ContentType.fromString("tool_result").?);
    try std.testing.expectEqual(ContentType.thinking, ContentType.fromString("thinking").?);
}

test "ContentType.fromString returns null for empty string" {
    try std.testing.expectEqual(@as(?ContentType, null), ContentType.fromString(""));
}

test "ContentType.fromString returns null for case variations" {
    try std.testing.expectEqual(@as(?ContentType, null), ContentType.fromString("Text"));
    try std.testing.expectEqual(@as(?ContentType, null), ContentType.fromString("TEXT"));
    try std.testing.expectEqual(@as(?ContentType, null), ContentType.fromString("TOOL_USE"));
}

test "ContentType.fromString returns null for partial matches" {
    try std.testing.expectEqual(@as(?ContentType, null), ContentType.fromString("tex"));
    try std.testing.expectEqual(@as(?ContentType, null), ContentType.fromString("tool"));
    try std.testing.expectEqual(@as(?ContentType, null), ContentType.fromString("tool_"));
}

test "ContentType.label roundtrip" {
    const variants = [_]ContentType{ .text, .image, .tool_use, .tool_result, .thinking };
    for (variants) |v| {
        const label_str = v.label();
        const parsed = ContentType.fromString(label_str).?;
        try std.testing.expectEqual(v, parsed);
    }
}

// --- Role exhaustive tests ---

test "Role.fromString empty string returns null" {
    try std.testing.expectEqual(@as(?Role, null), Role.fromString(""));
}

test "Role.fromString case sensitive" {
    try std.testing.expectEqual(@as(?Role, null), Role.fromString("System"));
    try std.testing.expectEqual(@as(?Role, null), Role.fromString("USER"));
    try std.testing.expectEqual(@as(?Role, null), Role.fromString("Assistant"));
    try std.testing.expectEqual(@as(?Role, null), Role.fromString("Tool"));
}

test "Role function alias maps to tool" {
    const from_function = Role.fromString("function").?;
    const from_tool = Role.fromString("tool").?;
    try std.testing.expectEqual(from_function, from_tool);
    try std.testing.expectEqualStrings("tool", from_function.label());
}

test "Role.label roundtrip for all variants" {
    const roles = [_]Role{ .system, .user, .assistant, .tool };
    for (roles) |r| {
        const label_str = r.label();
        const parsed = Role.fromString(label_str).?;
        try std.testing.expectEqual(r, parsed);
    }
}

test "Role.fromString rejects whitespace-padded input" {
    try std.testing.expectEqual(@as(?Role, null), Role.fromString(" user"));
    try std.testing.expectEqual(@as(?Role, null), Role.fromString("user "));
}

// --- StopReason exhaustive tests ---

test "StopReason.label for every variant" {
    try std.testing.expectEqualStrings("end_turn", StopReason.end_turn.label());
    try std.testing.expectEqualStrings("tool_use", StopReason.tool_use.label());
    try std.testing.expectEqualStrings("max_tokens", StopReason.max_tokens.label());
    try std.testing.expectEqualStrings("stop_sequence", StopReason.stop_sequence.label());
    try std.testing.expectEqualStrings("content_filter", StopReason.content_filter.label());
    try std.testing.expectEqualStrings("error", StopReason.@"error".label());
}

test "StopReason.fromString for all native values" {
    try std.testing.expectEqual(StopReason.end_turn, StopReason.fromString("end_turn").?);
    try std.testing.expectEqual(StopReason.tool_use, StopReason.fromString("tool_use").?);
    try std.testing.expectEqual(StopReason.max_tokens, StopReason.fromString("max_tokens").?);
    try std.testing.expectEqual(StopReason.stop_sequence, StopReason.fromString("stop_sequence").?);
    try std.testing.expectEqual(StopReason.content_filter, StopReason.fromString("content_filter").?);
    try std.testing.expectEqual(StopReason.@"error", StopReason.fromString("error").?);
}

test "StopReason.fromString OpenAI aliases" {
    try std.testing.expectEqual(StopReason.end_turn, StopReason.fromString("stop").?);
    try std.testing.expectEqual(StopReason.tool_use, StopReason.fromString("tool_calls").?);
    try std.testing.expectEqual(StopReason.max_tokens, StopReason.fromString("length").?);
}

test "StopReason.fromString returns null for unknown" {
    try std.testing.expectEqual(@as(?StopReason, null), StopReason.fromString(""));
    try std.testing.expectEqual(@as(?StopReason, null), StopReason.fromString("finished"));
    try std.testing.expectEqual(@as(?StopReason, null), StopReason.fromString("timeout"));
    try std.testing.expectEqual(@as(?StopReason, null), StopReason.fromString("cancelled"));
}

test "StopReason.label roundtrip" {
    const reasons = [_]StopReason{ .end_turn, .tool_use, .max_tokens, .stop_sequence, .content_filter, .@"error" };
    for (reasons) |r| {
        const label_str = r.label();
        const parsed = StopReason.fromString(label_str).?;
        try std.testing.expectEqual(r, parsed);
    }
}

// --- ApiType exhaustive tests ---

test "ApiType.label for every variant" {
    try std.testing.expectEqualStrings("anthropic-messages", ApiType.anthropic_messages.label());
    try std.testing.expectEqualStrings("openai-completions", ApiType.openai_completions.label());
    try std.testing.expectEqualStrings("google-genai", ApiType.google_genai.label());
    try std.testing.expectEqualStrings("ollama", ApiType.ollama.label());
}

test "ApiType.fromString for every variant" {
    try std.testing.expectEqual(ApiType.anthropic_messages, ApiType.fromString("anthropic-messages").?);
    try std.testing.expectEqual(ApiType.openai_completions, ApiType.fromString("openai-completions").?);
    try std.testing.expectEqual(ApiType.google_genai, ApiType.fromString("google-genai").?);
    try std.testing.expectEqual(ApiType.ollama, ApiType.fromString("ollama").?);
}

test "ApiType.fromString returns null for similar but wrong strings" {
    try std.testing.expectEqual(@as(?ApiType, null), ApiType.fromString("anthropic"));
    try std.testing.expectEqual(@as(?ApiType, null), ApiType.fromString("openai"));
    try std.testing.expectEqual(@as(?ApiType, null), ApiType.fromString("google"));
    try std.testing.expectEqual(@as(?ApiType, null), ApiType.fromString(""));
}

test "ApiType.label roundtrip" {
    const api_types = [_]ApiType{ .anthropic_messages, .openai_completions, .google_genai, .ollama };
    for (api_types) |a| {
        const label_str = a.label();
        const parsed = ApiType.fromString(label_str).?;
        try std.testing.expectEqual(a, parsed);
    }
}

// --- Usage arithmetic tests ---

test "Usage zero initialization" {
    const usage = Usage{};
    try std.testing.expectEqual(@as(u64, 0), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 0), usage.output_tokens);
    try std.testing.expectEqual(@as(u64, 0), usage.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 0), usage.cache_write_tokens);
    try std.testing.expectEqual(@as(u64, 0), usage.totalTokens());
}

test "Usage totalTokens is sum of input and output only" {
    const usage = Usage{
        .input_tokens = 100,
        .output_tokens = 50,
        .cache_read_tokens = 999,
        .cache_write_tokens = 888,
    };
    // totalTokens should be input + output, NOT cache tokens
    try std.testing.expectEqual(@as(u64, 150), usage.totalTokens());
}

test "Usage add accumulates all fields" {
    var usage = Usage{};
    usage.add(.{
        .input_tokens = 10,
        .output_tokens = 20,
        .cache_read_tokens = 5,
        .cache_write_tokens = 3,
    });
    try std.testing.expectEqual(@as(u64, 10), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 20), usage.output_tokens);
    try std.testing.expectEqual(@as(u64, 5), usage.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 3), usage.cache_write_tokens);
}

test "Usage add multiple times accumulates" {
    var usage = Usage{};
    usage.add(.{ .input_tokens = 100, .output_tokens = 50 });
    usage.add(.{ .input_tokens = 200, .output_tokens = 75 });
    usage.add(.{ .input_tokens = 50, .output_tokens = 25 });
    try std.testing.expectEqual(@as(u64, 350), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 150), usage.output_tokens);
    try std.testing.expectEqual(@as(u64, 500), usage.totalTokens());
}

test "Usage add with zero other is no-op" {
    var usage = Usage{ .input_tokens = 42, .output_tokens = 17 };
    usage.add(.{});
    try std.testing.expectEqual(@as(u64, 42), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 17), usage.output_tokens);
}

test "Usage add cache tokens separately" {
    var usage = Usage{};
    usage.add(.{ .cache_read_tokens = 100 });
    usage.add(.{ .cache_write_tokens = 200 });
    usage.add(.{ .cache_read_tokens = 50, .cache_write_tokens = 30 });
    try std.testing.expectEqual(@as(u64, 150), usage.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 230), usage.cache_write_tokens);
    try std.testing.expectEqual(@as(u64, 0), usage.totalTokens());
}

test "Usage large token counts" {
    var usage = Usage{};
    usage.add(.{ .input_tokens = 1_000_000, .output_tokens = 500_000 });
    try std.testing.expectEqual(@as(u64, 1_500_000), usage.totalTokens());
}

// --- ModelDef tests ---

test "ModelDef with all fields" {
    const model = ModelDef{
        .id = "gpt-4-turbo",
        .name = "GPT-4 Turbo",
        .api = .openai_completions,
        .provider = "openai",
        .base_url = "https://api.openai.com",
        .context_window = 128_000,
        .max_tokens = 8192,
        .reasoning = true,
    };
    try std.testing.expectEqualStrings("gpt-4-turbo", model.id);
    try std.testing.expectEqualStrings("GPT-4 Turbo", model.name);
    try std.testing.expectEqual(ApiType.openai_completions, model.api);
    try std.testing.expectEqualStrings("openai", model.provider);
    try std.testing.expectEqualStrings("https://api.openai.com", model.base_url.?);
    try std.testing.expectEqual(@as(u32, 128_000), model.context_window);
    try std.testing.expectEqual(@as(u32, 8192), model.max_tokens);
    try std.testing.expect(model.reasoning);
}

test "ModelDef default name is empty" {
    const model = ModelDef{ .id = "test-model" };
    try std.testing.expectEqualStrings("", model.name);
}

test "ModelDef default base_url is null" {
    const model = ModelDef{ .id = "test-model" };
    try std.testing.expect(model.base_url == null);
}

test "ModelDef default provider is anthropic" {
    const model = ModelDef{ .id = "test" };
    try std.testing.expectEqualStrings("anthropic", model.provider);
}

// --- StreamEvent construction tests ---

test "StreamEvent start event" {
    const evt = StreamEvent{ .event_type = .start };
    try std.testing.expectEqual(StreamEventType.start, evt.event_type);
    try std.testing.expect(evt.text == null);
    try std.testing.expect(evt.tool_call_id == null);
    try std.testing.expect(evt.tool_name == null);
    try std.testing.expect(evt.tool_input_delta == null);
    try std.testing.expect(evt.stop_reason == null);
    try std.testing.expect(evt.usage == null);
    try std.testing.expect(evt.error_message == null);
}

test "StreamEvent text_delta with text" {
    const evt = StreamEvent{
        .event_type = .text_delta,
        .text = "Hello, world!",
    };
    try std.testing.expectEqual(StreamEventType.text_delta, evt.event_type);
    try std.testing.expectEqualStrings("Hello, world!", evt.text.?);
}

test "StreamEvent tool_call_start with all fields" {
    const evt = StreamEvent{
        .event_type = .tool_call_start,
        .tool_call_id = "toolu_01234",
        .tool_name = "web_search",
        .tool_input_delta = "{\"query\":",
    };
    try std.testing.expectEqual(StreamEventType.tool_call_start, evt.event_type);
    try std.testing.expectEqualStrings("toolu_01234", evt.tool_call_id.?);
    try std.testing.expectEqualStrings("web_search", evt.tool_name.?);
    try std.testing.expectEqualStrings("{\"query\":", evt.tool_input_delta.?);
}

test "StreamEvent tool_call_delta" {
    const evt = StreamEvent{
        .event_type = .tool_call_delta,
        .tool_input_delta = "\"hello\"}",
    };
    try std.testing.expectEqual(StreamEventType.tool_call_delta, evt.event_type);
    try std.testing.expectEqualStrings("\"hello\"}", evt.tool_input_delta.?);
}

test "StreamEvent tool_call_end" {
    const evt = StreamEvent{ .event_type = .tool_call_end };
    try std.testing.expectEqual(StreamEventType.tool_call_end, evt.event_type);
}

test "StreamEvent stop with reason and usage" {
    const evt = StreamEvent{
        .event_type = .stop,
        .stop_reason = .end_turn,
        .usage = .{ .input_tokens = 100, .output_tokens = 200 },
    };
    try std.testing.expectEqual(StreamEventType.stop, evt.event_type);
    try std.testing.expectEqual(StopReason.end_turn, evt.stop_reason.?);
    try std.testing.expectEqual(@as(u64, 100), evt.usage.?.input_tokens);
    try std.testing.expectEqual(@as(u64, 200), evt.usage.?.output_tokens);
}

test "StreamEvent usage event" {
    const evt = StreamEvent{
        .event_type = .usage,
        .usage = .{
            .input_tokens = 500,
            .output_tokens = 300,
            .cache_read_tokens = 50,
        },
    };
    try std.testing.expectEqual(StreamEventType.usage, evt.event_type);
    try std.testing.expectEqual(@as(u64, 800), evt.usage.?.totalTokens());
}

test "StreamEvent error with message" {
    const evt = StreamEvent{
        .event_type = .@"error",
        .error_message = "overloaded_error: API is overloaded",
    };
    try std.testing.expectEqual(StreamEventType.@"error", evt.event_type);
    try std.testing.expectEqualStrings("overloaded_error: API is overloaded", evt.error_message.?);
}

test "StreamEvent error without message" {
    const evt = StreamEvent{ .event_type = .@"error" };
    try std.testing.expectEqual(StreamEventType.@"error", evt.event_type);
    try std.testing.expect(evt.error_message == null);
}

// --- StreamEventType exhaustive tests ---

test "StreamEventType all variants exist" {
    const types_list = [_]StreamEventType{
        .start,
        .text_delta,
        .tool_call_start,
        .tool_call_delta,
        .tool_call_end,
        .stop,
        .usage,
        .@"error",
    };
    try std.testing.expectEqual(@as(usize, 8), types_list.len);
}

// --- RequestConfig tests ---

test "RequestConfig with all fields" {
    const cfg = RequestConfig{
        .model = "claude-3-5-sonnet",
        .system_prompt = "You are a helpful assistant.",
        .max_tokens = 8192,
        .temperature = 0.7,
        .stream = false,
        .api_key = "sk-ant-test-key",
        .base_url = "https://custom.api.com",
    };
    try std.testing.expectEqualStrings("claude-3-5-sonnet", cfg.model);
    try std.testing.expectEqualStrings("You are a helpful assistant.", cfg.system_prompt.?);
    try std.testing.expectEqual(@as(u32, 8192), cfg.max_tokens);
    try std.testing.expectEqual(@as(f32, 0.7), cfg.temperature.?);
    try std.testing.expect(!cfg.stream);
    try std.testing.expectEqualStrings("sk-ant-test-key", cfg.api_key);
    try std.testing.expectEqualStrings("https://custom.api.com", cfg.base_url.?);
}

test "RequestConfig default system_prompt is null" {
    const cfg = RequestConfig{ .model = "test" };
    try std.testing.expect(cfg.system_prompt == null);
}

test "RequestConfig default temperature is null" {
    const cfg = RequestConfig{ .model = "test" };
    try std.testing.expect(cfg.temperature == null);
}

test "RequestConfig default stream is true" {
    const cfg = RequestConfig{ .model = "test" };
    try std.testing.expect(cfg.stream);
}

test "RequestConfig default api_key is empty" {
    const cfg = RequestConfig{ .model = "test" };
    try std.testing.expectEqualStrings("", cfg.api_key);
}

// --- ToolDefinition tests ---

test "ToolDefinition with no parameters" {
    const tool = ToolDefinition{
        .name = "stop",
        .description = "Stop the agent",
    };
    try std.testing.expectEqualStrings("stop", tool.name);
    try std.testing.expectEqualStrings("Stop the agent", tool.description);
    try std.testing.expect(tool.parameters_json == null);
}

test "ToolDefinition with empty description" {
    const tool = ToolDefinition{ .name = "noop" };
    try std.testing.expectEqualStrings("", tool.description);
}

test "ToolDefinition with complex parameters" {
    const params =
        \\{"type":"object","properties":{"url":{"type":"string"},"method":{"type":"string","enum":["GET","POST"]}},"required":["url"]}
    ;
    const tool = ToolDefinition{
        .name = "http_request",
        .description = "Make an HTTP request",
        .parameters_json = params,
    };
    try std.testing.expectEqualStrings("http_request", tool.name);
    try std.testing.expect(tool.parameters_json != null);
}
