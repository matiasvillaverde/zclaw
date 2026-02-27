const std = @import("std");

// --- Config Errors ---

pub const ConfigError = error{
    FileNotFound,
    ParseFailed,
    ValidationFailed,
    SchemaViolation,
    MissingEnvVar,
    DuplicateAgentDir,
    IncludeDepthExceeded,
    IncludeCycle,
    InvalidPath,
    WriteFailed,
};

// --- Protocol Errors ---

pub const ProtocolError = error{
    InvalidFrame,
    InvalidMethod,
    InvalidParams,
    FrameTooLarge,
    MalformedJson,
    UnexpectedClose,
    HandshakeFailed,
    NotLinked,
    NotPaired,
};

// --- Provider Errors ---

pub const ProviderError = error{
    AuthFailed,
    RateLimited,
    BillingError,
    Timeout,
    ModelNotFound,
    ContextOverflow,
    FormatError,
    Overloaded,
    ConnectionFailed,
    InvalidResponse,
    StreamingError,
    CompactionFailed,
};

// --- Channel Errors ---

pub const ChannelError = error{
    NotConnected,
    AuthenticationFailed,
    MessageSendFailed,
    InvalidPayload,
    ChannelNotFound,
    PollingFailed,
    WebhookFailed,
    RateLimited,
};

// --- Tool Errors ---

pub const ToolError = error{
    ToolNotFound,
    PolicyDenied,
    ExecutionFailed,
    InvalidInput,
    ToolTimeout,
    SandboxError,
};

// --- Auth Errors ---

pub const AuthError = error{
    InvalidToken,
    InvalidPassword,
    TokenExpired,
    ChallengeFailure,
    RateLimited,
    Locked,
};

// --- Session Errors ---

pub const SessionError = error{
    NotFound,
    LockTimeout,
    StaleLock,
    CorruptedFile,
    RepairFailed,
    WriteFailed,
};

// --- Memory Errors ---

pub const MemoryError = error{
    IndexingFailed,
    EmbeddingFailed,
    SearchFailed,
    ChunkingFailed,
    DatabaseError,
};

// --- Failover Reason ---

pub const FailoverReason = enum {
    billing,
    rate_limit,
    auth,
    timeout,
    format,
    model_not_found,
    overloaded,
    unknown,

    pub fn fromHttpStatus(status: u16) ?FailoverReason {
        return switch (status) {
            402 => .billing,
            429 => .rate_limit,
            401, 403 => .auth,
            408, 502, 503, 504 => .timeout,
            400 => .format,
            404 => .model_not_found,
            else => null,
        };
    }

    pub fn label(self: FailoverReason) []const u8 {
        return switch (self) {
            .billing => "billing",
            .rate_limit => "rate_limit",
            .auth => "auth",
            .timeout => "timeout",
            .format => "format",
            .model_not_found => "model_not_found",
            .overloaded => "overloaded",
            .unknown => "unknown",
        };
    }
};

// --- Gateway Error Codes ---

pub const GatewayErrorCode = enum {
    not_linked,
    not_paired,
    agent_timeout,
    invalid_request,
    unavailable,

    pub fn label(self: GatewayErrorCode) []const u8 {
        return switch (self) {
            .not_linked => "NOT_LINKED",
            .not_paired => "NOT_PAIRED",
            .agent_timeout => "AGENT_TIMEOUT",
            .invalid_request => "INVALID_REQUEST",
            .unavailable => "UNAVAILABLE",
        };
    }
};

// --- Error Context ---

pub const ErrorContext = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    profile_id: ?[]const u8 = null,
    status: ?u16 = null,
    code: ?[]const u8 = null,
    subsystem: ?[]const u8 = null,
    message: []const u8 = "",
};

// --- Error Message Classification ---

