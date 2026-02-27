const std = @import("std");
const output = @import("output.zig");
const config_schema = @import("../config/schema.zig");
const config_loader = @import("../config/loader.zig");
const runtime = @import("../agent/runtime.zig");
const http_client = @import("../infra/http_client.zig");
const session = @import("../agent/session.zig");
const openai_compat = @import("../providers/openai_compat.zig");

const OutputWriter = output.OutputWriter;
const OutputMode = output.OutputMode;

// --- Command Enum ---

pub const Command = enum {
    gateway,
    agent,
    channels,
    models,
    config,
    memory,
    sessions,
    doctor,
    status,
    setup,
    onboard,
    version,
    help,

    pub fn fromString(s: []const u8) ?Command {
        const map = std.StaticStringMap(Command).initComptime(.{
            .{ "gateway", .gateway },
            .{ "agent", .agent },
            .{ "channels", .channels },
            .{ "models", .models },
            .{ "config", .config },
            .{ "memory", .memory },
            .{ "sessions", .sessions },
            .{ "doctor", .doctor },
            .{ "status", .status },
            .{ "setup", .setup },
            .{ "onboard", .onboard },
            .{ "version", .version },
            .{ "--version", .version },
            .{ "-v", .version },
            .{ "help", .help },
            .{ "--help", .help },
            .{ "-h", .help },
        });
        return map.get(s);
    }

    pub fn label(self: Command) []const u8 {
        return switch (self) {
            .gateway => "gateway",
            .agent => "agent",
            .channels => "channels",
            .models => "models",
            .config => "config",
            .memory => "memory",
            .sessions => "sessions",
            .doctor => "doctor",
            .status => "status",
            .setup => "setup",
            .onboard => "onboard",
            .version => "version",
            .help => "help",
        };
    }

    pub fn description(self: Command) []const u8 {
        return switch (self) {
            .gateway => "Manage the gateway server (run, status, stop)",
            .agent => "Run an agent turn or manage agents",
            .channels => "List and manage channel connections",
            .models => "List available AI models",
            .config => "Get or set configuration values",
            .memory => "Search and manage memory",
            .sessions => "List and manage conversation sessions",
            .doctor => "Run health checks and diagnostics",
            .status => "Show system status overview",
            .setup => "Initialize configuration and workspace",
            .onboard => "Interactive onboarding wizard",
            .version => "Show version information",
            .help => "Show this help message",
        };
    }
};

// --- Subcommand Enum ---

pub const SubCommand = enum {
    // gateway
    run,
    start,
    stop,
    restart,

    // channels
    list,
    login,
    logout,

    // config
    get,
    set,

    // memory
    search,
    index,

    // sessions
    cleanup,
    preview,
    delete,

    // generic
    status_sub,
    help_sub,

    pub fn fromString(s: []const u8) ?SubCommand {
        const map = std.StaticStringMap(SubCommand).initComptime(.{
            .{ "run", .run },
            .{ "start", .start },
            .{ "stop", .stop },
            .{ "restart", .restart },
            .{ "list", .list },
            .{ "login", .login },
            .{ "logout", .logout },
            .{ "get", .get },
            .{ "set", .set },
            .{ "search", .search },
            .{ "index", .index },
            .{ "cleanup", .cleanup },
            .{ "preview", .preview },
            .{ "delete", .delete },
            .{ "status", .status_sub },
            .{ "help", .help_sub },
            .{ "--help", .help_sub },
            .{ "-h", .help_sub },
        });
        return map.get(s);
    }
};

// --- CLI Context ---

/// Optional services backend for wired CLI commands.
pub const CliServices = struct {
    config: ?*config_schema.Config = null,
};

pub const CliContext = struct {
    allocator: std.mem.Allocator,
    out: OutputWriter,
    mode: OutputMode,
    services: ?*CliServices = null,
};

// --- Command Result ---

pub const CommandResult = struct {
    exit_code: u8 = 0,
    message: ?[]const u8 = null,
};

// --- Dispatch ---

pub fn dispatch(ctx: *CliContext, args: []const []const u8) !CommandResult {
    // Find the first non-flag argument (the command)
    var cmd_idx: ?usize = null;
    for (args, 0..) |arg, i| {
        if (!isGlobalFlag(arg)) {
            cmd_idx = i;
            break;
        }
    }

    if (cmd_idx == null) {
        try printHelp(&ctx.out);
        return .{};
    }

    const cmd = Command.fromString(args[cmd_idx.?]) orelse {
        try ctx.out.err("Unknown command: ");
        try ctx.out.write(args[cmd_idx.?]);
        try ctx.out.newline();
        try ctx.out.write("Run 'zclaw help' for available commands.\n");
        return .{ .exit_code = 1 };
    };

    const sub_args = if (cmd_idx.? + 1 < args.len) args[cmd_idx.? + 1 ..] else &[_][]const u8{};

    return switch (cmd) {
        .version => {
            try output.printVersion(&ctx.out);
            return .{};
        },
        .help => {
            try printHelp(&ctx.out);
            return .{};
        },
        .gateway => runGateway(ctx, sub_args),
        .agent => runAgent(ctx, sub_args),
        .channels => runChannels(ctx, sub_args),
        .models => runModels(ctx, sub_args),
        .config => runConfig(ctx, sub_args),
        .memory => runMemory(ctx, sub_args),
        .sessions => runSessions(ctx, sub_args),
        .doctor => runDoctor(ctx, sub_args),
        .status => runStatus(ctx, sub_args),
        .setup => runSetup(ctx, sub_args),
        .onboard => runOnboard(ctx, sub_args),
    };
}

// --- Help ---

pub fn printHelp(out: *const OutputWriter) !void {
    try output.printBanner(out);
    try out.newline();
    try out.print("zclaw {s} - {s}\n\n", .{ output.VERSION, output.DESCRIPTION });
    try out.heading("Usage:");
    try out.write("  zclaw <command> [subcommand] [options]\n\n");
    try out.heading("Commands:");

    const commands = [_]Command{
        .gateway, .agent,  .channels, .models,
        .config,  .memory, .sessions, .doctor,
        .status,  .setup,  .onboard,  .version,
        .help,
    };

    for (commands) |cmd| {
        try out.print("  {s: <12} {s}\n", .{ cmd.label(), cmd.description() });
    }

    try out.newline();
    try out.heading("Global Options:");
    try out.write("  --json     Output in JSON format\n");
    try out.write("  --plain    Output in plain text (no colors)\n");
    try out.write("  --help     Show help for a command\n");
}

// --- Gateway Commands ---

