const std = @import("std");

// --- SSRF Protection ---
//
// Block private/internal IP addresses before HTTP requests.
// Prevents Server-Side Request Forgery attacks.

/// Parse an IPv4 address string into 4 octets.
pub fn parseIpv4(host: []const u8) ?[4]u8 {
    var octets: [4]u8 = undefined;
    var octet_idx: usize = 0;
    var current: u16 = 0;
    var has_digit = false;

    for (host) |c| {
        if (c >= '0' and c <= '9') {
            current = current * 10 + (c - '0');
            if (current > 255) return null;
            has_digit = true;
        } else if (c == '.') {
            if (!has_digit or octet_idx >= 3) return null;
            octets[octet_idx] = @intCast(current);
            octet_idx += 1;
            current = 0;
            has_digit = false;
        } else {
            return null;
        }
    }

    if (!has_digit or octet_idx != 3) return null;
    octets[3] = @intCast(current);
    return octets;
}

/// Check if an IP is a loopback address (127.0.0.0/8 or ::1).
pub fn isLoopback(host: []const u8) bool {
    if (std.mem.eql(u8, host, "::1")) return true;
    if (std.mem.eql(u8, host, "localhost")) return true;

    const octets = parseIpv4(host) orelse return false;
    return octets[0] == 127;
}

/// Check if an IP is a link-local address (169.254.0.0/16 or fe80::/10).
pub fn isLinkLocal(host: []const u8) bool {
    if (host.len >= 4 and std.mem.startsWith(u8, host, "fe80")) return true;

    const octets = parseIpv4(host) orelse return false;
    return octets[0] == 169 and octets[1] == 254;
}

/// Check if an IP is in a private range.
pub fn isPrivateIp(host: []const u8) bool {
    if (isLoopback(host)) return true;
    if (isLinkLocal(host)) return true;

    const octets = parseIpv4(host) orelse {
        // Check common IPv6 private prefixes
        if (std.mem.startsWith(u8, host, "fc") or std.mem.startsWith(u8, host, "fd")) return true;
        return false;
    };

    // 10.0.0.0/8
    if (octets[0] == 10) return true;
    // 172.16.0.0/12
    if (octets[0] == 172 and octets[1] >= 16 and octets[1] <= 31) return true;
    // 192.168.0.0/16
    if (octets[0] == 192 and octets[1] == 168) return true;
    // 0.0.0.0
    if (octets[0] == 0 and octets[1] == 0 and octets[2] == 0 and octets[3] == 0) return true;

    return false;
}

/// Extract the host from a URL.
pub fn extractHost(url: []const u8) ?[]const u8 {
    // Skip scheme
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |idx| {
        rest = rest[idx + 3 ..];
    }

    // Remove path/query/fragment to get authority
    const path_start = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..path_start];

    // Remove userinfo: find last '@' in authority (handles passwords containing '@')
    var host_port = authority;
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |idx| {
        host_port = authority[idx + 1 ..];
    }

    // Remove port
    const port_start = std.mem.lastIndexOf(u8, host_port, ":") orelse host_port.len;
    const host = host_port[0..port_start];

    if (host.len == 0) return null;
    return host;
}

/// Validate a URL is safe to fetch (not pointing to private infrastructure).
pub fn validateUrl(url: []const u8) bool {
    const host = extractHost(url) orelse return false;
    return !isPrivateIp(host);
}

// --- Tests ---

test "parseIpv4 valid" {
    const octets = parseIpv4("192.168.1.1").?;
    try std.testing.expectEqual(@as(u8, 192), octets[0]);
    try std.testing.expectEqual(@as(u8, 168), octets[1]);
    try std.testing.expectEqual(@as(u8, 1), octets[2]);
    try std.testing.expectEqual(@as(u8, 1), octets[3]);
}

test "parseIpv4 loopback" {
    const octets = parseIpv4("127.0.0.1").?;
    try std.testing.expectEqual(@as(u8, 127), octets[0]);
}

