const std = @import("std");
const registry = @import("registry.zig");
const ssrf = @import("../infra/ssrf.zig");
const http_client = @import("../infra/http_client.zig");

// --- Web Search Tool ---
//
// Brave Search API integration. Formats numbered results with
// title, URL, and snippet.

pub const BRAVE_BASE_URL = "https://api.search.brave.com";
pub const BRAVE_SEARCH_PATH = "/res/v1/web/search";
pub const DEFAULT_COUNT: u8 = 5;

var global_http_client: ?*http_client.HttpClient = null;
var global_brave_api_key: ?[]const u8 = null;

/// Set the HTTP client for web search operations.
pub fn setHttpClient(client: *http_client.HttpClient) void {
    global_http_client = client;
}

/// Clear the HTTP client reference.
pub fn clearHttpClient() void {
    global_http_client = null;
}

/// Set the Brave API key.
pub fn setBraveApiKey(key: []const u8) void {
    global_brave_api_key = key;
}

/// Clear the Brave API key.
pub fn clearBraveApiKey() void {
    global_brave_api_key = null;
}

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

/// Build search URL with query parameter.
pub fn buildSearchUrl(buf: []u8, query: []const u8, count: u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    try writer.writeAll(BRAVE_BASE_URL);
    try writer.writeAll(BRAVE_SEARCH_PATH);
    try writer.writeAll("?q=");
    // Simple URL encoding for the query
    for (query) |c| {
        switch (c) {
            ' ' => try writer.writeAll("+"),
            '&' => try writer.writeAll("%26"),
            '=' => try writer.writeAll("%3D"),
            '?' => try writer.writeAll("%3F"),
            '#' => try writer.writeAll("%23"),
            '+' => try writer.writeAll("%2B"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeAll("&count=");
    try std.fmt.format(writer, "{d}", .{count});
    return fbs.getWritten();
}

/// Parse search results from Brave API JSON response.
/// Extracts title, url, and description from web.results array.
pub fn parseSearchResults(json: []const u8, output: []u8) []const u8 {
    var fbs = std.io.fixedBufferStream(output);
    const writer = fbs.writer();
    var count: usize = 0;

    // Simple extraction: find "title":" and "url":" and "description":" patterns
    var pos: usize = 0;
    while (pos < json.len) {
        const title_start = std.mem.indexOf(u8, json[pos..], "\"title\":\"") orelse break;
        const abs_title_start = pos + title_start + 9;
        const title_end = std.mem.indexOf(u8, json[abs_title_start..], "\"") orelse break;
        const title = json[abs_title_start .. abs_title_start + title_end];

        pos = abs_title_start + title_end;

        const url_start = std.mem.indexOf(u8, json[pos..], "\"url\":\"") orelse break;
        const abs_url_start = pos + url_start + 7;
        const url_end = std.mem.indexOf(u8, json[abs_url_start..], "\"") orelse break;
        const url = json[abs_url_start .. abs_url_start + url_end];

        pos = abs_url_start + url_end;

        // Try to find description
        var desc: []const u8 = "";
        if (std.mem.indexOf(u8, json[pos..], "\"description\":\"")) |desc_start| {
            const abs_desc_start = pos + desc_start + 15;
            if (std.mem.indexOf(u8, json[abs_desc_start..], "\"")) |desc_end| {
                desc = json[abs_desc_start .. abs_desc_start + desc_end];
                pos = abs_desc_start + desc_end;
            }
        }

        count += 1;
        std.fmt.format(writer, "{d}. {s}\n   {s}\n", .{ count, title, url }) catch break;
        if (desc.len > 0) {
            std.fmt.format(writer, "   {s}\n", .{desc}) catch break;
        }
        writer.writeByte('\n') catch break;
    }

    if (count == 0) {
        writer.writeAll("No results found.") catch {};
    }

    return fbs.getWritten();
}

/// Web search tool handler.
/// Input: {"query": "search terms"}
/// Output: Numbered search results
pub fn webSearchHandler(input_json: []const u8, output_buf: []u8) registry.ToolResult {
    const query = extractParam(input_json, "query") orelse
        return .{ .success = false, .output = "", .error_message = "missing 'query' parameter" };

    if (query.len == 0)
        return .{ .success = false, .output = "", .error_message = "empty query" };

    const client = global_http_client orelse
        return .{ .success = false, .output = "", .error_message = "HTTP client not initialized" };

    const api_key = global_brave_api_key orelse
        return .{ .success = false, .output = "", .error_message = "Brave API key not configured" };

    // Build search URL
    var url_buf: [2048]u8 = undefined;
    const url = buildSearchUrl(&url_buf, query, DEFAULT_COUNT) catch
        return .{ .success = false, .output = "", .error_message = "URL build failed" };

    // Make the request with API key header
    const headers = [_]http_client.Header{
        .{ .name = "X-Subscription-Token", .value = api_key },
        .{ .name = "Accept", .value = "application/json" },
    };

    var resp = client.get(url, &headers) catch
        return .{ .success = false, .output = "", .error_message = "HTTP request failed" };
    defer resp.deinit();

    if (resp.status != 200) {
        var fbs = std.io.fixedBufferStream(output_buf);
        std.fmt.format(fbs.writer(), "Brave API error: status {d}", .{resp.status}) catch {};
        return .{ .success = false, .output = "", .error_message = fbs.getWritten() };
    }

    // Parse results
    const output = parseSearchResults(resp.body, output_buf);

    return .{
        .success = true,
        .output = output,
    };
}

pub const BUILTIN_WEB_SEARCH = registry.ToolDef{
    .name = "web_search",
    .description = "Search the web using Brave Search API",
    .category = .web,
    .parameters_json = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"Search query\"}},\"required\":[\"query\"]}",
};

// --- Tests ---

test "buildSearchUrl basic" {
    var buf: [1024]u8 = undefined;
    const url = try buildSearchUrl(&buf, "zig programming", 5);
    try std.testing.expect(std.mem.indexOf(u8, url, "api.search.brave.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "q=zig+programming") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "count=5") != null);
}

test "buildSearchUrl with special chars" {
    var buf: [1024]u8 = undefined;
    const url = try buildSearchUrl(&buf, "foo&bar=baz", 3);
    try std.testing.expect(std.mem.indexOf(u8, url, "%26") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "%3D") != null);
}

test "parseSearchResults single result" {
    const json =
        \\{"web":{"results":[{"title":"Zig Language","url":"https://ziglang.org","description":"A systems language"}]}}
    ;
    var buf: [4096]u8 = undefined;
    const result = parseSearchResults(json, &buf);
    try std.testing.expect(std.mem.indexOf(u8, result, "1. Zig Language") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "https://ziglang.org") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "A systems language") != null);
}

test "parseSearchResults empty" {
    var buf: [4096]u8 = undefined;
    const result = parseSearchResults("{}", &buf);
    try std.testing.expectEqualStrings("No results found.", result);
}

test "parseSearchResults multiple results" {
    const json =
        \\{"web":{"results":[{"title":"A","url":"https://a.com","description":"First"},{"title":"B","url":"https://b.com","description":"Second"}]}}
    ;
    var buf: [4096]u8 = undefined;
    const result = parseSearchResults(json, &buf);
    try std.testing.expect(std.mem.indexOf(u8, result, "1. A") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "2. B") != null);
}

test "webSearchHandler missing query" {
    var buf: [4096]u8 = undefined;
    const result = webSearchHandler("{}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("missing 'query' parameter", result.error_message.?);
}

test "webSearchHandler empty query" {
    var buf: [4096]u8 = undefined;
    const result = webSearchHandler("{\"query\":\"\"}", &buf);
    try std.testing.expect(!result.success);
}

test "webSearchHandler no client" {
    clearHttpClient();
    clearBraveApiKey();
    var buf: [4096]u8 = undefined;
    const result = webSearchHandler("{\"query\":\"zig language\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("HTTP client not initialized", result.error_message.?);
}

test "webSearchHandler no API key" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{};
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());

    setHttpClient(&client);
    clearBraveApiKey();
    defer clearHttpClient();

    var buf: [4096]u8 = undefined;
    const result = webSearchHandler("{\"query\":\"test\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("Brave API key not configured", result.error_message.?);
}

test "webSearchHandler successful search" {
    const allocator = std.testing.allocator;
    const brave_json =
        \\{"web":{"results":[{"title":"Zig Language","url":"https://ziglang.org","description":"A systems language"},{"title":"Zig Guide","url":"https://zig.guide","description":"Learn Zig"}]}}
    ;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = brave_json },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());

    setHttpClient(&client);
    setBraveApiKey("test-api-key");
    defer clearHttpClient();
    defer clearBraveApiKey();

    var buf: [4096]u8 = undefined;
    const result = webSearchHandler("{\"query\":\"zig language\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "1. Zig Language") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "https://ziglang.org") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "2. Zig Guide") != null);
    // Verify mock was called
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
}

test "webSearchHandler API error" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 429, .body = "{\"error\":\"rate limited\"}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());

    setHttpClient(&client);
    setBraveApiKey("test-key");
    defer clearHttpClient();
    defer clearBraveApiKey();

    var buf: [4096]u8 = undefined;
    const result = webSearchHandler("{\"query\":\"test\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_message.?, "429") != null);
}

test "webSearchHandler no results" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "{\"web\":{\"results\":[]}}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());

    setHttpClient(&client);
    setBraveApiKey("test-key");
    defer clearHttpClient();
    defer clearBraveApiKey();

    var buf: [4096]u8 = undefined;
    const result = webSearchHandler("{\"query\":\"xyznonexistent\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("No results found.", result.output);
}

test "webSearchHandler connection failure" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{};
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());

    setHttpClient(&client);
    setBraveApiKey("test-key");
    defer clearHttpClient();
    defer clearBraveApiKey();

    var buf: [4096]u8 = undefined;
    const result = webSearchHandler("{\"query\":\"test\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("HTTP request failed", result.error_message.?);
}

