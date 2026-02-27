const std = @import("std");
const http_client = @import("../infra/http_client.zig");

// --- Docker Engine API Constants ---

pub const DOCKER_SOCKET = "/var/run/docker.sock";
pub const API_VERSION = "v1.43";
pub const DEFAULT_IMAGE = "ubuntu:22.04";

// --- Container Config ---

pub const ContainerConfig = struct {
    image: []const u8 = DEFAULT_IMAGE,
    name: ?[]const u8 = null,
    cmd: []const []const u8 = &.{},
    env: []const []const u8 = &.{},
    working_dir: []const u8 = "/workspace",
    memory_limit: u64 = 512 * 1024 * 1024, // 512MB
    cpu_quota: i64 = 100000, // 100% of one CPU
    network_disabled: bool = false,
};

// --- Container State ---

pub const ContainerState = enum {
    created,
    running,
    paused,
    stopped,
    removing,
    exited,
    dead,

    pub fn label(self: ContainerState) []const u8 {
        return switch (self) {
            .created => "created",
            .running => "running",
            .paused => "paused",
            .stopped => "stopped",
            .removing => "removing",
            .exited => "exited",
            .dead => "dead",
        };
    }

    pub fn fromString(s: []const u8) ?ContainerState {
        const map = std.StaticStringMap(ContainerState).initComptime(.{
            .{ "created", .created },
            .{ "running", .running },
            .{ "paused", .paused },
            .{ "stopped", .stopped },
            .{ "removing", .removing },
            .{ "exited", .exited },
            .{ "dead", .dead },
        });
        return map.get(s);
    }

    pub fn isAlive(self: ContainerState) bool {
        return self == .running or self == .paused;
    }
};

// --- Container Info ---

pub const ContainerInfo = struct {
    id: []const u8,
    name: []const u8,
    image: []const u8,
    state: ContainerState = .created,
    created_at: i64 = 0,
};

// --- Docker API URL Builder ---

pub fn buildApiUrl(buf: []u8, endpoint: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("/");
    try w.writeAll(API_VERSION);
    try w.writeAll(endpoint);
    return fbs.getWritten();
}

// --- Request Body Builders ---

pub fn buildCreateContainerBody(buf: []u8, config: ContainerConfig) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("{\"Image\":\"");
    try w.writeAll(config.image);
    try w.writeAll("\",\"WorkingDir\":\"");
    try w.writeAll(config.working_dir);
    try w.writeAll("\"");

    if (config.cmd.len > 0) {
        try w.writeAll(",\"Cmd\":[");
        for (config.cmd, 0..) |arg, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try w.writeAll(arg);
            try w.writeAll("\"");
        }
        try w.writeAll("]");
    }

    if (config.env.len > 0) {
        try w.writeAll(",\"Env\":[");
        for (config.env, 0..) |e, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try w.writeAll(e);
            try w.writeAll("\"");
        }
        try w.writeAll("]");
    }

    // Host config
    try w.writeAll(",\"HostConfig\":{\"Memory\":");
    try std.fmt.format(w, "{d}", .{config.memory_limit});
    try w.writeAll(",\"CpuQuota\":");
    try std.fmt.format(w, "{d}", .{config.cpu_quota});
    if (config.network_disabled) {
        try w.writeAll(",\"NetworkMode\":\"none\"");
    }
    try w.writeAll("}");

    try w.writeAll("}");
    return fbs.getWritten();
}

pub fn buildExecBody(buf: []u8, cmd: []const []const u8, working_dir: ?[]const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("{\"AttachStdout\":true,\"AttachStderr\":true,\"Cmd\":[");
    for (cmd, 0..) |arg, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("\"");
        try writeJsonEscaped(w, arg);
        try w.writeAll("\"");
    }
    try w.writeAll("]");
    if (working_dir) |wd| {
        try w.writeAll(",\"WorkingDir\":\"");
        try w.writeAll(wd);
        try w.writeAll("\"");
    }
    try w.writeAll("}");
    return fbs.getWritten();
}

// --- Response Parsing ---

pub fn extractContainerId(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"Id\":\"");
}

pub fn extractContainerState(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"Status\":\"");
}