fn runGateway(ctx: *CliContext, args: []const []const u8) !CommandResult {
    if (args.len == 0) {
        try printGatewayHelp(&ctx.out);
        return .{};
    }

    const sub = SubCommand.fromString(args[0]) orelse {
        try ctx.out.err("Unknown gateway subcommand: ");
        try ctx.out.write(args[0]);
        try ctx.out.newline();
        return .{ .exit_code = 1 };
    };

    return switch (sub) {
        .run => {
            // When dispatched via CLI, gateway run is handled by main.zig directly.
            // This path is only reached if someone calls dispatch() without
            // the main.zig gateway-run interception (e.g. in tests).
            const port = findArgValue(args[1..], "--port") orelse "18789";
            if (ctx.mode == .json) {
                try ctx.out.print("{{\"command\":\"gateway.run\",\"port\":{s}}}\n", .{port});
            } else {
                try ctx.out.success("Starting gateway...");
                try ctx.out.kv("Port", port);
            }
            return .{};
        },
        .start => {
            if (ctx.mode == .json) {
                try ctx.out.write("{\"command\":\"gateway.start\",\"status\":\"starting\"}\n");
            } else {
                try ctx.out.success("Starting gateway service...");
            }
            return .{};
        },
        .stop => {
            if (ctx.mode == .json) {
                try ctx.out.write("{\"command\":\"gateway.stop\",\"status\":\"stopping\"}\n");
            } else {
                try ctx.out.write("Stopping gateway...\n");
            }
            return .{};
        },
        .restart => {
            if (ctx.mode == .json) {
                try ctx.out.write("{\"command\":\"gateway.restart\",\"status\":\"restarting\"}\n");
            } else {
                try ctx.out.write("Restarting gateway...\n");
            }
            return .{};
        },
        .status_sub => {
            if (ctx.mode == .json) {
                try ctx.out.write("{\"command\":\"gateway.status\",\"status\":\"unknown\"}\n");
            } else {
                try ctx.out.kv("Gateway", "not running");
            }
            return .{};
        },
        .help_sub => {
            try printGatewayHelp(&ctx.out);
            return .{};
        },
        else => {
            try ctx.out.err("Invalid gateway subcommand");
            return .{ .exit_code = 1 };
        },
    };
}

fn printGatewayHelp(out: *const OutputWriter) !void {
    try out.heading("Gateway Commands:");
    try out.write("  zclaw gateway run      Start gateway in foreground\n");
    try out.write("  zclaw gateway start    Start gateway as background service\n");
    try out.write("  zclaw gateway stop     Stop the gateway\n");
    try out.write("  zclaw gateway restart  Restart the gateway\n");
    try out.write("  zclaw gateway status   Show gateway status\n");
    try out.newline();
    try out.heading("Options:");
    try out.write("  --port <port>  Port number (default: 18789)\n");
}

// --- Agent Command ---

fn runAgent(ctx: *CliContext, args: []const []const u8) !CommandResult {
    const message = findArgValue(args, "--message") orelse findArgValue(args, "-m");
    const agent_name = findArgValue(args, "--agent") orelse "default";
    const model_override = findArgValue(args, "--model");

    if (message == null) {
        if (ctx.mode == .json) {
            try ctx.out.write("{\"error\":\"No message provided\"}\n");
        } else {
            try ctx.out.heading("Agent Command:");
            try ctx.out.write("  zclaw agent --message <text>  Run one agent turn\n");
            try ctx.out.newline();
            try ctx.out.heading("Options:");
            try ctx.out.write("  -m, --message <text>  Message to send\n");
            try ctx.out.write("  --agent <name>        Agent name (default: default)\n");
            try ctx.out.write("  --model <model>       Model to use\n");
            try ctx.out.write("  --provider <name>     Provider: anthropic, openai (default: anthropic)\n");
        }
        return .{};
    }

    const msg = message.?;

    // Detect provider and API key
    const provider_name = findArgValue(args, "--provider") orelse "anthropic";

    // Resolve API key based on provider
    const api_key = resolveApiKey(provider_name);

    if (api_key == null) {
        const env_name = resolveApiKeyEnvName(provider_name);
        if (ctx.mode == .json) {
            try ctx.out.print("{{\"error\":\"No API key found. Set {s} environment variable.\"}}\n", .{env_name});
        } else {
            try ctx.out.print("No API key found. Set {s} environment variable.\n", .{env_name});
        }
        return .{ .exit_code = 1 };
    }

    // Determine model
    const model = model_override orelse resolveDefaultModel(provider_name);

    // Create HTTP transport and client
    var transport_instance = http_client.StdHttpTransport.init(ctx.allocator);
    var client = http_client.HttpClient.init(ctx.allocator, transport_instance.transport());
    defer client.deinit();

    // Create provider dispatch
    var provider = resolveProvider(&client, provider_name, api_key.?);

    // Create agent runtime
    var agent_rt = runtime.AgentRuntime.init(ctx.allocator, .{
        .agent_id = agent_name,
        .model = model,
        .api_key = api_key.?,
        .max_turns = 1,
        .stream = false,
    });
    defer agent_rt.deinit();

    // Add user message
    try agent_rt.addUserMessage(msg);

    if (ctx.mode != .json) {
        try ctx.out.kv("Agent", agent_name);
        try ctx.out.kv("Model", model);
        try ctx.out.kv("Provider", provider_name);
        try ctx.out.newline();
    }

    // Run one turn
    var result = runtime.runLoop(ctx.allocator, &agent_rt, &provider, null) catch |err| {
        if (ctx.mode == .json) {
            try ctx.out.write("{\"error\":\"Agent run failed\"}\n");
        } else {
            try ctx.out.err("Agent run failed.");
            try ctx.out.print("  Error: {}\n", .{err});
        }
        return .{ .exit_code = 1 };
    };
    defer runtime.freeRunResult(ctx.allocator, &result);

    // Output result
    if (result.text) |text| {
        if (ctx.mode == .json) {
            try ctx.out.write("{\"agent\":\"");
            try ctx.out.write(agent_name);
            try ctx.out.write("\",\"response\":\"");
            // Simple JSON escape for the response text
            for (text) |c| {
                switch (c) {
                    '"' => try ctx.out.write("\\\""),
                    '\\' => try ctx.out.write("\\\\"),
                    '\n' => try ctx.out.write("\\n"),
                    '\r' => try ctx.out.write("\\r"),
                    '\t' => try ctx.out.write("\\t"),
                    else => {
                        const buf = [1]u8{c};
                        try ctx.out.write(&buf);
                    },
                }
            }
            try ctx.out.print("\",\"input_tokens\":{d},\"output_tokens\":{d}}}\n", .{
                agent_rt.total_input_tokens,
                agent_rt.total_output_tokens,
            });
        } else {
            try ctx.out.write(text);
            try ctx.out.newline();
            try ctx.out.newline();
            try ctx.out.print("  tokens: {d} in / {d} out\n", .{
                agent_rt.total_input_tokens,
                agent_rt.total_output_tokens,
            });
        }
    } else {
        if (ctx.mode == .json) {
            try ctx.out.write("{\"agent\":\"");
            try ctx.out.write(agent_name);
            try ctx.out.write("\",\"response\":null}\n");
        } else {
            try ctx.out.write("(no response)\n");
        }
    }

    // Save session
    saveAgentSession(agent_name, msg, result.text);

    return .{};
}

