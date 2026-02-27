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

// --- Additional Tests ---

test "CronService getJob nonexistent" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try std.testing.expect(svc.getJob("missing") == null);
}

test "CronService markExecuted nonexistent is safe" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    // Should not crash
    svc.markExecuted("missing");
}

test "CronService markExecuted sets recent timestamp" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("j1", "* * * * *", "agent", "action");
    const before = std.time.milliTimestamp();
    svc.markExecuted("j1");
    const after = std.time.milliTimestamp();

    const ts = svc.getJob("j1").?.last_run_ms;
    try std.testing.expect(ts >= before);
    try std.testing.expect(ts <= after);
}

test "CronService re-enable job becomes due" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("j1", "* * * * *", "a", "b");
    _ = svc.setEnabled("j1", false);

    const due1 = try svc.getDueJobs(0, 0, 1, 1, 0, allocator);
    defer allocator.free(due1);
    try std.testing.expectEqual(@as(usize, 0), due1.len);

    _ = svc.setEnabled("j1", true);

    const due2 = try svc.getDueJobs(0, 0, 1, 1, 0, allocator);
    defer allocator.free(due2);
    try std.testing.expectEqual(@as(usize, 1), due2.len);
}

test "CronService getDueJobs empty service" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    const due = try svc.getDueJobs(0, 0, 1, 1, 0, allocator);
    defer allocator.free(due);
    try std.testing.expectEqual(@as(usize, 0), due.len);
}

test "CronService removeJob returns false for nonexistent" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try std.testing.expect(!svc.removeJob("never-added"));
}

test "CronService add and remove multiple" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("a", "0 * * * *", "x", "y");
    try svc.addJob("b", "30 * * * *", "x", "z");
    try std.testing.expectEqual(@as(usize, 2), svc.jobCount());

    try std.testing.expect(svc.removeJob("a"));
    try std.testing.expectEqual(@as(usize, 1), svc.jobCount());
    try std.testing.expect(svc.getJob("a") == null);
    try std.testing.expect(svc.getJob("b") != null);
}

test "CronJob defaults" {
    const cron = try parser.parse("* * * * *");
    const job = CronJob{
        .id = "test",
        .expression = "* * * * *",
        .parsed = cron,
        .agent_id = "agent",
        .action = "do_thing",
    };
    try std.testing.expect(job.enabled);
    try std.testing.expectEqual(@as(i64, 0), job.last_run_ms);
}

test "CronService setEnabled returns false for nonexistent" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try std.testing.expect(!svc.setEnabled("missing", true));
}

// === New Tests (batch 2) ===

test "CronService addJob validates expression" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    // Valid expression
    try svc.addJob("good", "0 0 * * *", "agent", "action");
    try std.testing.expectEqual(@as(usize, 1), svc.jobCount());
}

test "CronService addJob invalid too many fields" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try std.testing.expectError(error.InvalidField, svc.addJob("bad", "* * * * * *", "a", "b"));
}

test "CronService addJob invalid too few fields" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try std.testing.expectError(error.InvalidField, svc.addJob("bad", "* *", "a", "b"));
}

test "CronService addJob invalid out of range" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try std.testing.expectError(error.InvalidField, svc.addJob("bad", "60 * * * *", "a", "b"));
}

test "CronService getJob returns all fields correctly" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("test-job", "*/5 9-17 * * 1-5", "agent-42", "send_report");
    const job = svc.getJob("test-job").?;
    try std.testing.expectEqualStrings("test-job", job.id);
    try std.testing.expectEqualStrings("*/5 9-17 * * 1-5", job.expression);
    try std.testing.expectEqualStrings("agent-42", job.agent_id);
    try std.testing.expectEqualStrings("send_report", job.action);
    try std.testing.expect(job.enabled);
    try std.testing.expectEqual(@as(i64, 0), job.last_run_ms);
}

test "CronService getDueJobs with step expression" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("every5", "*/5 * * * *", "a", "b");

    // minute 0 should match
    const due0 = try svc.getDueJobs(0, 12, 15, 6, 3, allocator);
    defer allocator.free(due0);
    try std.testing.expectEqual(@as(usize, 1), due0.len);

    // minute 3 should not match
    const due3 = try svc.getDueJobs(3, 12, 15, 6, 3, allocator);
    defer allocator.free(due3);
    try std.testing.expectEqual(@as(usize, 0), due3.len);

    // minute 15 should match
    const due15 = try svc.getDueJobs(15, 12, 15, 6, 3, allocator);
    defer allocator.free(due15);
    try std.testing.expectEqual(@as(usize, 1), due15.len);
}