pub fn extractExecId(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "\"Id\":\"");
}

// --- HTTP Request Builder (for Unix socket) ---

pub fn buildHttpRequest(buf: []u8, method: []const u8, path: []const u8, body: ?[]const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll(method);
    try w.writeAll(" ");
    try w.writeAll(path);
    try w.writeAll(" HTTP/1.1\r\nHost: localhost\r\n");
    if (body) |b| {
        try w.writeAll("Content-Type: application/json\r\nContent-Length: ");
        try std.fmt.format(w, "{d}", .{b.len});
        try w.writeAll("\r\n\r\n");
        try w.writeAll(b);
    } else {
        try w.writeAll("\r\n");
    }
    return fbs.getWritten();
}

// --- Helpers ---

fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            else => try writer.writeByte(c),
        }
    }
}

fn extractJsonString(json: []const u8, prefix: []const u8) ?[]const u8 {
    const start_idx = std.mem.indexOf(u8, json, prefix) orelse return null;
    const value_start = start_idx + prefix.len;
    if (value_start >= json.len) return null;
    var i = value_start;
    while (i < json.len) : (i += 1) {
        if (json[i] == '"' and (i == value_start or json[i - 1] != '\\')) {
            return json[value_start..i];
        }
    }
    return null;
}

// --- Docker Client ---

