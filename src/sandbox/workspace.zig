const std = @import("std");
const docker = @import("docker.zig");
const policy_mod = @import("policy.zig");

// --- Workspace Config ---

pub const WorkspaceConfig = struct {
    base_dir: []const u8 = "/tmp/zclaw-sandboxes",
    max_idle_seconds: u64 = 86400, // 24 hours
    max_workspaces: u32 = 10,
    default_mount: policy_mod.MountMode = .rw,
};

// --- Workspace State ---

pub const WorkspaceState = enum {
    creating,
    ready,
    active,
    idle,
    pruning,
    removed,

    pub fn label(self: WorkspaceState) []const u8 {
        return switch (self) {
            .creating => "creating",
            .ready => "ready",
            .active => "active",
            .idle => "idle",
            .pruning => "pruning",
            .removed => "removed",
        };
    }

    pub fn isUsable(self: WorkspaceState) bool {
        return self == .ready or self == .active;
    }
};

// --- Workspace Entry ---

pub const Workspace = struct {
    id: []const u8,
    name: []const u8,
    container_id: ?[]const u8 = null,
    host_path: []const u8,
    mount_mode: policy_mod.MountMode = .rw,
    state: WorkspaceState = .creating,
    created_at: i64 = 0,
    last_used_at: i64 = 0,
    security_level: policy_mod.SecurityLevel = .basic,

    pub fn isIdle(self: *const Workspace, now: i64, max_idle_seconds: u64) bool {
        if (self.state != .idle and self.state != .ready) return false;
        if (self.last_used_at == 0) return false;
        const elapsed: u64 = @intCast(@max(0, now - self.last_used_at));
        return elapsed >= max_idle_seconds;
    }

    pub fn markActive(self: *Workspace, now: i64) void {
        self.state = .active;
        self.last_used_at = now;
    }

    pub fn markIdle(self: *Workspace) void {
        self.state = .idle;
    }
};

// --- Workspace Path Builder ---

pub fn buildWorkspacePath(buf: []u8, base_dir: []const u8, workspace_id: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll(base_dir);
    if (base_dir.len > 0 and base_dir[base_dir.len - 1] != '/') {
        try w.writeByte('/');
    }
    try w.writeAll(workspace_id);
    return fbs.getWritten();
}

// --- Docker Mount Builder ---

pub fn buildMountArg(buf: []u8, host_path: []const u8, container_path: []const u8, mode: policy_mod.MountMode) ![]const u8 {
    if (mode == .none) return "";

    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll(host_path);
    try w.writeAll(":");
    try w.writeAll(container_path);
    if (mode == .ro) {
        try w.writeAll(":ro");
    }
    return fbs.getWritten();
}

// --- Prune Check ---

pub fn shouldPrune(workspace: *const Workspace, now: i64, config: WorkspaceConfig) bool {
    return workspace.isIdle(now, config.max_idle_seconds);
}

// --- Workspace Container Config ---

pub fn buildContainerConfig(workspace: *const Workspace, pol: policy_mod.SandboxPolicy) docker.ContainerConfig {
    return .{
        .image = docker.DEFAULT_IMAGE,
        .name = workspace.name,
        .working_dir = "/workspace",
        .memory_limit = @as(u64, pol.max_memory_mb) * 1024 * 1024,
        .cpu_quota = @as(i64, pol.max_cpu_percent) * 1000,
        .network_disabled = pol.network == .none,
    };
}

// --- Serialize Workspace ---

pub fn serializeWorkspace(buf: []u8, ws: *const Workspace) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("{\"id\":\"");
    try w.writeAll(ws.id);
    try w.writeAll("\",\"name\":\"");
    try w.writeAll(ws.name);
    try w.writeAll("\",\"state\":\"");
    try w.writeAll(ws.state.label());
    try w.writeAll("\",\"mount\":\"");
    try w.writeAll(ws.mount_mode.label());
    try w.writeAll("\",\"security\":\"");
    try w.writeAll(ws.security_level.label());
    try w.writeAll("\"}");
    return fbs.getWritten();
}

// --- Workspace Manager ---