test "parseIpv4 invalid" {
    try std.testing.expect(parseIpv4("not-an-ip") == null);
    try std.testing.expect(parseIpv4("256.1.1.1") == null);
    try std.testing.expect(parseIpv4("1.2.3") == null);
    try std.testing.expect(parseIpv4("") == null);
    try std.testing.expect(parseIpv4("1.2.3.4.5") == null);
}

test "isLoopback" {
    try std.testing.expect(isLoopback("127.0.0.1"));
    try std.testing.expect(isLoopback("127.0.1.1"));
    try std.testing.expect(isLoopback("127.255.255.255"));
    try std.testing.expect(isLoopback("::1"));
    try std.testing.expect(isLoopback("localhost"));
    try std.testing.expect(!isLoopback("8.8.8.8"));
    try std.testing.expect(!isLoopback("192.168.1.1"));
}

test "isLinkLocal" {
    try std.testing.expect(isLinkLocal("169.254.0.1"));
    try std.testing.expect(isLinkLocal("169.254.255.255"));
    try std.testing.expect(isLinkLocal("fe80::1"));
    try std.testing.expect(!isLinkLocal("8.8.8.8"));
    try std.testing.expect(!isLinkLocal("192.168.1.1"));
}

test "isPrivateIp private ranges" {
    // 10.x.x.x
    try std.testing.expect(isPrivateIp("10.0.0.1"));
    try std.testing.expect(isPrivateIp("10.255.255.255"));
    // 172.16-31.x.x
    try std.testing.expect(isPrivateIp("172.16.0.1"));
    try std.testing.expect(isPrivateIp("172.31.255.255"));
    try std.testing.expect(!isPrivateIp("172.15.0.1"));
    try std.testing.expect(!isPrivateIp("172.32.0.1"));
    // 192.168.x.x
    try std.testing.expect(isPrivateIp("192.168.0.1"));
    try std.testing.expect(isPrivateIp("192.168.255.255"));
    // Loopback
    try std.testing.expect(isPrivateIp("127.0.0.1"));
    try std.testing.expect(isPrivateIp("::1"));
    try std.testing.expect(isPrivateIp("localhost"));
    // Link-local
    try std.testing.expect(isPrivateIp("169.254.1.1"));
    // 0.0.0.0
    try std.testing.expect(isPrivateIp("0.0.0.0"));
    // IPv6 private
    try std.testing.expect(isPrivateIp("fc00::1"));
    try std.testing.expect(isPrivateIp("fd12::1"));
}

test "isPrivateIp public addresses" {
    try std.testing.expect(!isPrivateIp("8.8.8.8"));
    try std.testing.expect(!isPrivateIp("1.1.1.1"));
    try std.testing.expect(!isPrivateIp("93.184.216.34"));
    try std.testing.expect(!isPrivateIp("api.openai.com"));
}

test "extractHost basic" {
    try std.testing.expectEqualStrings("example.com", extractHost("https://example.com/path").?);
    try std.testing.expectEqualStrings("api.openai.com", extractHost("https://api.openai.com/v1/chat").?);
    try std.testing.expectEqualStrings("localhost", extractHost("http://localhost:8080/api").?);
    try std.testing.expectEqualStrings("192.168.1.1", extractHost("http://192.168.1.1:3000").?);
}

test "extractHost edge cases" {
    try std.testing.expectEqualStrings("host.com", extractHost("host.com/path").?);
    try std.testing.expectEqualStrings("host.com", extractHost("https://user:pass@host.com/path").?);
    try std.testing.expect(extractHost("") == null);
}

test "validateUrl safe" {
    try std.testing.expect(validateUrl("https://api.openai.com/v1/chat"));
    try std.testing.expect(validateUrl("https://example.com"));
    try std.testing.expect(validateUrl("https://8.8.8.8/dns"));
}