pub const DockerClient = struct {
    client: *http_client.HttpClient,
    allocator: std.mem.Allocator,

    pub const DockerError = error{
        CreateFailed,
        StartFailed,
        StopFailed,
        RemoveFailed,
        ExecFailed,
        InspectFailed,
    };

    pub fn init(allocator: std.mem.Allocator, client: *http_client.HttpClient) DockerClient {
        return .{ .allocator = allocator, .client = client };
    }

    /// Create a container. Returns the container ID on success.
    pub fn createContainer(self: *DockerClient, config: ContainerConfig) ![]const u8 {
        var body_buf: [4096]u8 = undefined;
        const body = buildCreateContainerBody(&body_buf, config) catch return DockerError.CreateFailed;

        var url_buf: [256]u8 = undefined;
        const url = buildApiUrl(&url_buf, "/containers/create") catch return DockerError.CreateFailed;

        var resp = self.client.postJson(url, &.{}, body) catch return DockerError.CreateFailed;
        defer resp.deinit();

        if (resp.status != 201 and resp.status != 200) return DockerError.CreateFailed;

        const id = extractContainerId(resp.body) orelse return DockerError.CreateFailed;
        return self.allocator.dupe(u8, id) catch return DockerError.CreateFailed;
    }

    /// Start a container by ID.
    pub fn startContainer(self: *DockerClient, container_id: []const u8) !void {
        var url_buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&url_buf);
        const w = fbs.writer();
        w.writeAll("/") catch return DockerError.StartFailed;
        w.writeAll(API_VERSION) catch return DockerError.StartFailed;
        w.writeAll("/containers/") catch return DockerError.StartFailed;
        w.writeAll(container_id) catch return DockerError.StartFailed;
        w.writeAll("/start") catch return DockerError.StartFailed;
        const url = fbs.getWritten();

        var resp = self.client.postJson(url, &.{}, "{}") catch return DockerError.StartFailed;
        defer resp.deinit();

        // 204 = started, 304 = already started
        if (resp.status != 204 and resp.status != 304 and resp.status != 200) return DockerError.StartFailed;
    }

    /// Stop a container by ID.
    pub fn stopContainer(self: *DockerClient, container_id: []const u8) !void {
        var url_buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&url_buf);
        const w = fbs.writer();
        w.writeAll("/") catch return DockerError.StopFailed;
        w.writeAll(API_VERSION) catch return DockerError.StopFailed;
        w.writeAll("/containers/") catch return DockerError.StopFailed;
        w.writeAll(container_id) catch return DockerError.StopFailed;
        w.writeAll("/stop") catch return DockerError.StopFailed;
        const url = fbs.getWritten();

        var resp = self.client.postJson(url, &.{}, "{}") catch return DockerError.StopFailed;
        defer resp.deinit();

        // 204 = stopped, 304 = already stopped
        if (resp.status != 204 and resp.status != 304 and resp.status != 200) return DockerError.StopFailed;
    }

    /// Remove a container by ID.
    pub fn removeContainer(self: *DockerClient, container_id: []const u8) !void {
        var url_buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&url_buf);
        const w = fbs.writer();
        w.writeAll("/") catch return DockerError.RemoveFailed;
        w.writeAll(API_VERSION) catch return DockerError.RemoveFailed;
        w.writeAll("/containers/") catch return DockerError.RemoveFailed;
        w.writeAll(container_id) catch return DockerError.RemoveFailed;
        w.writeAll("?force=true") catch return DockerError.RemoveFailed;
        const url = fbs.getWritten();

        var resp = self.request(url, .DELETE) catch return DockerError.RemoveFailed;
        defer resp.deinit();

        if (resp.status != 204 and resp.status != 200) return DockerError.RemoveFailed;
    }

    /// Inspect a container. Returns the parsed state string.
    pub fn inspectContainer(self: *DockerClient, container_id: []const u8) !ContainerState {
        var url_buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&url_buf);
        const w = fbs.writer();
        w.writeAll("/") catch return DockerError.InspectFailed;
        w.writeAll(API_VERSION) catch return DockerError.InspectFailed;
        w.writeAll("/containers/") catch return DockerError.InspectFailed;
        w.writeAll(container_id) catch return DockerError.InspectFailed;
        w.writeAll("/json") catch return DockerError.InspectFailed;
        const url = fbs.getWritten();

        var resp = self.client.get(url, &.{}) catch return DockerError.InspectFailed;
        defer resp.deinit();

        if (resp.status != 200) return DockerError.InspectFailed;

        const state_str = extractContainerState(resp.body) orelse return DockerError.InspectFailed;
        return ContainerState.fromString(state_str) orelse DockerError.InspectFailed;
    }

    /// Execute a command in a container. Returns the exec ID.
    pub fn execInContainer(self: *DockerClient, container_id: []const u8, cmd: []const []const u8, working_dir: ?[]const u8) ![]const u8 {
        // Create exec instance
        var body_buf: [2048]u8 = undefined;
        const body = buildExecBody(&body_buf, cmd, working_dir) catch return DockerError.ExecFailed;

        var url_buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&url_buf);
        const w = fbs.writer();
        w.writeAll("/") catch return DockerError.ExecFailed;
        w.writeAll(API_VERSION) catch return DockerError.ExecFailed;
        w.writeAll("/containers/") catch return DockerError.ExecFailed;
        w.writeAll(container_id) catch return DockerError.ExecFailed;
        w.writeAll("/exec") catch return DockerError.ExecFailed;
        const url = fbs.getWritten();

        var resp = self.client.postJson(url, &.{}, body) catch return DockerError.ExecFailed;
        defer resp.deinit();

        if (resp.status != 201 and resp.status != 200) return DockerError.ExecFailed;

        const exec_id = extractExecId(resp.body) orelse return DockerError.ExecFailed;
        return self.allocator.dupe(u8, exec_id) catch return DockerError.ExecFailed;
    }

    fn request(self: *DockerClient, url: []const u8, method: http_client.HttpMethod) !http_client.HttpResponse {
        return self.client.transport.request(self.client.allocator, .{
            .method = method,
            .url = url,
        });
    }
};

// --- Tests ---

test "ContainerState labels and fromString" {
    try std.testing.expectEqualStrings("running", ContainerState.running.label());
    try std.testing.expectEqualStrings("exited", ContainerState.exited.label());
    try std.testing.expectEqual(ContainerState.running, ContainerState.fromString("running").?);
    try std.testing.expectEqual(ContainerState.dead, ContainerState.fromString("dead").?);
    try std.testing.expectEqual(@as(?ContainerState, null), ContainerState.fromString("unknown"));
}

test "ContainerState isAlive" {
    try std.testing.expect(ContainerState.running.isAlive());
    try std.testing.expect(ContainerState.paused.isAlive());
    try std.testing.expect(!ContainerState.stopped.isAlive());
    try std.testing.expect(!ContainerState.exited.isAlive());
    try std.testing.expect(!ContainerState.created.isAlive());
}