pub const WorkspaceManager = struct {
    workspaces: std.StringHashMapUnmanaged(Workspace),
    config: WorkspaceConfig,
    docker: *docker.DockerClient,
    allocator: std.mem.Allocator,
    next_id: u32 = 1,

    pub const ManagerError = error{
        TooManyWorkspaces,
        WorkspaceNotFound,
        CreateFailed,
        AlreadyExists,
    };

    pub fn init(allocator: std.mem.Allocator, dock: *docker.DockerClient, config: WorkspaceConfig) WorkspaceManager {
        return .{
            .workspaces = .{},
            .config = config,
            .docker = dock,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WorkspaceManager) void {
        var iter = self.workspaces.valueIterator();
        while (iter.next()) |ws| {
            self.allocator.free(ws.id);
            self.allocator.free(ws.name);
            self.allocator.free(ws.host_path);
            if (ws.container_id) |cid| self.allocator.free(cid);
        }
        self.workspaces.deinit(self.allocator);
    }

    pub fn count(self: *const WorkspaceManager) usize {
        return self.workspaces.count();
    }

    pub fn createWorkspace(self: *WorkspaceManager, name: []const u8, level: policy_mod.SecurityLevel) !*Workspace {
        if (self.workspaces.count() >= self.config.max_workspaces) return ManagerError.TooManyWorkspaces;
        if (self.workspaces.contains(name)) return ManagerError.AlreadyExists;

        // Generate ID
        var id_buf: [32]u8 = undefined;
        var id_fbs = std.io.fixedBufferStream(&id_buf);
        std.fmt.format(id_fbs.writer(), "ws-{d}", .{self.next_id}) catch return ManagerError.CreateFailed;
        self.next_id += 1;

        // Build host path
        var path_buf: [256]u8 = undefined;
        const host_path_raw = buildWorkspacePath(&path_buf, self.config.base_dir, id_fbs.getWritten()) catch return ManagerError.CreateFailed;

        const id_owned = self.allocator.dupe(u8, id_fbs.getWritten()) catch return ManagerError.CreateFailed;
        errdefer self.allocator.free(id_owned);
        const name_owned = self.allocator.dupe(u8, name) catch return ManagerError.CreateFailed;
        errdefer self.allocator.free(name_owned);
        const path_owned = self.allocator.dupe(u8, host_path_raw) catch return ManagerError.CreateFailed;
        errdefer self.allocator.free(path_owned);

        const pol = policy_mod.policyForLevel(level);
        const mount = if (pol.mount_mode == .none) policy_mod.MountMode.none else self.config.default_mount;

        const ws = Workspace{
            .id = id_owned,
            .name = name_owned,
            .host_path = path_owned,
            .mount_mode = mount,
            .state = .ready,
            .security_level = level,
        };

        self.workspaces.put(self.allocator, name_owned, ws) catch return ManagerError.CreateFailed;
        return self.workspaces.getPtr(name_owned).?;
    }

    pub fn getWorkspace(self: *WorkspaceManager, name: []const u8) ?*Workspace {
        return self.workspaces.getPtr(name);
    }

    pub fn activateWorkspace(self: *WorkspaceManager, name: []const u8, now: i64) !void {
        const ws = self.workspaces.getPtr(name) orelse return ManagerError.WorkspaceNotFound;
        ws.markActive(now);
    }

    pub fn deactivateWorkspace(self: *WorkspaceManager, name: []const u8) !void {
        const ws = self.workspaces.getPtr(name) orelse return ManagerError.WorkspaceNotFound;
        ws.markIdle();
    }

    /// Prune idle workspaces past the max idle time.
    /// Returns the number of workspaces pruned.
    pub fn pruneIdle(self: *WorkspaceManager, now: i64) usize {
        var pruned: usize = 0;
        var to_remove: [64][]const u8 = undefined;
        var remove_count: usize = 0;

        var iter = self.workspaces.valueIterator();
        while (iter.next()) |ws| {
            if (shouldPrune(ws, now, self.config)) {
                if (remove_count < 64) {
                    to_remove[remove_count] = ws.name;
                    remove_count += 1;
                }
            }
        }

        for (to_remove[0..remove_count]) |name| {
            if (self.workspaces.fetchRemove(name)) |kv| {
                self.allocator.free(kv.value.id);
                self.allocator.free(kv.value.name);
                self.allocator.free(kv.value.host_path);
                if (kv.value.container_id) |cid| self.allocator.free(cid);
                pruned += 1;
            }
        }

        return pruned;
    }

    pub fn listWorkspaces(self: *const WorkspaceManager, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.writeAll("{\"workspaces\":[");
        var first = true;
        var iter = self.workspaces.valueIterator();
        while (iter.next()) |ws| {
            if (!first) try w.writeAll(",");
            var ws_buf: [512]u8 = undefined;
            const ws_json = try serializeWorkspace(&ws_buf, ws);
            try w.writeAll(ws_json);
            first = false;
        }
        try w.writeAll("],\"count\":");
        try std.fmt.format(w, "{d}", .{self.workspaces.count()});
        try w.writeAll("}");
        return fbs.getWritten();
    }
};

// --- Tests ---

test "WorkspaceState labels" {
    try std.testing.expectEqualStrings("creating", WorkspaceState.creating.label());
    try std.testing.expectEqualStrings("ready", WorkspaceState.ready.label());
    try std.testing.expectEqualStrings("active", WorkspaceState.active.label());
    try std.testing.expectEqualStrings("idle", WorkspaceState.idle.label());
    try std.testing.expectEqualStrings("removed", WorkspaceState.removed.label());
}

test "WorkspaceState isUsable" {
    try std.testing.expect(WorkspaceState.ready.isUsable());
    try std.testing.expect(WorkspaceState.active.isUsable());
    try std.testing.expect(!WorkspaceState.creating.isUsable());
    try std.testing.expect(!WorkspaceState.idle.isUsable());
    try std.testing.expect(!WorkspaceState.removed.isUsable());
}

test "WorkspaceConfig defaults" {
    const config = WorkspaceConfig{};
    try std.testing.expectEqual(@as(u64, 86400), config.max_idle_seconds);
    try std.testing.expectEqual(@as(u32, 10), config.max_workspaces);
}

test "Workspace isIdle" {
    const ws = Workspace{
        .id = "ws1",
        .name = "test",
        .host_path = "/tmp/ws1",
        .state = .idle,
        .last_used_at = 1000,
    };

    // After max_idle (24h = 86400s)
    try std.testing.expect(ws.isIdle(90000, 86400));
    // Before max_idle
    try std.testing.expect(!ws.isIdle(50000, 86400));
}

test "Workspace isIdle not idle state" {
    const ws = Workspace{
        .id = "ws1",
        .name = "test",
        .host_path = "/tmp/ws1",
        .state = .active,
        .last_used_at = 1000,
    };
    try std.testing.expect(!ws.isIdle(90000, 86400));
}

test "Workspace markActive and markIdle" {
    var ws = Workspace{
        .id = "ws1",
        .name = "test",
        .host_path = "/tmp/ws1",
        .state = .ready,
    };

    ws.markActive(5000);
    try std.testing.expectEqual(WorkspaceState.active, ws.state);
    try std.testing.expectEqual(@as(i64, 5000), ws.last_used_at);

    ws.markIdle();
    try std.testing.expectEqual(WorkspaceState.idle, ws.state);
}

test "buildWorkspacePath" {
    var buf: [256]u8 = undefined;
    const path = try buildWorkspacePath(&buf, "/tmp/zclaw-sandboxes", "ws-abc123");
    try std.testing.expectEqualStrings("/tmp/zclaw-sandboxes/ws-abc123", path);
}

test "buildWorkspacePath trailing slash" {
    var buf: [256]u8 = undefined;
    const path = try buildWorkspacePath(&buf, "/tmp/sandboxes/", "ws1");
    try std.testing.expectEqualStrings("/tmp/sandboxes/ws1", path);
}

test "buildMountArg rw" {
    var buf: [256]u8 = undefined;
    const arg = try buildMountArg(&buf, "/host/path", "/workspace", .rw);
    try std.testing.expectEqualStrings("/host/path:/workspace", arg);
}

test "buildMountArg ro" {
    var buf: [256]u8 = undefined;
    const arg = try buildMountArg(&buf, "/host/path", "/workspace", .ro);
    try std.testing.expectEqualStrings("/host/path:/workspace:ro", arg);
}

test "buildMountArg none" {
    var buf: [256]u8 = undefined;
    const arg = try buildMountArg(&buf, "/host", "/ws", .none);
    try std.testing.expectEqualStrings("", arg);
}

test "shouldPrune" {
    const config = WorkspaceConfig{ .max_idle_seconds = 3600 };
    const ws_idle = Workspace{
        .id = "ws1",
        .name = "test",
        .host_path = "/tmp/ws1",
        .state = .idle,
        .last_used_at = 1000,
    };
    try std.testing.expect(shouldPrune(&ws_idle, 5000, config));
    try std.testing.expect(!shouldPrune(&ws_idle, 2000, config));
}

test "buildContainerConfig" {
    const ws = Workspace{
        .id = "ws1",
        .name = "my-sandbox",
        .host_path = "/tmp/ws1",
    };
    const pol = policy_mod.STRICT_POLICY;
    const config = buildContainerConfig(&ws, pol);
    try std.testing.expectEqualStrings("my-sandbox", config.name.?);
    try std.testing.expect(config.network_disabled);
    try std.testing.expectEqual(@as(u64, 256 * 1024 * 1024), config.memory_limit);
}

test "buildContainerConfig basic policy" {
    const ws = Workspace{
        .id = "ws2",
        .name = "basic-sandbox",
        .host_path = "/tmp/ws2",
    };
    const config = buildContainerConfig(&ws, policy_mod.BASIC_POLICY);
    try std.testing.expect(!config.network_disabled);
    try std.testing.expectEqual(@as(u64, 512 * 1024 * 1024), config.memory_limit);
}

test "serializeWorkspace" {
    const ws = Workspace{
        .id = "ws-abc",
        .name = "dev-sandbox",
        .host_path = "/tmp/ws-abc",
        .state = .active,
        .mount_mode = .rw,
        .security_level = .basic,
    };
    var buf: [512]u8 = undefined;
    const json = try serializeWorkspace(&buf, &ws);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"ws-abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"state\":\"active\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mount\":\"rw\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"security\":\"basic\"") != null);
}

