const std = @import("std");
const registry = @import("registry.zig");

const CAMPER_CLI_PATH = "/srv/data/apps/camper-sensor/bin/camper-cli";
const DEFAULT_TIMEOUT = "45";

fn skipWhitespace(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and (s[i] == ' ' or s[i] == '\n' or s[i] == '\r' or s[i] == '\t')) : (i += 1) {}
    return i;
}

fn findValueStart(json: []const u8, key: []const u8) ?usize {
    var key_buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&key_buf);
    fbs.writer().writeByte('"') catch return null;
    fbs.writer().writeAll(key) catch return null;
    fbs.writer().writeByte('"') catch return null;
    const key_token = fbs.getWritten();

    const pos = std.mem.indexOf(u8, json, key_token) orelse return null;
    var i = pos + key_token.len;
    i = skipWhitespace(json, i);
    if (i >= json.len or json[i] != ':') return null;
    i += 1;
    i = skipWhitespace(json, i);
    return if (i < json.len) i else null;
}

fn extractStringParam(json: []const u8, key: []const u8) ?[]const u8 {
    const start = findValueStart(json, key) orelse return null;
    if (json[start] != '"') return null;
    var i = start + 1;
    while (i < json.len) : (i += 1) {
        if (json[i] == '"' and json[i - 1] != '\\') {
            return json[start + 1 .. i];
        }
    }
    return null;
}

fn extractIntParam(json: []const u8, key: []const u8) ?i64 {
    const start = findValueStart(json, key) orelse return null;
    if (start >= json.len) return null;
    var i = start;
    if (json[i] == '-') i += 1;
    const digits_start = i;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1) {}
    if (i == digits_start) return null;
    return std.fmt.parseInt(i64, json[start..i], 10) catch null;
}

fn extractBoolParam(json: []const u8, key: []const u8, default_value: bool) bool {
    const start = findValueStart(json, key) orelse return default_value;
    if (start + 4 <= json.len and std.mem.eql(u8, json[start .. start + 4], "true")) return true;
    if (start + 5 <= json.len and std.mem.eql(u8, json[start .. start + 5], "false")) return false;
    return default_value;
}