test "CronService getDueJobs hour filter" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("morning", "0 9 * * *", "a", "b");

    // hour 9 matches
    const due9 = try svc.getDueJobs(0, 9, 1, 1, 0, allocator);
    defer allocator.free(due9);
    try std.testing.expectEqual(@as(usize, 1), due9.len);

    // hour 10 does not match
    const due10 = try svc.getDueJobs(0, 10, 1, 1, 0, allocator);
    defer allocator.free(due10);
    try std.testing.expectEqual(@as(usize, 0), due10.len);
}

test "CronService getDueJobs day of week filter" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("weekday", "0 0 * * 1-5", "a", "b");

    // Monday (1) should match
    const due1 = try svc.getDueJobs(0, 0, 1, 1, 1, allocator);
    defer allocator.free(due1);
    try std.testing.expectEqual(@as(usize, 1), due1.len);

    // Sunday (0) should not match
    const due0 = try svc.getDueJobs(0, 0, 1, 1, 0, allocator);
    defer allocator.free(due0);
    try std.testing.expectEqual(@as(usize, 0), due0.len);

    // Saturday (6) should not match
    const due6 = try svc.getDueJobs(0, 0, 1, 1, 6, allocator);
    defer allocator.free(due6);
    try std.testing.expectEqual(@as(usize, 0), due6.len);
}

test "CronService getDueJobs month filter" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("jan_only", "0 0 1 1 *", "a", "b");

    // January matches
    const jan = try svc.getDueJobs(0, 0, 1, 1, 0, allocator);
    defer allocator.free(jan);
    try std.testing.expectEqual(@as(usize, 1), jan.len);

    // February does not match
    const feb = try svc.getDueJobs(0, 0, 1, 2, 0, allocator);
    defer allocator.free(feb);
    try std.testing.expectEqual(@as(usize, 0), feb.len);
}

test "CronService setEnabled toggle multiple times" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("j", "* * * * *", "a", "b");

    _ = svc.setEnabled("j", false);
    try std.testing.expect(!svc.getJob("j").?.enabled);

    _ = svc.setEnabled("j", true);
    try std.testing.expect(svc.getJob("j").?.enabled);

    _ = svc.setEnabled("j", false);
    try std.testing.expect(!svc.getJob("j").?.enabled);
}

test "CronService removeJob then getJob returns null" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("temp", "0 0 * * *", "a", "b");
    try std.testing.expect(svc.getJob("temp") != null);

    _ = svc.removeJob("temp");
    try std.testing.expect(svc.getJob("temp") == null);
}

test "CronService multiple jobs same time different filters" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("hourly", "0 * * * *", "a", "hourly_check");
    try svc.addJob("daily", "0 0 * * *", "a", "daily_check");
    try svc.addJob("weekly", "0 0 * * 1", "a", "weekly_check");

    // At midnight Monday: all three match
    const due_monday_midnight = try svc.getDueJobs(0, 0, 1, 1, 1, allocator);
    defer allocator.free(due_monday_midnight);
    try std.testing.expectEqual(@as(usize, 3), due_monday_midnight.len);

    // At midnight Sunday: hourly and daily match, not weekly (requires Monday)
    const due_sunday_midnight = try svc.getDueJobs(0, 0, 1, 1, 0, allocator);
    defer allocator.free(due_sunday_midnight);
    try std.testing.expectEqual(@as(usize, 2), due_sunday_midnight.len);

    // At 3am Monday: only hourly matches (minute=0, hour=3)
    const due_3am = try svc.getDueJobs(0, 3, 1, 1, 1, allocator);
    defer allocator.free(due_3am);
    try std.testing.expectEqual(@as(usize, 1), due_3am.len);
}

test "CronService markExecuted updates timestamp" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("j", "* * * * *", "a", "b");
    try std.testing.expectEqual(@as(i64, 0), svc.getJob("j").?.last_run_ms);

    svc.markExecuted("j");
    const ts1 = svc.getJob("j").?.last_run_ms;
    try std.testing.expect(ts1 > 0);

    // Second execution should have >= timestamp
    svc.markExecuted("j");
    const ts2 = svc.getJob("j").?.last_run_ms;
    try std.testing.expect(ts2 >= ts1);
}

test "CronService add remove add same id" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("recycle", "0 0 * * *", "agent1", "action1");
    try std.testing.expectEqualStrings("agent1", svc.getJob("recycle").?.agent_id);

    _ = svc.removeJob("recycle");
    try std.testing.expect(svc.getJob("recycle") == null);

    try svc.addJob("recycle", "*/5 * * * *", "agent2", "action2");
    try std.testing.expectEqualStrings("agent2", svc.getJob("recycle").?.agent_id);
    try std.testing.expectEqualStrings("action2", svc.getJob("recycle").?.action);
}

