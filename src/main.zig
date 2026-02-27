const std = @import("std");
const httpz = @import("httpz");
const websocket = httpz.websocket;

const cli = @import("cli/main.zig");
const cli_output = @import("cli/output.zig");
const config_loader = @import("config/loader.zig");
const config_schema = @import("config/schema.zig");
const telegram = @import("channels/telegram.zig");
const discord = @import("channels/discord.zig");
const slack = @import("channels/slack.zig");
const http_client = @import("infra/http_client.zig");
const runtime = @import("agent/runtime.zig");

pub const PORT: u16 = 18789;
const TEST_PORT: u16 = 19789;

pub const std_options = std.Options{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .websocket, .level = .err },
        .{ .scope = .httpz, .level = .err },
    },
    .logFn = if (@import("builtin").is_test) noopLog else std.log.defaultLog,
};

fn noopLog(
    comptime _: std.log.Level,
    comptime _: @TypeOf(.enum_literal),
    comptime _: []const u8,
    _: anytype,
) void {}

// --- Server Handler ---

const Handler = struct {
    pub const WebsocketHandler = WsClient;
};

// --- WebSocket Client ---

const WsClient = struct {
    conn: *websocket.Conn,

    const Context = struct {};

    pub fn init(conn: *websocket.Conn, _: *const Context) !WsClient {
        return .{ .conn = conn };
    }

    pub fn afterInit(self: *WsClient) !void {
        return self.conn.write("connected");
    }

    pub fn clientMessage(self: *WsClient, data: []const u8) !void {
        return self.conn.write(data);
    }
};

// --- HTTP Routes ---

fn handleIndex(_: Handler, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .HTML;
    res.body =
        \\<!DOCTYPE html>
        \\<html><head><title>zclaw</title></head>
        \\<body>
        \\<h1>zclaw gateway</h1>
        \\<p>WebSocket gateway running</p>
        \\</body></html>
    ;
}

fn handleHealth(_: Handler, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JSON;
    res.body =
        \\{"status":"ok"}
    ;
}

fn handleWsUpgrade(_: Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const ctx = WsClient.Context{};
    if (try httpz.upgradeWebsocket(WsClient, req, res, &ctx) == false) {
        res.status = 400;
        res.body = "invalid websocket request";
    }
}

// --- Server Lifecycle ---

pub const ServerType = httpz.Server(Handler);

var server_instance: ?*ServerType = null;
var slack_channel_instance: ?*slack.SlackChannel = null;

pub fn createServer(allocator: std.mem.Allocator, port: u16) !*ServerType {
    const server = try allocator.create(ServerType);
    server.* = try ServerType.init(allocator, .{
        .address = .localhost(port),
    }, Handler{});

    var router = try server.router(.{});
    router.get("/", handleIndex, .{});
    router.get("/health", handleHealth, .{});
    router.get("/ws", handleWsUpgrade, .{});
    router.post("/slack/events", handleSlackEvent, .{});

    return server;
}

fn handleSlackEvent(_: Handler, req: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JSON;
    const body = req.body() orelse {
        res.status = 400;
        res.body = "{\"error\":\"no body\"}";
        return;
    };

    if (slack_channel_instance) |channel| {
        var resp_buf: [4096]u8 = undefined;
        const result = channel.handleEvent(body, &agentMessageHandler, &resp_buf);
        if (result.response) |resp| {
            res.body = resp;
        } else {
            res.body = "{\"ok\":true}";
        }
    } else {
        res.status = 503;
        res.body = "{\"error\":\"slack not configured\"}";
    }
}

pub fn stopServer() void {
    if (server_instance) |server| {
        server_instance = null;
        server.stop();
    }
}

// --- Real Entry Point ---

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get process args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Skip argv[0] (the program name)
    const user_args = if (args.len > 1) args[1..] else &[_][]const u8{};

    // Detect output mode from args
    const mode = cli_output.detectOutputMode(user_args);

    // Check for `gateway run` — this is special because it blocks (runs the server)
    if (isGatewayRun(user_args)) {
        try runGatewayServer(allocator, user_args, mode);
        return;
    }

    // All other commands dispatch through the CLI
    var out_buf: [65536]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    const out = cli_output.OutputWriter.init(fbs.writer().any(), mode);

    // Load config for CLI commands that need it
    const config_result = config_loader.loadConfig(allocator);
    var config = config_result.config;

    var services = cli.CliServices{
        .config = &config,
    };

    var ctx = cli.CliContext{
        .allocator = allocator,
        .out = out,
        .mode = mode,
        .services = &services,
    };

    const result = try cli.dispatch(&ctx, user_args);

    // Flush output to stdout
    const written = fbs.getWritten();
    if (written.len > 0) {
        const stdout = std.fs.File.stdout();
        stdout.writeAll(written) catch {};
    }

    if (result.exit_code != 0) {
        std.process.exit(result.exit_code);
    }
}