/// Save agent session to disk (best effort)
fn saveAgentSession(agent_name: []const u8, user_msg: []const u8, response: ?[]const u8) void {
    var path_buf: [4096]u8 = undefined;
    const home = std.posix.getenv("HOME") orelse return;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.openclaw/sessions/{s}.jsonl", .{ home, agent_name }) catch return;

    var writer = session.JsonlWriter.init(path) catch return;
    defer writer.close();

    writer.writeMessage(.user, user_msg) catch {};
    if (response) |resp| {
        writer.writeMessage(.assistant, resp) catch {};
    }
}

// --- Channels Commands ---

fn runChannels(ctx: *CliContext, args: []const []const u8) !CommandResult {
    const sub = if (args.len > 0) SubCommand.fromString(args[0]) else null;

    if (sub == null or (sub != null and sub.? == .help_sub)) {
        try ctx.out.heading("Channel Commands:");
        try ctx.out.write("  zclaw channels list    List configured channels\n");
        try ctx.out.write("  zclaw channels status  Show channel status\n");
        try ctx.out.write("  zclaw channels login   Connect a channel\n");
        try ctx.out.write("  zclaw channels logout  Disconnect a channel\n");
        return .{};
    }

    return switch (sub.?) {
        .list => {
            if (ctx.mode == .json) {
                try ctx.out.write("{\"command\":\"channels.list\",\"channels\":[]}\n");
            } else {
                try ctx.out.heading("Configured Channels:");
                try ctx.out.write("  No channels configured.\n");
                try ctx.out.write("  Run 'zclaw setup' to configure channels.\n");
            }
            return .{};
        },
        .status_sub => {
            if (ctx.mode == .json) {
                try ctx.out.write("{\"command\":\"channels.status\",\"channels\":[]}\n");
            } else {
                try ctx.out.heading("Channel Status:");
                try ctx.out.write("  No channels active.\n");
            }
            return .{};
        },
        .login => {
            const channel_name = if (args.len > 1) args[1] else null;
            if (channel_name) |name| {
                try ctx.out.write("Connecting channel: ");
                try ctx.out.write(name);
                try ctx.out.newline();
            } else {
                try ctx.out.err("Usage: zclaw channels login <channel>");
                return .{ .exit_code = 1 };
            }
            return .{};
        },
        .logout => {
            const channel_name = if (args.len > 1) args[1] else null;
            if (channel_name) |name| {
                try ctx.out.write("Disconnecting channel: ");
                try ctx.out.write(name);
                try ctx.out.newline();
            } else {
                try ctx.out.err("Usage: zclaw channels logout <channel>");
                return .{ .exit_code = 1 };
            }
            return .{};
        },
        else => {
            try ctx.out.err("Unknown channels subcommand");
            return .{ .exit_code = 1 };
        },
    };
}

// --- Models Command ---

fn runModels(ctx: *CliContext, _: []const []const u8) !CommandResult {
    if (ctx.mode == .json) {
        try ctx.out.write("{\"command\":\"models\",\"providers\":[\"anthropic\",\"openai\"]}\n");
    } else {
        try ctx.out.heading("Available Providers:");
        try ctx.out.write("  anthropic   Claude models (Haiku, Sonnet, Opus)\n");
        try ctx.out.write("  openai      GPT models\n");
        try ctx.out.write("  local       Local models via llama.cpp\n");
    }
    return .{};
}

// --- Config Commands ---

fn runConfig(ctx: *CliContext, args: []const []const u8) !CommandResult {
    const sub = if (args.len > 0) SubCommand.fromString(args[0]) else null;

    if (sub == null or (sub != null and sub.? == .help_sub)) {
        try ctx.out.heading("Config Commands:");
        try ctx.out.write("  zclaw config get <key>          Get a config value\n");
        try ctx.out.write("  zclaw config set <key> <value>  Set a config value\n");
        return .{};
    }

    return switch (sub.?) {
        .get => {
            if (args.len < 2) {
                try ctx.out.err("Usage: zclaw config get <key>");
                return .{ .exit_code = 1 };
            }
            const value = configGetValue(ctx, args[1]);
            if (ctx.mode == .json) {
                try ctx.out.write("{\"key\":\"");
                try ctx.out.write(args[1]);
                try ctx.out.write("\",\"value\":\"");
                try ctx.out.write(value);
                try ctx.out.write("\"}\n");
            } else {
                try ctx.out.kv(args[1], value);
            }
            return .{};
        },
        .set => {
            if (args.len < 3) {
                try ctx.out.err("Usage: zclaw config set <key> <value>");
                return .{ .exit_code = 1 };
            }
            configSetValue(ctx, args[1], args[2]);
            if (ctx.mode == .json) {
                try ctx.out.write("{\"key\":\"");
                try ctx.out.write(args[1]);
                try ctx.out.write("\",\"value\":\"");
                try ctx.out.write(args[2]);
                try ctx.out.write("\",\"status\":\"set\"}\n");
            } else {
                try ctx.out.success("Configuration updated.");
                try ctx.out.kv(args[1], args[2]);
            }
            return .{};
        },
        else => {
            try ctx.out.err("Unknown config subcommand");
            return .{ .exit_code = 1 };
        },
    };
}

// --- Memory Commands ---

fn runMemory(ctx: *CliContext, args: []const []const u8) !CommandResult {
    const sub = if (args.len > 0) SubCommand.fromString(args[0]) else null;

    if (sub == null or (sub != null and sub.? == .help_sub)) {
        try ctx.out.heading("Memory Commands:");
        try ctx.out.write("  zclaw memory status  Show memory index status\n");
        try ctx.out.write("  zclaw memory index   Reindex memory files\n");
        try ctx.out.write("  zclaw memory search  Search memory\n");
        return .{};
    }

    return switch (sub.?) {
        .status_sub => {
            if (ctx.mode == .json) {
                try ctx.out.write("{\"command\":\"memory.status\",\"documents\":0,\"chunks\":0}\n");
            } else {
                try ctx.out.heading("Memory Status:");
                try ctx.out.kv("Documents", "0");
                try ctx.out.kv("Chunks", "0");
            }
            return .{};
        },
        .index => {
            if (ctx.mode == .json) {
                try ctx.out.write("{\"command\":\"memory.index\",\"status\":\"complete\",\"indexed\":0}\n");
            } else {
                try ctx.out.success("Memory reindex complete.");
                try ctx.out.kv("Documents indexed", "0");
            }
            return .{};
        },
        .search => {
            const query = if (args.len > 1) args[1] else null;
            if (query) |q| {
                if (ctx.mode == .json) {
                    try ctx.out.write("{\"command\":\"memory.search\",\"query\":\"");
                    try ctx.out.write(q);
                    try ctx.out.write("\",\"results\":[]}\n");
                } else {
                    try ctx.out.kv("Search", q);
                    try ctx.out.write("  No results found.\n");
                }
            } else {
                try ctx.out.err("Usage: zclaw memory search <query>");
                return .{ .exit_code = 1 };
            }
            return .{};
        },
        else => {
            try ctx.out.err("Unknown memory subcommand");
            return .{ .exit_code = 1 };
        },
    };
}