test "BUILTIN_WEB_SEARCH definition" {
    try std.testing.expectEqualStrings("web_search", BUILTIN_WEB_SEARCH.name);
    try std.testing.expectEqual(registry.ToolCategory.web, BUILTIN_WEB_SEARCH.category);
}

// --- Additional Tests ---

test "buildSearchUrl empty query" {
    var buf: [1024]u8 = undefined;
    const url = try buildSearchUrl(&buf, "", 5);
    try std.testing.expect(std.mem.indexOf(u8, url, "q=") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "count=5") != null);
}

test "buildSearchUrl with plus sign" {
    var buf: [1024]u8 = undefined;
    const url = try buildSearchUrl(&buf, "c++", 3);
    try std.testing.expect(std.mem.indexOf(u8, url, "c%2B%2B") != null);
}

test "buildSearchUrl with question mark" {
    var buf: [1024]u8 = undefined;
    const url = try buildSearchUrl(&buf, "what?", 5);
    try std.testing.expect(std.mem.indexOf(u8, url, "%3F") != null);
}

test "buildSearchUrl with hash" {
    var buf: [1024]u8 = undefined;
    const url = try buildSearchUrl(&buf, "c#", 5);
    try std.testing.expect(std.mem.indexOf(u8, url, "%23") != null);
}

