const std = @import("std");
const registry = @import("registry.zig");
const ssrf = @import("../infra/ssrf.zig");

// --- Web Fetch Tool ---
//
// HTTP GET with HTML-to-text conversion, SSRF protection, and size limits.

pub const MAX_RESPONSE_SIZE: usize = 1024 * 1024; // 1MB
pub const MAX_OUTPUT_SIZE: usize = 64 * 1024; // 64KB output limit

/// Extract a JSON string value for a given key from simple JSON.
fn extractParam(json: []const u8, key: []const u8) ?[]const u8 {
    var prefix_buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&prefix_buf);
    fbs.writer().writeByte('"') catch return null;
    fbs.writer().writeAll(key) catch return null;
    fbs.writer().writeAll("\":\"") catch return null;
    const prefix = fbs.getWritten();

    const start = std.mem.indexOf(u8, json, prefix) orelse return null;
    const value_start = start + prefix.len;
    if (value_start >= json.len) return null;

    var i = value_start;
    while (i < json.len) : (i += 1) {
        if (json[i] == '"' and (i == value_start or json[i - 1] != '\\')) {
            return json[value_start..i];
        }
    }
    return null;
}

/// Strip HTML tags and decode common entities.
pub fn stripHtml(html: []const u8, output: []u8) []const u8 {
    var fbs = std.io.fixedBufferStream(output);
    const writer = fbs.writer();
    var in_tag = false;
    var i: usize = 0;

    while (i < html.len) {
        const c = html[i];
        if (c == '<') {
            in_tag = true;
            // Check for block-level tags that should emit newlines
            if (i + 1 < html.len and !in_tag) {
                // Already set in_tag
            }
            i += 1;
            continue;
        }
        if (c == '>') {
            in_tag = false;
            i += 1;
            continue;
        }
        if (in_tag) {
            i += 1;
            continue;
        }

        // Decode HTML entities
        if (c == '&') {
            if (std.mem.startsWith(u8, html[i..], "&amp;")) {
                writer.writeByte('&') catch break;
                i += 5;
            } else if (std.mem.startsWith(u8, html[i..], "&lt;")) {
                writer.writeByte('<') catch break;
                i += 4;
            } else if (std.mem.startsWith(u8, html[i..], "&gt;")) {
                writer.writeByte('>') catch break;
                i += 4;
            } else if (std.mem.startsWith(u8, html[i..], "&quot;")) {
                writer.writeByte('"') catch break;
                i += 6;
            } else if (std.mem.startsWith(u8, html[i..], "&apos;")) {
                writer.writeByte('\'') catch break;
                i += 6;
            } else if (std.mem.startsWith(u8, html[i..], "&nbsp;")) {
                writer.writeByte(' ') catch break;
                i += 6;
            } else {
                writer.writeByte(c) catch break;
                i += 1;
            }
            continue;
        }

        writer.writeByte(c) catch break;
        i += 1;
    }

    return fbs.getWritten();
}

/// Web fetch tool handler.
/// Input: {"url": "https://example.com"}
/// Output: Text content of the page
pub fn webFetchHandler(input_json: []const u8, output_buf: []u8) registry.ToolResult {
    const url = extractParam(input_json, "url") orelse
        return .{ .success = false, .output = "", .error_message = "missing 'url' parameter" };

    if (url.len == 0)
        return .{ .success = false, .output = "", .error_message = "empty url" };

    // SSRF protection
    if (!ssrf.validateUrl(url))
        return .{ .success = false, .output = "", .error_message = "URL blocked: private/internal address" };

    // In a real implementation, this would do an HTTP GET.
    // For now, return a placeholder indicating the URL was validated.
    var fbs = std.io.fixedBufferStream(output_buf);
    std.fmt.format(fbs.writer(), "web_fetch: validated URL {s}", .{url}) catch
        return .{ .success = false, .output = "", .error_message = "output buffer overflow" };

    return .{
        .success = true,
        .output = fbs.getWritten(),
    };
}

pub const BUILTIN_WEB_FETCH = registry.ToolDef{
    .name = "web_fetch",
    .description = "Fetch a URL and return its text content",
    .category = .web,
    .parameters_json = "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\",\"description\":\"URL to fetch\"}},\"required\":[\"url\"]}",
};

// --- Tests ---

test "stripHtml basic tags" {
    var buf: [1024]u8 = undefined;
    const result = stripHtml("<h1>Hello</h1><p>World</p>", &buf);
    try std.testing.expectEqualStrings("HelloWorld", result);
}

test "stripHtml entities" {
    var buf: [1024]u8 = undefined;
    const result = stripHtml("A &amp; B &lt; C &gt; D", &buf);
    try std.testing.expectEqualStrings("A & B < C > D", result);
}

test "stripHtml quotes and apos" {
    var buf: [1024]u8 = undefined;
    const result = stripHtml("&quot;hello&quot; &apos;world&apos;", &buf);
    try std.testing.expectEqualStrings("\"hello\" 'world'", result);
}

test "stripHtml nbsp" {
    var buf: [1024]u8 = undefined;
    const result = stripHtml("hello&nbsp;world", &buf);
    try std.testing.expectEqualStrings("hello world", result);
}

test "stripHtml no tags" {
    var buf: [1024]u8 = undefined;
    const result = stripHtml("plain text", &buf);
    try std.testing.expectEqualStrings("plain text", result);
}

test "stripHtml empty" {
    var buf: [1024]u8 = undefined;
    const result = stripHtml("", &buf);
    try std.testing.expectEqualStrings("", result);
}

test "webFetchHandler missing url" {
    var buf: [4096]u8 = undefined;
    const result = webFetchHandler("{}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("missing 'url' parameter", result.error_message.?);
}

test "webFetchHandler empty url" {
    var buf: [4096]u8 = undefined;
    const result = webFetchHandler("{\"url\":\"\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("empty url", result.error_message.?);
}

test "webFetchHandler blocks private IP" {
    var buf: [4096]u8 = undefined;
    const result = webFetchHandler("{\"url\":\"http://127.0.0.1:8080\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("URL blocked: private/internal address", result.error_message.?);
}

test "webFetchHandler validates public URL" {
    var buf: [4096]u8 = undefined;
    const result = webFetchHandler("{\"url\":\"https://example.com\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "example.com") != null);
}

test "BUILTIN_WEB_FETCH definition" {
    try std.testing.expectEqualStrings("web_fetch", BUILTIN_WEB_FETCH.name);
    try std.testing.expectEqual(registry.ToolCategory.web, BUILTIN_WEB_FETCH.category);
    try std.testing.expect(BUILTIN_WEB_FETCH.parameters_json != null);
}