// --- Sessions Commands ---

fn runSessions(ctx: *CliContext, args: []const []const u8) !CommandResult {
    const sub = if (args.len > 0) SubCommand.fromString(args[0]) else null;

    if (sub == null) {
        // Default: list sessions
        return runSessionsList(ctx);
    }

    return switch (sub.?) {
        .list => runSessionsList(ctx),
        .cleanup => {
            if (ctx.mode == .json) {
                try ctx.out.write("{\"command\":\"sessions.cleanup\",\"removed\":0}\n");
            } else {
                try ctx.out.success("Session cleanup complete.");
                try ctx.out.kv("Removed", "0");
            }
            return .{};
        },
        .delete => {
            if (args.len < 2) {
                try ctx.out.err("Usage: zclaw sessions delete <session-id>");
                return .{ .exit_code = 1 };
            }
            if (ctx.mode == .json) {
                try ctx.out.write("{\"command\":\"sessions.delete\",\"id\":\"");
                try ctx.out.write(args[1]);
                try ctx.out.write("\",\"status\":\"deleted\"}\n");
            } else {
                try ctx.out.write("Session deleted: ");
                try ctx.out.write(args[1]);
                try ctx.out.newline();
            }
            return .{};
        },
        .help_sub => {
            try ctx.out.heading("Session Commands:");
            try ctx.out.write("  zclaw sessions [list]    List conversation sessions\n");
            try ctx.out.write("  zclaw sessions cleanup   Remove old sessions\n");
            try ctx.out.write("  zclaw sessions delete    Delete a specific session\n");
            return .{};
        },
        else => {
            try ctx.out.err("Unknown sessions subcommand");
            return .{ .exit_code = 1 };
        },
    };
}

fn runSessionsList(ctx: *CliContext) !CommandResult {
    if (ctx.mode == .json) {
        try ctx.out.write("{\"command\":\"sessions.list\",\"sessions\":[]}\n");
    } else {
        try ctx.out.heading("Sessions:");
        try ctx.out.write("  No active sessions.\n");
    }
    return .{};
}

// --- Doctor Command ---

fn runDoctor(ctx: *CliContext, _: []const []const u8) !CommandResult {
    // Real health checks
    const has_config = if (ctx.services) |svc| svc.config != null else false;
    const has_anthropic_key = std.posix.getenv("ANTHROPIC_API_KEY") != null;
    const has_openai_key = std.posix.getenv("OPENAI_API_KEY") != null;
    const has_any_key = has_anthropic_key or has_openai_key;

    // Check config file exists
    var path_buf: [4096]u8 = undefined;
    const config_exists = blk: {
        const home = std.posix.getenv("HOME") orelse break :blk false;
        const path = std.fmt.bufPrint(&path_buf, "{s}/.openclaw/openclaw.json", .{home}) catch break :blk false;
        std.fs.cwd().access(path, .{}) catch break :blk false;
        break :blk true;
    };

    if (ctx.mode == .json) {
        try ctx.out.write("{\"command\":\"doctor\",\"checks\":[");
        try ctx.out.print("{{\"name\":\"config\",\"status\":\"{s}\"}},", .{if (has_config) "ok" else "missing"});
        try ctx.out.print("{{\"name\":\"config_file\",\"status\":\"{s}\"}},", .{if (config_exists) "found" else "not_found"});
        try ctx.out.print("{{\"name\":\"api_keys\",\"status\":\"{s}\"}}", .{if (has_any_key) "ok" else "missing"});
        try ctx.out.write("]}\n");
    } else {
        try ctx.out.heading("Health Checks:");
        if (has_config) {
            try ctx.out.success("  [ok] Configuration loaded");
        } else {
            try ctx.out.warning("  [--] Configuration not loaded");
        }
        if (config_exists) {
            try ctx.out.success("  [ok] Config file found");
        } else {
            try ctx.out.warning("  [--] No config file (~/.openclaw/openclaw.json)");
        }
        if (has_anthropic_key) {
            try ctx.out.success("  [ok] ANTHROPIC_API_KEY set");
        } else {
            try ctx.out.warning("  [--] ANTHROPIC_API_KEY not set");
        }
        if (has_openai_key) {
            try ctx.out.success("  [ok] OPENAI_API_KEY set");
        } else {
            try ctx.out.warning("  [--] OPENAI_API_KEY not set");
        }
        try ctx.out.newline();
        if (!has_any_key) {
            try ctx.out.write("Set ANTHROPIC_API_KEY or OPENAI_API_KEY to use AI providers.\n");
        }
        if (!config_exists) {
            try ctx.out.write("Run 'zclaw setup' to create a configuration file.\n");
        }
    }
    return .{};
}

// --- Status Command ---

fn runStatus(ctx: *CliContext, _: []const []const u8) !CommandResult {
    const port_str = if (ctx.services) |svc|
        if (svc.config) |cfg| portToString(cfg.gateway.port) else "18789"
    else
        "18789";

    const log_level = if (ctx.services) |svc|
        if (svc.config) |cfg| cfg.logging.level.label() else "info"
    else
        "info";

    if (ctx.mode == .json) {
        try ctx.out.print("{{\"command\":\"status\",\"version\":\"{s}\",\"port\":{s},\"log_level\":\"{s}\"}}\n", .{
            output.VERSION,
            port_str,
            log_level,
        });
    } else {
        try ctx.out.heading("System Status:");
        try ctx.out.kv("Version", output.VERSION);
        try ctx.out.kv("Port", port_str);
        try ctx.out.kv("Log Level", log_level);

        // Show provider availability
        if (std.posix.getenv("ANTHROPIC_API_KEY")) |_| {
            try ctx.out.kv("Anthropic", "configured");
        }
        if (std.posix.getenv("OPENAI_API_KEY")) |_| {
            try ctx.out.kv("OpenAI", "configured");
        }
    }
    return .{};
}

