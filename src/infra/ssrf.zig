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

    // Remove userinfo (must be before port removal since user:pass contains ':')
    if (std.mem.indexOf(u8, rest, "@")) |idx| {
        rest = rest[idx + 1 ..];
    }

    // Remove path
    const path_start = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
    rest = rest[0..path_start];

    // Remove port
    const port_start = std.mem.lastIndexOf(u8, rest, ":") orelse rest.len;
    rest = rest[0..port_start];

    if (rest.len == 0) return null;
    return rest;
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
