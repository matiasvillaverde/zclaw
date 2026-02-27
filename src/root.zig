// Root module for zclaw - imports all sub-modules
pub const infra = struct {
    pub const errors = @import("infra/errors.zig");
    pub const log = @import("infra/log.zig");
    pub const env = @import("infra/env.zig");
    pub const http_client = @import("infra/http_client.zig");
    pub const retry = @import("infra/retry.zig");
    pub const ssrf = @import("infra/ssrf.zig");
    pub const scrub = @import("infra/scrub.zig");
    pub const validate = @import("infra/validate.zig");
};

pub const config = struct {
    pub const schema = @import("config/schema.zig");
    pub const loader = @import("config/loader.zig");
    pub const watcher = @import("config/watcher.zig");
    pub const validator = @import("config/validator.zig");
};

pub const agent = struct {
    pub const session = @import("agent/session.zig");
    pub const prompt = @import("agent/prompt.zig");
    pub const compaction_mod = @import("agent/compaction.zig");
    pub const failover_mod = @import("agent/failover.zig");
    pub const runtime = @import("agent/runtime.zig");
};

pub const gateway = struct {
    pub const protocol = struct {
        pub const schema = @import("gateway/protocol/schema.zig");
        pub const auth = @import("gateway/protocol/auth.zig");
        pub const handler = @import("gateway/protocol/handler.zig");
    };
    pub const state = @import("gateway/state.zig");
    pub const server = @import("gateway/server.zig");
    pub const methods = @import("gateway/methods.zig");
    pub const rate_limit = @import("gateway/rate_limit.zig");
};

pub const channels = struct {
    pub const channel_plugin = @import("channels/plugin.zig");
    pub const routing = @import("channels/routing.zig");
    pub const access = @import("channels/access.zig");
    pub const telegram = @import("channels/telegram.zig");
    pub const discord_mod = @import("channels/discord.zig");
    pub const slack_mod = @import("channels/slack.zig");
    pub const whatsapp_mod = @import("channels/whatsapp.zig");
    pub const signal_mod = @import("channels/signal.zig");
    pub const matrix_mod = @import("channels/matrix.zig");
};

pub const tools = struct {
    pub const tool_registry = @import("tools/registry.zig");
    pub const policy = @import("tools/policy.zig");
    pub const builtins = @import("tools/builtins.zig");
    pub const web_fetch = @import("tools/web_fetch.zig");
    pub const web_search = @import("tools/web_search.zig");
    pub const memory_tools = @import("tools/memory_tools.zig");
    pub const message = @import("tools/message.zig");
    pub const workspace_guard = @import("tools/workspace_guard.zig");
};

pub const cli = struct {
    pub const cli_main = @import("cli/main.zig");
    pub const cli_output = @import("cli/output.zig");
};

pub const sandbox = struct {
    pub const sandbox_docker = @import("sandbox/docker.zig");
    pub const sandbox_policy = @import("sandbox/policy.zig");
    pub const sandbox_workspace = @import("sandbox/workspace.zig");
};

pub const plugins = struct {
    pub const plugin_manifest = @import("plugins/manifest.zig");
    pub const plugin_api = @import("plugins/api.zig");
    pub const plugin_loader = @import("plugins/loader.zig");
};

pub const ui = struct {
    pub const ui_state = @import("ui/state.zig");
    pub const ui_rpc = @import("ui/rpc.zig");
    pub const ui_views = @import("ui/views.zig");
    pub const ui_static = @import("ui/static.zig");
};

pub const memory = struct {
    pub const chunker = @import("memory/chunker.zig");
    pub const search_mod = @import("memory/search.zig");
    pub const embeddings = @import("memory/embeddings.zig");
    pub const manager = @import("memory/manager.zig");
    pub const storage = @import("memory/storage.zig");
};

pub const providers = struct {
    pub const provider_types = @import("providers/types.zig");
    pub const provider_sse = @import("providers/sse.zig");
    pub const anthropic = @import("providers/anthropic.zig");
    pub const openai = @import("providers/openai.zig");
    pub const openai_compat = @import("providers/openai_compat.zig");
    pub const reliable = @import("providers/reliable.zig");
    pub const gemini = @import("providers/gemini.zig");
};