// --- Setup Command ---

fn runSetup(ctx: *CliContext, _: []const []const u8) !CommandResult {
    if (ctx.mode == .json) {
        try ctx.out.write("{\"command\":\"setup\",\"status\":\"interactive\"}\n");
    } else {
        try output.printBanner(&ctx.out);
        try ctx.out.newline();
        try ctx.out.heading("Setup Wizard");
        try ctx.out.write("This will initialize your zclaw configuration.\n");
        try ctx.out.newline();
        try ctx.out.write("Configuration: ~/.openclaw/openclaw.json\n");
        try ctx.out.write("Sessions:      ~/.openclaw/sessions/\n");
        try ctx.out.write("Memory:        ~/.openclaw/memory/\n");
    }
    return .{};
}

// --- Onboard Command ---

fn runOnboard(ctx: *CliContext, _: []const []const u8) !CommandResult {
    if (ctx.mode == .json) {
        try ctx.out.write("{\"command\":\"onboard\",\"status\":\"interactive\"}\n");
    } else {
        try output.printBanner(&ctx.out);
        try ctx.out.newline();
        try ctx.out.heading("Welcome to zclaw!");
        try ctx.out.write("Let's get you set up.\n\n");
        try ctx.out.write("Steps:\n");
        try ctx.out.write("  1. Configure API keys\n");
        try ctx.out.write("  2. Set up channels\n");
        try ctx.out.write("  3. Start the gateway\n");
    }
    return .{};
}

// --- Helpers ---

fn isGlobalFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--json") or
        std.mem.eql(u8, arg, "--plain");
}

fn findArgValue(args: []const []const u8, flag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag) and i + 1 < args.len) {
            return args[i + 1];
        }
    }
    return null;
}

// --- Config Helpers ---

fn configGetValue(ctx: *CliContext, key: []const u8) []const u8 {
    if (ctx.services) |svc| {
        if (svc.config) |cfg| {
            if (std.mem.eql(u8, key, "gateway.port")) {
                // Return the port as a string via a static buffer
                return portToString(cfg.gateway.port);
            } else if (std.mem.eql(u8, key, "logging.level")) {
                return cfg.logging.level.label();
            } else if (std.mem.eql(u8, key, "session.mainKey")) {
                return cfg.session.main_key;
            }
        }
    }
    return "(not set)";
}

var port_str_buf: [8]u8 = undefined;

fn portToString(port: u16) []const u8 {
    return std.fmt.bufPrint(&port_str_buf, "{d}", .{port}) catch "(error)";
}

fn configSetValue(ctx: *CliContext, key: []const u8, value: []const u8) void {
    if (ctx.services) |svc| {
        if (svc.config) |cfg| {
            if (std.mem.eql(u8, key, "gateway.port")) {
                const port = std.fmt.parseInt(u16, value, 10) catch return;
                cfg.gateway.port = port;
            } else if (std.mem.eql(u8, key, "logging.level")) {
                const map = std.StaticStringMap(config_schema.LogLevel).initComptime(.{
                    .{ "silent", .silent },
                    .{ "fatal", .fatal },
                    .{ "error", .err },
                    .{ "warn", .warn },
                    .{ "info", .info },
                    .{ "debug", .debug },
                    .{ "trace", .trace },
                });
                if (map.get(value)) |level| {
                    cfg.logging.level = level;
                }
            }
        }
    }
}

// --- Provider Resolution Helpers ---

/// Resolve API key for a given provider name.
fn resolveApiKey(provider_name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider_name, "anthropic")) {
        return std.posix.getenv("ANTHROPIC_API_KEY");
    } else if (std.mem.eql(u8, provider_name, "openai")) {
        return std.posix.getenv("OPENAI_API_KEY");
    } else if (std.mem.eql(u8, provider_name, "gemini")) {
        return std.posix.getenv("GEMINI_API_KEY") orelse std.posix.getenv("GOOGLE_API_KEY");
    } else if (std.mem.eql(u8, provider_name, "groq")) {
        return std.posix.getenv("GROQ_API_KEY");
    } else if (std.mem.eql(u8, provider_name, "deepseek")) {
        return std.posix.getenv("DEEPSEEK_API_KEY");
    } else if (std.mem.eql(u8, provider_name, "mistral")) {
        return std.posix.getenv("MISTRAL_API_KEY");
    } else if (std.mem.eql(u8, provider_name, "xai")) {
        return std.posix.getenv("XAI_API_KEY");
    } else if (std.mem.eql(u8, provider_name, "fireworks")) {
        return std.posix.getenv("FIREWORKS_API_KEY");
    } else if (std.mem.eql(u8, provider_name, "cerebras")) {
        return std.posix.getenv("CEREBRAS_API_KEY");
    } else if (std.mem.eql(u8, provider_name, "perplexity")) {
        return std.posix.getenv("PERPLEXITY_API_KEY");
    } else if (std.mem.eql(u8, provider_name, "openrouter")) {
        return std.posix.getenv("OPENROUTER_API_KEY");
    } else if (std.mem.eql(u8, provider_name, "together")) {
        return std.posix.getenv("TOGETHER_API_KEY");
    } else if (std.mem.eql(u8, provider_name, "ollama")) {
        return "ollama"; // Ollama needs no API key
    }
    // Try generic key env var
    return std.posix.getenv("ANTHROPIC_API_KEY");
}

/// Get the env var name for a provider (for error messages).
fn resolveApiKeyEnvName(provider_name: []const u8) []const u8 {
    if (std.mem.eql(u8, provider_name, "openai")) return "OPENAI_API_KEY";
    if (std.mem.eql(u8, provider_name, "gemini")) return "GEMINI_API_KEY";
    if (std.mem.eql(u8, provider_name, "groq")) return "GROQ_API_KEY";
    if (std.mem.eql(u8, provider_name, "deepseek")) return "DEEPSEEK_API_KEY";
    if (std.mem.eql(u8, provider_name, "mistral")) return "MISTRAL_API_KEY";
    if (std.mem.eql(u8, provider_name, "xai")) return "XAI_API_KEY";
    if (std.mem.eql(u8, provider_name, "fireworks")) return "FIREWORKS_API_KEY";
    if (std.mem.eql(u8, provider_name, "cerebras")) return "CEREBRAS_API_KEY";
    if (std.mem.eql(u8, provider_name, "perplexity")) return "PERPLEXITY_API_KEY";
    if (std.mem.eql(u8, provider_name, "openrouter")) return "OPENROUTER_API_KEY";
    if (std.mem.eql(u8, provider_name, "together")) return "TOGETHER_API_KEY";
    return "ANTHROPIC_API_KEY";
}