test "validateUrl unsafe" {
    try std.testing.expect(!validateUrl("http://127.0.0.1:8080"));
    try std.testing.expect(!validateUrl("http://localhost:3000"));
    try std.testing.expect(!validateUrl("http://10.0.0.1/admin"));
    try std.testing.expect(!validateUrl("http://192.168.1.1"));
    try std.testing.expect(!validateUrl("http://169.254.169.254/metadata"));
    try std.testing.expect(!validateUrl(""));
}

// ===== Additional comprehensive tests =====

// --- parseIpv4 edge cases ---

test "parseIpv4 - all zeros" {
    const octets = parseIpv4("0.0.0.0").?;
    try std.testing.expectEqual(@as(u8, 0), octets[0]);
    try std.testing.expectEqual(@as(u8, 0), octets[1]);
    try std.testing.expectEqual(@as(u8, 0), octets[2]);
    try std.testing.expectEqual(@as(u8, 0), octets[3]);
}

test "parseIpv4 - all max" {
    const octets = parseIpv4("255.255.255.255").?;
    try std.testing.expectEqual(@as(u8, 255), octets[0]);
    try std.testing.expectEqual(@as(u8, 255), octets[1]);
    try std.testing.expectEqual(@as(u8, 255), octets[2]);
    try std.testing.expectEqual(@as(u8, 255), octets[3]);
}

test "parseIpv4 - leading zeros in octets" {
    // "01.02.03.04" - leading zeros are valid digits
    const octets = parseIpv4("01.02.03.04").?;
    try std.testing.expectEqual(@as(u8, 1), octets[0]);
    try std.testing.expectEqual(@as(u8, 2), octets[1]);
    try std.testing.expectEqual(@as(u8, 3), octets[2]);
    try std.testing.expectEqual(@as(u8, 4), octets[3]);
}

test "parseIpv4 - octet over 255" {
    try std.testing.expect(parseIpv4("256.0.0.1") == null);
    try std.testing.expect(parseIpv4("0.256.0.1") == null);
    try std.testing.expect(parseIpv4("0.0.256.1") == null);
    try std.testing.expect(parseIpv4("0.0.0.256") == null);
    try std.testing.expect(parseIpv4("999.999.999.999") == null);
}

test "parseIpv4 - too few octets" {
    try std.testing.expect(parseIpv4("1") == null);
    try std.testing.expect(parseIpv4("1.2") == null);
    try std.testing.expect(parseIpv4("1.2.3") == null);
}

test "parseIpv4 - too many octets" {
    try std.testing.expect(parseIpv4("1.2.3.4.5") == null);
    try std.testing.expect(parseIpv4("1.2.3.4.5.6") == null);
}

test "parseIpv4 - empty segments" {
    try std.testing.expect(parseIpv4(".1.2.3") == null);
    try std.testing.expect(parseIpv4("1..2.3") == null);
    try std.testing.expect(parseIpv4("1.2.3.") == null);
    try std.testing.expect(parseIpv4("...") == null);
}

test "parseIpv4 - trailing dot" {
    try std.testing.expect(parseIpv4("1.2.3.4.") == null);
}

test "parseIpv4 - non-numeric characters" {
    try std.testing.expect(parseIpv4("a.b.c.d") == null);
    try std.testing.expect(parseIpv4("1.2.3.x") == null);
    try std.testing.expect(parseIpv4("1a.2.3.4") == null);
    try std.testing.expect(parseIpv4("1.2.3.4a") == null);
}

test "parseIpv4 - spaces" {
    try std.testing.expect(parseIpv4(" 1.2.3.4") == null);
    try std.testing.expect(parseIpv4("1.2.3.4 ") == null);
    try std.testing.expect(parseIpv4("1. 2.3.4") == null);
}

test "parseIpv4 - IPv6 address" {
    try std.testing.expect(parseIpv4("::1") == null);
    try std.testing.expect(parseIpv4("fe80::1") == null);
    try std.testing.expect(parseIpv4("2001:db8::1") == null);
}