test "CronService getDueJobs does not include removed jobs" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("a", "* * * * *", "x", "y");
    try svc.addJob("b", "* * * * *", "x", "z");

    _ = svc.removeJob("a");

    const due = try svc.getDueJobs(0, 0, 1, 1, 0, allocator);
    defer allocator.free(due);
    try std.testing.expectEqual(@as(usize, 1), due.len);
}

test "CronJob enabled defaults to true" {
    const cron = try parser.parse("* * * * *");
    const job = CronJob{
        .id = "x",
        .expression = "* * * * *",
        .parsed = cron,
        .agent_id = "a",
        .action = "b",
    };
    try std.testing.expect(job.enabled);
}

test "CronJob last_run_ms defaults to 0" {
    const cron = try parser.parse("* * * * *");
    const job = CronJob{
        .id = "x",
        .expression = "* * * * *",
        .parsed = cron,
        .agent_id = "a",
        .action = "b",
    };
    try std.testing.expectEqual(@as(i64, 0), job.last_run_ms);
}

test "CronService removeJob double remove" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("once", "* * * * *", "a", "b");
    try std.testing.expect(svc.removeJob("once"));
    try std.testing.expect(!svc.removeJob("once"));
}

test "CronService addJob with range expression" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("range", "0-30 9-17 1-15 1-6 1-5", "a", "b");
    const job = svc.getJob("range").?;
    try std.testing.expectEqualStrings("0-30 9-17 1-15 1-6 1-5", job.expression);
}

test "CronService jobCount after add and remove" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("a", "* * * * *", "x", "y");
    try svc.addJob("b", "* * * * *", "x", "y");
    try svc.addJob("c", "* * * * *", "x", "y");
    try std.testing.expectEqual(@as(usize, 3), svc.jobCount());

    _ = svc.removeJob("b");
    try std.testing.expectEqual(@as(usize, 2), svc.jobCount());

    _ = svc.removeJob("a");
    _ = svc.removeJob("c");
    try std.testing.expectEqual(@as(usize, 0), svc.jobCount());
}

test "CronService getDueJobs with range and step" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    // Every 15 minutes during business hours on weekdays
    try svc.addJob("biz", "*/15 9-17 * * 1-5", "a", "b");

    // 9:00 Monday should match
    const due1 = try svc.getDueJobs(0, 9, 1, 1, 1, allocator);
    defer allocator.free(due1);
    try std.testing.expectEqual(@as(usize, 1), due1.len);

    // 9:07 Monday should not match (not a */15 minute)
    const due2 = try svc.getDueJobs(7, 9, 1, 1, 1, allocator);
    defer allocator.free(due2);
    try std.testing.expectEqual(@as(usize, 0), due2.len);

    // 3:00 Monday should not match (outside 9-17)
    const due3 = try svc.getDueJobs(0, 3, 1, 1, 1, allocator);
    defer allocator.free(due3);
    try std.testing.expectEqual(@as(usize, 0), due3.len);
}

// === Tests batch 3: job store, due-job detection, missed jobs, state management, concurrency edge cases ===

test "CronService getDueJobs returns correct job IDs" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("alpha", "0 * * * *", "a", "action_a");
    try svc.addJob("beta", "30 * * * *", "a", "action_b");
    try svc.addJob("gamma", "* * * * *", "a", "action_c");

    // At minute 0: alpha and gamma should be due
    const due = try svc.getDueJobs(0, 12, 15, 6, 3, allocator);
    defer allocator.free(due);
    try std.testing.expectEqual(@as(usize, 2), due.len);

    // Verify the returned IDs reference the actual job IDs
    var found_alpha = false;
    var found_gamma = false;
    for (due) |id| {
        if (std.mem.eql(u8, id, "alpha")) found_alpha = true;
        if (std.mem.eql(u8, id, "gamma")) found_gamma = true;
    }
    try std.testing.expect(found_alpha);
    try std.testing.expect(found_gamma);
}

test "CronService disable one of many jobs affects getDueJobs" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("j1", "* * * * *", "a", "b");
    try svc.addJob("j2", "* * * * *", "a", "c");
    try svc.addJob("j3", "* * * * *", "a", "d");

    // All three due
    const due_all = try svc.getDueJobs(0, 0, 1, 1, 0, allocator);
    defer allocator.free(due_all);
    try std.testing.expectEqual(@as(usize, 3), due_all.len);

    // Disable j2
    _ = svc.setEnabled("j2", false);
    const due_after = try svc.getDueJobs(0, 0, 1, 1, 0, allocator);
    defer allocator.free(due_after);
    try std.testing.expectEqual(@as(usize, 2), due_after.len);
}