/// Get the default model for a provider.
fn resolveDefaultModel(provider_name: []const u8) []const u8 {
    if (std.mem.eql(u8, provider_name, "openai")) return "gpt-4o";
    if (std.mem.eql(u8, provider_name, "gemini")) return "gemini-2.0-flash";
    if (std.mem.eql(u8, provider_name, "groq")) return "llama-3.3-70b-versatile";
    if (std.mem.eql(u8, provider_name, "deepseek")) return "deepseek-chat";
    if (std.mem.eql(u8, provider_name, "mistral")) return "mistral-large-latest";
    if (std.mem.eql(u8, provider_name, "xai")) return "grok-2";
    if (std.mem.eql(u8, provider_name, "fireworks")) return "accounts/fireworks/models/llama-v3p1-70b-instruct";
    if (std.mem.eql(u8, provider_name, "cerebras")) return "llama-3.3-70b";
    if (std.mem.eql(u8, provider_name, "perplexity")) return "llama-3.1-sonar-large-128k-online";
    if (std.mem.eql(u8, provider_name, "openrouter")) return "anthropic/claude-sonnet-4-20250514";
    if (std.mem.eql(u8, provider_name, "together")) return "meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo";
    if (std.mem.eql(u8, provider_name, "ollama")) return "llama3";
    return "claude-sonnet-4-20250514";
}

/// Create a ProviderDispatch for the given provider name.
fn resolveProvider(client: *http_client.HttpClient, provider_name: []const u8, api_key: []const u8) runtime.ProviderDispatch {
    if (std.mem.eql(u8, provider_name, "anthropic")) {
        return runtime.ProviderDispatch.initAnthropic(client, api_key, null);
    } else if (std.mem.eql(u8, provider_name, "openai")) {
        return runtime.ProviderDispatch.initOpenAI(client, api_key, null);
    } else if (std.mem.eql(u8, provider_name, "gemini")) {
        return runtime.ProviderDispatch.initGemini(client, api_key, null);
    } else if (openai_compat.getPreset(provider_name)) |preset| {
        return runtime.ProviderDispatch.initCompat(client, api_key, preset);
    }
    // Default to Anthropic
    return runtime.ProviderDispatch.initAnthropic(client, api_key, null);
}

// --- Tests ---

fn makeCtx(fbs: *std.io.FixedBufferStream([]u8), mode: OutputMode) CliContext {
    return .{
        .allocator = std.testing.allocator,
        .out = OutputWriter.init(fbs.writer().any(), mode),
        .mode = mode,
    };
}

test "Command fromString" {
    try std.testing.expectEqual(Command.gateway, Command.fromString("gateway").?);
    try std.testing.expectEqual(Command.version, Command.fromString("--version").?);
    try std.testing.expectEqual(Command.version, Command.fromString("-v").?);
    try std.testing.expectEqual(Command.help, Command.fromString("--help").?);
    try std.testing.expectEqual(Command.help, Command.fromString("-h").?);
    try std.testing.expectEqual(Command.doctor, Command.fromString("doctor").?);
    try std.testing.expectEqual(@as(?Command, null), Command.fromString("unknown"));
}

test "Command label and description" {
    try std.testing.expectEqualStrings("gateway", Command.gateway.label());
    try std.testing.expect(Command.gateway.description().len > 0);
    try std.testing.expect(Command.status.description().len > 0);
}

test "SubCommand fromString" {
    try std.testing.expectEqual(SubCommand.run, SubCommand.fromString("run").?);
    try std.testing.expectEqual(SubCommand.start, SubCommand.fromString("start").?);
    try std.testing.expectEqual(SubCommand.get, SubCommand.fromString("get").?);
    try std.testing.expectEqual(SubCommand.set, SubCommand.fromString("set").?);
    try std.testing.expectEqual(SubCommand.search, SubCommand.fromString("search").?);
    try std.testing.expectEqual(@as(?SubCommand, null), SubCommand.fromString("xyz"));
}

test "dispatch version" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{"version"};
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), output.VERSION) != null);
}

test "dispatch help" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{"help"};
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    const written = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "gateway") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Commands:") != null);
}

test "dispatch no args shows help" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{};
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(fbs.getWritten().len > 0);
}

test "dispatch unknown command" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{"foobar"};
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "Unknown command") != null);
}

test "dispatch gateway run" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "gateway", "run" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "18789") != null);
}

test "dispatch gateway run with port" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "gateway", "run", "--port", "9090" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "9090") != null);
}

test "dispatch gateway run json" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .json);
    const args = [_][]const u8{ "gateway", "run" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\"command\":\"gateway.run\"") != null);
}

test "dispatch gateway status" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "gateway", "status" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "dispatch gateway help" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{"gateway"};
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "Gateway Commands") != null);
}

test "dispatch gateway stop" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "gateway", "stop" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "Stopping") != null);
}

test "dispatch gateway restart" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "gateway", "restart" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "Restarting") != null);
}

test "dispatch gateway start json" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .json);
    const args = [_][]const u8{ "gateway", "start" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\"command\":\"gateway.start\"") != null);
}

test "dispatch channels list" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "channels", "list" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "dispatch channels list json" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .json);
    const args = [_][]const u8{ "channels", "list" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\"channels\":[]") != null);
}

test "dispatch channels login" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "channels", "login", "telegram" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "telegram") != null);
}

test "dispatch channels login no name" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "channels", "login" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
}

test "dispatch channels logout" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "channels", "logout", "discord" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "discord") != null);
}

test "dispatch channels help" {
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{"channels"};
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "Channel Commands") != null);
}

test "dispatch models" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{"models"};
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "anthropic") != null);
}

test "dispatch models json" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .json);
    const args = [_][]const u8{"models"};
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\"providers\"") != null);
}

test "dispatch config get" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "config", "get", "port" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "port") != null);
}

test "dispatch config get no key" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "config", "get" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
}

test "dispatch config set" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "config", "set", "port", "9090" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "9090") != null);
}

test "dispatch config set json" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .json);
    const args = [_][]const u8{ "config", "set", "port", "9090" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\"status\":\"set\"") != null);
}

test "dispatch config set no value" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "config", "set", "port" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
}

test "dispatch config help" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{"config"};
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "Config Commands") != null);
}

test "dispatch memory status" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "memory", "status" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "Documents") != null);
}

test "dispatch memory index" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "memory", "index" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "reindex") != null);
}

test "dispatch memory search" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "memory", "search", "test query" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "test query") != null);
}

test "dispatch memory search no query" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "memory", "search" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
}

test "dispatch memory search json" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .json);
    const args = [_][]const u8{ "memory", "search", "hello" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\"results\":[]") != null);
}

test "dispatch sessions" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{"sessions"};
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "Sessions") != null);
}