test "parseSearchResults with description only" {
    const json =
        \\{"web":{"results":[{"title":"Test","url":"https://t.com","description":"Desc here"}]}}
    ;
    var buf: [4096]u8 = undefined;
    const result = parseSearchResults(json, &buf);
    try std.testing.expect(std.mem.indexOf(u8, result, "1. Test") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Desc here") != null);
}

test "parseSearchResults no web field" {
    var buf: [4096]u8 = undefined;
    const result = parseSearchResults("{\"other\":\"data\"}", &buf);
    try std.testing.expectEqualStrings("No results found.", result);
}

test "DEFAULT_COUNT is 5" {
    try std.testing.expectEqual(@as(u8, 5), DEFAULT_COUNT);
}

test "BRAVE_BASE_URL format" {
    try std.testing.expect(std.mem.startsWith(u8, BRAVE_BASE_URL, "https://"));
    try std.testing.expect(std.mem.indexOf(u8, BRAVE_BASE_URL, "brave.com") != null);
}

test "BRAVE_SEARCH_PATH starts with slash" {
    try std.testing.expect(std.mem.startsWith(u8, BRAVE_SEARCH_PATH, "/"));
}

test "BUILTIN_WEB_SEARCH parameters contain query" {
    const params = BUILTIN_WEB_SEARCH.parameters_json.?;
    try std.testing.expect(std.mem.indexOf(u8, params, "query") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "required") != null);
}