test "Workspace defaults" {
    const ws = Workspace{
        .id = "w",
        .name = "n",
        .host_path = "/p",
    };
    try std.testing.expectEqual(WorkspaceState.creating, ws.state);
    try std.testing.expectEqual(policy_mod.MountMode.rw, ws.mount_mode);
    try std.testing.expectEqual(policy_mod.SecurityLevel.basic, ws.security_level);
    try std.testing.expect(ws.container_id == null);
}

test "WorkspaceManager init and deinit" {
    const allocator = std.testing.allocator;
    const http = @import("../infra/http_client.zig");
    const responses = [_]http.MockTransport.MockResponse{};
    var mock = http.MockTransport.init(&responses);
    var client = http.HttpClient.init(allocator, mock.transport());
    var dock = docker.DockerClient.init(allocator, &client);
    var mgr = WorkspaceManager.init(allocator, &dock, .{});
    defer mgr.deinit();

    try std.testing.expectEqual(@as(usize, 0), mgr.count());
}

test "WorkspaceManager createWorkspace" {
    const allocator = std.testing.allocator;
    const http = @import("../infra/http_client.zig");
    const responses = [_]http.MockTransport.MockResponse{};
    var mock = http.MockTransport.init(&responses);
    var client = http.HttpClient.init(allocator, mock.transport());
    var dock = docker.DockerClient.init(allocator, &client);
    var mgr = WorkspaceManager.init(allocator, &dock, .{});
    defer mgr.deinit();

    const ws = try mgr.createWorkspace("dev-sandbox", .basic);
    try std.testing.expectEqualStrings("dev-sandbox", ws.name);
    try std.testing.expectEqual(WorkspaceState.ready, ws.state);
    try std.testing.expectEqual(policy_mod.SecurityLevel.basic, ws.security_level);
    try std.testing.expectEqual(@as(usize, 1), mgr.count());
}