pub fn classifyFailoverReason(message: []const u8) ?FailoverReason {
    if (containsAnyNoCase(message, &.{ "model not found", "unknown model", "does not exist" })) {
        return .model_not_found;
    }
    if (containsAnyNoCase(message, &.{ "rate limit", "429", "too many requests", "quota exceeded" })) {
        return .rate_limit;
    }
    if (containsAnyNoCase(message, &.{ "overloaded", "service unavailable", "high demand" })) {
        return .overloaded;
    }
    if (containsAnyNoCase(message, &.{ "insufficient credits", "402", "billing" })) {
        return .billing;
    }
    if (containsAnyNoCase(message, &.{ "timeout", "timed out", "deadline exceeded", "ETIMEDOUT" })) {
        return .timeout;
    }
    if (containsAnyNoCase(message, &.{ "invalid api key", "unauthorized", "401", "403", "forbidden" })) {
        return .auth;
    }
    if (containsAnyNoCase(message, &.{ "invalid request", "bad request", "400" })) {
        return .format;
    }
    return null;
}

pub fn isContextOverflowError(message: []const u8) bool {
    return containsAnyNoCase(message, &.{
        "context window exceeded",
        "prompt too long",
        "request_too_large",
        "maximum context length",
        "tokens exceed",
    });
}

fn containsAnyNoCase(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (indexOfNoCase(haystack, needle) != null) return true;
    }
    return false;
}

