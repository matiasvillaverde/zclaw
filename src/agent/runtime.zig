const std = @import("std");
const prompt_mod = @import("prompt.zig");
const compaction = @import("compaction.zig");
const failover = @import("failover.zig");
const types = @import("../providers/types.zig");
const anthropic = @import("../providers/anthropic.zig");
const openai = @import("../providers/openai.zig");
const openai_compat = @import("../providers/openai_compat.zig");
const gemini = @import("../providers/gemini.zig");
const sse = @import("../providers/sse.zig");
const http_client = @import("../infra/http_client.zig");
const tool_registry = @import("../tools/registry.zig");

// --- Agent Run Config ---

pub const RunConfig = struct {
    agent_id: []const u8 = "main",
    model: []const u8 = "claude-sonnet-4-20250514",
    system_prompt: ?[]const u8 = null,
    max_turns: u32 = 25,
    max_tokens: u32 = 4096,
    temperature: ?f32 = null,
    tools_json: ?[]const u8 = null,
    api_key: []const u8 = "",
    stream: bool = true,
};

// --- Agent Run State ---

pub const RunState = enum {
    idle,
    running,
    waiting_tool,
    compacting,
    completed,
    failed,
    aborted,

    pub fn label(self: RunState) []const u8 {
        return switch (self) {
            .idle => "idle",
            .running => "running",
            .waiting_tool => "waiting_tool",
            .compacting => "compacting",
            .completed => "completed",
            .failed => "failed",
            .aborted => "aborted",
        };
    }

    pub fn isTerminal(self: RunState) bool {
        return self == .completed or self == .failed or self == .aborted;
    }
};

// --- Agent Run Events ---

pub const RunEventType = enum {
    start,
    delta,
    tool_call,
    tool_result,
    compaction,
    complete,
    @"error",
    abort,
};

pub const RunEvent = struct {
    event_type: RunEventType,
    agent_id: []const u8 = "",
    run_id: []const u8 = "",
    text: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_input: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    turn: u32 = 0,
};

// --- Message History ---

pub const HistoryMessage = struct {
    role: Role,
    content: []const u8,
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
};

pub const Role = enum {
    user,
    assistant,
    tool_result,

    pub fn label(self: Role) []const u8 {
        return switch (self) {
            .user => "user",
            .assistant => "assistant",
            .tool_result => "tool_result",
        };
    }
};

// --- Tool Result Input ---

pub const ToolResultInput = struct {
    tool_call_id: []const u8,
    content: []const u8,
};

// --- Tool Call from Provider Response ---

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    input_json: []const u8,
};

// --- Run Result ---

pub const RunResult = struct {
    text: ?[]const u8 = null,
    tool_calls: []ToolCall = &.{},
    stop_reason: ?types.StopReason = null,
    usage: types.Usage = .{},

    pub fn hasToolCalls(self: *const RunResult) bool {
        return self.tool_calls.len > 0;
    }
};

// --- Provider Dispatch ---

pub const ProviderDispatch = struct {
    api_type: types.ApiType,
    anthropic_client: ?anthropic.Client,
    openai_client: ?openai.Client,
    compat_client: ?openai_compat.Client = null,
    gemini_client: ?gemini.Client = null,

    pub fn initAnthropic(http: *http_client.HttpClient, api_key: []const u8, base_url: ?[]const u8) ProviderDispatch {
        return .{
            .api_type = .anthropic_messages,
            .anthropic_client = anthropic.Client.init(http, api_key, base_url),
            .openai_client = null,
        };
    }

    pub fn initOpenAI(http: *http_client.HttpClient, api_key: []const u8, base_url: ?[]const u8) ProviderDispatch {
        return .{
            .api_type = .openai_completions,
            .anthropic_client = null,
            .openai_client = openai.Client.init(http, api_key, base_url),
        };
    }

    /// Initialize with an OpenAI-compatible provider (Groq, Ollama, etc.)
    pub fn initCompat(http: *http_client.HttpClient, api_key: []const u8, config: openai_compat.CompatConfig) ProviderDispatch {
        return .{
            .api_type = .openai_completions,
            .anthropic_client = null,
            .openai_client = null,
            .compat_client = openai_compat.Client.init(http, api_key, config),
        };
    }

    /// Initialize with Google Gemini provider
    pub fn initGemini(http: *http_client.HttpClient, api_key: []const u8, base_url: ?[]const u8) ProviderDispatch {
        return .{
            .api_type = .google_genai,
            .anthropic_client = null,
            .openai_client = null,
            .gemini_client = gemini.Client.init(http, api_key, base_url),
        };
    }

    /// Send a message through the appropriate provider.
    pub fn sendMessage(
        self: *ProviderDispatch,
        config: types.RequestConfig,
        messages_json: []const u8,
        tools_json: ?[]const u8,
    ) !ProviderResult {
        // Check compat client first (it uses openai_completions api_type)
        if (self.compat_client != null) {
            var client = &self.compat_client.?;
            const resp = try client.sendMessage(config, messages_json, tools_json);
            return .{
                .status = resp.status,
                .body = resp.body,
                .allocator = resp.allocator,
                .api_type = .openai_completions,
            };
        }

        // Check gemini client
        if (self.gemini_client != null) {
            var client = &self.gemini_client.?;
            const resp = try client.sendMessage(config, messages_json, tools_json);
            return .{
                .status = resp.status,
                .body = resp.body,
                .allocator = resp.allocator,
                .api_type = .google_genai,
            };
        }

        switch (self.api_type) {
            .anthropic_messages => {
                var client = &self.anthropic_client.?;
                const resp = try client.sendMessage(config, messages_json, tools_json);
                return .{
                    .status = resp.status,
                    .body = resp.body,
                    .allocator = resp.allocator,
                    .api_type = .anthropic_messages,
                };
            },
            .openai_completions => {
                var client = &self.openai_client.?;
                const resp = try client.sendMessage(config, messages_json, tools_json);
                return .{
                    .status = resp.status,
                    .body = resp.body,
                    .allocator = resp.allocator,
                    .api_type = .openai_completions,
                };
            },
            else => return error.UnsupportedProvider,
        }
    }
};