test "ContainerConfig defaults" {
    const config = ContainerConfig{};
    try std.testing.expectEqualStrings(DEFAULT_IMAGE, config.image);
    try std.testing.expectEqualStrings("/workspace", config.working_dir);
    try std.testing.expectEqual(@as(u64, 512 * 1024 * 1024), config.memory_limit);
    try std.testing.expect(!config.network_disabled);
}

test "buildApiUrl" {
    var buf: [256]u8 = undefined;
    const url = try buildApiUrl(&buf, "/containers/create");
    try std.testing.expectEqualStrings("/v1.43/containers/create", url);
}

test "buildApiUrl exec" {
    var buf: [256]u8 = undefined;
    const url = try buildApiUrl(&buf, "/containers/abc123/exec");
    try std.testing.expectEqualStrings("/v1.43/containers/abc123/exec", url);
}

test "buildCreateContainerBody basic" {
    var buf: [2048]u8 = undefined;
    const body = try buildCreateContainerBody(&buf, .{});
    try std.testing.expect(std.mem.indexOf(u8, body, "\"Image\":\"ubuntu:22.04\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"WorkingDir\":\"/workspace\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"Memory\":") != null);
}

test "buildCreateContainerBody with cmd" {
    var buf: [2048]u8 = undefined;
    const cmd = [_][]const u8{ "bash", "-c", "echo hello" };
    const body = try buildCreateContainerBody(&buf, .{ .cmd = &cmd });
    try std.testing.expect(std.mem.indexOf(u8, body, "\"Cmd\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"bash\"") != null);
}

test "buildCreateContainerBody with env" {
    var buf: [2048]u8 = undefined;
    const env = [_][]const u8{"HOME=/workspace"};
    const body = try buildCreateContainerBody(&buf, .{ .env = &env });
    try std.testing.expect(std.mem.indexOf(u8, body, "\"Env\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "HOME=/workspace") != null);
}

test "buildCreateContainerBody network disabled" {
    var buf: [2048]u8 = undefined;
    const body = try buildCreateContainerBody(&buf, .{ .network_disabled = true });
    try std.testing.expect(std.mem.indexOf(u8, body, "\"NetworkMode\":\"none\"") != null);
}

test "buildExecBody" {
    var buf: [1024]u8 = undefined;
    const cmd = [_][]const u8{ "ls", "-la" };
    const body = try buildExecBody(&buf, &cmd, "/workspace");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"Cmd\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"ls\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"WorkingDir\":\"/workspace\"") != null);
}

test "buildExecBody no working_dir" {
    var buf: [1024]u8 = undefined;
    const cmd = [_][]const u8{"pwd"};
    const body = try buildExecBody(&buf, &cmd, null);
    try std.testing.expect(std.mem.indexOf(u8, body, "WorkingDir") == null);
}

test "extractContainerId" {
    const json = "{\"Id\":\"abc123def456\",\"Warnings\":[]}";
    try std.testing.expectEqualStrings("abc123def456", extractContainerId(json).?);
}

test "extractContainerId missing" {
    const json = "{\"error\":\"not found\"}";
    try std.testing.expect(extractContainerId(json) == null);
}

test "extractContainerState" {
    const json = "{\"Status\":\"running\"}";
    try std.testing.expectEqualStrings("running", extractContainerState(json).?);
}

test "buildHttpRequest GET" {
    var buf: [512]u8 = undefined;
    const req = try buildHttpRequest(&buf, "GET", "/v1.43/containers/json", null);
    try std.testing.expect(std.mem.startsWith(u8, req, "GET /v1.43/containers/json HTTP/1.1"));
    try std.testing.expect(std.mem.indexOf(u8, req, "Host: localhost") != null);
}

test "buildHttpRequest POST with body" {
    var buf: [1024]u8 = undefined;
    const body_content = "{\"Image\":\"test\"}";
    const req = try buildHttpRequest(&buf, "POST", "/v1.43/containers/create", body_content);
    try std.testing.expect(std.mem.startsWith(u8, req, "POST"));
    try std.testing.expect(std.mem.indexOf(u8, req, "Content-Type: application/json") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, body_content) != null);
}