fn runCamperCli(args: []const []const u8, output_buf: []u8) registry.ToolResult {
    // Fail fast with an explicit message if the bridge is not installed.
    std.fs.cwd().access(CAMPER_CLI_PATH, .{}) catch {
        return .{ .success = false, .output = "", .error_message = "camper-cli not found on target host" };
    };

    var child = std.process.Child.init(args, std.heap.page_allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch {
        return .{ .success = false, .output = "", .error_message = "failed to spawn camper-cli" };
    };

    const stdout_len: usize = if (child.stdout) |stdout|
        stdout.readAll(output_buf) catch 0
    else
        0;

    var stderr_buf: [1024]u8 = undefined;
    const stderr_len: usize = if (child.stderr) |stderr|
        stderr.readAll(&stderr_buf) catch 0
    else
        0;

    const term = child.wait() catch {
        return .{ .success = false, .output = output_buf[0..stdout_len], .error_message = "camper-cli wait failed" };
    };
    const exit_code = switch (term) {
        .Exited => |code| code,
        else => 1,
    };

    if (exit_code == 0) {
        if (stdout_len > 0) {
            return .{ .success = true, .output = output_buf[0..stdout_len] };
        }
        return .{ .success = true, .output = "{\"ok\":true}" };
    }

    if (stderr_len > 0) {
        return .{
            .success = false,
            .output = output_buf[0..stdout_len],
            .error_message = stderr_buf[0..stderr_len],
        };
    }
    return .{
        .success = false,
        .output = output_buf[0..stdout_len],
        .error_message = "camper-cli returned non-zero exit",
    };
}

fn clampInt(value: i64, min: i64, max: i64, default_value: i64) i64 {
    var v = value;
    if (v < min or v > max) v = default_value;
    if (v < min) v = min;
    if (v > max) v = max;
    return v;
}

pub fn camperSnapshotHandler(input_json: []const u8, output_buf: []u8) registry.ToolResult {
    const send_telegram = extractBoolParam(input_json, "send_telegram", true);
    const annotate = extractBoolParam(input_json, "annotate", true);

    var argv: [8][]const u8 = undefined;
    var argc: usize = 0;
    argv[argc] = CAMPER_CLI_PATH;
    argc += 1;
    argv[argc] = "--timeout";
    argc += 1;
    argv[argc] = DEFAULT_TIMEOUT;
    argc += 1;
    argv[argc] = "snapshot";
    argc += 1;
    if (send_telegram) {
        argv[argc] = "--send-telegram";
        argc += 1;
    }
    if (!annotate) {
        argv[argc] = "--no-annotate";
        argc += 1;
    }

    return runCamperCli(argv[0..argc], output_buf);
}

pub fn camperDetectHandler(_: []const u8, output_buf: []u8) registry.ToolResult {
    const argv = [_][]const u8{
        CAMPER_CLI_PATH,
        "--timeout",
        DEFAULT_TIMEOUT,
        "detect",
    };
    return runCamperCli(&argv, output_buf);
}

pub fn camperStatusHandler(_: []const u8, output_buf: []u8) registry.ToolResult {
    const argv = [_][]const u8{
        CAMPER_CLI_PATH,
        "--timeout",
        DEFAULT_TIMEOUT,
        "status",
    };
    return runCamperCli(&argv, output_buf);
}

pub fn camperVideoHandler(input_json: []const u8, output_buf: []u8) registry.ToolResult {
    const raw_seconds = extractIntParam(input_json, "seconds") orelse 6;
    const seconds = clampInt(raw_seconds, 2, 45, 6);
    const send_telegram = extractBoolParam(input_json, "send_telegram", true);

    var seconds_buf: [16]u8 = undefined;
    const seconds_arg = std.fmt.bufPrint(&seconds_buf, "{d}", .{seconds}) catch "6";

    var argv: [10][]const u8 = undefined;
    var argc: usize = 0;
    argv[argc] = CAMPER_CLI_PATH;
    argc += 1;
    argv[argc] = "--timeout";
    argc += 1;
    argv[argc] = DEFAULT_TIMEOUT;
    argc += 1;
    argv[argc] = "video";
    argc += 1;
    argv[argc] = "--seconds";
    argc += 1;
    argv[argc] = seconds_arg;
    argc += 1;
    if (send_telegram) {
        argv[argc] = "--send-telegram";
        argc += 1;
    }

    return runCamperCli(argv[0..argc], output_buf);
}

pub fn camperAudioHandler(input_json: []const u8, output_buf: []u8) registry.ToolResult {
    const raw_seconds = extractIntParam(input_json, "seconds") orelse 6;
    const seconds = clampInt(raw_seconds, 1, 45, 6);
    const send_telegram = extractBoolParam(input_json, "send_telegram", true);

    var seconds_buf: [16]u8 = undefined;
    const seconds_arg = std.fmt.bufPrint(&seconds_buf, "{d}", .{seconds}) catch "6";

    var argv: [10][]const u8 = undefined;
    var argc: usize = 0;
    argv[argc] = CAMPER_CLI_PATH;
    argc += 1;
    argv[argc] = "--timeout";
    argc += 1;
    argv[argc] = DEFAULT_TIMEOUT;
    argc += 1;
    argv[argc] = "audio";
    argc += 1;
    argv[argc] = "--seconds";
    argc += 1;
    argv[argc] = seconds_arg;
    argc += 1;
    if (send_telegram) {
        argv[argc] = "--send-telegram";
        argc += 1;
    }

    return runCamperCli(argv[0..argc], output_buf);
}

pub fn camperListEventsHandler(input_json: []const u8, output_buf: []u8) registry.ToolResult {
    const raw_limit = extractIntParam(input_json, "limit") orelse 8;
    const limit = clampInt(raw_limit, 1, 50, 8);

    var limit_buf: [16]u8 = undefined;
    const limit_arg = std.fmt.bufPrint(&limit_buf, "{d}", .{limit}) catch "8";

    const argv = [_][]const u8{
        CAMPER_CLI_PATH,
        "--timeout",
        DEFAULT_TIMEOUT,
        "list-events",
        "--limit",
        limit_arg,
    };
    return runCamperCli(&argv, output_buf);
}

pub fn camperTtsHandler(input_json: []const u8, output_buf: []u8) registry.ToolResult {
    const text = extractStringParam(input_json, "text") orelse
        return .{ .success = false, .output = "", .error_message = "missing 'text' parameter" };
    if (text.len == 0) {
        return .{ .success = false, .output = "", .error_message = "empty 'text' parameter" };
    }

    const send_telegram = extractBoolParam(input_json, "send_telegram", true);
    const play_local = extractBoolParam(input_json, "play_local", false);

    var argv: [12][]const u8 = undefined;
    var argc: usize = 0;
    argv[argc] = CAMPER_CLI_PATH;
    argc += 1;
    argv[argc] = "--timeout";
    argc += 1;
    argv[argc] = DEFAULT_TIMEOUT;
    argc += 1;
    argv[argc] = "tts";
    argc += 1;
    argv[argc] = "--text";
    argc += 1;
    argv[argc] = text;
    argc += 1;
    if (send_telegram) {
        argv[argc] = "--send-telegram";
        argc += 1;
    }
    if (play_local) {
        argv[argc] = "--play-local";
        argc += 1;
    }

    return runCamperCli(argv[0..argc], output_buf);
}

pub fn camperReloadFacesHandler(_: []const u8, output_buf: []u8) registry.ToolResult {
    const argv = [_][]const u8{
        CAMPER_CLI_PATH,
        "--timeout",
        DEFAULT_TIMEOUT,
        "reload-faces",
    };
    return runCamperCli(&argv, output_buf);
}

pub const TOOL_CAMPER_SNAPSHOT = registry.ToolDef{
    .name = "camper_snapshot",
    .description = "Capture a camera snapshot and return detection metadata",
    .category = .image,
    .parameters_json = "{\"type\":\"object\",\"properties\":{\"send_telegram\":{\"type\":\"boolean\"},\"annotate\":{\"type\":\"boolean\"}}}",
};

pub const TOOL_CAMPER_DETECT = registry.ToolDef{
    .name = "camper_detect",
    .description = "Read current person and face detection summary",
    .category = .image,
    .parameters_json = "{\"type\":\"object\",\"properties\":{}}",
};

pub const TOOL_CAMPER_STATUS = registry.ToolDef{
    .name = "camper_status",
    .description = "Read sensor uptime, counters, and recognition state",
    .category = .custom,
    .parameters_json = "{\"type\":\"object\",\"properties\":{}}",
};

pub const TOOL_CAMPER_VIDEO = registry.ToolDef{
    .name = "camper_video",
    .description = "Record a short camera video clip",
    .category = .image,
    .parameters_json = "{\"type\":\"object\",\"properties\":{\"seconds\":{\"type\":\"integer\"},\"send_telegram\":{\"type\":\"boolean\"}}}",
};

pub const TOOL_CAMPER_AUDIO = registry.ToolDef{
    .name = "camper_audio",
    .description = "Record a short microphone clip",
    .category = .custom,
    .parameters_json = "{\"type\":\"object\",\"properties\":{\"seconds\":{\"type\":\"integer\"},\"send_telegram\":{\"type\":\"boolean\"}}}",
};

pub const TOOL_CAMPER_LIST_EVENTS = registry.ToolDef{
    .name = "camper_list_events",
    .description = "List recent stored sensor events and media files",
    .category = .custom,
    .parameters_json = "{\"type\":\"object\",\"properties\":{\"limit\":{\"type\":\"integer\"}}}",
};

pub const TOOL_CAMPER_TTS = registry.ToolDef{
    .name = "camper_tts",
    .description = "Synthesize local speech to an audio file",
    .category = .custom,
    .parameters_json = "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"},\"send_telegram\":{\"type\":\"boolean\"},\"play_local\":{\"type\":\"boolean\"}},\"required\":[\"text\"]}",
};