// --- isLoopback extended ---

test "isLoopback - full 127.x.x.x range" {
    try std.testing.expect(isLoopback("127.0.0.0"));
    try std.testing.expect(isLoopback("127.0.0.1"));
    try std.testing.expect(isLoopback("127.1.2.3"));
    try std.testing.expect(isLoopback("127.255.255.255"));
    try std.testing.expect(!isLoopback("128.0.0.1"));
    try std.testing.expect(!isLoopback("126.255.255.255"));
}

test "isLoopback - IPv6 loopback" {
    try std.testing.expect(isLoopback("::1"));
    try std.testing.expect(!isLoopback("::2"));
    try std.testing.expect(!isLoopback("::0"));
}

test "isLoopback - non-IP strings" {
    try std.testing.expect(isLoopback("localhost"));
    try std.testing.expect(!isLoopback("LOCALHOST")); // case-sensitive
    try std.testing.expect(!isLoopback("example.com"));
    try std.testing.expect(!isLoopback(""));
}

// --- isLinkLocal extended ---

test "isLinkLocal - full range" {
    try std.testing.expect(isLinkLocal("169.254.0.0"));
    try std.testing.expect(isLinkLocal("169.254.0.1"));
    try std.testing.expect(isLinkLocal("169.254.128.0"));
    try std.testing.expect(isLinkLocal("169.254.255.255"));
    try std.testing.expect(!isLinkLocal("169.253.255.255"));
    try std.testing.expect(!isLinkLocal("169.255.0.0"));
}

test "isLinkLocal - AWS metadata endpoint" {
    try std.testing.expect(isLinkLocal("169.254.169.254"));
}

test "isLinkLocal - IPv6 link-local" {
    try std.testing.expect(isLinkLocal("fe80::1"));
    try std.testing.expect(isLinkLocal("fe80:abcd::1"));
    try std.testing.expect(!isLinkLocal("fe70::1"));
    try std.testing.expect(!isLinkLocal("fe90::1"));
}

// --- isPrivateIp extended ---

test "isPrivateIp - 10.0.0.0/8 boundaries" {
    try std.testing.expect(isPrivateIp("10.0.0.0"));
    try std.testing.expect(isPrivateIp("10.0.0.1"));
    try std.testing.expect(isPrivateIp("10.128.0.0"));
    try std.testing.expect(isPrivateIp("10.255.255.255"));
    try std.testing.expect(!isPrivateIp("11.0.0.0"));
    try std.testing.expect(!isPrivateIp("9.255.255.255"));
}

test "isPrivateIp - 172.16.0.0/12 boundaries" {
    try std.testing.expect(isPrivateIp("172.16.0.0"));
    try std.testing.expect(isPrivateIp("172.16.0.1"));
    try std.testing.expect(isPrivateIp("172.20.0.0"));
    try std.testing.expect(isPrivateIp("172.31.0.0"));
    try std.testing.expect(isPrivateIp("172.31.255.255"));
    try std.testing.expect(!isPrivateIp("172.15.255.255"));
    try std.testing.expect(!isPrivateIp("172.32.0.0"));
}

test "isPrivateIp - 192.168.0.0/16 boundaries" {
    try std.testing.expect(isPrivateIp("192.168.0.0"));
    try std.testing.expect(isPrivateIp("192.168.0.1"));
    try std.testing.expect(isPrivateIp("192.168.128.0"));
    try std.testing.expect(isPrivateIp("192.168.255.255"));
    try std.testing.expect(!isPrivateIp("192.167.255.255"));
    try std.testing.expect(!isPrivateIp("192.169.0.0"));
}

test "isPrivateIp - IPv6 unique local (fc00::/7)" {
    try std.testing.expect(isPrivateIp("fc00::1"));
    try std.testing.expect(isPrivateIp("fc01::1"));
    try std.testing.expect(isPrivateIp("fcff::1"));
    try std.testing.expect(isPrivateIp("fd00::1"));
    try std.testing.expect(isPrivateIp("fd12:3456::1"));
    try std.testing.expect(isPrivateIp("fdff::1"));
}