test "webSearchHandler with empty response body" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = "" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());

    setHttpClient(&client);
    setBraveApiKey("test-key");
    defer clearHttpClient();
    defer clearBraveApiKey();

    var buf: [4096]u8 = undefined;
    const result = webSearchHandler("{\"query\":\"test\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("No results found.", result.output);
}

// === New Tests (batch 2) ===

test "buildSearchUrl count parameter varies" {
    var buf: [1024]u8 = undefined;
    const url3 = try buildSearchUrl(&buf, "test", 3);
    try std.testing.expect(std.mem.indexOf(u8, url3, "count=3") != null);

    const url10 = try buildSearchUrl(&buf, "test", 10);
    try std.testing.expect(std.mem.indexOf(u8, url10, "count=10") != null);

    const url1 = try buildSearchUrl(&buf, "test", 1);
    try std.testing.expect(std.mem.indexOf(u8, url1, "count=1") != null);
}

test "buildSearchUrl path is correct" {
    var buf: [1024]u8 = undefined;
    const url = try buildSearchUrl(&buf, "hello", 5);
    try std.testing.expect(std.mem.indexOf(u8, url, BRAVE_SEARCH_PATH) != null);
    try std.testing.expect(std.mem.indexOf(u8, url, BRAVE_BASE_URL) != null);
}

test "buildSearchUrl multiple spaces" {
    var buf: [1024]u8 = undefined;
    const url = try buildSearchUrl(&buf, "a b c", 5);
    try std.testing.expect(std.mem.indexOf(u8, url, "a+b+c") != null);
}

test "buildSearchUrl all special chars" {
    var buf: [1024]u8 = undefined;
    const url = try buildSearchUrl(&buf, "a&b=c?d#e+f", 5);
    try std.testing.expect(std.mem.indexOf(u8, url, "%26") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "%3D") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "%3F") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "%23") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "%2B") != null);
}

test "buildSearchUrl normal alphanumeric not encoded" {
    var buf: [1024]u8 = undefined;
    const url = try buildSearchUrl(&buf, "hello123", 5);
    try std.testing.expect(std.mem.indexOf(u8, url, "q=hello123") != null);
}

test "parseSearchResults three results" {
    const json =
        \\{"web":{"results":[{"title":"A","url":"https://a.com","description":"Desc A"},{"title":"B","url":"https://b.com","description":"Desc B"},{"title":"C","url":"https://c.com","description":"Desc C"}]}}
    ;
    var buf: [4096]u8 = undefined;
    const result = parseSearchResults(json, &buf);
    try std.testing.expect(std.mem.indexOf(u8, result, "1. A") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "2. B") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "3. C") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Desc A") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Desc C") != null);
}

test "parseSearchResults result without description" {
    const json =
        \\{"web":{"results":[{"title":"NoDesc","url":"https://nodesc.com"}]}}
    ;
    var buf: [4096]u8 = undefined;
    const result = parseSearchResults(json, &buf);
    try std.testing.expect(std.mem.indexOf(u8, result, "1. NoDesc") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "https://nodesc.com") != null);
}

test "parseSearchResults malformed JSON" {
    var buf: [4096]u8 = undefined;
    const result = parseSearchResults("not json at all", &buf);
    try std.testing.expectEqualStrings("No results found.", result);
}