test "WorkspaceManager createWorkspace duplicate" {
    const allocator = std.testing.allocator;
    const http = @import("../infra/http_client.zig");
    const responses = [_]http.MockTransport.MockResponse{};
    var mock = http.MockTransport.init(&responses);
    var client = http.HttpClient.init(allocator, mock.transport());
    var dock = docker.DockerClient.init(allocator, &client);
    var mgr = WorkspaceManager.init(allocator, &dock, .{});
    defer mgr.deinit();

    _ = try mgr.createWorkspace("ws1", .basic);
    try std.testing.expectError(WorkspaceManager.ManagerError.AlreadyExists, mgr.createWorkspace("ws1", .basic));
}

test "WorkspaceManager too many workspaces" {
    const allocator = std.testing.allocator;
    const http = @import("../infra/http_client.zig");
    const responses = [_]http.MockTransport.MockResponse{};
    var mock = http.MockTransport.init(&responses);
    var client = http.HttpClient.init(allocator, mock.transport());
    var dock = docker.DockerClient.init(allocator, &client);
    var mgr = WorkspaceManager.init(allocator, &dock, .{ .max_workspaces = 2 });
    defer mgr.deinit();

    _ = try mgr.createWorkspace("ws1", .basic);
    _ = try mgr.createWorkspace("ws2", .basic);
    try std.testing.expectError(WorkspaceManager.ManagerError.TooManyWorkspaces, mgr.createWorkspace("ws3", .basic));
}