test "ContainerInfo struct" {
    const info = ContainerInfo{
        .id = "abc123",
        .name = "my-sandbox",
        .image = "ubuntu:22.04",
        .state = .running,
    };
    try std.testing.expectEqualStrings("abc123", info.id);
    try std.testing.expect(info.state.isAlive());
}

test "buildCreateContainerBody custom image" {
    var buf: [2048]u8 = undefined;
    const body = try buildCreateContainerBody(&buf, .{ .image = "node:20" });
    try std.testing.expect(std.mem.indexOf(u8, body, "\"Image\":\"node:20\"") != null);
}

test "DockerClient createContainer" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 201, .body = "{\"Id\":\"abc123def\",\"Warnings\":[]}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var docker = DockerClient.init(allocator, &client);

    const id = try docker.createContainer(.{});
    defer allocator.free(id);
    try std.testing.expectEqualStrings("abc123def", id);
    try std.testing.expectEqual(http_client.HttpMethod.POST, mock.last_method.?);
}

test "DockerClient createContainer failure" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 500, .body = "{\"message\":\"error\"}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var docker = DockerClient.init(allocator, &client);

    try std.testing.expectError(DockerClient.DockerError.CreateFailed, docker.createContainer(.{}));
}

test "DockerClient startContainer" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 204, .body = "" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var docker = DockerClient.init(allocator, &client);

    try docker.startContainer("abc123");
    try std.testing.expect(std.mem.indexOf(u8, mock.last_url.?, "/containers/abc123/start") != null);
}

test "DockerClient stopContainer" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 204, .body = "" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var docker = DockerClient.init(allocator, &client);

    try docker.stopContainer("abc123");
    try std.testing.expect(std.mem.indexOf(u8, mock.last_url.?, "/containers/abc123/stop") != null);
}

test "DockerClient removeContainer" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 204, .body = "" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var docker = DockerClient.init(allocator, &client);

    try docker.removeContainer("abc123");
    try std.testing.expect(std.mem.indexOf(u8, mock.last_url.?, "/containers/abc123") != null);
    try std.testing.expectEqual(http_client.HttpMethod.DELETE, mock.last_method.?);
}

test "DockerClient inspectContainer running" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "{\"State\":{\"Status\":\"running\"},\"Id\":\"abc\"}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var docker = DockerClient.init(allocator, &client);

    const state = try docker.inspectContainer("abc123");
    try std.testing.expectEqual(ContainerState.running, state);
}

test "DockerClient inspectContainer failure" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 404, .body = "{}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var docker = DockerClient.init(allocator, &client);

    try std.testing.expectError(DockerClient.DockerError.InspectFailed, docker.inspectContainer("missing"));
}

test "DockerClient execInContainer" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 201, .body = "{\"Id\":\"exec-abc123\"}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var docker = DockerClient.init(allocator, &client);

    const cmd = [_][]const u8{ "ls", "-la" };
    const exec_id = try docker.execInContainer("container1", &cmd, "/workspace");
    defer allocator.free(exec_id);
    try std.testing.expectEqualStrings("exec-abc123", exec_id);
}

test "DockerClient full lifecycle" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 201, .body = "{\"Id\":\"c1\",\"Warnings\":[]}" }, // create
        .{ .status = 204, .body = "" }, // start
        .{ .status = 200, .body = "{\"State\":{\"Status\":\"running\"}}" }, // inspect
        .{ .status = 204, .body = "" }, // stop
        .{ .status = 204, .body = "" }, // remove
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());
    var docker = DockerClient.init(allocator, &client);

    const id = try docker.createContainer(.{ .image = "ubuntu:22.04" });
    defer allocator.free(id);
    try std.testing.expectEqualStrings("c1", id);

    try docker.startContainer(id);
    const state = try docker.inspectContainer(id);
    try std.testing.expectEqual(ContainerState.running, state);

    try docker.stopContainer(id);
    try docker.removeContainer(id);
    try std.testing.expectEqual(@as(usize, 5), mock.call_count);
}

