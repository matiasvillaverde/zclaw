const std = @import("std");

// --- Content Types ---

pub const ContentType = enum {
    html,
    css,
    javascript,
    json,
    wasm,
    png,
    svg,
    ico,
    plain,

    pub fn mimeType(self: ContentType) []const u8 {
        return switch (self) {
            .html => "text/html; charset=utf-8",
            .css => "text/css; charset=utf-8",
            .javascript => "application/javascript; charset=utf-8",
            .json => "application/json",
            .wasm => "application/wasm",
            .png => "image/png",
            .svg => "image/svg+xml",
            .ico => "image/x-icon",
            .plain => "text/plain",
        };
    }

    pub fn fromExtension(ext: []const u8) ContentType {
        const map = std.StaticStringMap(ContentType).initComptime(.{
            .{ ".html", .html },
            .{ ".css", .css },
            .{ ".js", .javascript },
            .{ ".json", .json },
            .{ ".wasm", .wasm },
            .{ ".png", .png },
            .{ ".svg", .svg },
            .{ ".ico", .ico },
        });
        return map.get(ext) orelse .plain;
    }
};

// --- Static File Entry ---

pub const StaticFile = struct {
    path: []const u8,
    content: []const u8,
    content_type: ContentType,
};

// --- Embedded Files ---

pub const INDEX_HTML =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="UTF-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\<title>zclaw</title>
    \\<link rel="stylesheet" href="/static/style.css">
    \\</head>
    \\<body>
    \\<div id="app">
    \\  <nav id="sidebar"></nav>
    \\  <main id="content">
    \\    <div id="loading">Connecting to gateway...</div>
    \\  </main>
    \\</div>
    \\<script src="/static/app.js"></script>
    \\</body>
    \\</html>
;

pub const STYLE_CSS =
    \\:root {
    \\  --bg: #1a1b26;
    \\  --bg-secondary: #24283b;
    \\  --text: #c0caf5;
    \\  --text-muted: #565f89;
    \\  --accent: #7aa2f7;
    \\  --success: #9ece6a;
    \\  --warning: #e0af68;
    \\  --error: #f7768e;
    \\  --border: #3b4261;
    \\  --sidebar-width: 220px;
    \\}
    \\* { margin: 0; padding: 0; box-sizing: border-box; }
    \\body {
    \\  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    \\  background: var(--bg);
    \\  color: var(--text);
    \\  height: 100vh;
    \\  overflow: hidden;
    \\}
    \\#app {
    \\  display: flex;
    \\  height: 100vh;
    \\}
    \\#sidebar {
    \\  width: var(--sidebar-width);
    \\  background: var(--bg-secondary);
    \\  border-right: 1px solid var(--border);
    \\  padding: 16px 0;
    \\  display: flex;
    \\  flex-direction: column;
    \\}
    \\.nav-item {
    \\  padding: 10px 20px;
    \\  cursor: pointer;
    \\  color: var(--text-muted);
    \\  transition: all 0.15s;
    \\}
    \\.nav-item:hover { color: var(--text); background: rgba(255,255,255,0.05); }
    \\.nav-item.active { color: var(--accent); background: rgba(122,162,247,0.1); }
    \\#content {
    \\  flex: 1;
    \\  padding: 24px;
    \\  overflow-y: auto;
    \\}
    \\.card {
    \\  background: var(--bg-secondary);
    \\  border: 1px solid var(--border);
    \\  border-radius: 8px;
    \\  padding: 20px;
    \\  margin-bottom: 16px;
    \\}
    \\.stat { font-size: 2em; font-weight: bold; color: var(--accent); }
    \\.stat-label { font-size: 0.85em; color: var(--text-muted); }
    \\.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; }
    \\.status-dot {
    \\  display: inline-block;
    \\  width: 8px; height: 8px;
    \\  border-radius: 50%;
    \\  margin-right: 6px;
    \\}
    \\.status-dot.connected { background: var(--success); }
    \\.status-dot.disconnected { background: var(--error); }
    \\.status-dot.connecting { background: var(--warning); }
    \\h1 { font-size: 1.5em; margin-bottom: 16px; }
    \\h2 { font-size: 1.2em; margin-bottom: 12px; color: var(--text-muted); }
    \\#chat-container {
    \\  display: flex;
    \\  flex-direction: column;
    \\  height: calc(100vh - 48px);
    \\}
    \\#chat-messages {
    \\  flex: 1;
    \\  overflow-y: auto;
    \\  padding: 16px 0;
    \\}
    \\.message { padding: 8px 0; }
    \\.message .role { font-weight: bold; color: var(--accent); }
    \\.message .content { margin-top: 4px; white-space: pre-wrap; }
    \\#chat-input {
    \\  display: flex;
    \\  gap: 8px;
    \\  padding-top: 12px;
    \\  border-top: 1px solid var(--border);
    \\}
    \\#chat-input input {
    \\  flex: 1;
    \\  padding: 10px 14px;
    \\  background: var(--bg-secondary);
    \\  border: 1px solid var(--border);
    \\  border-radius: 6px;
    \\  color: var(--text);
    \\  font-size: 14px;
    \\}
    \\#chat-input button {
    \\  padding: 10px 20px;
    \\  background: var(--accent);
    \\  color: var(--bg);
    \\  border: none;
    \\  border-radius: 6px;
    \\  cursor: pointer;
    \\  font-weight: bold;
    \\}