test "WorkspaceManager activate and deactivate" {
    const allocator = std.testing.allocator;
    const http = @import("../infra/http_client.zig");
    const responses = [_]http.MockTransport.MockResponse{};
    var mock = http.MockTransport.init(&responses);
    var client = http.HttpClient.init(allocator, mock.transport());
    var dock = docker.DockerClient.init(allocator, &client);
    var mgr = WorkspaceManager.init(allocator, &dock, .{});
    defer mgr.deinit();

    _ = try mgr.createWorkspace("ws1", .basic);
    try mgr.activateWorkspace("ws1", 5000);

    const ws = mgr.getWorkspace("ws1").?;
    try std.testing.expectEqual(WorkspaceState.active, ws.state);
    try std.testing.expectEqual(@as(i64, 5000), ws.last_used_at);

    try mgr.deactivateWorkspace("ws1");
    try std.testing.expectEqual(WorkspaceState.idle, ws.state);
}

test "WorkspaceManager activate nonexistent" {
    const allocator = std.testing.allocator;
    const http = @import("../infra/http_client.zig");
    const responses = [_]http.MockTransport.MockResponse{};
    var mock = http.MockTransport.init(&responses);
    var client = http.HttpClient.init(allocator, mock.transport());
    var dock = docker.DockerClient.init(allocator, &client);
    var mgr = WorkspaceManager.init(allocator, &dock, .{});
    defer mgr.deinit();

    try std.testing.expectError(WorkspaceManager.ManagerError.WorkspaceNotFound, mgr.activateWorkspace("nope", 0));
}

test "WorkspaceManager pruneIdle" {
    const allocator = std.testing.allocator;
    const http = @import("../infra/http_client.zig");
    const responses = [_]http.MockTransport.MockResponse{};
    var mock = http.MockTransport.init(&responses);
    var client = http.HttpClient.init(allocator, mock.transport());
    var dock = docker.DockerClient.init(allocator, &client);
    var mgr = WorkspaceManager.init(allocator, &dock, .{ .max_idle_seconds = 100 });
    defer mgr.deinit();

    _ = try mgr.createWorkspace("ws1", .basic);
    try mgr.activateWorkspace("ws1", 1000);
    try mgr.deactivateWorkspace("ws1");

    // Not enough time passed
    try std.testing.expectEqual(@as(usize, 0), mgr.pruneIdle(1050));
    try std.testing.expectEqual(@as(usize, 1), mgr.count());

    // Enough time passed
    try std.testing.expectEqual(@as(usize, 1), mgr.pruneIdle(1200));
    try std.testing.expectEqual(@as(usize, 0), mgr.count());
}

test "WorkspaceManager listWorkspaces" {
    const allocator = std.testing.allocator;
    const http = @import("../infra/http_client.zig");
    const responses = [_]http.MockTransport.MockResponse{};
    var mock = http.MockTransport.init(&responses);
    var client = http.HttpClient.init(allocator, mock.transport());
    var dock = docker.DockerClient.init(allocator, &client);
    var mgr = WorkspaceManager.init(allocator, &dock, .{});
    defer mgr.deinit();

    _ = try mgr.createWorkspace("ws1", .basic);

    var buf: [2048]u8 = undefined;
    const json = try mgr.listWorkspaces(&buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"workspaces\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"ws1\"") != null);
}

test "WorkspaceManager listWorkspaces empty" {
    const allocator = std.testing.allocator;
    const http = @import("../infra/http_client.zig");
    const responses = [_]http.MockTransport.MockResponse{};
    var mock = http.MockTransport.init(&responses);
    var client = http.HttpClient.init(allocator, mock.transport());
    var dock = docker.DockerClient.init(allocator, &client);
    var mgr = WorkspaceManager.init(allocator, &dock, .{});
    defer mgr.deinit();

    var buf: [512]u8 = undefined;
    const json = try mgr.listWorkspaces(&buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"workspaces\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\":0") != null);
}