pub const ProviderResult = struct {
    status: u16,
    body: []const u8,
    allocator: ?std.mem.Allocator = null,
    api_type: types.ApiType,

    pub fn deinit(self: *ProviderResult) void {
        if (self.allocator) |alloc| {
            alloc.free(self.body);
        }
    }

    pub fn isSuccess(self: *const ProviderResult) bool {
        return self.status >= 200 and self.status < 300;
    }

    /// Parse SSE events and extract text, tool calls, and usage.
    pub fn parseRunResult(self: *const ProviderResult, allocator: std.mem.Allocator) !RunResult {
        var parser = sse.SseParser.init(allocator);
        defer parser.deinit();

        const events = try parser.feed(self.body);
        defer sse.freeEvents(allocator, events);

        var text_parts = std.ArrayListUnmanaged(u8){};
        defer text_parts.deinit(allocator);

        var tool_calls_list = std.ArrayListUnmanaged(ToolCall){};
        var usage = types.Usage{};
        var stop_reason: ?types.StopReason = null;

        // Track current tool call being built
        var current_tool_id: ?[]const u8 = null;
        var current_tool_name: ?[]const u8 = null;
        var current_tool_input = std.ArrayListUnmanaged(u8){};
        defer current_tool_input.deinit(allocator);

        for (events) |raw_event| {
            const stream_event = switch (self.api_type) {
                .anthropic_messages => anthropic.parseStreamEvent(&raw_event),
                .openai_completions => openai.parseStreamEvent(&raw_event),
                .google_genai => gemini.parseStreamEvent(&raw_event),
                else => null,
            };

            if (stream_event) |evt| {
                switch (evt.event_type) {
                    .text_delta => {
                        if (evt.text) |t| {
                            try text_parts.appendSlice(allocator, t);
                        }
                    },
                    .tool_call_start => {
                        // Flush any previous tool call
                        if (current_tool_id != null) {
                            try tool_calls_list.append(allocator, .{
                                .id = current_tool_id.?,
                                .name = current_tool_name orelse "",
                                .input_json = try allocator.dupe(u8, current_tool_input.items),
                            });
                            current_tool_input.clearRetainingCapacity();
                        }
                        current_tool_id = if (evt.tool_call_id) |id| try allocator.dupe(u8, id) else null;
                        current_tool_name = if (evt.tool_name) |name| try allocator.dupe(u8, name) else null;
                        if (evt.tool_input_delta) |delta| {
                            try current_tool_input.appendSlice(allocator, delta);
                        }
                    },
                    .tool_call_delta => {
                        if (evt.tool_input_delta) |delta| {
                            try current_tool_input.appendSlice(allocator, delta);
                        }
                    },
                    .tool_call_end => {},
                    .stop => {
                        // Only set stop_reason if not already set (avoid [DONE] overwriting tool_use)
                        if (evt.stop_reason) |sr| {
                            if (stop_reason == null) stop_reason = sr;
                        }
                        if (evt.usage) |u| usage.add(u);
                    },
                    .usage => {
                        if (evt.usage) |u| usage.add(u);
                    },
                    .start => {
                        if (evt.usage) |u| usage.add(u);
                    },
                    .@"error" => {},
                }
            }
        }

        // Flush last tool call
        if (current_tool_id != null) {
            try tool_calls_list.append(allocator, .{
                .id = current_tool_id.?,
                .name = current_tool_name orelse "",
                .input_json = try allocator.dupe(u8, current_tool_input.items),
            });
        }

        const text = if (text_parts.items.len > 0)
            try allocator.dupe(u8, text_parts.items)
        else
            null;

        return .{
            .text = text,
            .tool_calls = try tool_calls_list.toOwnedSlice(allocator),
            .stop_reason = stop_reason,
            .usage = usage,
        };
    }
};

/// Build messages JSON array from history.
/// Returns allocated string in the format: [{"role":"user","content":"..."}, ...]
pub fn buildMessagesJson(
    allocator: std.mem.Allocator,
    history: []const HistoryMessage,
    api_type: types.ApiType,
) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);

    try buf.append(allocator, '[');

    for (history, 0..) |msg, i| {
        if (i > 0) try buf.append(allocator, ',');

        switch (api_type) {
            .anthropic_messages => {
                switch (msg.role) {
                    .user => {
                        var msg_buf: [32 * 1024]u8 = undefined;
                        const json = try anthropic.buildUserMessage(&msg_buf, msg.content);
                        try buf.appendSlice(allocator, json);
                    },
                    .assistant => {
                        var msg_buf: [32 * 1024]u8 = undefined;
                        const json = try anthropic.buildAssistantMessage(&msg_buf, msg.content);
                        try buf.appendSlice(allocator, json);
                    },
                    .tool_result => {
                        var msg_buf: [32 * 1024]u8 = undefined;
                        const json = try anthropic.buildToolResultMessage(&msg_buf, msg.tool_call_id orelse "", msg.content);
                        try buf.appendSlice(allocator, json);
                    },
                }
            },
            .openai_completions => {
                switch (msg.role) {
                    .user => {
                        var msg_buf: [32 * 1024]u8 = undefined;
                        const json = try openai.buildUserMessage(&msg_buf, msg.content);
                        try buf.appendSlice(allocator, json);
                    },
                    .assistant => {
                        var msg_buf: [32 * 1024]u8 = undefined;
                        const json = try openai.buildAssistantMessage(&msg_buf, msg.content);
                        try buf.appendSlice(allocator, json);
                    },
                    .tool_result => {
                        var msg_buf: [32 * 1024]u8 = undefined;
                        const json = try openai.buildToolResultMessage(&msg_buf, msg.tool_call_id orelse "", msg.content);
                        try buf.appendSlice(allocator, json);
                    },
                }
            },
            .google_genai => {
                switch (msg.role) {
                    .user => {
                        var msg_buf: [32 * 1024]u8 = undefined;
                        // buildUserMessage returns array, strip [ and ]
                        const json = try gemini.buildUserMessage(&msg_buf, msg.content);
                        // Strip wrapping [ ]
                        if (json.len > 2 and json[0] == '[') {
                            try buf.appendSlice(allocator, json[1 .. json.len - 1]);
                        } else {
                            try buf.appendSlice(allocator, json);
                        }
                    },
                    .assistant => {
                        var msg_buf: [32 * 1024]u8 = undefined;
                        const json = try gemini.buildModelMessage(&msg_buf, msg.content);
                        try buf.appendSlice(allocator, json);
                    },
                    .tool_result => {
                        // Gemini tool results not yet supported, send as user message
                        var msg_buf: [32 * 1024]u8 = undefined;
                        const json = try gemini.buildUserMessage(&msg_buf, msg.content);
                        if (json.len > 2 and json[0] == '[') {
                            try buf.appendSlice(allocator, json[1 .. json.len - 1]);
                        } else {
                            try buf.appendSlice(allocator, json);
                        }
                    },
                }
            },
            else => return error.UnsupportedProvider,
        }
    }

    try buf.append(allocator, ']');
    return try allocator.dupe(u8, buf.items);
}

/// Free a RunResult's allocated memory
pub fn freeRunResult(allocator: std.mem.Allocator, result: *RunResult) void {
    if (result.text) |t| allocator.free(t);
    for (result.tool_calls) |tc| {
        allocator.free(tc.id);
        allocator.free(tc.name);
        allocator.free(tc.input_json);
    }
    allocator.free(result.tool_calls);
}

// --- Run Loop ---

/// Execute a multi-turn agent loop: provider call -> parse -> tool dispatch -> repeat.
/// Stops when: text-only response, max_turns exceeded, or error.
pub fn runLoop(
    allocator: std.mem.Allocator,
    runtime: *AgentRuntime,
    provider: *ProviderDispatch,
    registry: ?*const tool_registry.ToolRegistry,
) !RunResult {
    runtime.start();

    var last_result: ?RunResult = null;

    while (runtime.nextTurn()) {
        // Free previous result if any
        if (last_result) |*lr| {
            freeRunResult(allocator, lr);
            last_result = null;
        }

        var result = try runtime.runInference(provider);

        if (result.hasToolCalls() and registry != null) {
            // Dispatch tool calls
            var tool_results = std.ArrayListUnmanaged(ToolResultInput){};
            defer {
                for (tool_results.items) |tr| {
                    allocator.free(tr.content);
                }
                tool_results.deinit(allocator);
            }

            for (result.tool_calls) |tc| {
                const tr = dispatchToolCall(allocator, registry.?, tc);
                try tool_results.append(allocator, tr);
            }

            try runtime.submitToolResults(tool_results.items);

            // Store result for potential cleanup
            last_result = result;
            continue;
        }

        // Text-only response or no tool calls — done
        runtime.complete(result.text);
        return result;
    }

    // max_turns exceeded
    if (last_result) |lr| {
        return lr;
    }
    return RunResult{};
}

