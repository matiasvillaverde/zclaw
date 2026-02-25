// Root module for zclaw - imports all sub-modules
pub const infra = struct {
    pub const errors = @import("infra/errors.zig");
    pub const log = @import("infra/log.zig");
    pub const env = @import("infra/env.zig");
};

pub const config = struct {
    pub const schema = @import("config/schema.zig");
    pub const loader = @import("config/loader.zig");
    pub const watcher = @import("config/watcher.zig");
};

pub const agent = struct {
    pub const session = @import("agent/session.zig");
};

test {
    // Import all test modules
    _ = @import("infra/errors.zig");
    _ = @import("infra/log.zig");
    _ = @import("infra/env.zig");
    _ = @import("config/schema.zig");
    _ = @import("config/loader.zig");
    _ = @import("config/watcher.zig");
    _ = @import("agent/session.zig");
}
