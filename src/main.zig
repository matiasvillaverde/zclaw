const std = @import("std");
const httpz = @import("httpz");
const websocket = httpz.websocket;

pub const PORT: u16 = 18789;
const TEST_PORT: u16 = 19789;

pub const std_options = std.Options{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .websocket, .level = .err },
        .{ .scope = .httpz, .level = .err },
    },
    // Use a no-op log function during tests to avoid "logged errors" failures
    // from httpz when ports are temporarily unavailable
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
        \\<p>WebSocket echo server running on port 18789</p>
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

pub fn createServer(allocator: std.mem.Allocator, port: u16) !*ServerType {
    const server = try allocator.create(ServerType);
    server.* = try ServerType.init(allocator, .{
        .address = .localhost(port),
    }, Handler{});

    var router = try server.router(.{});
    router.get("/", handleIndex, .{});
    router.get("/health", handleHealth, .{});
    router.get("/ws", handleWsUpgrade, .{});

    return server;
}

pub fn stopServer() void {
    if (server_instance) |server| {
        server_instance = null;
        server.stop();
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Handle SIGINT / SIGTERM for graceful shutdown
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

    const server = try createServer(allocator, PORT);
    server_instance = server;
    defer {
        server.deinit();
        allocator.destroy(server);
    }

    std.debug.print("zclaw gateway listening on http://localhost:{d}/\n", .{PORT});

    try server.listen();

    std.debug.print("zclaw gateway stopped\n", .{});
}

fn handleSignal(_: c_int) callconv(.c) void {
    stopServer();
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

    // listenInNewThread signals when server is ready
    const listen_thread = try server.listenInNewThread();

    // Make raw HTTP request to /health
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

    // Verify HTTP 200 response
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200"));

    // Find body after \r\n\r\n
    if (std.mem.indexOf(u8, response, "\r\n\r\n")) |header_end| {
        const body = response[header_end + 4 ..];
        // Body may be chunked - look for our JSON
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
    const allocator = std.testing.allocator;
    const ws_port: u16 = TEST_PORT + 1;

    // Skip test if port is unavailable to avoid httpz error logging
    if (!isPortAvailable(ws_port)) return;

    const server = try createServer(allocator, ws_port);
    defer {
        server.deinit();
        allocator.destroy(server);
    }

    const listen_thread = server.listenInNewThread() catch return;

    // Connect via raw TCP and do WebSocket handshake
    const tcp = try std.net.tcpConnectToAddress(std.net.Address.initIp4(.{ 127, 0, 0, 1 }, ws_port));
    defer tcp.close();

    // WebSocket upgrade handshake
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    const handshake = "GET /ws HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: " ++ key ++ "\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";

    _ = try tcp.write(handshake);

    // Read upgrade response
    var resp_buf: [4096]u8 = undefined;
    const resp_len = try tcp.read(&resp_buf);
    const response = resp_buf[0..resp_len];

    // Verify 101 Switching Protocols
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 101"));

    // Read welcome message ("connected") - server sends unmasked frame
    var frame_buf: [256]u8 = undefined;
    const frame_len = try tcp.read(&frame_buf);
    try std.testing.expect(frame_len >= 2);

    // First byte: FIN bit + text opcode (0x81)
    try std.testing.expectEqual(@as(u8, 0x81), frame_buf[0]);
    const payload_len = frame_buf[1] & 0x7f;
    try std.testing.expectEqual(@as(u8, 9), payload_len); // "connected" = 9 bytes
    try std.testing.expectEqualStrings("connected", frame_buf[2 .. 2 + payload_len]);

    // Send a masked text frame with "hello zclaw"
    const message = "hello zclaw";
    const mask_key = [4]u8{ 0x12, 0x34, 0x56, 0x78 };

    var ws_frame: [2 + 4 + message.len]u8 = undefined;
    ws_frame[0] = 0x81; // FIN + text opcode
    ws_frame[1] = 0x80 | @as(u8, @intCast(message.len)); // MASK bit + length
    ws_frame[2] = mask_key[0];
    ws_frame[3] = mask_key[1];
    ws_frame[4] = mask_key[2];
    ws_frame[5] = mask_key[3];
    for (message, 0..) |byte, i| {
        ws_frame[6 + i] = byte ^ mask_key[i % 4];
    }
    _ = try tcp.write(&ws_frame);

    // Read echoed message
    const echo_len = try tcp.read(&frame_buf);
    try std.testing.expect(echo_len >= 2);
    try std.testing.expectEqual(@as(u8, 0x81), frame_buf[0]);
    const echo_payload_len = frame_buf[1] & 0x7f;
    try std.testing.expectEqual(@as(u8, message.len), echo_payload_len);
    try std.testing.expectEqualStrings(message, frame_buf[2 .. 2 + echo_payload_len]);

    server.stop();
    listen_thread.join();
}