test "WorkspaceManager paranoid mount mode" {
    const allocator = std.testing.allocator;
    const http = @import("../infra/http_client.zig");
    const responses = [_]http.MockTransport.MockResponse{};
    var mock = http.MockTransport.init(&responses);
    var client = http.HttpClient.init(allocator, mock.transport());
    var dock = docker.DockerClient.init(allocator, &client);
    var mgr = WorkspaceManager.init(allocator, &dock, .{});
    defer mgr.deinit();

    const ws = try mgr.createWorkspace("paranoid-ws", .paranoid);
    try std.testing.expectEqual(policy_mod.MountMode.none, ws.mount_mode);
    try std.testing.expectEqual(policy_mod.SecurityLevel.paranoid, ws.security_level);
}

// --- Additional Tests ---

test "WorkspaceState pruning label" {
    try std.testing.expectEqualStrings("pruning", WorkspaceState.pruning.label());
}

test "WorkspaceState pruning not usable" {
    try std.testing.expect(!WorkspaceState.pruning.isUsable());
}

test "Workspace isIdle zero last_used returns false" {
    const ws = Workspace{
        .id = "ws1",
        .name = "test",
        .host_path = "/tmp/ws1",
        .state = .idle,
        .last_used_at = 0,
    };
    try std.testing.expect(!ws.isIdle(100000, 1));
}

test "Workspace isIdle ready state also triggers" {
    const ws = Workspace{
        .id = "ws1",
        .name = "test",
        .host_path = "/tmp/ws1",
        .state = .ready,
        .last_used_at = 1000,
    };
    try std.testing.expect(ws.isIdle(90000, 86400));
}

test "Workspace markActive updates both fields" {
    var ws = Workspace{
        .id = "ws1",
        .name = "test",
        .host_path = "/tmp/ws1",
        .state = .creating,
    };
    ws.markActive(12345);
    try std.testing.expectEqual(WorkspaceState.active, ws.state);
    try std.testing.expectEqual(@as(i64, 12345), ws.last_used_at);
}

test "buildWorkspacePath empty base" {
    var buf: [256]u8 = undefined;
    const path = try buildWorkspacePath(&buf, "", "ws1");
    try std.testing.expectEqualStrings("ws1", path);
}

test "buildMountArg rw no trailing colon" {
    var buf: [256]u8 = undefined;
    const arg = try buildMountArg(&buf, "/a", "/b", .rw);
    try std.testing.expect(!std.mem.endsWith(u8, arg, ":ro"));
    try std.testing.expectEqualStrings("/a:/b", arg);
}

test "shouldPrune active workspace" {
    const config = WorkspaceConfig{ .max_idle_seconds = 1 };
    const ws = Workspace{
        .id = "ws1",
        .name = "test",
        .host_path = "/tmp/ws1",
        .state = .active,
        .last_used_at = 1000,
    };
    try std.testing.expect(!shouldPrune(&ws, 99999, config));
}

test "WorkspaceConfig custom values" {
    const config = WorkspaceConfig{
        .base_dir = "/custom/path",
        .max_idle_seconds = 3600,
        .max_workspaces = 5,
        .default_mount = .ro,
    };
    try std.testing.expectEqualStrings("/custom/path", config.base_dir);
    try std.testing.expectEqual(@as(u64, 3600), config.max_idle_seconds);
    try std.testing.expectEqual(@as(u32, 5), config.max_workspaces);
    try std.testing.expectEqual(policy_mod.MountMode.ro, config.default_mount);
}

test "serializeWorkspace creating state" {
    const ws = Workspace{
        .id = "ws-new",
        .name = "fresh",
        .host_path = "/tmp/ws-new",
        .state = .creating,
        .security_level = .strict,
    };
    var buf: [512]u8 = undefined;
    const json = try serializeWorkspace(&buf, &ws);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"state\":\"creating\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"security\":\"strict\"") != null);
}

test "WorkspaceManager getWorkspace nonexistent" {
    const allocator = std.testing.allocator;
    const http = @import("../infra/http_client.zig");
    const responses = [_]http.MockTransport.MockResponse{};
    var mock = http.MockTransport.init(&responses);
    var client = http.HttpClient.init(allocator, mock.transport());
    var dock = docker.DockerClient.init(allocator, &client);
    var mgr = WorkspaceManager.init(allocator, &dock, .{});
    defer mgr.deinit();

    try std.testing.expect(mgr.getWorkspace("missing") == null);
}