/// Dispatch a single tool call to the registry and return the result.
fn dispatchToolCall(
    allocator: std.mem.Allocator,
    registry: *const tool_registry.ToolRegistry,
    tc: ToolCall,
) ToolResultInput {
    var output_buf: [64 * 1024]u8 = undefined;
    const tool_result = registry.execute(tc.name, tc.input_json, &output_buf);

    if (tool_result) |tr| {
        const content = allocator.dupe(u8, tr.output) catch "error: out of memory";
        return .{
            .tool_call_id = tc.id,
            .content = content,
        };
    }

    const err_msg = allocator.dupe(u8, "tool not found") catch "error";
    return .{
        .tool_call_id = tc.id,
        .content = err_msg,
    };
}

// --- Agent Runtime ---

pub const AgentRuntime = struct {
    allocator: std.mem.Allocator,
    config: RunConfig,
    state: RunState,
    history: std.ArrayListUnmanaged(HistoryMessage),
    turn: u32,
    run_id: [36]u8,
    total_input_tokens: u64,
    total_output_tokens: u64,
    failover_state: failover.FailoverState,
    event_callback: ?*const fn (event: RunEvent) void,

    pub fn init(allocator: std.mem.Allocator, config: RunConfig) AgentRuntime {
        var run_id: [36]u8 = undefined;
        // Generate a simple run ID
        std.crypto.random.bytes(run_id[0..16]);
        _ = std.fmt.bufPrint(&run_id, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
            run_id[0], run_id[1], run_id[2], run_id[3],
            run_id[4], run_id[5], run_id[6], run_id[7],
            run_id[8], run_id[9], run_id[10], run_id[11],
            run_id[12], run_id[13], run_id[14], run_id[15],
        }) catch {};

        return .{
            .allocator = allocator,
            .config = config,
            .state = .idle,
            .history = .{},
            .turn = 0,
            .run_id = run_id,
            .total_input_tokens = 0,
            .total_output_tokens = 0,
            .failover_state = failover.FailoverState.init(allocator, 3, 30_000),
            .event_callback = null,
        };
    }

    pub fn deinit(self: *AgentRuntime) void {
        for (self.history.items) |msg| {
            self.allocator.free(msg.content);
            if (msg.tool_call_id) |id| self.allocator.free(id);
            if (msg.tool_name) |name| self.allocator.free(name);
        }
        self.history.deinit(self.allocator);
        self.failover_state.deinit();
    }

    /// Add a user message to history
    pub fn addUserMessage(self: *AgentRuntime, content: []const u8) !void {
        const content_copy = try self.allocator.dupe(u8, content);
        try self.history.append(self.allocator, .{
            .role = .user,
            .content = content_copy,
        });
    }

    /// Add an assistant message to history
    pub fn addAssistantMessage(self: *AgentRuntime, content: []const u8) !void {
        const content_copy = try self.allocator.dupe(u8, content);
        try self.history.append(self.allocator, .{
            .role = .assistant,
            .content = content_copy,
        });
    }

    /// Add a tool result to history
    pub fn addToolResult(self: *AgentRuntime, tool_call_id: []const u8, content: []const u8) !void {
        const content_copy = try self.allocator.dupe(u8, content);
        const id_copy = try self.allocator.dupe(u8, tool_call_id);
        try self.history.append(self.allocator, .{
            .role = .tool_result,
            .content = content_copy,
            .tool_call_id = id_copy,
        });
    }

    /// Get message count
    pub fn messageCount(self: *const AgentRuntime) usize {
        return self.history.items.len;
    }

    /// Check if compaction is needed
    pub fn needsCompaction(self: *const AgentRuntime, max_context_tokens: u32) bool {
        var total_bytes: usize = 0;
        for (self.history.items) |msg| {
            total_bytes += msg.content.len;
        }
        return compaction.needsCompaction(total_bytes, max_context_tokens);
    }

    /// Start a new run
    pub fn start(self: *AgentRuntime) void {
        self.state = .running;
        self.turn = 0;
        self.emitEvent(.{
            .event_type = .start,
            .agent_id = self.config.agent_id,
            .run_id = &self.run_id,
        });
    }

    /// Advance to next turn
    pub fn nextTurn(self: *AgentRuntime) bool {
        if (self.state != .running and self.state != .waiting_tool) return false;
        if (self.turn >= self.config.max_turns) {
            self.state = .failed;
            self.emitEvent(.{
                .event_type = .@"error",
                .agent_id = self.config.agent_id,
                .run_id = &self.run_id,
                .error_message = "max turns exceeded",
                .turn = self.turn,
            });
            return false;
        }
        self.turn += 1;
        self.state = .running;
        return true;
    }

    /// Complete the run
    pub fn complete(self: *AgentRuntime, final_text: ?[]const u8) void {
        self.state = .completed;
        self.emitEvent(.{
            .event_type = .complete,
            .agent_id = self.config.agent_id,
            .run_id = &self.run_id,
            .text = final_text,
            .turn = self.turn,
        });
    }

    /// Abort the run
    pub fn abort(self: *AgentRuntime) void {
        self.state = .aborted;
        self.emitEvent(.{
            .event_type = .abort,
            .agent_id = self.config.agent_id,
            .run_id = &self.run_id,
            .turn = self.turn,
        });
    }

    /// Run a single inference step: call provider, process response.
    /// Returns the RunResult with text and/or tool calls.
    pub fn runInference(
        self: *AgentRuntime,
        provider: *ProviderDispatch,
    ) !RunResult {
        if (self.state != .running) return error.InvalidState;

        // Build messages JSON
        const messages_json = try buildMessagesJson(
            self.allocator,
            self.history.items,
            provider.api_type,
        );
        defer self.allocator.free(messages_json);

        // Build request config
        const config = types.RequestConfig{
            .model = self.config.model,
            .system_prompt = self.config.system_prompt,
            .max_tokens = self.config.max_tokens,
            .temperature = self.config.temperature,
            .stream = self.config.stream,
            .api_key = self.config.api_key,
        };

        // Call provider
        var resp = provider.sendMessage(config, messages_json, self.config.tools_json) catch |err| {
            self.state = .failed;
            self.emitEvent(.{
                .event_type = .@"error",
                .agent_id = self.config.agent_id,
                .run_id = &self.run_id,
                .error_message = "provider call failed",
                .turn = self.turn,
            });
            return err;
        };
        defer resp.deinit();

        if (!resp.isSuccess()) {
            self.state = .failed;
            self.emitEvent(.{
                .event_type = .@"error",
                .agent_id = self.config.agent_id,
                .run_id = &self.run_id,
                .error_message = "provider returned error status",
                .turn = self.turn,
            });
            return error.ProviderError;
        }

        // Parse response into RunResult
        var result = try resp.parseRunResult(self.allocator);

        // Update usage
        self.total_input_tokens += result.usage.input_tokens;
        self.total_output_tokens += result.usage.output_tokens;

        // Process result
        if (result.hasToolCalls()) {
            self.state = .waiting_tool;
            // Add assistant message (may have text + tool calls)
            if (result.text) |t| {
                try self.addAssistantMessage(t);
            }
            // Emit tool call events
            for (result.tool_calls) |tc| {
                self.emitEvent(.{
                    .event_type = .tool_call,
                    .agent_id = self.config.agent_id,
                    .run_id = &self.run_id,
                    .tool_name = tc.name,
                    .tool_call_id = tc.id,
                    .tool_input = tc.input_json,
                    .turn = self.turn,
                });
            }
        } else if (result.text) |t| {
            // Text-only response — complete the turn
            try self.addAssistantMessage(t);
            self.emitEvent(.{
                .event_type = .delta,
                .agent_id = self.config.agent_id,
                .run_id = &self.run_id,
                .text = t,
                .turn = self.turn,
            });
        }

        return result;
    }

    /// Submit tool results and transition back to running state.
    pub fn submitToolResults(self: *AgentRuntime, results: []const ToolResultInput) !void {
        if (self.state != .waiting_tool) return error.InvalidState;

        for (results) |r| {
            try self.addToolResult(r.tool_call_id, r.content);
            self.emitEvent(.{
                .event_type = .tool_result,
                .agent_id = self.config.agent_id,
                .run_id = &self.run_id,
                .tool_call_id = r.tool_call_id,
                .text = r.content,
                .turn = self.turn,
            });
        }

        self.state = .running;
    }

    /// Emit a run event
    fn emitEvent(self: *const AgentRuntime, event: RunEvent) void {
        if (self.event_callback) |cb| {
            cb(event);
        }
    }

    /// Get estimated total bytes in history
    pub fn historyBytes(self: *const AgentRuntime) usize {
        var total: usize = 0;
        for (self.history.items) |msg| {
            total += msg.content.len;
        }
        return total;
    }
};

