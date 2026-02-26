const std = @import("std");
const parser = @import("parser.zig");

// --- Cron Service ---
//
// Job store with registration and due-job detection.

pub const CronJob = struct {
    id: []const u8,
    expression: []const u8,
    parsed: parser.CronExpr,
    agent_id: []const u8,
    action: []const u8,
    enabled: bool = true,
    last_run_ms: i64 = 0,
};

pub const CronService = struct {
    jobs: std.StringHashMapUnmanaged(CronJob),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CronService {
        return .{
            .jobs = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CronService) void {
        var iter = self.jobs.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.id);
            self.allocator.free(entry.value_ptr.expression);
            self.allocator.free(entry.value_ptr.agent_id);
            self.allocator.free(entry.value_ptr.action);
        }
        self.jobs.deinit(self.allocator);
    }

    /// Add a new cron job.
    pub fn addJob(
        self: *CronService,
        id: []const u8,
        expression: []const u8,
        agent_id: []const u8,
        action: []const u8,
    ) !void {
        const parsed = try parser.parse(expression);
        const id_copy = try self.allocator.dupe(u8, id);
        const expr_copy = try self.allocator.dupe(u8, expression);
        const agent_copy = try self.allocator.dupe(u8, agent_id);
        const action_copy = try self.allocator.dupe(u8, action);

        try self.jobs.put(self.allocator, id_copy, .{
            .id = id_copy,
            .expression = expr_copy,
            .parsed = parsed,
            .agent_id = agent_copy,
            .action = action_copy,
        });
    }

    /// Remove a cron job by ID.
    pub fn removeJob(self: *CronService, id: []const u8) bool {
        if (self.jobs.fetchRemove(id)) |kv| {
            self.allocator.free(kv.value.id);
            self.allocator.free(kv.value.expression);
            self.allocator.free(kv.value.agent_id);
            self.allocator.free(kv.value.action);
            return true;
        }
        return false;
    }

    /// Get jobs that are due at the given time.
    pub fn getDueJobs(
        self: *const CronService,
        minute: u6,
        hour: u5,
        mday: u5,
        month: u4,
        wday: u3,
        allocator: std.mem.Allocator,
    ) ![][]const u8 {
        var due = std.ArrayListUnmanaged([]const u8){};
        var iter = self.jobs.iterator();
        while (iter.next()) |entry| {
            const job = entry.value_ptr;
            if (job.enabled and job.parsed.matches(minute, hour, mday, month, wday)) {
                try due.append(allocator, job.id);
            }
        }
        return try due.toOwnedSlice(allocator);
    }

    /// Mark a job as executed.
    pub fn markExecuted(self: *CronService, id: []const u8) void {
        if (self.jobs.getPtr(id)) |job| {
            job.last_run_ms = std.time.milliTimestamp();
        }
    }

    /// Get job count.
    pub fn jobCount(self: *const CronService) usize {
        return self.jobs.count();
    }

    /// Get a job by ID.
    pub fn getJob(self: *const CronService, id: []const u8) ?CronJob {
        return self.jobs.get(id);
    }

    /// Enable or disable a job.
    pub fn setEnabled(self: *CronService, id: []const u8, enabled: bool) bool {
        if (self.jobs.getPtr(id)) |job| {
            job.enabled = enabled;
            return true;
        }
        return false;
    }
};

// --- Tests ---

test "CronService init and deinit" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();
    try std.testing.expectEqual(@as(usize, 0), svc.jobCount());
}

test "CronService addJob" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("job1", "*/5 * * * *", "agent1", "run_check");
    try std.testing.expectEqual(@as(usize, 1), svc.jobCount());

    const job = svc.getJob("job1").?;
    try std.testing.expectEqualStrings("job1", job.id);
    try std.testing.expectEqualStrings("agent1", job.agent_id);
    try std.testing.expectEqualStrings("run_check", job.action);
    try std.testing.expect(job.enabled);
}

test "CronService removeJob" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("job1", "* * * * *", "a", "b");
    try std.testing.expectEqual(@as(usize, 1), svc.jobCount());

    try std.testing.expect(svc.removeJob("job1"));
    try std.testing.expectEqual(@as(usize, 0), svc.jobCount());
    try std.testing.expect(!svc.removeJob("nonexistent"));
}

test "CronService getDueJobs" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("every_min", "* * * * *", "a", "b");
    try svc.addJob("at_30", "30 * * * *", "a", "c");

    const due = try svc.getDueJobs(30, 9, 15, 6, 1, allocator);
    defer allocator.free(due);

    try std.testing.expectEqual(@as(usize, 2), due.len);
}

test "CronService getDueJobs filtered" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("at_30", "30 * * * *", "a", "c");

    // Minute 0 — job at_30 should not be due
    const due = try svc.getDueJobs(0, 9, 15, 6, 1, allocator);
    defer allocator.free(due);
    try std.testing.expectEqual(@as(usize, 0), due.len);
}

test "CronService markExecuted" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("job1", "* * * * *", "a", "b");
    try std.testing.expectEqual(@as(i64, 0), svc.getJob("job1").?.last_run_ms);

    svc.markExecuted("job1");
    try std.testing.expect(svc.getJob("job1").?.last_run_ms > 0);
}

test "CronService setEnabled" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("job1", "* * * * *", "a", "b");
    try std.testing.expect(svc.getJob("job1").?.enabled);

    try std.testing.expect(svc.setEnabled("job1", false));
    try std.testing.expect(!svc.getJob("job1").?.enabled);

    try std.testing.expect(!svc.setEnabled("nonexistent", true));
}

test "CronService disabled job not due" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("job1", "* * * * *", "a", "b");
    _ = svc.setEnabled("job1", false);

    const due = try svc.getDueJobs(0, 0, 1, 1, 0, allocator);
    defer allocator.free(due);
    try std.testing.expectEqual(@as(usize, 0), due.len);
}

test "CronService addJob invalid expression" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try std.testing.expectError(error.InvalidField, svc.addJob("bad", "invalid", "a", "b"));
}

test "CronService multiple jobs" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("j1", "0 * * * *", "a", "b");
    try svc.addJob("j2", "30 * * * *", "a", "c");
    try svc.addJob("j3", "*/15 * * * *", "a", "d");

    try std.testing.expectEqual(@as(usize, 3), svc.jobCount());
}