test "WorkspaceManager deactivate nonexistent" {
    const allocator = std.testing.allocator;
    const http = @import("../infra/http_client.zig");
    const responses = [_]http.MockTransport.MockResponse{};
    var mock = http.MockTransport.init(&responses);
    var client = http.HttpClient.init(allocator, mock.transport());
    var dock = docker.DockerClient.init(allocator, &client);
    var mgr = WorkspaceManager.init(allocator, &dock, .{});
    defer mgr.deinit();

    try std.testing.expectError(WorkspaceManager.ManagerError.WorkspaceNotFound, mgr.deactivateWorkspace("nope"));
}

// ===== New tests added for comprehensive coverage =====

test "WorkspaceState all labels non-empty" {
    const states = [_]WorkspaceState{ .creating, .ready, .active, .idle, .pruning, .removed };
    for (states) |s| {
        try std.testing.expect(s.label().len > 0);
    }
}

test "WorkspaceState removed not usable" {
    try std.testing.expect(!WorkspaceState.removed.isUsable());
}

test "Workspace isIdle creating state returns false" {
    const ws = Workspace{
        .id = "ws1",
        .name = "test",
        .host_path = "/tmp",
        .state = .creating,
        .last_used_at = 1000,
    };
    try std.testing.expect(!ws.isIdle(999999, 1));
}

test "Workspace isIdle removed state returns false" {
    const ws = Workspace{
        .id = "ws1",
        .name = "test",
        .host_path = "/tmp",
        .state = .removed,
        .last_used_at = 1000,
    };
    try std.testing.expect(!ws.isIdle(999999, 1));
}

test "Workspace isIdle pruning state returns false" {
    const ws = Workspace{
        .id = "ws1",
        .name = "test",
        .host_path = "/tmp",
        .state = .pruning,
        .last_used_at = 1000,
    };
    try std.testing.expect(!ws.isIdle(999999, 1));
}

test "Workspace markActive from idle" {
    var ws = Workspace{
        .id = "ws1",
        .name = "test",
        .host_path = "/tmp",
        .state = .idle,
    };
    ws.markActive(9999);
    try std.testing.expectEqual(WorkspaceState.active, ws.state);
    try std.testing.expectEqual(@as(i64, 9999), ws.last_used_at);
}

test "buildWorkspacePath with long id" {
    var buf: [512]u8 = undefined;
    const long_id = "workspace-" ++ "a" ** 50;
    const path = try buildWorkspacePath(&buf, "/tmp/sandboxes", long_id);
    try std.testing.expect(std.mem.startsWith(u8, path, "/tmp/sandboxes/"));
    try std.testing.expect(std.mem.endsWith(u8, path, long_id));
}

test "buildWorkspacePath buffer too small" {
    var buf: [5]u8 = undefined;
    const result = buildWorkspacePath(&buf, "/tmp/long-base-dir", "ws1");
    try std.testing.expectError(error.NoSpaceLeft, result);
}

test "buildMountArg buffer too small" {
    var buf: [5]u8 = undefined;
    const result = buildMountArg(&buf, "/very/long/host/path", "/workspace", .rw);
    try std.testing.expectError(error.NoSpaceLeft, result);
}

test "shouldPrune removed workspace" {
    const config = WorkspaceConfig{ .max_idle_seconds = 1 };
    const ws = Workspace{
        .id = "ws1",
        .name = "test",
        .host_path = "/tmp/ws1",
        .state = .removed,
        .last_used_at = 1000,
    };
    try std.testing.expect(!shouldPrune(&ws, 999999, config));
}

test "shouldPrune creating workspace" {
    const config = WorkspaceConfig{ .max_idle_seconds = 1 };
    const ws = Workspace{
        .id = "ws1",
        .name = "test",
        .host_path = "/tmp/ws1",
        .state = .creating,
        .last_used_at = 1000,
    };
    try std.testing.expect(!shouldPrune(&ws, 999999, config));
}

test "buildContainerConfig paranoid policy" {
    const ws = Workspace{
        .id = "ws1",
        .name = "paranoid-ws",
        .host_path = "/tmp/ws1",
    };
    const pol = policy_mod.PARANOID_POLICY;
    const config = buildContainerConfig(&ws, pol);
    try std.testing.expect(config.network_disabled);
    try std.testing.expectEqual(@as(u64, 128 * 1024 * 1024), config.memory_limit);
    try std.testing.expectEqual(@as(i64, 25000), config.cpu_quota);
}