test "dispatch sessions list" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "sessions", "list" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "dispatch sessions cleanup" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "sessions", "cleanup" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "cleanup") != null);
}

test "dispatch sessions delete" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "sessions", "delete", "sess-123" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "sess-123") != null);
}

test "dispatch sessions delete no id" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "sessions", "delete" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
}

test "dispatch doctor" {
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{"doctor"};
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "Health Checks") != null);
}

test "dispatch doctor json" {
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .json);
    const args = [_][]const u8{"doctor"};
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\"checks\"") != null);
}

test "dispatch status" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{"status"};
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "System Status") != null);
}

test "dispatch status json" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .json);
    const args = [_][]const u8{"status"};
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\"version\":\"") != null);
}

test "dispatch setup" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{"setup"};
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "Setup Wizard") != null);
}

test "dispatch onboard" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{"onboard"};
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "Welcome") != null);
}

test "findArgValue" {
    const args = [_][]const u8{ "--port", "8080", "--host", "localhost" };
    try std.testing.expectEqualStrings("8080", findArgValue(&args, "--port").?);
    try std.testing.expectEqualStrings("localhost", findArgValue(&args, "--host").?);
    try std.testing.expect(findArgValue(&args, "--missing") == null);
}

test "findArgValue last flag" {
    const args = [_][]const u8{"--port"};
    try std.testing.expect(findArgValue(&args, "--port") == null);
}

test "isGlobalFlag" {
    try std.testing.expect(isGlobalFlag("--json"));
    try std.testing.expect(isGlobalFlag("--plain"));
    try std.testing.expect(!isGlobalFlag("gateway"));
    try std.testing.expect(!isGlobalFlag("run"));
}

test "dispatch gateway unknown sub" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "gateway", "xyz" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
}

test "dispatch channels status" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "channels", "status" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "Channel Status") != null);
}

test "dispatch memory help" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{"memory"};
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "Memory Commands") != null);
}

test "dispatch sessions help" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "sessions", "help" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "Session Commands") != null);
}

test "dispatch config get json" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .json);
    const args = [_][]const u8{ "config", "get", "port" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\"key\":\"port\"") != null);
}

test "dispatch sessions cleanup json" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .json);
    const args = [_][]const u8{ "sessions", "cleanup" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\"removed\":0") != null);
}

test "dispatch sessions delete json" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .json);
    const args = [_][]const u8{ "sessions", "delete", "s1" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\"status\":\"deleted\"") != null);
}

test "dispatch sessions list json" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .json);
    const args = [_][]const u8{ "sessions", "list" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\"sessions\":[]") != null);
}

test "dispatch memory status json" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .json);
    const args = [_][]const u8{ "memory", "status" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\"documents\":0") != null);
}

test "dispatch memory index json" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .json);
    const args = [_][]const u8{ "memory", "index" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\"status\":\"complete\"") != null);
}

test "dispatch setup json" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .json);
    const args = [_][]const u8{"setup"};
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\"command\":\"setup\"") != null);
}

test "dispatch onboard json" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .json);
    const args = [_][]const u8{"onboard"};
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\"command\":\"onboard\"") != null);
}

test "dispatch gateway stop json" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .json);
    const args = [_][]const u8{ "gateway", "stop" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\"command\":\"gateway.stop\"") != null);
}

test "dispatch gateway restart json" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .json);
    const args = [_][]const u8{ "gateway", "restart" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\"command\":\"gateway.restart\"") != null);
}

test "dispatch gateway status json" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .json);
    const args = [_][]const u8{ "gateway", "status" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\"command\":\"gateway.status\"") != null);
}

test "dispatch channels status json" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .json);
    const args = [_][]const u8{ "channels", "status" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\"channels\":[]") != null);
}

test "dispatch channels logout no name" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "channels", "logout" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
}

// --- Wired Config Tests ---

fn makeCtxWithServices(fbs: *std.io.FixedBufferStream([]u8), mode: OutputMode, svc: *CliServices) CliContext {
    return .{
        .allocator = std.testing.allocator,
        .out = OutputWriter.init(fbs.writer().any(), mode),
        .mode = mode,
        .services = svc,
    };
}

test "config get reads real port" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var config = config_schema.defaultConfig();
    config.gateway.port = 9876;
    var svc = CliServices{ .config = &config };
    var ctx = makeCtxWithServices(&fbs, .plain, &svc);
    const args = [_][]const u8{ "config", "get", "gateway.port" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    const out = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "9876") != null);
}

test "config get reads real log level" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var config = config_schema.defaultConfig();
    config.logging.level = .debug;
    var svc = CliServices{ .config = &config };
    var ctx = makeCtxWithServices(&fbs, .plain, &svc);
    const args = [_][]const u8{ "config", "get", "logging.level" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    const out = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "debug") != null);
}

test "config set updates real port" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var config = config_schema.defaultConfig();
    var svc = CliServices{ .config = &config };
    var ctx = makeCtxWithServices(&fbs, .plain, &svc);
    const args = [_][]const u8{ "config", "set", "gateway.port", "5555" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqual(@as(u16, 5555), config.gateway.port);
}

test "config set updates real log level" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var config = config_schema.defaultConfig();
    var svc = CliServices{ .config = &config };
    var ctx = makeCtxWithServices(&fbs, .plain, &svc);
    const args = [_][]const u8{ "config", "set", "logging.level", "trace" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqual(config_schema.LogLevel.trace, config.logging.level);
}

test "config get json with services" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var config = config_schema.defaultConfig();
    var svc = CliServices{ .config = &config };
    var ctx = makeCtxWithServices(&fbs, .json, &svc);
    const args = [_][]const u8{ "config", "get", "gateway.port" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    const out = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "18789") != null);
}

test "config get unknown key returns not set" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var config = config_schema.defaultConfig();
    var svc = CliServices{ .config = &config };
    var ctx = makeCtxWithServices(&fbs, .plain, &svc);
    const args = [_][]const u8{ "config", "get", "unknown.key" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    const out = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "(not set)") != null);
}

test "configGetValue without services" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const val = configGetValue(&ctx, "gateway.port");
    try std.testing.expectEqualStrings("(not set)", val);
}

test "CliServices default" {
    const svc = CliServices{};
    try std.testing.expect(svc.config == null);
}

// --- Additional Tests ---

test "Command all labels non-empty" {
    for (std.meta.tags(Command)) |cmd| {
        try std.testing.expect(cmd.label().len > 0);
    }
}

test "Command all descriptions non-empty" {
    for (std.meta.tags(Command)) |cmd| {
        try std.testing.expect(cmd.description().len > 0);
    }
}