fn indexOfNoCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    const limit = haystack.len - needle.len + 1;
    for (0..limit) |i| {
        if (eqlNoCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn eqlNoCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

// --- Tests ---

test "FailoverReason.fromHttpStatus" {
    try std.testing.expectEqual(FailoverReason.billing, FailoverReason.fromHttpStatus(402).?);
    try std.testing.expectEqual(FailoverReason.rate_limit, FailoverReason.fromHttpStatus(429).?);
    try std.testing.expectEqual(FailoverReason.auth, FailoverReason.fromHttpStatus(401).?);
    try std.testing.expectEqual(FailoverReason.auth, FailoverReason.fromHttpStatus(403).?);
    try std.testing.expectEqual(FailoverReason.timeout, FailoverReason.fromHttpStatus(408).?);
    try std.testing.expectEqual(FailoverReason.timeout, FailoverReason.fromHttpStatus(502).?);
    try std.testing.expectEqual(FailoverReason.timeout, FailoverReason.fromHttpStatus(503).?);
    try std.testing.expectEqual(FailoverReason.timeout, FailoverReason.fromHttpStatus(504).?);
    try std.testing.expectEqual(FailoverReason.format, FailoverReason.fromHttpStatus(400).?);
    try std.testing.expectEqual(FailoverReason.model_not_found, FailoverReason.fromHttpStatus(404).?);
    try std.testing.expectEqual(@as(?FailoverReason, null), FailoverReason.fromHttpStatus(200));
    try std.testing.expectEqual(@as(?FailoverReason, null), FailoverReason.fromHttpStatus(500));
}

test "FailoverReason.label" {
    try std.testing.expectEqualStrings("billing", FailoverReason.billing.label());
    try std.testing.expectEqualStrings("rate_limit", FailoverReason.rate_limit.label());
    try std.testing.expectEqualStrings("auth", FailoverReason.auth.label());
    try std.testing.expectEqualStrings("unknown", FailoverReason.unknown.label());
}

test "GatewayErrorCode.label" {
    try std.testing.expectEqualStrings("NOT_LINKED", GatewayErrorCode.not_linked.label());
    try std.testing.expectEqualStrings("AGENT_TIMEOUT", GatewayErrorCode.agent_timeout.label());
    try std.testing.expectEqualStrings("INVALID_REQUEST", GatewayErrorCode.invalid_request.label());
}

test "classifyFailoverReason" {
    try std.testing.expectEqual(FailoverReason.model_not_found, classifyFailoverReason("Error: model not found").?);
    try std.testing.expectEqual(FailoverReason.rate_limit, classifyFailoverReason("Error 429: Too Many Requests").?);
    try std.testing.expectEqual(FailoverReason.billing, classifyFailoverReason("Insufficient Credits").?);
    try std.testing.expectEqual(FailoverReason.timeout, classifyFailoverReason("request timed out").?);
    try std.testing.expectEqual(FailoverReason.auth, classifyFailoverReason("Invalid API Key").?);
    try std.testing.expectEqual(FailoverReason.overloaded, classifyFailoverReason("server overloaded").?);
    try std.testing.expectEqual(FailoverReason.format, classifyFailoverReason("400 Bad Request").?);
    try std.testing.expectEqual(@as(?FailoverReason, null), classifyFailoverReason("everything is fine"));
}

test "isContextOverflowError" {
    try std.testing.expect(isContextOverflowError("Error: context window exceeded"));
    try std.testing.expect(isContextOverflowError("prompt too long for model"));
    try std.testing.expect(isContextOverflowError("request_too_large"));
    try std.testing.expect(!isContextOverflowError("normal error message"));
}

test "case insensitive matching" {
    try std.testing.expectEqual(FailoverReason.rate_limit, classifyFailoverReason("RATE LIMIT exceeded").?);
    try std.testing.expectEqual(FailoverReason.auth, classifyFailoverReason("UNAUTHORIZED access").?);
}

test "ErrorContext defaults" {
    const ctx = ErrorContext{};
    try std.testing.expect(ctx.provider == null);
    try std.testing.expect(ctx.model == null);
    try std.testing.expect(ctx.status == null);
    try std.testing.expectEqualStrings("", ctx.message);
}

test "ErrorContext with values" {
    const ctx = ErrorContext{
        .provider = "anthropic",
        .model = "claude-3",
        .status = 429,
        .message = "rate limited",
    };
    try std.testing.expectEqualStrings("anthropic", ctx.provider.?);
    try std.testing.expectEqual(@as(u16, 429), ctx.status.?);
}

test "GatewayErrorCode all labels" {
    try std.testing.expectEqualStrings("NOT_PAIRED", GatewayErrorCode.not_paired.label());
    try std.testing.expectEqualStrings("UNAVAILABLE", GatewayErrorCode.unavailable.label());
}

test "FailoverReason all labels" {
    try std.testing.expectEqualStrings("timeout", FailoverReason.timeout.label());
    try std.testing.expectEqualStrings("format", FailoverReason.format.label());
    try std.testing.expectEqualStrings("model_not_found", FailoverReason.model_not_found.label());
    try std.testing.expectEqualStrings("overloaded", FailoverReason.overloaded.label());
}

test "classifyFailoverReason priority" {
    // "model not found" should be detected even with extra context
    try std.testing.expectEqual(FailoverReason.model_not_found, classifyFailoverReason("The requested model does not exist in our catalog").?);
    // "quota exceeded" maps to rate_limit
    try std.testing.expectEqual(FailoverReason.rate_limit, classifyFailoverReason("quota exceeded for this month").?);
    // "service unavailable" maps to overloaded
    try std.testing.expectEqual(FailoverReason.overloaded, classifyFailoverReason("Service Unavailable - high demand").?);
    // "ETIMEDOUT" maps to timeout
    try std.testing.expectEqual(FailoverReason.timeout, classifyFailoverReason("connect ETIMEDOUT").?);
}

test "isContextOverflowError additional" {
    try std.testing.expect(isContextOverflowError("maximum context length is 200000 tokens"));
    try std.testing.expect(isContextOverflowError("tokens exceed the limit"));
    try std.testing.expect(!isContextOverflowError(""));
}

// ===== Additional comprehensive tests =====

test "FailoverReason.fromHttpStatus - all 2xx codes return null" {
    const codes_2xx = [_]u16{ 200, 201, 202, 203, 204, 205, 206 };
    for (codes_2xx) |code| {
        try std.testing.expectEqual(@as(?FailoverReason, null), FailoverReason.fromHttpStatus(code));
    }
}

test "FailoverReason.fromHttpStatus - all 3xx codes return null" {
    const codes_3xx = [_]u16{ 300, 301, 302, 303, 304, 307, 308 };
    for (codes_3xx) |code| {
        try std.testing.expectEqual(@as(?FailoverReason, null), FailoverReason.fromHttpStatus(code));
    }
}

test "FailoverReason.fromHttpStatus - unmapped 4xx codes return null" {
    const unmapped = [_]u16{ 405, 406, 407, 409, 410, 411, 412, 413, 414, 415, 416, 417, 418, 422, 423, 426, 428, 431, 451 };
    for (unmapped) |code| {
        try std.testing.expectEqual(@as(?FailoverReason, null), FailoverReason.fromHttpStatus(code));
    }
}

test "FailoverReason.fromHttpStatus - 500 returns null, 502-504 return timeout" {
    try std.testing.expectEqual(@as(?FailoverReason, null), FailoverReason.fromHttpStatus(500));
    try std.testing.expectEqual(FailoverReason.timeout, FailoverReason.fromHttpStatus(502).?);
    try std.testing.expectEqual(FailoverReason.timeout, FailoverReason.fromHttpStatus(503).?);
    try std.testing.expectEqual(FailoverReason.timeout, FailoverReason.fromHttpStatus(504).?);
}

test "FailoverReason.fromHttpStatus - 505-599 return null" {
    const codes = [_]u16{ 505, 506, 507, 508, 510, 511 };
    for (codes) |code| {
        try std.testing.expectEqual(@as(?FailoverReason, null), FailoverReason.fromHttpStatus(code));
    }
}

test "FailoverReason.fromHttpStatus - boundary codes 0, 1, 65535" {
    try std.testing.expectEqual(@as(?FailoverReason, null), FailoverReason.fromHttpStatus(0));
    try std.testing.expectEqual(@as(?FailoverReason, null), FailoverReason.fromHttpStatus(1));
    try std.testing.expectEqual(@as(?FailoverReason, null), FailoverReason.fromHttpStatus(65535));
}

test "FailoverReason.fromHttpStatus - 99, 100, 199 return null" {
    try std.testing.expectEqual(@as(?FailoverReason, null), FailoverReason.fromHttpStatus(99));
    try std.testing.expectEqual(@as(?FailoverReason, null), FailoverReason.fromHttpStatus(100));
    try std.testing.expectEqual(@as(?FailoverReason, null), FailoverReason.fromHttpStatus(199));
}

test "FailoverReason.label roundtrip - every variant" {
    const variants = [_]FailoverReason{ .billing, .rate_limit, .auth, .timeout, .format, .model_not_found, .overloaded, .unknown };
    for (variants) |v| {
        const lbl = v.label();
        try std.testing.expect(lbl.len > 0);
        // Verify label is ASCII lowercase with underscores
        for (lbl) |c| {
            try std.testing.expect((c >= 'a' and c <= 'z') or c == '_');
        }
    }
}

test "GatewayErrorCode.label - all variants are SCREAMING_SNAKE_CASE" {
    const variants = [_]GatewayErrorCode{ .not_linked, .not_paired, .agent_timeout, .invalid_request, .unavailable };
    for (variants) |v| {
        const lbl = v.label();
        try std.testing.expect(lbl.len > 0);
        for (lbl) |c| {
            try std.testing.expect((c >= 'A' and c <= 'Z') or c == '_');
        }
    }
}

test "GatewayErrorCode.label - uniqueness" {
    const variants = [_]GatewayErrorCode{ .not_linked, .not_paired, .agent_timeout, .invalid_request, .unavailable };
    for (variants, 0..) |v1, i| {
        for (variants[i + 1 ..]) |v2| {
            try std.testing.expect(!std.mem.eql(u8, v1.label(), v2.label()));
        }
    }
}

test "ErrorContext - all fields null except message" {
    const ctx = ErrorContext{};
    try std.testing.expect(ctx.provider == null);
    try std.testing.expect(ctx.model == null);
    try std.testing.expect(ctx.profile_id == null);
    try std.testing.expect(ctx.status == null);
    try std.testing.expect(ctx.code == null);
    try std.testing.expect(ctx.subsystem == null);
    try std.testing.expectEqualStrings("", ctx.message);
}

test "ErrorContext - with all fields populated" {
    const ctx = ErrorContext{
        .provider = "openai",
        .model = "gpt-4",
        .profile_id = "profile-123",
        .status = 500,
        .code = "internal_error",
        .subsystem = "agent",
        .message = "something went wrong",
    };
    try std.testing.expectEqualStrings("openai", ctx.provider.?);
    try std.testing.expectEqualStrings("gpt-4", ctx.model.?);
    try std.testing.expectEqualStrings("profile-123", ctx.profile_id.?);
    try std.testing.expectEqual(@as(u16, 500), ctx.status.?);
    try std.testing.expectEqualStrings("internal_error", ctx.code.?);
    try std.testing.expectEqualStrings("agent", ctx.subsystem.?);
    try std.testing.expectEqualStrings("something went wrong", ctx.message);
}

test "ErrorContext - message with special characters" {
    const ctx = ErrorContext{
        .message = "error: \"invalid\" <json> & 'quotes' \\ backslash",
    };
    try std.testing.expectEqualStrings("error: \"invalid\" <json> & 'quotes' \\ backslash", ctx.message);
}

test "ErrorContext - message with unicode" {
    const ctx = ErrorContext{
        .message = "error: \xc3\xa9\xc3\xa0\xc3\xbc unicode chars",
    };
    try std.testing.expect(ctx.message.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, ctx.message, "unicode") != null);
}

test "ErrorContext - message with newlines and tabs" {
    const ctx = ErrorContext{
        .message = "line1\nline2\ttab",
    };
    try std.testing.expect(std.mem.indexOf(u8, ctx.message, "\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx.message, "\t") != null);
}

test "ErrorContext - empty strings for optional fields" {
    const ctx = ErrorContext{
        .provider = "",
        .model = "",
        .code = "",
    };
    try std.testing.expectEqualStrings("", ctx.provider.?);
    try std.testing.expectEqualStrings("", ctx.model.?);
    try std.testing.expectEqualStrings("", ctx.code.?);
}

test "classifyFailoverReason - model not found variants" {
    try std.testing.expectEqual(FailoverReason.model_not_found, classifyFailoverReason("model not found").?);
    try std.testing.expectEqual(FailoverReason.model_not_found, classifyFailoverReason("unknown model gpt-5").?);
    try std.testing.expectEqual(FailoverReason.model_not_found, classifyFailoverReason("The model does not exist").?);
    try std.testing.expectEqual(FailoverReason.model_not_found, classifyFailoverReason("MODEL NOT FOUND").?);
    try std.testing.expectEqual(FailoverReason.model_not_found, classifyFailoverReason("Model Not Found in registry").?);
}

test "classifyFailoverReason - rate limit variants" {
    try std.testing.expectEqual(FailoverReason.rate_limit, classifyFailoverReason("rate limit exceeded").?);
    try std.testing.expectEqual(FailoverReason.rate_limit, classifyFailoverReason("HTTP 429").?);
    try std.testing.expectEqual(FailoverReason.rate_limit, classifyFailoverReason("too many requests").?);
    try std.testing.expectEqual(FailoverReason.rate_limit, classifyFailoverReason("quota exceeded").?);
    try std.testing.expectEqual(FailoverReason.rate_limit, classifyFailoverReason("RATE LIMIT").?);
    try std.testing.expectEqual(FailoverReason.rate_limit, classifyFailoverReason("Too Many Requests - slow down").?);
}

test "classifyFailoverReason - overloaded variants" {
    try std.testing.expectEqual(FailoverReason.overloaded, classifyFailoverReason("server is overloaded").?);
    try std.testing.expectEqual(FailoverReason.overloaded, classifyFailoverReason("503 Service Unavailable").?);
    try std.testing.expectEqual(FailoverReason.overloaded, classifyFailoverReason("high demand, try again later").?);
    try std.testing.expectEqual(FailoverReason.overloaded, classifyFailoverReason("OVERLOADED").?);
}

test "classifyFailoverReason - billing variants" {
    try std.testing.expectEqual(FailoverReason.billing, classifyFailoverReason("insufficient credits").?);
    try std.testing.expectEqual(FailoverReason.billing, classifyFailoverReason("402 Payment Required").?);
    try std.testing.expectEqual(FailoverReason.billing, classifyFailoverReason("billing issue detected").?);
    try std.testing.expectEqual(FailoverReason.billing, classifyFailoverReason("BILLING error").?);
}

test "classifyFailoverReason - timeout variants" {
    try std.testing.expectEqual(FailoverReason.timeout, classifyFailoverReason("request timeout").?);
    try std.testing.expectEqual(FailoverReason.timeout, classifyFailoverReason("connection timed out").?);
    try std.testing.expectEqual(FailoverReason.timeout, classifyFailoverReason("deadline exceeded").?);
    try std.testing.expectEqual(FailoverReason.timeout, classifyFailoverReason("ETIMEDOUT error").?);
    try std.testing.expectEqual(FailoverReason.timeout, classifyFailoverReason("TIMEOUT").?);
}

test "classifyFailoverReason - auth variants" {
    try std.testing.expectEqual(FailoverReason.auth, classifyFailoverReason("invalid api key").?);
    try std.testing.expectEqual(FailoverReason.auth, classifyFailoverReason("unauthorized access").?);
    try std.testing.expectEqual(FailoverReason.auth, classifyFailoverReason("HTTP 401").?);
    try std.testing.expectEqual(FailoverReason.auth, classifyFailoverReason("HTTP 403").?);
    try std.testing.expectEqual(FailoverReason.auth, classifyFailoverReason("access forbidden").?);
    try std.testing.expectEqual(FailoverReason.auth, classifyFailoverReason("FORBIDDEN").?);
}

test "classifyFailoverReason - format variants" {
    try std.testing.expectEqual(FailoverReason.format, classifyFailoverReason("invalid request body").?);
    try std.testing.expectEqual(FailoverReason.format, classifyFailoverReason("400 bad request").?);
    try std.testing.expectEqual(FailoverReason.format, classifyFailoverReason("Bad Request: missing field").?);
}

test "classifyFailoverReason - no match returns null" {
    try std.testing.expectEqual(@as(?FailoverReason, null), classifyFailoverReason(""));
    try std.testing.expectEqual(@as(?FailoverReason, null), classifyFailoverReason("success"));
    try std.testing.expectEqual(@as(?FailoverReason, null), classifyFailoverReason("everything works fine"));
    try std.testing.expectEqual(@as(?FailoverReason, null), classifyFailoverReason("completed successfully"));
    try std.testing.expectEqual(@as(?FailoverReason, null), classifyFailoverReason("200 OK"));
}

test "classifyFailoverReason - mixed case" {
    try std.testing.expectEqual(FailoverReason.model_not_found, classifyFailoverReason("MoDeL nOt FoUnD").?);
    try std.testing.expectEqual(FailoverReason.rate_limit, classifyFailoverReason("RaTe LiMiT").?);
    try std.testing.expectEqual(FailoverReason.auth, classifyFailoverReason("UnAuThOrIzEd").?);
}

test "classifyFailoverReason - priority order (model_not_found wins)" {
    // "model not found" check comes first, should win over others
    try std.testing.expectEqual(FailoverReason.model_not_found, classifyFailoverReason("model not found, rate limit also mentioned").?);
}

test "classifyFailoverReason - long message" {
    const long_prefix = "A" ** 1000;
    const msg = long_prefix ++ " rate limit exceeded " ++ long_prefix;
    try std.testing.expectEqual(FailoverReason.rate_limit, classifyFailoverReason(msg).?);
}

test "classifyFailoverReason - needle at start of message" {
    try std.testing.expectEqual(FailoverReason.timeout, classifyFailoverReason("timeout").?);
    try std.testing.expectEqual(FailoverReason.billing, classifyFailoverReason("billing problem").?);
}

test "classifyFailoverReason - needle at end of message" {
    try std.testing.expectEqual(FailoverReason.timeout, classifyFailoverReason("connection timeout").?);
    try std.testing.expectEqual(FailoverReason.rate_limit, classifyFailoverReason("hit the rate limit").?);
}

test "isContextOverflowError - case sensitivity" {
    // The function uses case-insensitive matching
    try std.testing.expect(isContextOverflowError("Context Window Exceeded"));
    try std.testing.expect(isContextOverflowError("PROMPT TOO LONG"));
    try std.testing.expect(isContextOverflowError("REQUEST_TOO_LARGE"));
    try std.testing.expect(isContextOverflowError("Maximum Context Length"));
    try std.testing.expect(isContextOverflowError("TOKENS EXCEED the limit"));
}

test "isContextOverflowError - partial matches should work" {
    try std.testing.expect(isContextOverflowError("Error: context window exceeded for model gpt-4"));
    try std.testing.expect(isContextOverflowError("Your prompt too long, please shorten it"));
}

test "isContextOverflowError - non-matching messages" {
    try std.testing.expect(!isContextOverflowError("context"));
    try std.testing.expect(!isContextOverflowError("window"));
    try std.testing.expect(!isContextOverflowError("prompt"));
    try std.testing.expect(!isContextOverflowError("too"));
    try std.testing.expect(!isContextOverflowError("long"));
    try std.testing.expect(!isContextOverflowError("request too small"));
}

test "indexOfNoCase - basic functionality" {
    try std.testing.expect(indexOfNoCase("Hello World", "hello") != null);
    try std.testing.expectEqual(@as(?usize, 0), indexOfNoCase("Hello World", "hello"));
    try std.testing.expectEqual(@as(?usize, 6), indexOfNoCase("Hello World", "world"));
}

test "indexOfNoCase - needle longer than haystack" {
    try std.testing.expect(indexOfNoCase("hi", "hello world") == null);
}

test "indexOfNoCase - empty needle" {
    // Empty needle should match at position 0
    try std.testing.expectEqual(@as(?usize, 0), indexOfNoCase("hello", ""));
}

test "indexOfNoCase - empty haystack" {
    try std.testing.expect(indexOfNoCase("", "hello") == null);
}

test "indexOfNoCase - both empty" {
    try std.testing.expectEqual(@as(?usize, 0), indexOfNoCase("", ""));
}

test "eqlNoCase - equal strings" {
    try std.testing.expect(eqlNoCase("hello", "hello"));
    try std.testing.expect(eqlNoCase("HELLO", "hello"));
    try std.testing.expect(eqlNoCase("Hello", "hELLO"));
}

test "eqlNoCase - unequal strings" {
    try std.testing.expect(!eqlNoCase("hello", "world"));
    try std.testing.expect(!eqlNoCase("hello", "hell"));
    try std.testing.expect(!eqlNoCase("he", "hello"));
}

test "eqlNoCase - empty strings" {
    try std.testing.expect(eqlNoCase("", ""));
}

test "eqlNoCase - single characters" {
    try std.testing.expect(eqlNoCase("A", "a"));
    try std.testing.expect(eqlNoCase("Z", "z"));
    try std.testing.expect(!eqlNoCase("A", "b"));
}

test "FailoverReason.label - all labels unique" {
    const variants = [_]FailoverReason{ .billing, .rate_limit, .auth, .timeout, .format, .model_not_found, .overloaded, .unknown };
    for (variants, 0..) |v1, i| {
        for (variants[i + 1 ..]) |v2| {
            try std.testing.expect(!std.mem.eql(u8, v1.label(), v2.label()));
        }
    }
}

test "FailoverReason.fromHttpStatus - 408 maps to timeout" {
    try std.testing.expectEqual(FailoverReason.timeout, FailoverReason.fromHttpStatus(408).?);
}

test "ErrorContext - status boundary values" {
    const ctx_min = ErrorContext{ .status = 0 };
    try std.testing.expectEqual(@as(u16, 0), ctx_min.status.?);

    const ctx_max = ErrorContext{ .status = 65535 };
    try std.testing.expectEqual(@as(u16, 65535), ctx_max.status.?);

    const ctx_100 = ErrorContext{ .status = 100 };
    try std.testing.expectEqual(@as(u16, 100), ctx_100.status.?);
}

test "ErrorContext - very long message" {
    const long_msg = "x" ** 10000;
    const ctx = ErrorContext{ .message = long_msg };
    try std.testing.expectEqual(@as(usize, 10000), ctx.message.len);
}

test "containsAnyNoCase - no needles" {
    try std.testing.expect(!containsAnyNoCase("hello", &.{}));
}

test "containsAnyNoCase - multiple needles with first matching" {
    try std.testing.expect(containsAnyNoCase("hello world", &.{ "hello", "world", "other" }));
}

test "containsAnyNoCase - multiple needles with last matching" {
    try std.testing.expect(containsAnyNoCase("hello world", &.{ "foo", "bar", "world" }));
}