// --- Tests ---

test "RunState labels and terminal" {
    try std.testing.expectEqualStrings("idle", RunState.idle.label());
    try std.testing.expectEqualStrings("running", RunState.running.label());
    try std.testing.expectEqualStrings("completed", RunState.completed.label());

    try std.testing.expect(!RunState.idle.isTerminal());
    try std.testing.expect(!RunState.running.isTerminal());
    try std.testing.expect(RunState.completed.isTerminal());
    try std.testing.expect(RunState.failed.isTerminal());
    try std.testing.expect(RunState.aborted.isTerminal());
}

test "AgentRuntime init and deinit" {
    const allocator = std.testing.allocator;
    var runtime = AgentRuntime.init(allocator, .{
        .agent_id = "test-agent",
        .model = "claude-3-5-sonnet",
    });
    defer runtime.deinit();

    try std.testing.expectEqual(RunState.idle, runtime.state);
    try std.testing.expectEqual(@as(u32, 0), runtime.turn);
    try std.testing.expectEqual(@as(usize, 0), runtime.messageCount());
}

test "AgentRuntime add messages" {
    const allocator = std.testing.allocator;
    var runtime = AgentRuntime.init(allocator, .{});
    defer runtime.deinit();

    try runtime.addUserMessage("Hello");
    try runtime.addAssistantMessage("Hi there!");
    try runtime.addToolResult("call_1", "tool output");

    try std.testing.expectEqual(@as(usize, 3), runtime.messageCount());
    try std.testing.expectEqual(Role.user, runtime.history.items[0].role);
    try std.testing.expectEqual(Role.assistant, runtime.history.items[1].role);
    try std.testing.expectEqual(Role.tool_result, runtime.history.items[2].role);
    try std.testing.expectEqualStrings("Hello", runtime.history.items[0].content);
    try std.testing.expectEqualStrings("Hi there!", runtime.history.items[1].content);
    try std.testing.expectEqualStrings("call_1", runtime.history.items[2].tool_call_id.?);
}

test "AgentRuntime start and turns" {
    const allocator = std.testing.allocator;
    var runtime = AgentRuntime.init(allocator, .{ .max_turns = 3 });
    defer runtime.deinit();

    runtime.start();
    try std.testing.expectEqual(RunState.running, runtime.state);

    // Advance turns
    try std.testing.expect(runtime.nextTurn());
    try std.testing.expectEqual(@as(u32, 1), runtime.turn);

    try std.testing.expect(runtime.nextTurn());
    try std.testing.expectEqual(@as(u32, 2), runtime.turn);

    try std.testing.expect(runtime.nextTurn());
    try std.testing.expectEqual(@as(u32, 3), runtime.turn);

    // Exceeded max turns
    try std.testing.expect(!runtime.nextTurn());
    try std.testing.expectEqual(RunState.failed, runtime.state);
}

test "AgentRuntime complete" {
    const allocator = std.testing.allocator;
    var runtime = AgentRuntime.init(allocator, .{});
    defer runtime.deinit();

    runtime.start();
    runtime.complete("Final answer");

    try std.testing.expectEqual(RunState.completed, runtime.state);
    try std.testing.expect(runtime.state.isTerminal());
}

test "AgentRuntime abort" {
    const allocator = std.testing.allocator;
    var runtime = AgentRuntime.init(allocator, .{});
    defer runtime.deinit();

    runtime.start();
    runtime.abort();

    try std.testing.expectEqual(RunState.aborted, runtime.state);
    try std.testing.expect(runtime.state.isTerminal());
}

test "AgentRuntime needsCompaction" {
    const allocator = std.testing.allocator;
    var runtime = AgentRuntime.init(allocator, .{});
    defer runtime.deinit();

    // Small history shouldn't need compaction
    try runtime.addUserMessage("short");
    try std.testing.expect(!runtime.needsCompaction(200_000));

    // Add lots of content
    const large_content = "x" ** 800_000; // ~200k tokens
    try runtime.addAssistantMessage(large_content);
    try std.testing.expect(runtime.needsCompaction(200_000));
}

test "AgentRuntime historyBytes" {
    const allocator = std.testing.allocator;
    var runtime = AgentRuntime.init(allocator, .{});
    defer runtime.deinit();

    try runtime.addUserMessage("hello"); // 5 bytes
    try runtime.addAssistantMessage("world!"); // 6 bytes

    try std.testing.expectEqual(@as(usize, 11), runtime.historyBytes());
}

test "AgentRuntime event callback" {
    const allocator = std.testing.allocator;

    var runtime = AgentRuntime.init(allocator, .{});
    defer runtime.deinit();

    // Verify callback is null by default
    try std.testing.expect(runtime.event_callback == null);

    // Set a no-op callback
    const noop = struct {
        fn cb(_: RunEvent) void {}
    }.cb;
    runtime.event_callback = noop;
    try std.testing.expect(runtime.event_callback != null);

    // Start should emit event via callback without crash
    runtime.start();
    try std.testing.expectEqual(RunState.running, runtime.state);
}

test "AgentRuntime nextTurn from idle does nothing" {
    const allocator = std.testing.allocator;
    var runtime = AgentRuntime.init(allocator, .{});
    defer runtime.deinit();

    // Can't advance from idle
    try std.testing.expect(!runtime.nextTurn());
    try std.testing.expectEqual(RunState.idle, runtime.state);
}

test "RunEvent fields" {
    const event = RunEvent{
        .event_type = .tool_call,
        .agent_id = "agent-1",
        .run_id = "run-123",
        .tool_name = "bash",
        .tool_call_id = "call_abc",
        .tool_input = "{\"command\":\"ls\"}",
        .turn = 3,
    };
    try std.testing.expectEqual(RunEventType.tool_call, event.event_type);
    try std.testing.expectEqualStrings("bash", event.tool_name.?);
    try std.testing.expectEqual(@as(u32, 3), event.turn);
}

test "RunConfig defaults" {
    const config = RunConfig{};
    try std.testing.expectEqualStrings("main", config.agent_id);
    try std.testing.expectEqual(@as(u32, 25), config.max_turns);
    try std.testing.expectEqual(@as(u32, 4096), config.max_tokens);
    try std.testing.expect(config.stream);
}

// --- ProviderDispatch Tests ---