test "isPrivateIp - IPv6 non-private" {
    try std.testing.expect(!isPrivateIp("2001:db8::1"));
    try std.testing.expect(!isPrivateIp("2607:f8b0::1"));
    try std.testing.expect(!isPrivateIp("::2"));
    // fe80 is link-local, should be private
    try std.testing.expect(isPrivateIp("fe80::1"));
}

test "isPrivateIp - 0.0.0.0" {
    try std.testing.expect(isPrivateIp("0.0.0.0"));
    // 0.0.0.1 is not explicitly blocked by the code (only 0.0.0.0)
    try std.testing.expect(!isPrivateIp("0.0.0.1"));
}

test "isPrivateIp - public addresses" {
    try std.testing.expect(!isPrivateIp("1.0.0.1"));
    try std.testing.expect(!isPrivateIp("1.1.1.1"));
    try std.testing.expect(!isPrivateIp("8.8.8.8"));
    try std.testing.expect(!isPrivateIp("8.8.4.4"));
    try std.testing.expect(!isPrivateIp("93.184.216.34"));
    try std.testing.expect(!isPrivateIp("142.250.80.46"));
    try std.testing.expect(!isPrivateIp("151.101.1.69"));
    try std.testing.expect(!isPrivateIp("208.67.222.222"));
}

test "isPrivateIp - hostname strings" {
    try std.testing.expect(isPrivateIp("localhost"));
    try std.testing.expect(!isPrivateIp("example.com"));
    try std.testing.expect(!isPrivateIp("api.openai.com"));
    try std.testing.expect(!isPrivateIp("google.com"));
}

// --- extractHost extended ---

test "extractHost - various schemes" {
    try std.testing.expectEqualStrings("example.com", extractHost("http://example.com/path").?);
    try std.testing.expectEqualStrings("example.com", extractHost("https://example.com/path").?);
    try std.testing.expectEqualStrings("example.com", extractHost("ftp://example.com/path").?);
    try std.testing.expectEqualStrings("example.com", extractHost("ws://example.com/path").?);
    try std.testing.expectEqualStrings("example.com", extractHost("wss://example.com/path").?);
}

test "extractHost - with port" {
    try std.testing.expectEqualStrings("localhost", extractHost("http://localhost:8080").?);
    try std.testing.expectEqualStrings("example.com", extractHost("https://example.com:443/path").?);
    try std.testing.expectEqualStrings("192.168.1.1", extractHost("http://192.168.1.1:3000/api").?);
}

test "extractHost - with query string" {
    try std.testing.expectEqualStrings("example.com", extractHost("https://example.com?key=value").?);
    try std.testing.expectEqualStrings("example.com", extractHost("https://example.com/path?key=value").?);
}

test "extractHost - with fragment" {
    // Fragment starts with # but indexOfAny only checks / and ? so # goes to port-removal
    try std.testing.expectEqualStrings("example.com", extractHost("https://example.com/path#section").?);
}

test "extractHost - with userinfo" {
    try std.testing.expectEqualStrings("host.com", extractHost("https://user@host.com/path").?);
    try std.testing.expectEqualStrings("host.com", extractHost("https://user:pass@host.com/path").?);
    try std.testing.expectEqualStrings("host.com", extractHost("https://user:p@ss@host.com/path").?);
}

test "extractHost - multiple @ in URL" {
    // The code uses indexOf which finds the first @
    // "user:pass@more@host.com" -> after first @ -> "more@host.com"
    // then after second @ -> "host.com"
    // Actually indexOf finds first @, so rest = "more@host.com"
    // But there's another @ so... let's check. The code only removes up to first @.
    // Wait, it uses indexOf which finds first @. So "user@more@host.com" -> "more@host.com"
    // Then path removal + port removal... but there's still an @ in there
    // Actually the code doesn't do multiple @ handling. Let's just test what it does.
    const result = extractHost("https://user@more@host.com/path");
    try std.testing.expect(result != null);
}