pub const TOOL_CAMPER_RELOAD_FACES = registry.ToolDef{
    .name = "camper_reload_faces",
    .description = "Reload known face identities from disk",
    .category = .custom,
    .parameters_json = "{\"type\":\"object\",\"properties\":{}}",
};

pub fn registerCamperTools(reg: *registry.ToolRegistry) !void {
    try reg.register(TOOL_CAMPER_SNAPSHOT, camperSnapshotHandler);
    try reg.register(TOOL_CAMPER_DETECT, camperDetectHandler);
    try reg.register(TOOL_CAMPER_STATUS, camperStatusHandler);
    try reg.register(TOOL_CAMPER_VIDEO, camperVideoHandler);
    try reg.register(TOOL_CAMPER_AUDIO, camperAudioHandler);
    try reg.register(TOOL_CAMPER_LIST_EVENTS, camperListEventsHandler);
    try reg.register(TOOL_CAMPER_TTS, camperTtsHandler);
    try reg.register(TOOL_CAMPER_RELOAD_FACES, camperReloadFacesHandler);
}

test "registerCamperTools" {
    var reg = registry.ToolRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try registerCamperTools(&reg);
    try std.testing.expect(reg.get("camper_snapshot") != null);
    try std.testing.expect(reg.get("camper_detect") != null);
    try std.testing.expect(reg.get("camper_status") != null);
    try std.testing.expect(reg.get("camper_video") != null);
    try std.testing.expect(reg.get("camper_audio") != null);
    try std.testing.expect(reg.get("camper_list_events") != null);
    try std.testing.expect(reg.get("camper_tts") != null);
    try std.testing.expect(reg.get("camper_reload_faces") != null);
}

test "extractBoolParam default and explicit values" {
    try std.testing.expect(extractBoolParam("{}", "send_telegram", true));
    try std.testing.expect(!extractBoolParam("{}", "send_telegram", false));
    try std.testing.expect(!extractBoolParam("{\"send_telegram\":false}", "send_telegram", true));
    try std.testing.expect(extractBoolParam("{\"send_telegram\":true}", "send_telegram", false));
}
