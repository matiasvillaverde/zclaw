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