test "parseSearchResults partial JSON" {
    var buf: [4096]u8 = undefined;
    const result = parseSearchResults("{\"title\":\"incomplete", &buf);
    try std.testing.expectEqualStrings("No results found.", result);
}

test "webSearchHandler empty query error message" {
    var buf: [4096]u8 = undefined;
    const result = webSearchHandler("{\"query\":\"\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("empty query", result.error_message.?);
}

test "webSearchHandler HTTP 500 error" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 500, .body = "Internal Server Error" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());

    setHttpClient(&client);
    setBraveApiKey("test-key");
    defer clearHttpClient();
    defer clearBraveApiKey();

    var buf: [4096]u8 = undefined;
    const result = webSearchHandler("{\"query\":\"test\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_message.?, "500") != null);
}

test "webSearchHandler HTTP 401 unauthorized" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 401, .body = "{\"error\":\"unauthorized\"}" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());

    setHttpClient(&client);
    setBraveApiKey("bad-key");
    defer clearHttpClient();
    defer clearBraveApiKey();

    var buf: [4096]u8 = undefined;
    const result = webSearchHandler("{\"query\":\"test\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_message.?, "401") != null);
}

test "webSearchHandler HTTP 403 forbidden" {
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 403, .body = "Forbidden" },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());

    setHttpClient(&client);
    setBraveApiKey("test-key");
    defer clearHttpClient();
    defer clearBraveApiKey();

    var buf: [4096]u8 = undefined;
    const result = webSearchHandler("{\"query\":\"test\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_message.?, "403") != null);
}

test "BUILTIN_WEB_SEARCH description is non-empty" {
    try std.testing.expect(BUILTIN_WEB_SEARCH.description.len > 0);
}

test "BUILTIN_WEB_SEARCH not sandboxed" {
    try std.testing.expect(!BUILTIN_WEB_SEARCH.sandboxed);
}

test "BUILTIN_WEB_SEARCH not require approval" {
    try std.testing.expect(!BUILTIN_WEB_SEARCH.requires_approval);
}

test "setHttpClient and clearHttpClient" {
    clearHttpClient();
    clearBraveApiKey();
    var buf: [4096]u8 = undefined;
    const result = webSearchHandler("{\"query\":\"test\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("HTTP client not initialized", result.error_message.?);
}

test "setBraveApiKey and clearBraveApiKey" {
    setBraveApiKey("test-key-123");
    clearBraveApiKey();
    // After clearing, should report no API key
    const allocator = std.testing.allocator;
    const responses = [_]http_client.MockTransport.MockResponse{};
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());

    setHttpClient(&client);
    defer clearHttpClient();

    var buf: [4096]u8 = undefined;
    const result = webSearchHandler("{\"query\":\"test\"}", &buf);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("Brave API key not configured", result.error_message.?);
}

test "parseSearchResults output format includes newlines" {
    const json =
        \\{"web":{"results":[{"title":"Test","url":"https://t.com","description":"Desc"}]}}
    ;
    var buf: [4096]u8 = undefined;
    const result = parseSearchResults(json, &buf);
    try std.testing.expect(std.mem.indexOf(u8, result, "\n") != null);
}

test "buildSearchUrl with single char query" {
    var buf: [1024]u8 = undefined;
    const url = try buildSearchUrl(&buf, "x", 5);
    try std.testing.expect(std.mem.indexOf(u8, url, "q=x") != null);
}

test "webSearchHandler single result output" {
    const allocator = std.testing.allocator;
    const brave_json =
        \\{"web":{"results":[{"title":"Only One","url":"https://only.com","description":"Single result"}]}}
    ;
    const responses = [_]http_client.MockTransport.MockResponse{
        .{ .status = 200, .body = brave_json },
    };
    var mock = http_client.MockTransport.init(&responses);
    var client = http_client.HttpClient.init(allocator, mock.transport());

    setHttpClient(&client);
    setBraveApiKey("key");
    defer clearHttpClient();
    defer clearBraveApiKey();

    var buf: [4096]u8 = undefined;
    const result = webSearchHandler("{\"query\":\"only one\"}", &buf);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "1. Only One") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "2.") == null);
}