;

pub const APP_JS =
    \\// zclaw UI client
    \\const state = {
    \\  view: 'dashboard',
    \\  connected: false,
    \\  ws: null,
    \\  messages: [],
    \\  reqId: 0,
    \\  pending: {}
    \\};
    \\
    \\const views = ['dashboard','chat','channels','agents','sessions','memory','config','logs'];
    \\
    \\function connect() {
    \\  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    \\  state.ws = new WebSocket(`${proto}//${location.host}/ws`);
    \\  state.ws.onopen = () => { state.connected = true; render(); };
    \\  state.ws.onclose = () => { state.connected = false; render(); setTimeout(connect, 2000); };
    \\  state.ws.onmessage = (e) => handleMessage(JSON.parse(e.data));
    \\}
    \\
    \\function send(method, params) {
    \\  const id = `ui-${++state.reqId}`;
    \\  state.ws.send(JSON.stringify({type:'req',id,method,params}));
    \\  return new Promise((resolve) => { state.pending[id] = resolve; });
    \\}
    \\
    \\function handleMessage(msg) {
    \\  if (msg.type === 'res' && state.pending[msg.id]) {
    \\    state.pending[msg.id](msg);
    \\    delete state.pending[msg.id];
    \\  }
    \\  if (msg.type === 'event' && msg.event === 'agent.stream') {
    \\    if (msg.payload && msg.payload.delta) {
    \\      const last = state.messages[state.messages.length - 1];
    \\      if (last && last.role === 'assistant' && last.streaming) {
    \\        last.content += msg.payload.delta;
    \\      } else {
    \\        state.messages.push({role:'assistant',content:msg.payload.delta,streaming:true});
    \\      }
    \\      render();
    \\    }
    \\  }
    \\}
    \\
    \\function navigate(view) {
    \\  state.view = view;
    \\  history.pushState(null, '', view === 'dashboard' ? '/' : '/' + view);
    \\  render();
    \\}
    \\
    \\function render() {
    \\  const sidebar = document.getElementById('sidebar');
    \\  sidebar.innerHTML = '<div style="padding:16px 20px;font-weight:bold;color:var(--accent)">zclaw</div>' +
    \\    views.map(v =>
    \\      `<div class="nav-item ${v===state.view?'active':''}" onclick="navigate('${v}')">${v}</div>`
    \\    ).join('');
    \\
    \\  const content = document.getElementById('content');
    \\  switch(state.view) {
    \\    case 'dashboard': content.innerHTML = renderDashboard(); break;
    \\    case 'chat': content.innerHTML = renderChat(); break;
    \\    default: content.innerHTML = `<h1>${state.view}</h1><p>Coming soon</p>`;
    \\  }
    \\}
    \\
    \\function renderDashboard() {
    \\  const dot = state.connected ? 'connected' : 'disconnected';
    \\  return `<h1>Dashboard</h1>
    \\    <div class="grid">
    \\      <div class="card"><div class="stat-label">Gateway</div>
    \\        <div><span class="status-dot ${dot}"></span>${state.connected?'Connected':'Disconnected'}</div></div>
    \\      <div class="card"><div class="stat-label">Channels</div><div class="stat">0</div></div>
    \\      <div class="card"><div class="stat-label">Sessions</div><div class="stat">0</div></div>
    \\      <div class="card"><div class="stat-label">Agents</div><div class="stat">0</div></div>
    \\    </div>`;
    \\}
    \\
    \\function renderChat() {
    \\  const msgs = state.messages.map(m =>
    \\    `<div class="message"><span class="role">${m.role}</span><div class="content">${escapeHtml(m.content)}</div></div>`
    \\  ).join('');
    \\  return `<div id="chat-container">
    \\    <h1>Chat</h1>
    \\    <div id="chat-messages">${msgs || '<p style="color:var(--text-muted)">Send a message to start chatting.</p>'}</div>
    \\    <div id="chat-input">
    \\      <input type="text" id="msg-input" placeholder="Type a message..." onkeydown="if(event.key==='Enter')sendChat()">
    \\      <button onclick="sendChat()">Send</button>
    \\    </div>
    \\  </div>`;
    \\}
    \\
    \\function escapeHtml(s) {
    \\  return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    \\}
    \\
    \\function sendChat() {
    \\  const input = document.getElementById('msg-input');
    \\  if (!input || !input.value.trim()) return;
    \\  state.messages.push({role:'user',content:input.value});
    \\  send('agent', {message:input.value, agent:'default'});
    \\  input.value = '';
    \\  render();
    \\}
    \\
    \\// Init
    \\window.onpopstate = () => {
    \\  const path = location.pathname.replace('/','') || 'dashboard';
    \\  state.view = views.includes(path) ? path : 'dashboard';
    \\  render();
    \\};
    \\connect();
    \\render();