test "ProviderDispatch.initAnthropic" {
    const responses = [_]http_client.MockTransport.MockResponse{};
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    const dispatch = ProviderDispatch.initAnthropic(&http, "sk-test", null);
    try std.testing.expectEqual(types.ApiType.anthropic_messages, dispatch.api_type);
    try std.testing.expect(dispatch.anthropic_client != null);
    try std.testing.expect(dispatch.openai_client == null);
}

test "ProviderDispatch.initOpenAI" {
    const responses = [_]http_client.MockTransport.MockResponse{};
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    const dispatch = ProviderDispatch.initOpenAI(&http, "sk-test", null);
    try std.testing.expectEqual(types.ApiType.openai_completions, dispatch.api_type);
    try std.testing.expect(dispatch.openai_client != null);
    try std.testing.expect(dispatch.anthropic_client == null);
}

test "ProviderDispatch.sendMessage Anthropic" {
    const mock_sse =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":10}}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}\n\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";

    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = mock_sse },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var dispatch = ProviderDispatch.initAnthropic(&http, "sk-test", null);

    var resp = try dispatch.sendMessage(.{
        .model = "claude-3-5-sonnet",
        .api_key = "sk-test",
    }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
    try std.testing.expectEqual(types.ApiType.anthropic_messages, resp.api_type);
}

test "ProviderDispatch.sendMessage OpenAI" {
    const mock_sse =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n" ++
        "data: [DONE]\n\n";

    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = mock_sse },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var dispatch = ProviderDispatch.initOpenAI(&http, "sk-test", null);

    var resp = try dispatch.sendMessage(.{
        .model = "gpt-4",
        .api_key = "sk-test",
    }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
    try std.testing.expectEqual(types.ApiType.openai_completions, resp.api_type);
}

// --- ProviderResult.parseRunResult Tests ---

test "ProviderResult.parseRunResult text only (Anthropic)" {
    const allocator = std.testing.allocator;
    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":10}}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello \"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"world\"}}\n\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n\n";

    const result_obj = ProviderResult{
        .status = 200,
        .body = body,
        .api_type = .anthropic_messages,
    };

    var result = try result_obj.parseRunResult(allocator);
    defer freeRunResult(allocator, &result);

    try std.testing.expectEqualStrings("Hello world", result.text.?);
    try std.testing.expect(!result.hasToolCalls());
    try std.testing.expectEqual(types.StopReason.end_turn, result.stop_reason.?);
    try std.testing.expectEqual(@as(u64, 10), result.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 5), result.usage.output_tokens);
}

test "ProviderResult.parseRunResult text only (OpenAI)" {
    const allocator = std.testing.allocator;
    const body =
        "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hi \"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"there\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";

    const result_obj = ProviderResult{
        .status = 200,
        .body = body,
        .api_type = .openai_completions,
    };

    var result = try result_obj.parseRunResult(allocator);
    defer freeRunResult(allocator, &result);

    try std.testing.expectEqualStrings("Hi there", result.text.?);
    try std.testing.expect(!result.hasToolCalls());
    try std.testing.expectEqual(types.StopReason.end_turn, result.stop_reason.?);
}

test "ProviderResult.parseRunResult with tool calls (Anthropic)" {
    const allocator = std.testing.allocator;
    const body =
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_abc\",\"name\":\"bash\"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"cmd\\\":\\\"ls\\\"}\" }}\n\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n\n";

    const result_obj = ProviderResult{
        .status = 200,
        .body = body,
        .api_type = .anthropic_messages,
    };

    var result = try result_obj.parseRunResult(allocator);
    defer freeRunResult(allocator, &result);

    try std.testing.expect(result.hasToolCalls());
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings("call_abc", result.tool_calls[0].id);
    try std.testing.expectEqualStrings("bash", result.tool_calls[0].name);
    try std.testing.expectEqual(types.StopReason.tool_use, result.stop_reason.?);
}

test "ProviderResult.parseRunResult with tool calls (OpenAI)" {
    const allocator = std.testing.allocator;
    const body =
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_xyz\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n\n";

    const result_obj = ProviderResult{
        .status = 200,
        .body = body,
        .api_type = .openai_completions,
    };

    var result = try result_obj.parseRunResult(allocator);
    defer freeRunResult(allocator, &result);

    try std.testing.expect(result.hasToolCalls());
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings("call_xyz", result.tool_calls[0].id);
    try std.testing.expectEqualStrings("read", result.tool_calls[0].name);
    try std.testing.expectEqual(types.StopReason.tool_use, result.stop_reason.?);
}

// --- buildMessagesJson Tests ---

test "buildMessagesJson Anthropic" {
    const allocator = std.testing.allocator;
    const msgs = [_]HistoryMessage{
        .{ .role = .user, .content = "Hello" },
        .{ .role = .assistant, .content = "Hi there" },
    };

    const json = try buildMessagesJson(allocator, &msgs, .anthropic_messages);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"assistant\"") != null);
    try std.testing.expect(json[0] == '[');
    try std.testing.expect(json[json.len - 1] == ']');
}

test "buildMessagesJson OpenAI" {
    const allocator = std.testing.allocator;
    const msgs = [_]HistoryMessage{
        .{ .role = .user, .content = "Hello" },
        .{ .role = .assistant, .content = "Hi" },
        .{ .role = .tool_result, .content = "output", .tool_call_id = "call_1" },
    };

    const json = try buildMessagesJson(allocator, &msgs, .openai_completions);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"assistant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tool_call_id\":\"call_1\"") != null);
}

test "buildMessagesJson empty" {
    const allocator = std.testing.allocator;
    const msgs = [_]HistoryMessage{};

    const json = try buildMessagesJson(allocator, &msgs, .anthropic_messages);
    defer allocator.free(json);

    try std.testing.expectEqualStrings("[]", json);
}

// --- RunResult Tests ---

test "RunResult.hasToolCalls" {
    const no_tools = RunResult{};
    try std.testing.expect(!no_tools.hasToolCalls());

    const tool_calls = [_]ToolCall{
        .{ .id = "c1", .name = "bash", .input_json = "{}" },
    };
    const with_tools = RunResult{ .tool_calls = @constCast(&tool_calls) };
    try std.testing.expect(with_tools.hasToolCalls());
}

test "ToolCall fields" {
    const tc = ToolCall{
        .id = "call_abc",
        .name = "bash",
        .input_json = "{\"command\":\"ls\"}",
    };
    try std.testing.expectEqualStrings("call_abc", tc.id);
    try std.testing.expectEqualStrings("bash", tc.name);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", tc.input_json);
}

// --- AgentRuntime inference integration tests ---

test "AgentRuntime.runInference text response (Anthropic)" {
    const allocator = std.testing.allocator;
    const mock_sse =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":15}}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello!\"}}\n\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n";

    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = mock_sse },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(allocator, mock.transport());
    var dispatch = ProviderDispatch.initAnthropic(&http, "sk-test", null);

    var runtime = AgentRuntime.init(allocator, .{
        .model = "claude-3-5-sonnet",
        .api_key = "sk-test",
    });
    defer runtime.deinit();

    try runtime.addUserMessage("Hello");
    runtime.start();
    _ = runtime.nextTurn();

    var result = try runtime.runInference(&dispatch);
    defer freeRunResult(allocator, &result);

    try std.testing.expectEqualStrings("Hello!", result.text.?);
    try std.testing.expect(!result.hasToolCalls());
    try std.testing.expectEqual(@as(u64, 15), runtime.total_input_tokens);
    try std.testing.expectEqual(@as(u64, 3), runtime.total_output_tokens);
    // Assistant message added to history
    try std.testing.expectEqual(@as(usize, 2), runtime.messageCount());
}