// --- Additional Tests ---

test "ContainerState all labels non-empty" {
    for (std.meta.tags(ContainerState)) |cs| {
        try std.testing.expect(cs.label().len > 0);
    }
}

test "ContainerState created label" {
    try std.testing.expectEqualStrings("created", ContainerState.created.label());
}

test "ContainerState paused label" {
    try std.testing.expectEqualStrings("paused", ContainerState.paused.label());
}

test "ContainerState stopped label" {
    try std.testing.expectEqualStrings("stopped", ContainerState.stopped.label());
}

test "ContainerState removing label" {
    try std.testing.expectEqualStrings("removing", ContainerState.removing.label());
}

test "ContainerState dead label" {
    try std.testing.expectEqualStrings("dead", ContainerState.dead.label());
}

test "ContainerState dead not alive" {
    try std.testing.expect(!ContainerState.dead.isAlive());
    try std.testing.expect(!ContainerState.removing.isAlive());
}

test "ContainerState fromString all valid" {
    try std.testing.expectEqual(ContainerState.created, ContainerState.fromString("created").?);
    try std.testing.expectEqual(ContainerState.paused, ContainerState.fromString("paused").?);
    try std.testing.expectEqual(ContainerState.stopped, ContainerState.fromString("stopped").?);
    try std.testing.expectEqual(ContainerState.removing, ContainerState.fromString("removing").?);
}

test "DOCKER_SOCKET value" {
    try std.testing.expectEqualStrings("/var/run/docker.sock", DOCKER_SOCKET);
}

test "API_VERSION value" {
    try std.testing.expectEqualStrings("v1.43", API_VERSION);
}

test "DEFAULT_IMAGE value" {
    try std.testing.expectEqualStrings("ubuntu:22.04", DEFAULT_IMAGE);
}

test "ContainerConfig custom values" {
    const config = ContainerConfig{
        .image = "node:20",
        .name = "my-container",
        .working_dir = "/app",
        .memory_limit = 1024 * 1024 * 1024,
        .cpu_quota = 50000,
        .network_disabled = true,
    };
    try std.testing.expectEqualStrings("node:20", config.image);
    try std.testing.expectEqualStrings("my-container", config.name.?);
    try std.testing.expectEqualStrings("/app", config.working_dir);
    try std.testing.expect(config.network_disabled);
}

test "ContainerInfo defaults" {
    const info = ContainerInfo{
        .id = "abc",
        .name = "test",
        .image = "ubuntu:22.04",
    };
    try std.testing.expectEqual(ContainerState.created, info.state);
    try std.testing.expectEqual(@as(i64, 0), info.created_at);
}

test "extractContainerId with warnings" {
    const json = "{\"Id\":\"long-container-id-here\",\"Warnings\":[\"warning1\"]}";
    try std.testing.expectEqualStrings("long-container-id-here", extractContainerId(json).?);
}

test "extractContainerState exited" {
    const json = "{\"Status\":\"exited\"}";
    try std.testing.expectEqualStrings("exited", extractContainerState(json).?);
}

test "extractExecId" {
    const json = "{\"Id\":\"exec-id-123\"}";
    try std.testing.expectEqualStrings("exec-id-123", extractExecId(json).?);
}

test "buildHttpRequest DELETE" {
    var buf: [512]u8 = undefined;
    const req = try buildHttpRequest(&buf, "DELETE", "/v1.43/containers/abc?force=true", null);
    try std.testing.expect(std.mem.startsWith(u8, req, "DELETE"));
    try std.testing.expect(std.mem.indexOf(u8, req, "force=true") != null);
}

// ===== New tests added for comprehensive coverage =====

test "ContainerState fromString empty string" {
    try std.testing.expectEqual(@as(?ContainerState, null), ContainerState.fromString(""));
}

test "ContainerState fromString case sensitive" {
    try std.testing.expectEqual(@as(?ContainerState, null), ContainerState.fromString("Running"));
    try std.testing.expectEqual(@as(?ContainerState, null), ContainerState.fromString("RUNNING"));
}