;

// --- File Registry ---

pub const STATIC_FILES = [_]StaticFile{
    .{ .path = "/", .content = INDEX_HTML, .content_type = .html },
    .{ .path = "/index.html", .content = INDEX_HTML, .content_type = .html },
    .{ .path = "/static/style.css", .content = STYLE_CSS, .content_type = .css },
    .{ .path = "/static/app.js", .content = APP_JS, .content_type = .javascript },
};

pub fn findFile(request_path: []const u8) ?StaticFile {
    for (STATIC_FILES) |file| {
        if (std.mem.eql(u8, file.path, request_path)) {
            return file;
        }
    }
    return null;
}

/// Get the extension from a path.
pub fn getExtension(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '.') return path[i..];
        if (path[i] == '/') break;
    }
    return "";
}

/// Build an HTTP response header for a static file.
pub fn buildResponseHeader(buf: []u8, status: u16, content_type: ContentType, content_length: usize) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("HTTP/1.1 ");
    try std.fmt.format(w, "{d}", .{status});
    try w.writeAll(switch (status) {
        200 => " OK",
        304 => " Not Modified",
        404 => " Not Found",
        else => " Unknown",
    });
    try w.writeAll("\r\nContent-Type: ");
    try w.writeAll(content_type.mimeType());
    try w.writeAll("\r\nContent-Length: ");
    try std.fmt.format(w, "{d}", .{content_length});
    try w.writeAll("\r\nCache-Control: no-cache\r\n\r\n");
    return fbs.getWritten();
}

// --- Tests ---