test "AgentRuntime.runInference tool call response (Anthropic)" {
    const allocator = std.testing.allocator;
    const mock_sse =
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_1\",\"name\":\"bash\"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"cmd\\\":\\\"ls\\\"}\"}}\n\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n\n";

    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = mock_sse },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(allocator, mock.transport());
    var dispatch = ProviderDispatch.initAnthropic(&http, "sk-test", null);

    var runtime = AgentRuntime.init(allocator, .{
        .model = "claude-3-5-sonnet",
        .api_key = "sk-test",
    });
    defer runtime.deinit();

    try runtime.addUserMessage("Run ls");
    runtime.start();
    _ = runtime.nextTurn();

    var result = try runtime.runInference(&dispatch);
    defer freeRunResult(allocator, &result);

    try std.testing.expect(result.hasToolCalls());
    try std.testing.expectEqual(RunState.waiting_tool, runtime.state);
    try std.testing.expectEqualStrings("call_1", result.tool_calls[0].id);
    try std.testing.expectEqualStrings("bash", result.tool_calls[0].name);
}

test "AgentRuntime.runInference text response (OpenAI)" {
    const allocator = std.testing.allocator;
    const mock_sse =
        "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"World\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";

    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = mock_sse },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(allocator, mock.transport());
    var dispatch = ProviderDispatch.initOpenAI(&http, "sk-test", null);

    var runtime = AgentRuntime.init(allocator, .{
        .model = "gpt-4",
        .api_key = "sk-test",
    });
    defer runtime.deinit();

    try runtime.addUserMessage("Hi");
    runtime.start();
    _ = runtime.nextTurn();

    var result = try runtime.runInference(&dispatch);
    defer freeRunResult(allocator, &result);

    try std.testing.expectEqualStrings("World", result.text.?);
    try std.testing.expectEqual(@as(usize, 2), runtime.messageCount());
}

test "AgentRuntime.runInference provider error" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 500, .body = "{\"error\":\"internal\"}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(allocator, mock.transport());
    var dispatch = ProviderDispatch.initAnthropic(&http, "sk-test", null);

    var runtime = AgentRuntime.init(allocator, .{
        .model = "claude-3-5-sonnet",
        .api_key = "sk-test",
    });
    defer runtime.deinit();

    try runtime.addUserMessage("Hello");
    runtime.start();
    _ = runtime.nextTurn();

    const result = runtime.runInference(&dispatch);
    try std.testing.expectError(error.ProviderError, result);
    try std.testing.expectEqual(RunState.failed, runtime.state);
}

test "AgentRuntime.runInference from wrong state" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{};
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(allocator, mock.transport());
    var dispatch = ProviderDispatch.initAnthropic(&http, "sk-test", null);

    var runtime = AgentRuntime.init(allocator, .{
        .api_key = "sk-test",
    });
    defer runtime.deinit();

    // idle state — can't run inference
    const result = runtime.runInference(&dispatch);
    try std.testing.expectError(error.InvalidState, result);
}

test "AgentRuntime.submitToolResults" {
    const allocator = std.testing.allocator;
    var runtime = AgentRuntime.init(allocator, .{});
    defer runtime.deinit();

    runtime.start();
    _ = runtime.nextTurn();
    runtime.state = .waiting_tool;

    const results = [_]ToolResultInput{
        .{ .tool_call_id = "call_1", .content = "file list: a.txt b.txt" },
    };
    try runtime.submitToolResults(&results);

    try std.testing.expectEqual(RunState.running, runtime.state);
    try std.testing.expectEqual(@as(usize, 1), runtime.messageCount());
    try std.testing.expectEqual(Role.tool_result, runtime.history.items[0].role);
}

test "AgentRuntime.submitToolResults from wrong state" {
    const allocator = std.testing.allocator;
    var runtime = AgentRuntime.init(allocator, .{});
    defer runtime.deinit();

    runtime.start();

    const results = [_]ToolResultInput{
        .{ .tool_call_id = "call_1", .content = "output" },
    };
    const err = runtime.submitToolResults(&results);
    try std.testing.expectError(error.InvalidState, err);
}

// --- Full inference loop integration test ---

test "AgentRuntime full loop: message → tool call → tool result → response" {
    const allocator = std.testing.allocator;

    // First call: tool call
    const tool_call_sse =
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_99\",\"name\":\"read\"}}\n\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n\n";

    // Second call: text response
    const text_sse =
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"The file contains: foo\"}}\n\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n";

    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = tool_call_sse },
        .{ .status = 200, .body = text_sse },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(allocator, mock.transport());
    var dispatch = ProviderDispatch.initAnthropic(&http, "sk-test", null);

    var runtime = AgentRuntime.init(allocator, .{
        .model = "claude-3-5-sonnet",
        .api_key = "sk-test",
        .max_turns = 10,
    });
    defer runtime.deinit();

    // User sends message
    try runtime.addUserMessage("Read the file");
    runtime.start();

    // Turn 1: Provider returns tool call
    try std.testing.expect(runtime.nextTurn());
    var result1 = try runtime.runInference(&dispatch);
    defer freeRunResult(allocator, &result1);

    try std.testing.expect(result1.hasToolCalls());
    try std.testing.expectEqual(RunState.waiting_tool, runtime.state);

    // Submit tool result
    const tool_results = [_]ToolResultInput{
        .{ .tool_call_id = "call_99", .content = "foo" },
    };
    try runtime.submitToolResults(&tool_results);
    try std.testing.expectEqual(RunState.running, runtime.state);

    // Turn 2: Provider returns text
    try std.testing.expect(runtime.nextTurn());
    var result2 = try runtime.runInference(&dispatch);
    defer freeRunResult(allocator, &result2);

    try std.testing.expectEqualStrings("The file contains: foo", result2.text.?);
    try std.testing.expect(!result2.hasToolCalls());

    // Complete
    runtime.complete(result2.text);
    try std.testing.expectEqual(RunState.completed, runtime.state);
    try std.testing.expectEqual(@as(usize, 2), mock.call_count);
}

test "freeRunResult" {
    const allocator = std.testing.allocator;
    const id = try allocator.dupe(u8, "id1");
    const name = try allocator.dupe(u8, "bash");
    const input = try allocator.dupe(u8, "{}");
    const text = try allocator.dupe(u8, "hello");

    var tcs = try allocator.alloc(ToolCall, 1);
    tcs[0] = .{ .id = id, .name = name, .input_json = input };

    var result = RunResult{
        .text = text,
        .tool_calls = tcs,
    };
    freeRunResult(allocator, &result);
}

test "ProviderResult.isSuccess" {
    const ok = ProviderResult{ .status = 200, .body = "", .api_type = .anthropic_messages };
    try std.testing.expect(ok.isSuccess());

    const err_status = ProviderResult{ .status = 500, .body = "", .api_type = .anthropic_messages };
    try std.testing.expect(!err_status.isSuccess());
}

test "ProviderDispatch.initAnthropic custom base_url" {
    const responses = [_]http_client.MockTransport.MockResponse{};
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    const dispatch = ProviderDispatch.initAnthropic(&http, "key", "https://proxy.example.com");
    try std.testing.expectEqualStrings("https://proxy.example.com", dispatch.anthropic_client.?.base_url);
}