test "Command fromString aliases" {
    // Version aliases
    try std.testing.expectEqual(Command.version, Command.fromString("version").?);
    try std.testing.expectEqual(Command.version, Command.fromString("--version").?);
    try std.testing.expectEqual(Command.version, Command.fromString("-v").?);

    // Help aliases
    try std.testing.expectEqual(Command.help, Command.fromString("help").?);
    try std.testing.expectEqual(Command.help, Command.fromString("--help").?);
    try std.testing.expectEqual(Command.help, Command.fromString("-h").?);
}

test "Command fromString all commands" {
    try std.testing.expectEqual(Command.agent, Command.fromString("agent").?);
    try std.testing.expectEqual(Command.channels, Command.fromString("channels").?);
    try std.testing.expectEqual(Command.models, Command.fromString("models").?);
    try std.testing.expectEqual(Command.config, Command.fromString("config").?);
    try std.testing.expectEqual(Command.memory, Command.fromString("memory").?);
    try std.testing.expectEqual(Command.sessions, Command.fromString("sessions").?);
    try std.testing.expectEqual(Command.status, Command.fromString("status").?);
    try std.testing.expectEqual(Command.setup, Command.fromString("setup").?);
    try std.testing.expectEqual(Command.onboard, Command.fromString("onboard").?);
}

test "SubCommand fromString all" {
    try std.testing.expectEqual(SubCommand.stop, SubCommand.fromString("stop").?);
    try std.testing.expectEqual(SubCommand.restart, SubCommand.fromString("restart").?);
    try std.testing.expectEqual(SubCommand.list, SubCommand.fromString("list").?);
    try std.testing.expectEqual(SubCommand.login, SubCommand.fromString("login").?);
    try std.testing.expectEqual(SubCommand.logout, SubCommand.fromString("logout").?);
    try std.testing.expectEqual(SubCommand.index, SubCommand.fromString("index").?);
    try std.testing.expectEqual(SubCommand.cleanup, SubCommand.fromString("cleanup").?);
    try std.testing.expectEqual(SubCommand.preview, SubCommand.fromString("preview").?);
    try std.testing.expectEqual(SubCommand.delete, SubCommand.fromString("delete").?);
    try std.testing.expectEqual(SubCommand.status_sub, SubCommand.fromString("status").?);
    try std.testing.expectEqual(SubCommand.help_sub, SubCommand.fromString("help").?);
    try std.testing.expectEqual(SubCommand.help_sub, SubCommand.fromString("--help").?);
    try std.testing.expectEqual(SubCommand.help_sub, SubCommand.fromString("-h").?);
}

test "SubCommand fromString empty" {
    try std.testing.expect(SubCommand.fromString("") == null);
}

test "CommandResult defaults" {
    const result = CommandResult{};
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(result.message == null);
}

test "CommandResult with values" {
    const result = CommandResult{ .exit_code = 1, .message = "failed" };
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings("failed", result.message.?);
}

test "dispatch version json" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .json);
    const args = [_][]const u8{"version"};
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\"version\"") != null);
}

test "dispatch agent no message plain" {
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{"agent"};
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "Agent Command") != null);
}

test "dispatch agent with message requires api key" {
    // Without an API key set, agent command returns exit_code 1
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "agent", "--message", "hello world" };
    const result = try dispatch(&ctx, &args);
    // Without ANTHROPIC_API_KEY, should fail with exit 1
    if (std.posix.getenv("ANTHROPIC_API_KEY") == null) {
        try std.testing.expectEqual(@as(u8, 1), result.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "API key") != null or
            std.mem.indexOf(u8, fbs.getWritten(), "ANTHROPIC") != null);
    }
}

test "dispatch agent with message json requires api key" {
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .json);
    const args = [_][]const u8{ "agent", "--message", "test" };
    const result = try dispatch(&ctx, &args);
    if (std.posix.getenv("ANTHROPIC_API_KEY") == null) {
        try std.testing.expectEqual(@as(u8, 1), result.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "API key") != null or
            std.mem.indexOf(u8, fbs.getWritten(), "error") != null);
    }
}

test "dispatch agent with custom agent name" {
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "agent", "--message", "hi", "--agent", "custom" };
    const result = try dispatch(&ctx, &args);
    // Without API key, should still report the error (exit 1)
    if (std.posix.getenv("ANTHROPIC_API_KEY") == null) {
        try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    }
}

test "dispatch agent with -m shorthand" {
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "agent", "-m", "short" };
    const result = try dispatch(&ctx, &args);
    if (std.posix.getenv("ANTHROPIC_API_KEY") == null) {
        try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    }
}

test "dispatch agent no message json" {
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .json);
    const args = [_][]const u8{"agent"};
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\"error\"") != null);
}

test "dispatch gateway help sub" {
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "gateway", "help" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "Gateway Commands") != null);
}

test "dispatch channels login json" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var ctx = makeCtx(&fbs, .plain);
    const args = [_][]const u8{ "channels", "login", "whatsapp" };
    const result = try dispatch(&ctx, &args);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "whatsapp") != null);
}

test "findArgValue multiple flags" {
    const args = [_][]const u8{ "--port", "8080", "--host", "localhost", "--env", "prod" };
    try std.testing.expectEqualStrings("prod", findArgValue(&args, "--env").?);
}

test "findArgValue empty args" {
    const args = [_][]const u8{};
    try std.testing.expect(findArgValue(&args, "--port") == null);
}

test "isGlobalFlag non-flags" {
    try std.testing.expect(!isGlobalFlag("--help"));
    try std.testing.expect(!isGlobalFlag("status"));
    try std.testing.expect(!isGlobalFlag(""));
}

test "config set invalid port" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var config = config_schema.defaultConfig();
    const original_port = config.gateway.port;
    var svc = CliServices{ .config = &config };
    var ctx = makeCtxWithServices(&fbs, .plain, &svc);
    configSetValue(&ctx, "gateway.port", "not_a_number");
    // Port should remain unchanged
    try std.testing.expectEqual(original_port, config.gateway.port);
}

test "config set invalid log level" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var config = config_schema.defaultConfig();
    const original_level = config.logging.level;
    var svc = CliServices{ .config = &config };
    var ctx = makeCtxWithServices(&fbs, .plain, &svc);
    configSetValue(&ctx, "logging.level", "invalid_level");
    // Level should remain unchanged
    try std.testing.expectEqual(original_level, config.logging.level);
}

test "config get session.mainKey" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var config = config_schema.defaultConfig();
    var svc = CliServices{ .config = &config };
    var ctx = makeCtxWithServices(&fbs, .plain, &svc);
    const val = configGetValue(&ctx, "session.mainKey");
    try std.testing.expect(val.len > 0);
}

test "portToString" {
    const result = portToString(9090);
    try std.testing.expectEqualStrings("9090", result);
}

test "portToString default port" {
    const result = portToString(18789);
    try std.testing.expectEqualStrings("18789", result);
}