test "ContentType mimeType" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", ContentType.html.mimeType());
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", ContentType.javascript.mimeType());
    try std.testing.expectEqualStrings("text/css; charset=utf-8", ContentType.css.mimeType());
    try std.testing.expectEqualStrings("application/wasm", ContentType.wasm.mimeType());
}

test "ContentType fromExtension" {
    try std.testing.expectEqual(ContentType.html, ContentType.fromExtension(".html"));
    try std.testing.expectEqual(ContentType.javascript, ContentType.fromExtension(".js"));
    try std.testing.expectEqual(ContentType.css, ContentType.fromExtension(".css"));
    try std.testing.expectEqual(ContentType.wasm, ContentType.fromExtension(".wasm"));
    try std.testing.expectEqual(ContentType.plain, ContentType.fromExtension(".txt"));
}

test "findFile index" {
    const file = findFile("/").?;
    try std.testing.expectEqualStrings("/", file.path);
    try std.testing.expectEqual(ContentType.html, file.content_type);
    try std.testing.expect(file.content.len > 0);
}

test "findFile style.css" {
    const file = findFile("/static/style.css").?;
    try std.testing.expectEqual(ContentType.css, file.content_type);
    try std.testing.expect(std.mem.indexOf(u8, file.content, "--bg:") != null);
}

test "findFile app.js" {
    const file = findFile("/static/app.js").?;
    try std.testing.expectEqual(ContentType.javascript, file.content_type);
    try std.testing.expect(std.mem.indexOf(u8, file.content, "connect()") != null);
}

test "findFile missing" {
    try std.testing.expect(findFile("/missing") == null);
}

test "getExtension" {
    try std.testing.expectEqualStrings(".html", getExtension("/index.html"));
    try std.testing.expectEqualStrings(".js", getExtension("/static/app.js"));
    try std.testing.expectEqualStrings(".css", getExtension("/static/style.css"));
    try std.testing.expectEqualStrings("", getExtension("/no-extension"));
    try std.testing.expectEqualStrings("", getExtension("/"));
}

test "buildResponseHeader 200" {
    var buf: [512]u8 = undefined;
    const header = try buildResponseHeader(&buf, 200, .html, 1234);
    try std.testing.expect(std.mem.indexOf(u8, header, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "text/html") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "1234") != null);
}

test "buildResponseHeader 404" {
    var buf: [512]u8 = undefined;
    const header = try buildResponseHeader(&buf, 404, .plain, 0);
    try std.testing.expect(std.mem.indexOf(u8, header, "404 Not Found") != null);
}

test "STATIC_FILES count" {
    try std.testing.expectEqual(@as(usize, 4), STATIC_FILES.len);
}

test "INDEX_HTML contains essentials" {
    try std.testing.expect(std.mem.indexOf(u8, INDEX_HTML, "<!DOCTYPE html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, INDEX_HTML, "<title>zclaw</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, INDEX_HTML, "style.css") != null);
    try std.testing.expect(std.mem.indexOf(u8, INDEX_HTML, "app.js") != null);
}

test "STYLE_CSS contains essentials" {
    try std.testing.expect(std.mem.indexOf(u8, STYLE_CSS, "--bg:") != null);
    try std.testing.expect(std.mem.indexOf(u8, STYLE_CSS, "#sidebar") != null);
    try std.testing.expect(std.mem.indexOf(u8, STYLE_CSS, ".nav-item") != null);
}

test "APP_JS contains essentials" {
    try std.testing.expect(std.mem.indexOf(u8, APP_JS, "WebSocket") != null);
    try std.testing.expect(std.mem.indexOf(u8, APP_JS, "navigate") != null);
    try std.testing.expect(std.mem.indexOf(u8, APP_JS, "render()") != null);
    try std.testing.expect(std.mem.indexOf(u8, APP_JS, "sendChat") != null);
}

test "buildResponseHeader 304" {
    var buf: [512]u8 = undefined;
    const header = try buildResponseHeader(&buf, 304, .html, 0);
    try std.testing.expect(std.mem.indexOf(u8, header, "304 Not Modified") != null);
}