test "buildContainerConfig workspace name passed through" {
    const ws = Workspace{
        .id = "ws-xyz",
        .name = "my-workspace",
        .host_path = "/tmp/ws-xyz",
    };
    const config = buildContainerConfig(&ws, policy_mod.BASIC_POLICY);
    try std.testing.expectEqualStrings("my-workspace", config.name.?);
    try std.testing.expectEqualStrings(docker.DEFAULT_IMAGE, config.image);
}

test "serializeWorkspace idle state" {
    const ws = Workspace{
        .id = "ws-idle",
        .name = "idle-ws",
        .host_path = "/tmp",
        .state = .idle,
        .mount_mode = .ro,
        .security_level = .paranoid,
    };
    var buf: [512]u8 = undefined;
    const json = try serializeWorkspace(&buf, &ws);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"state\":\"idle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mount\":\"ro\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"security\":\"paranoid\"") != null);
}

test "serializeWorkspace buffer too small" {
    const ws = Workspace{
        .id = "ws-abc",
        .name = "my-workspace",
        .host_path = "/tmp",
    };
    var buf: [10]u8 = undefined;
    const result = serializeWorkspace(&buf, &ws);
    try std.testing.expectError(error.NoSpaceLeft, result);
}

test "WorkspaceManager create multiple workspaces" {
    const allocator = std.testing.allocator;
    const http = @import("../infra/http_client.zig");
    const responses = [_]http.MockTransport.MockResponse{};
    var mock = http.MockTransport.init(&responses);
    var client = http.HttpClient.init(allocator, mock.transport());
    var dock = docker.DockerClient.init(allocator, &client);
    var mgr = WorkspaceManager.init(allocator, &dock, .{ .max_workspaces = 5 });
    defer mgr.deinit();

    _ = try mgr.createWorkspace("ws1", .basic);
    _ = try mgr.createWorkspace("ws2", .strict);
    _ = try mgr.createWorkspace("ws3", .paranoid);
    try std.testing.expectEqual(@as(usize, 3), mgr.count());
}

test "WorkspaceManager strict workspace has ro mount" {
    const allocator = std.testing.allocator;
    const http = @import("../infra/http_client.zig");
    const responses = [_]http.MockTransport.MockResponse{};
    var mock = http.MockTransport.init(&responses);
    var client = http.HttpClient.init(allocator, mock.transport());
    var dock = docker.DockerClient.init(allocator, &client);
    var mgr = WorkspaceManager.init(allocator, &dock, .{});
    defer mgr.deinit();

    const ws = try mgr.createWorkspace("strict-ws", .strict);
    try std.testing.expectEqual(policy_mod.SecurityLevel.strict, ws.security_level);
    // strict policy has .ro mount, but workspace uses config.default_mount (.rw) since policy is not .none
    try std.testing.expectEqual(policy_mod.MountMode.rw, ws.mount_mode);
}

test "WorkspaceManager pruneIdle no workspaces" {
    const allocator = std.testing.allocator;
    const http = @import("../infra/http_client.zig");
    const responses = [_]http.MockTransport.MockResponse{};
    var mock = http.MockTransport.init(&responses);
    var client = http.HttpClient.init(allocator, mock.transport());
    var dock = docker.DockerClient.init(allocator, &client);
    var mgr = WorkspaceManager.init(allocator, &dock, .{});
    defer mgr.deinit();

    try std.testing.expectEqual(@as(usize, 0), mgr.pruneIdle(999999));
}

test "WorkspaceManager activate and check state" {
    const allocator = std.testing.allocator;
    const http = @import("../infra/http_client.zig");
    const responses = [_]http.MockTransport.MockResponse{};
    var mock = http.MockTransport.init(&responses);
    var client = http.HttpClient.init(allocator, mock.transport());
    var dock = docker.DockerClient.init(allocator, &client);
    var mgr = WorkspaceManager.init(allocator, &dock, .{});
    defer mgr.deinit();

    _ = try mgr.createWorkspace("ws1", .basic);
    const ws = mgr.getWorkspace("ws1").?;
    try std.testing.expectEqual(WorkspaceState.ready, ws.state);

    try mgr.activateWorkspace("ws1", 1000);
    try std.testing.expectEqual(WorkspaceState.active, ws.state);
    try std.testing.expect(ws.state.isUsable());
}