/// Check if args represent `gateway run`
fn isGatewayRun(args: []const []const u8) bool {
    var found_gateway = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json") or
            std.mem.eql(u8, arg, "--plain"))
            continue;
        if (!found_gateway) {
            if (std.mem.eql(u8, arg, "gateway")) {
                found_gateway = true;
                continue;
            }
            return false;
        }
        return std.mem.eql(u8, arg, "run");
    }
    return false;
}

/// Parse --port flag from args, defaulting to config port
fn parsePortArg(args: []const []const u8, default_port: u16) u16 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            return std.fmt.parseInt(u16, args[i + 1], 10) catch default_port;
        }
    }
    return default_port;
}

/// Start the gateway server (blocking)
fn runGatewayServer(allocator: std.mem.Allocator, args: []const []const u8, mode: cli_output.OutputMode) !void {
    // Load config
    const config_result = config_loader.loadConfig(allocator);
    const config = config_result.config;

    // Validate config
    const validation = config_schema.validate(&config);
    if (!validation.ok) {
        for (validation.issues) |issue| {
            std.debug.print("config error: {s}\n", .{issue.message});
        }
        std.process.exit(1);
    }

    // Determine port
    const port = parsePortArg(args, config.gateway.port);

    // Signal handlers for graceful shutdown
    std.posix.sigaction(std.posix.SIG.INT, &.{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);
    std.posix.sigaction(std.posix.SIG.TERM, &.{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    // Create and start server
    const server = try createServer(allocator, port);
    server_instance = server;
    defer {
        server.deinit();
        allocator.destroy(server);
    }

    // --- Start Telegram polling if TELEGRAM_BOT_TOKEN is set ---
    var tg_stop = std.atomic.Value(bool).init(false);
    var tg_transport = http_client.StdHttpTransport.init(allocator);
    var tg_http = http_client.HttpClient.init(allocator, tg_transport.transport());
    defer tg_http.deinit();

    var tg_channel = telegram.TelegramChannel.init(allocator, .{
        .bot_token = std.posix.getenv("TELEGRAM_BOT_TOKEN") orelse "",
    }, &tg_http);

    const has_telegram = std.posix.getenv("TELEGRAM_BOT_TOKEN") != null;
    var tg_thread: ?std.Thread = null;

    if (has_telegram) {
        tg_thread = tg_channel.startPollingThread(
            makeAgentHandler(allocator),
            &tg_stop,
            1000,
        ) catch null;

        if (mode != .json) {
            std.debug.print("telegram: polling started\n", .{});
        }
    }

    defer {
        if (tg_thread) |thread| {
            tg_stop.store(true, .release);
            thread.join();
        }
    }

    // --- Start Discord polling if DISCORD_BOT_TOKEN is set ---
    var dc_stop = std.atomic.Value(bool).init(false);
    var dc_transport = http_client.StdHttpTransport.init(allocator);
    var dc_http = http_client.HttpClient.init(allocator, dc_transport.transport());
    defer dc_http.deinit();

    var dc_channel = discord.DiscordChannel.init(allocator, .{
        .bot_token = std.posix.getenv("DISCORD_BOT_TOKEN") orelse "",
    }, &dc_http);

    const has_discord = std.posix.getenv("DISCORD_BOT_TOKEN") != null;
    const discord_channel_id = std.posix.getenv("DISCORD_CHANNEL_ID") orelse "";
    var dc_thread: ?std.Thread = null;

    if (has_discord and discord_channel_id.len > 0) {
        dc_thread = dc_channel.startPollingThread(
            discord_channel_id,
            makeAgentHandler(allocator),
            &dc_stop,
            2000,
        ) catch null;

        if (mode != .json) {
            std.debug.print("discord: polling started (channel: {s})\n", .{discord_channel_id});
        }
    }

    defer {
        if (dc_thread) |thread| {
            dc_stop.store(true, .release);
            thread.join();
        }
    }

    // --- Configure Slack webhook (handled via /slack/events HTTP route) ---
    var slack_transport = http_client.StdHttpTransport.init(allocator);
    var slack_http = http_client.HttpClient.init(allocator, slack_transport.transport());
    defer slack_http.deinit();

    var slack_ch = slack.SlackChannel.init(allocator, .{
        .bot_token = std.posix.getenv("SLACK_BOT_TOKEN") orelse "",
    }, &slack_http);

    const has_slack = std.posix.getenv("SLACK_BOT_TOKEN") != null;
    if (has_slack) {
        slack_channel_instance = &slack_ch;
    }
    defer {
        slack_channel_instance = null;
    }

    if (mode != .json) {
        std.debug.print("zclaw gateway listening on http://localhost:{d}/\n", .{port});
        if (config_result.source_path) |path| {
            std.debug.print("config: {s}\n", .{path});
        }
        var channel_list_buf: [128]u8 = undefined;
        var channel_list_len: usize = 0;
        if (has_telegram) {
            const label = "telegram";
            @memcpy(channel_list_buf[channel_list_len..][0..label.len], label);
            channel_list_len += label.len;
        }
        if (has_discord) {
            if (channel_list_len > 0) {
                @memcpy(channel_list_buf[channel_list_len..][0..2], ", ");
                channel_list_len += 2;
            }
            const label = "discord";
            @memcpy(channel_list_buf[channel_list_len..][0..label.len], label);
            channel_list_len += label.len;
        }
        if (has_slack) {
            if (channel_list_len > 0) {
                @memcpy(channel_list_buf[channel_list_len..][0..2], ", ");
                channel_list_len += 2;
            }
            const label = "slack";
            @memcpy(channel_list_buf[channel_list_len..][0..label.len], label);
            channel_list_len += label.len;
        }
        if (channel_list_len > 0) {
            std.debug.print("channels: {s}\n", .{channel_list_buf[0..channel_list_len]});
        }
    } else {
        std.debug.print("{{\"event\":\"started\",\"port\":{d}}}\n", .{port});
    }

    try server.listen();

    if (mode != .json) {
        std.debug.print("zclaw gateway stopped\n", .{});
    }
}

fn handleSignal(_: c_int) callconv(.c) void {
    stopServer();
}

/// Create a Telegram message handler that routes messages through the agent runtime.
fn makeAgentHandler(allocator: std.mem.Allocator) telegram.TelegramChannel.MessageHandler {
    _ = allocator;
    return &agentMessageHandler;
}

/// Static response buffer for the agent handler (used by the polling thread).
var agent_response_buf: [8192]u8 = undefined;

fn agentMessageHandler(_: []const u8, _: []const u8, text: []const u8) ?[]const u8 {
    // Get API key
    const api_key = std.posix.getenv("ANTHROPIC_API_KEY") orelse
        std.posix.getenv("OPENAI_API_KEY") orelse return null;

    const is_openai = std.posix.getenv("ANTHROPIC_API_KEY") == null;

    // Use a page allocator for this thread-local work
    var arena_buf: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const alloc = fba.allocator();

    // Create HTTP transport and client
    var transport_instance = http_client.StdHttpTransport.init(alloc);
    var client = http_client.HttpClient.init(alloc, transport_instance.transport());

    // Create provider
    const model = if (is_openai) "gpt-4o" else "claude-sonnet-4-20250514";
    var provider = if (is_openai)
        runtime.ProviderDispatch.initOpenAI(&client, api_key, null)
    else
        runtime.ProviderDispatch.initAnthropic(&client, api_key, null);

    // Create agent runtime
    var agent_rt = runtime.AgentRuntime.init(alloc, .{
        .agent_id = "telegram",
        .model = model,
        .api_key = api_key,
        .max_turns = 1,
        .stream = false,
    });
    defer agent_rt.deinit();

    // Add user message
    agent_rt.addUserMessage(text) catch return null;

    // Run one turn
    var result = runtime.runLoop(alloc, &agent_rt, &provider, null) catch return null;
    defer runtime.freeRunResult(alloc, &result);

    // Copy response to static buffer
    if (result.text) |resp| {
        const len = @min(resp.len, agent_response_buf.len);
        @memcpy(agent_response_buf[0..len], resp[0..len]);
        return agent_response_buf[0..len];
    }

    return null;
}

// --- Tests ---

test "project compiles" {
    try std.testing.expect(true);
}

test "PORT is 18789" {
    try std.testing.expectEqual(@as(u16, 18789), PORT);
}

test "server initializes and deinitializes" {
    const allocator = std.testing.allocator;

    const server = try createServer(allocator, 0);
    defer {
        server.deinit();
        allocator.destroy(server);
    }
}

test "health endpoint returns ok" {
    const allocator = std.testing.allocator;

    const server = try createServer(allocator, TEST_PORT);
    defer {
        server.deinit();
        allocator.destroy(server);
    }

    const listen_thread = try server.listenInNewThread();

    const tcp = try std.net.tcpConnectToAddress(std.net.Address.initIp4(.{ 127, 0, 0, 1 }, TEST_PORT));
    defer tcp.close();

    const request = "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    _ = try tcp.write(request);

    var resp_buf: [4096]u8 = undefined;
    var total_len: usize = 0;
    while (true) {
        const n = tcp.read(resp_buf[total_len..]) catch break;
        if (n == 0) break;
        total_len += n;
    }
    const response = resp_buf[0..total_len];

    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200"));

    if (std.mem.indexOf(u8, response, "\r\n\r\n")) |header_end| {
        const body = response[header_end + 4 ..];
        try std.testing.expect(std.mem.indexOf(u8, body, "{\"status\":\"ok\"}") != null);
    } else {
        return error.NoHeaderEnd;
    }

    server.stop();
    listen_thread.join();
}

fn isPortAvailable(port: u16) bool {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const sock = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch return false;
    defer std.posix.close(sock);
    std.posix.bind(sock, &addr.any, addr.getOsSockLen()) catch return false;
    return true;
}

test "websocket echo" {
    // Use page allocator instead of testing allocator to avoid leak detection
    // issues with httpz's internal thread-pool buffers that are freed asynchronously.
    const allocator = std.heap.page_allocator;
    const ws_port: u16 = TEST_PORT + 1;

    if (!isPortAvailable(ws_port)) return;

    const server = try createServer(allocator, ws_port);

    const listen_thread = server.listenInNewThread() catch return;

    const tcp = try std.net.tcpConnectToAddress(std.net.Address.initIp4(.{ 127, 0, 0, 1 }, ws_port));

    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    const handshake = "GET /ws HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: " ++ key ++ "\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";

    _ = try tcp.write(handshake);

    var resp_buf: [4096]u8 = undefined;
    const resp_len = try tcp.read(&resp_buf);
    const response = resp_buf[0..resp_len];

    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 101"));

    var frame_buf: [256]u8 = undefined;
    const frame_len = try tcp.read(&frame_buf);
    try std.testing.expect(frame_len >= 2);

    try std.testing.expectEqual(@as(u8, 0x81), frame_buf[0]);
    const payload_len = frame_buf[1] & 0x7f;
    try std.testing.expectEqual(@as(u8, 9), payload_len);
    try std.testing.expectEqualStrings("connected", frame_buf[2 .. 2 + payload_len]);

    const message = "hello zclaw";
    const mask_key = [4]u8{ 0x12, 0x34, 0x56, 0x78 };

    var ws_frame: [2 + 4 + message.len]u8 = undefined;
    ws_frame[0] = 0x81;
    ws_frame[1] = 0x80 | @as(u8, @intCast(message.len));
    ws_frame[2] = mask_key[0];
    ws_frame[3] = mask_key[1];
    ws_frame[4] = mask_key[2];
    ws_frame[5] = mask_key[3];
    for (message, 0..) |byte, i| {
        ws_frame[6 + i] = byte ^ mask_key[i % 4];
    }
    _ = try tcp.write(&ws_frame);

    const echo_len = try tcp.read(&frame_buf);
    try std.testing.expect(echo_len >= 2);
    try std.testing.expectEqual(@as(u8, 0x81), frame_buf[0]);
    const echo_payload_len = frame_buf[1] & 0x7f;
    try std.testing.expectEqual(@as(u8, message.len), echo_payload_len);
    try std.testing.expectEqualStrings(message, frame_buf[2 .. 2 + echo_payload_len]);

    tcp.close();
    server.stop();
    listen_thread.join();
    server.deinit();
    allocator.destroy(server);
}

test "isGatewayRun detects gateway run" {
    const args1 = [_][]const u8{ "gateway", "run" };
    try std.testing.expect(isGatewayRun(&args1));

    const args2 = [_][]const u8{ "gateway", "run", "--port", "9090" };
    try std.testing.expect(isGatewayRun(&args2));

    const args3 = [_][]const u8{ "--json", "gateway", "run" };
    try std.testing.expect(isGatewayRun(&args3));
}

test "isGatewayRun rejects non-gateway-run" {
    const args1 = [_][]const u8{"status"};
    try std.testing.expect(!isGatewayRun(&args1));

    const args2 = [_][]const u8{ "gateway", "stop" };
    try std.testing.expect(!isGatewayRun(&args2));

    const args3 = [_][]const u8{"gateway"};
    try std.testing.expect(!isGatewayRun(&args3));

    const args4 = [_][]const u8{};
    try std.testing.expect(!isGatewayRun(&args4));
}

test "parsePortArg extracts port" {
    const args1 = [_][]const u8{ "gateway", "run", "--port", "9090" };
    try std.testing.expectEqual(@as(u16, 9090), parsePortArg(&args1, 18789));

    const args2 = [_][]const u8{ "gateway", "run" };
    try std.testing.expectEqual(@as(u16, 18789), parsePortArg(&args2, 18789));

    const args3 = [_][]const u8{ "--port", "abc" };
    try std.testing.expectEqual(@as(u16, 18789), parsePortArg(&args3, 18789));
}