pub const media = struct {
    pub const chunking = @import("media/chunking.zig");
    pub const markdown = @import("media/markdown.zig");
};

pub const cron = struct {
    pub const cron_parser = @import("cron/parser.zig");
    pub const cron_service = @import("cron/service.zig");
};

pub const hooks = struct {
    pub const hook_registry = @import("hooks/registry.zig");
};

pub const security = struct {
    pub const audit = @import("security/audit.zig");
    pub const secrets = @import("security/secrets.zig");
};

pub const testing_helpers = struct {
    pub const helpers = @import("testing/helpers.zig");
};

test {
    // Import all test modules — infra
    _ = @import("infra/errors.zig");
    _ = @import("infra/log.zig");
    _ = @import("infra/env.zig");
    _ = @import("infra/http_client.zig");
    _ = @import("infra/retry.zig");
    _ = @import("infra/ssrf.zig");
    _ = @import("infra/scrub.zig");
    // config
    _ = @import("config/schema.zig");
    _ = @import("config/loader.zig");
    _ = @import("config/watcher.zig");
    // agent
    _ = @import("agent/session.zig");
    _ = @import("agent/prompt.zig");
    _ = @import("agent/compaction.zig");
    _ = @import("agent/failover.zig");
    _ = @import("agent/runtime.zig");
    // gateway
    _ = @import("gateway/protocol/schema.zig");
    _ = @import("gateway/protocol/auth.zig");
    _ = @import("gateway/protocol/handler.zig");
    _ = @import("gateway/state.zig");
    _ = @import("gateway/server.zig");
    _ = @import("gateway/methods.zig");
    // channels
    _ = @import("channels/plugin.zig");
    _ = @import("channels/routing.zig");
    _ = @import("channels/access.zig");
    _ = @import("channels/telegram.zig");
    _ = @import("channels/discord.zig");
    _ = @import("channels/slack.zig");
    _ = @import("channels/whatsapp.zig");
    _ = @import("channels/signal.zig");
    _ = @import("channels/matrix.zig");
    // tools
    _ = @import("tools/registry.zig");
    _ = @import("tools/policy.zig");
    _ = @import("tools/builtins.zig");
    _ = @import("tools/web_fetch.zig");
    _ = @import("tools/web_search.zig");
    _ = @import("tools/memory_tools.zig");
    _ = @import("tools/message.zig");
    // memory
    _ = @import("memory/chunker.zig");
    _ = @import("memory/search.zig");
    _ = @import("memory/embeddings.zig");
    _ = @import("memory/manager.zig");
    _ = @import("memory/storage.zig");
    // providers
    _ = @import("providers/types.zig");
    _ = @import("providers/sse.zig");
    _ = @import("providers/anthropic.zig");
    _ = @import("providers/openai.zig");
    _ = @import("providers/openai_compat.zig");
    _ = @import("providers/reliable.zig");
    _ = @import("providers/gemini.zig");
    // cli
    _ = @import("cli/main.zig");
    _ = @import("cli/output.zig");
    // sandbox
    _ = @import("sandbox/docker.zig");
    _ = @import("sandbox/policy.zig");
    _ = @import("sandbox/workspace.zig");
    // plugins
    _ = @import("plugins/manifest.zig");
    _ = @import("plugins/api.zig");
    _ = @import("plugins/loader.zig");
    // ui
    _ = @import("ui/state.zig");
    _ = @import("ui/rpc.zig");
    _ = @import("ui/views.zig");
    _ = @import("ui/static.zig");
    // media
    _ = @import("media/chunking.zig");
    _ = @import("media/markdown.zig");
    // cron
    _ = @import("cron/parser.zig");
    _ = @import("cron/service.zig");
    // hooks
    _ = @import("hooks/registry.zig");
    // security
    _ = @import("security/audit.zig");
    _ = @import("security/secrets.zig");
    // new modules
    _ = @import("infra/validate.zig");
    _ = @import("config/validator.zig");
    _ = @import("gateway/rate_limit.zig");
    _ = @import("tools/workspace_guard.zig");
    _ = @import("testing/helpers.zig");
}