test "ContainerState isAlive for all states" {
    try std.testing.expect(ContainerState.running.isAlive());
    try std.testing.expect(ContainerState.paused.isAlive());
    try std.testing.expect(!ContainerState.created.isAlive());
    try std.testing.expect(!ContainerState.stopped.isAlive());
    try std.testing.expect(!ContainerState.removing.isAlive());
    try std.testing.expect(!ContainerState.exited.isAlive());
    try std.testing.expect(!ContainerState.dead.isAlive());
}

test "ContainerConfig null name" {
    const config = ContainerConfig{};
    try std.testing.expect(config.name == null);
}

test "ContainerConfig default cpu_quota" {
    const config = ContainerConfig{};
    try std.testing.expectEqual(@as(i64, 100000), config.cpu_quota);
}

test "ContainerConfig empty cmd and env" {
    const config = ContainerConfig{};
    try std.testing.expectEqual(@as(usize, 0), config.cmd.len);
    try std.testing.expectEqual(@as(usize, 0), config.env.len);
}

test "buildApiUrl images endpoint" {
    var buf: [256]u8 = undefined;
    const url = try buildApiUrl(&buf, "/images/json");
    try std.testing.expectEqualStrings("/v1.43/images/json", url);
}

test "buildApiUrl volumes endpoint" {
    var buf: [256]u8 = undefined;
    const url = try buildApiUrl(&buf, "/volumes");
    try std.testing.expectEqualStrings("/v1.43/volumes", url);
}

test "buildApiUrl buffer too small" {
    var buf: [5]u8 = undefined;
    const result = buildApiUrl(&buf, "/containers/create");
    try std.testing.expectError(error.NoSpaceLeft, result);
}

test "buildCreateContainerBody with multiple cmd args" {
    var buf: [2048]u8 = undefined;
    const cmd = [_][]const u8{ "sh", "-c", "echo hello && ls" };
    const body = try buildCreateContainerBody(&buf, .{ .cmd = &cmd });
    try std.testing.expect(std.mem.indexOf(u8, body, "\"sh\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"-c\"") != null);
}

test "buildCreateContainerBody with multiple env vars" {
    var buf: [2048]u8 = undefined;
    const env = [_][]const u8{ "HOME=/workspace", "PATH=/usr/bin", "TERM=xterm" };
    const body = try buildCreateContainerBody(&buf, .{ .env = &env });
    try std.testing.expect(std.mem.indexOf(u8, body, "HOME=/workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "PATH=/usr/bin") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "TERM=xterm") != null);
}

test "buildCreateContainerBody custom memory and cpu" {
    var buf: [2048]u8 = undefined;
    const body = try buildCreateContainerBody(&buf, .{
        .memory_limit = 1024 * 1024 * 1024,
        .cpu_quota = 200000,
    });
    try std.testing.expect(std.mem.indexOf(u8, body, "1073741824") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "200000") != null);
}

test "buildExecBody with single command" {
    var buf: [1024]u8 = undefined;
    const cmd = [_][]const u8{"whoami"};
    const body = try buildExecBody(&buf, &cmd, null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"whoami\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "AttachStdout") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "AttachStderr") != null);
}

test "extractContainerId empty json" {
    try std.testing.expect(extractContainerId("{}") == null);
}

test "extractContainerState missing" {
    try std.testing.expect(extractContainerState("{}") == null);
}

test "extractExecId missing" {
    try std.testing.expect(extractExecId("{}") == null);
}

test "buildHttpRequest PUT" {
    var buf: [512]u8 = undefined;
    const req = try buildHttpRequest(&buf, "PUT", "/v1.43/containers/abc/update", "{\"Memory\":256}");
    try std.testing.expect(std.mem.startsWith(u8, req, "PUT"));
    try std.testing.expect(std.mem.indexOf(u8, req, "Content-Type: application/json") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "{\"Memory\":256}") != null);
}

test "buildHttpRequest Content-Length is correct" {
    var buf: [1024]u8 = undefined;
    const body_content = "test body";
    const req = try buildHttpRequest(&buf, "POST", "/path", body_content);
    try std.testing.expect(std.mem.indexOf(u8, req, "Content-Length: 9") != null);
}