test "ProviderDispatch.initOpenAI custom base_url" {
    const responses = [_]http_client.MockTransport.MockResponse{};
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    const dispatch = ProviderDispatch.initOpenAI(&http, "key", "https://openrouter.ai");
    try std.testing.expectEqualStrings("https://openrouter.ai", dispatch.openai_client.?.base_url);
}

// --- initCompat Tests ---

test "ProviderDispatch.initCompat" {
    const responses = [_]http_client.MockTransport.MockResponse{};
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    const dispatch = ProviderDispatch.initCompat(&http, "gsk_test", openai_compat.GROQ);
    try std.testing.expectEqual(types.ApiType.openai_completions, dispatch.api_type);
    try std.testing.expect(dispatch.compat_client != null);
    try std.testing.expect(dispatch.openai_client == null);
    try std.testing.expect(dispatch.anthropic_client == null);
}

test "ProviderDispatch.initCompat sendMessage" {
    const mock_sse =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Groq says hi\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";

    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = mock_sse },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(std.testing.allocator, mock.transport());
    var dispatch = ProviderDispatch.initCompat(&http, "gsk_test", openai_compat.GROQ);

    var resp = try dispatch.sendMessage(.{
        .model = "llama-3.1-70b",
        .api_key = "gsk_test",
    }, "[]", null);
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
    try std.testing.expectEqual(types.ApiType.openai_completions, resp.api_type);
}

test "ProviderDispatch.initCompat parseRunResult" {
    const allocator = std.testing.allocator;
    const mock_sse =
        "data: {\"choices\":[{\"delta\":{\"content\":\"test output\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";

    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = mock_sse },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(allocator, mock.transport());
    var dispatch = ProviderDispatch.initCompat(&http, "key", openai_compat.TOGETHER);

    var resp = try dispatch.sendMessage(.{
        .model = "meta-llama/Meta-Llama-3.1-70B",
        .api_key = "key",
    }, "[]", null);
    defer resp.deinit();

    var result = try resp.parseRunResult(allocator);
    defer freeRunResult(allocator, &result);

    try std.testing.expectEqualStrings("test output", result.text.?);
}

// --- runLoop Tests ---

test "runLoop text-only response completes in one turn" {
    const allocator = std.testing.allocator;
    const mock_sse =
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Done!\"}}\n\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n";

    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = mock_sse },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(allocator, mock.transport());
    var dispatch = ProviderDispatch.initAnthropic(&http, "sk-test", null);

    var runtime = AgentRuntime.init(allocator, .{
        .model = "claude-3-5-sonnet",
        .api_key = "sk-test",
    });
    defer runtime.deinit();

    try runtime.addUserMessage("Hello");

    var result = try runLoop(allocator, &runtime, &dispatch, null);
    defer freeRunResult(allocator, &result);

    try std.testing.expectEqualStrings("Done!", result.text.?);
    try std.testing.expectEqual(RunState.completed, runtime.state);
    try std.testing.expectEqual(@as(u32, 1), runtime.turn);
}

test "runLoop tool dispatch with registry" {
    const allocator = std.testing.allocator;

    // Turn 1: tool call
    const tool_sse =
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"id\":\"c1\",\"name\":\"echo_tool\"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n\n";

    // Turn 2: text response
    const text_sse =
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"All done\"}}\n\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n";

    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = tool_sse },
        .{ .status = 200, .body = text_sse },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(allocator, mock.transport());
    var dispatch = ProviderDispatch.initAnthropic(&http, "sk-test", null);

    // Set up tool registry with a dummy tool
    var registry = tool_registry.ToolRegistry.init(allocator);
    defer registry.deinit();

    const echo_handler = struct {
        fn handle(_: []const u8, output_buf: []u8) tool_registry.ToolResult {
            const msg = "echo output";
            @memcpy(output_buf[0..msg.len], msg);
            return .{ .success = true, .output = output_buf[0..msg.len] };
        }
    }.handle;
    try registry.register(.{ .name = "echo_tool" }, echo_handler);

    var runtime = AgentRuntime.init(allocator, .{
        .model = "claude-3-5-sonnet",
        .api_key = "sk-test",
        .max_turns = 5,
    });
    defer runtime.deinit();

    try runtime.addUserMessage("Do something");

    var result = try runLoop(allocator, &runtime, &dispatch, &registry);
    defer freeRunResult(allocator, &result);

    try std.testing.expectEqualStrings("All done", result.text.?);
    try std.testing.expectEqual(RunState.completed, runtime.state);
    try std.testing.expectEqual(@as(u32, 2), runtime.turn);
    try std.testing.expectEqual(@as(usize, 2), mock.call_count);
}

test "runLoop unknown tool returns tool not found" {
    const allocator = std.testing.allocator;

    // Tool call for unknown tool, then text response
    const tool_sse =
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"id\":\"c1\",\"name\":\"unknown\"}}\n\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n\n";

    const text_sse =
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n";

    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = tool_sse },
        .{ .status = 200, .body = text_sse },
    };
    var mock = http_client.MockTransport.init(&responses);
    var http = http_client.HttpClient.init(allocator, mock.transport());
    var dispatch = ProviderDispatch.initAnthropic(&http, "sk-test", null);

    var registry = tool_registry.ToolRegistry.init(allocator);
    defer registry.deinit();

    var runtime = AgentRuntime.init(allocator, .{
        .api_key = "sk-test",
        .max_turns = 5,
    });
    defer runtime.deinit();

    try runtime.addUserMessage("test");

    var result = try runLoop(allocator, &runtime, &dispatch, &registry);
    defer freeRunResult(allocator, &result);

    try std.testing.expectEqualStrings("ok", result.text.?);
}

test "dispatchToolCall with registry hit" {
    const allocator = std.testing.allocator;
    var registry = tool_registry.ToolRegistry.init(allocator);
    defer registry.deinit();

    const handler = struct {
        fn handle(_: []const u8, buf: []u8) tool_registry.ToolResult {
            const msg = "result";
            @memcpy(buf[0..msg.len], msg);
            return .{ .success = true, .output = buf[0..msg.len] };
        }
    }.handle;
    try registry.register(.{ .name = "test_tool" }, handler);

    const tr = dispatchToolCall(allocator, &registry, .{
        .id = "c1",
        .name = "test_tool",
        .input_json = "{}",
    });
    defer allocator.free(tr.content);

    try std.testing.expectEqualStrings("c1", tr.tool_call_id);
    try std.testing.expectEqualStrings("result", tr.content);
}

test "dispatchToolCall with registry miss" {
    const allocator = std.testing.allocator;
    var registry = tool_registry.ToolRegistry.init(allocator);
    defer registry.deinit();

    const tr = dispatchToolCall(allocator, &registry, .{
        .id = "c2",
        .name = "nonexistent",
        .input_json = "{}",
    });
    defer allocator.free(tr.content);

    try std.testing.expectEqualStrings("c2", tr.tool_call_id);
    try std.testing.expectEqualStrings("tool not found", tr.content);
}

// --- Additional Tests ---

test "RunState all labels non-empty" {
    for (std.meta.tags(RunState)) |rs| {
        try std.testing.expect(rs.label().len > 0);
    }
}

test "RunState waiting_tool label" {
    try std.testing.expectEqualStrings("waiting_tool", RunState.waiting_tool.label());
}

test "RunState compacting label" {
    try std.testing.expectEqualStrings("compacting", RunState.compacting.label());
}

test "RunState waiting_tool not terminal" {
    try std.testing.expect(!RunState.waiting_tool.isTerminal());
}

test "RunState compacting not terminal" {
    try std.testing.expect(!RunState.compacting.isTerminal());
}