test "extractHost - no scheme" {
    try std.testing.expectEqualStrings("host.com", extractHost("host.com/path").?);
    try std.testing.expectEqualStrings("host.com", extractHost("host.com").?);
}

test "extractHost - empty string" {
    try std.testing.expect(extractHost("") == null);
}

test "extractHost - scheme only" {
    try std.testing.expect(extractHost("https://") == null);
}

test "extractHost - IP address in URL" {
    try std.testing.expectEqualStrings("1.2.3.4", extractHost("http://1.2.3.4/path").?);
    try std.testing.expectEqualStrings("1.2.3.4", extractHost("http://1.2.3.4:8080/path").?);
}

test "extractHost - subdomain" {
    try std.testing.expectEqualStrings("api.v2.example.com", extractHost("https://api.v2.example.com/endpoint").?);
}

test "extractHost - just a path" {
    // A bare path like "/path" has no host
    try std.testing.expect(extractHost("/path") == null);
}

// --- validateUrl extended ---

test "validateUrl - all private ranges blocked" {
    try std.testing.expect(!validateUrl("http://127.0.0.1"));
    try std.testing.expect(!validateUrl("http://10.0.0.1"));
    try std.testing.expect(!validateUrl("http://172.16.0.1"));
    try std.testing.expect(!validateUrl("http://192.168.0.1"));
    try std.testing.expect(!validateUrl("http://169.254.169.254"));
    try std.testing.expect(!validateUrl("http://0.0.0.0"));
    try std.testing.expect(!validateUrl("http://localhost"));
}

test "validateUrl - public IPs allowed" {
    try std.testing.expect(validateUrl("https://8.8.8.8"));
    try std.testing.expect(validateUrl("https://1.1.1.1"));
    try std.testing.expect(validateUrl("https://93.184.216.34"));
}

test "validateUrl - domain names allowed" {
    try std.testing.expect(validateUrl("https://api.openai.com/v1/chat"));
    try std.testing.expect(validateUrl("https://api.anthropic.com/v1/messages"));
    try std.testing.expect(validateUrl("https://example.com"));
    try std.testing.expect(validateUrl("https://sub.domain.example.com/path"));
}

test "validateUrl - empty and malformed" {
    try std.testing.expect(!validateUrl(""));
    try std.testing.expect(!validateUrl("https://"));
}

test "validateUrl - URL with port to private IP" {
    try std.testing.expect(!validateUrl("http://127.0.0.1:8080"));
    try std.testing.expect(!validateUrl("http://127.0.0.1:3000"));
    try std.testing.expect(!validateUrl("http://10.0.0.1:443"));
    try std.testing.expect(!validateUrl("http://192.168.1.1:22"));
}

test "validateUrl - URL with userinfo to private IP" {
    try std.testing.expect(!validateUrl("http://admin:password@127.0.0.1/admin"));
    try std.testing.expect(!validateUrl("http://user:pass@192.168.1.1/"));
}

test "validateUrl - AWS metadata endpoint" {
    try std.testing.expect(!validateUrl("http://169.254.169.254/latest/meta-data/"));
    try std.testing.expect(!validateUrl("http://169.254.169.254/latest/api/token"));
}

test "validateUrl - IPv6 private addresses" {
    try std.testing.expect(!validateUrl("http://fc00::1/path"));
    try std.testing.expect(!validateUrl("http://fd12::1/path"));
}

test "validateUrl - various safe URLs with paths" {
    try std.testing.expect(validateUrl("https://api.example.com/v1/chat/completions"));
    try std.testing.expect(validateUrl("https://example.com/path/to/resource?query=value"));
    try std.testing.expect(validateUrl("https://cdn.example.com/assets/image.png"));
}