test "CronService markExecuted does not affect due detection" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("j1", "* * * * *", "a", "b");
    svc.markExecuted("j1");

    // markExecuted only updates last_run_ms, doesn't disable the job
    const due = try svc.getDueJobs(0, 0, 1, 1, 0, allocator);
    defer allocator.free(due);
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expect(svc.getJob("j1").?.last_run_ms > 0);
}

test "CronService addJob stores parsed expression that matches correctly" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    // Every 10 minutes at hour 8 on weekdays in January
    try svc.addJob("specific", "*/10 8 * 1 1-5", "agent", "check");

    // 8:00 Monday January should match
    const due_match = try svc.getDueJobs(0, 8, 15, 1, 1, allocator);
    defer allocator.free(due_match);
    try std.testing.expectEqual(@as(usize, 1), due_match.len);

    // 8:05 Monday January should NOT match (5 is not */10)
    const due_no = try svc.getDueJobs(5, 8, 15, 1, 1, allocator);
    defer allocator.free(due_no);
    try std.testing.expectEqual(@as(usize, 0), due_no.len);

    // 8:00 Monday February should NOT match (month 2 != 1)
    const due_feb = try svc.getDueJobs(0, 8, 15, 2, 1, allocator);
    defer allocator.free(due_feb);
    try std.testing.expectEqual(@as(usize, 0), due_feb.len);
}

test "CronService remove then add preserves independent state" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("temp", "0 0 * * *", "agent-old", "old-action");
    svc.markExecuted("temp");
    const old_ts = svc.getJob("temp").?.last_run_ms;
    try std.testing.expect(old_ts > 0);

    _ = svc.removeJob("temp");

    // Re-add with same id but different params -- should have fresh state
    try svc.addJob("temp", "30 12 * * *", "agent-new", "new-action");
    const job = svc.getJob("temp").?;
    try std.testing.expectEqualStrings("agent-new", job.agent_id);
    try std.testing.expectEqualStrings("new-action", job.action);
    try std.testing.expectEqualStrings("30 12 * * *", job.expression);
    // last_run_ms should be reset to 0 since it's a brand new job
    try std.testing.expectEqual(@as(i64, 0), job.last_run_ms);
    try std.testing.expect(job.enabled);
}

test "CronService getDueJobs day of month filter" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    // First of the month only
    try svc.addJob("monthly", "0 0 1 * *", "a", "monthly_report");

    // Day 1 should match
    const due1 = try svc.getDueJobs(0, 0, 1, 6, 3, allocator);
    defer allocator.free(due1);
    try std.testing.expectEqual(@as(usize, 1), due1.len);

    // Day 15 should not match
    const due15 = try svc.getDueJobs(0, 0, 15, 6, 3, allocator);
    defer allocator.free(due15);
    try std.testing.expectEqual(@as(usize, 0), due15.len);
}

test "CronService setEnabled idempotent" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("j1", "* * * * *", "a", "b");

    // Disable multiple times - should succeed each time
    try std.testing.expect(svc.setEnabled("j1", false));
    try std.testing.expect(!svc.getJob("j1").?.enabled);
    try std.testing.expect(svc.setEnabled("j1", false));
    try std.testing.expect(!svc.getJob("j1").?.enabled);

    // Enable multiple times - should succeed each time
    try std.testing.expect(svc.setEnabled("j1", true));
    try std.testing.expect(svc.getJob("j1").?.enabled);
    try std.testing.expect(svc.setEnabled("j1", true));
    try std.testing.expect(svc.getJob("j1").?.enabled);
}

test "CronService getDueJobs many jobs mixed matching" {
    const allocator = std.testing.allocator;
    var svc = CronService.init(allocator);
    defer svc.deinit();

    try svc.addJob("every_min", "* * * * *", "a", "b");
    try svc.addJob("at_noon", "0 12 * * *", "a", "c");
    try svc.addJob("weekends", "0 12 * * 0", "a", "d");
    try svc.addJob("disabled_all", "* * * * *", "a", "e");
    _ = svc.setEnabled("disabled_all", false);

    try std.testing.expectEqual(@as(usize, 4), svc.jobCount());
    try std.testing.expect(!svc.getJob("disabled_all").?.enabled);

    // At noon on a Sunday: every_min + at_noon + weekends = 3 (disabled not counted)
    const due = try svc.getDueJobs(0, 12, 15, 6, 0, allocator);
    defer allocator.free(due);
    try std.testing.expectEqual(@as(usize, 3), due.len);
}