test "Role all labels non-empty" {
    for (std.meta.tags(Role)) |r| {
        try std.testing.expect(r.label().len > 0);
    }
}

test "Role tool_result label" {
    try std.testing.expectEqualStrings("tool_result", Role.tool_result.label());
}

test "RunEvent defaults" {
    const event = RunEvent{ .event_type = .start };
    try std.testing.expectEqualStrings("", event.agent_id);
    try std.testing.expectEqualStrings("", event.run_id);
    try std.testing.expect(event.text == null);
    try std.testing.expect(event.tool_name == null);
    try std.testing.expect(event.tool_call_id == null);
    try std.testing.expect(event.tool_input == null);
    try std.testing.expect(event.error_message == null);
    try std.testing.expectEqual(@as(u32, 0), event.turn);
}

test "RunEvent error type" {
    const event = RunEvent{
        .event_type = .@"error",
        .error_message = "something went wrong",
    };
    try std.testing.expectEqual(RunEventType.@"error", event.event_type);
    try std.testing.expectEqualStrings("something went wrong", event.error_message.?);
}

test "HistoryMessage defaults" {
    const msg = HistoryMessage{ .role = .user, .content = "hi" };
    try std.testing.expect(msg.tool_call_id == null);
    try std.testing.expect(msg.tool_name == null);
}

test "HistoryMessage with tool fields" {
    const msg = HistoryMessage{
        .role = .tool_result,
        .content = "output",
        .tool_call_id = "call_1",
        .tool_name = "bash",
    };
    try std.testing.expectEqualStrings("call_1", msg.tool_call_id.?);
    try std.testing.expectEqualStrings("bash", msg.tool_name.?);
}

test "ToolResultInput fields" {
    const tri = ToolResultInput{ .tool_call_id = "tc1", .content = "result" };
    try std.testing.expectEqualStrings("tc1", tri.tool_call_id);
    try std.testing.expectEqualStrings("result", tri.content);
}

test "RunResult defaults" {
    const result = RunResult{};
    try std.testing.expect(result.text == null);
    try std.testing.expect(!result.hasToolCalls());
    try std.testing.expect(result.stop_reason == null);
    try std.testing.expectEqual(@as(u64, 0), result.usage.input_tokens);
}

test "RunConfig custom values" {
    const config = RunConfig{
        .agent_id = "custom",
        .model = "gpt-4o",
        .max_turns = 10,
        .max_tokens = 8192,
        .temperature = 0.7,
        .stream = false,
    };
    try std.testing.expectEqualStrings("custom", config.agent_id);
    try std.testing.expectEqualStrings("gpt-4o", config.model);
    try std.testing.expectEqual(@as(u32, 10), config.max_turns);
    try std.testing.expectEqual(@as(u32, 8192), config.max_tokens);
    try std.testing.expect(!config.stream);
}

test "RunConfig system_prompt default null" {
    const config = RunConfig{};
    try std.testing.expect(config.system_prompt == null);
    try std.testing.expect(config.tools_json == null);
    try std.testing.expect(config.temperature == null);
}

test "AgentRuntime run_id is populated" {
    const allocator = std.testing.allocator;
    var runtime = AgentRuntime.init(allocator, .{});
    defer runtime.deinit();

    // run_id should be non-zero after init
    try std.testing.expectEqual(@as(usize, 36), runtime.run_id.len);
}

test "AgentRuntime token tracking starts at zero" {
    const allocator = std.testing.allocator;
    var runtime = AgentRuntime.init(allocator, .{});
    defer runtime.deinit();

    try std.testing.expectEqual(@as(u64, 0), runtime.total_input_tokens);
    try std.testing.expectEqual(@as(u64, 0), runtime.total_output_tokens);
}

test "AgentRuntime multiple user messages" {
    const allocator = std.testing.allocator;
    var runtime = AgentRuntime.init(allocator, .{});
    defer runtime.deinit();

    try runtime.addUserMessage("msg1");
    try runtime.addUserMessage("msg2");
    try runtime.addUserMessage("msg3");

    try std.testing.expectEqual(@as(usize, 3), runtime.messageCount());
    try std.testing.expectEqualStrings("msg1", runtime.history.items[0].content);
    try std.testing.expectEqualStrings("msg3", runtime.history.items[2].content);
}

test "AgentRuntime historyBytes empty" {
    const allocator = std.testing.allocator;
    var runtime = AgentRuntime.init(allocator, .{});
    defer runtime.deinit();

    try std.testing.expectEqual(@as(usize, 0), runtime.historyBytes());
}

test "AgentRuntime start changes state from idle" {
    const allocator = std.testing.allocator;
    var runtime = AgentRuntime.init(allocator, .{});
    defer runtime.deinit();

    try std.testing.expectEqual(RunState.idle, runtime.state);
    runtime.start();
    try std.testing.expectEqual(RunState.running, runtime.state);
    try std.testing.expectEqual(@as(u32, 0), runtime.turn);
}

test "AgentRuntime max_turns 1" {
    const allocator = std.testing.allocator;
    var runtime = AgentRuntime.init(allocator, .{ .max_turns = 1 });
    defer runtime.deinit();

    runtime.start();
    try std.testing.expect(runtime.nextTurn()); // turn 1
    try std.testing.expect(!runtime.nextTurn()); // exceeded
    try std.testing.expectEqual(RunState.failed, runtime.state);
}

test "AgentRuntime complete then nextTurn fails" {
    const allocator = std.testing.allocator;
    var runtime = AgentRuntime.init(allocator, .{});
    defer runtime.deinit();

    runtime.start();
    runtime.complete("done");
    try std.testing.expect(!runtime.nextTurn());
}

test "AgentRuntime abort then nextTurn fails" {
    const allocator = std.testing.allocator;
    var runtime = AgentRuntime.init(allocator, .{});
    defer runtime.deinit();

    runtime.start();
    runtime.abort();
    try std.testing.expect(!runtime.nextTurn());
}

test "ProviderResult isSuccess boundary" {
    const ok_200 = ProviderResult{ .status = 200, .body = "", .api_type = .anthropic_messages };
    try std.testing.expect(ok_200.isSuccess());

    const ok_299 = ProviderResult{ .status = 299, .body = "", .api_type = .anthropic_messages };
    try std.testing.expect(ok_299.isSuccess());

    const fail_300 = ProviderResult{ .status = 300, .body = "", .api_type = .anthropic_messages };
    try std.testing.expect(!fail_300.isSuccess());

    const fail_199 = ProviderResult{ .status = 199, .body = "", .api_type = .anthropic_messages };
    try std.testing.expect(!fail_199.isSuccess());

    const fail_400 = ProviderResult{ .status = 400, .body = "", .api_type = .anthropic_messages };
    try std.testing.expect(!fail_400.isSuccess());
}

test "buildMessagesJson single user message Anthropic" {
    const allocator = std.testing.allocator;
    const msgs = [_]HistoryMessage{
        .{ .role = .user, .content = "test" },
    };

    const json = try buildMessagesJson(allocator, &msgs, .anthropic_messages);
    defer allocator.free(json);

    try std.testing.expect(json[0] == '[');
    try std.testing.expect(json[json.len - 1] == ']');
    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"user\"") != null);
}

test "buildMessagesJson tool_result Anthropic" {
    const allocator = std.testing.allocator;
    const msgs = [_]HistoryMessage{
        .{ .role = .tool_result, .content = "output", .tool_call_id = "tc_1" },
    };

    const json = try buildMessagesJson(allocator, &msgs, .anthropic_messages);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "tc_1") != null);
}
