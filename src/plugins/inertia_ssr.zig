//! Inertia server-side rendering client, used by `zoda.Inertia` when its
//! `ssr` setting is present.
//!
//! One render is one `POST` of the page JSON to an SSR server such as
//! `@inertiajs/*/server` (default `http://127.0.0.1:13714/render`), which
//! answers 200 with `{"head": [string], "body": string}`. The connection is
//! opened, written, and read under one absolute monotonic deadline, so a
//! render never holds the request longer than `timeout_ms`; the response is
//! read to the end, at most `max_response_bytes`, and parsed strictly.
//!
//! The pinned std panics on `IpAddress.connect` with a timeout, and handlers
//! have no `std.Io`, so the client uses Linux syscalls directly: a
//! non-blocking socket and `poll` against `CLOCK_MONOTONIC`. Like
//! `zoda.static`, it fails closed on other targets with
//! `error.SsrUnsupported`, and the plugin falls back to client rendering.
//! The address is a literal: no name lookup happens in the request path.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const IpAddress = std.Io.net.IpAddress;

pub const supported = builtin.os.tag == .linux;
pub const default_port = 13714;
/// Longest `timeout_ms`.
pub const max_timeout_ms = 60_000;
/// Most bytes in `path`.
pub const max_path_bytes = 256;

/// Where and how long to render. Every field has a default; `.{}` targets
/// the default Inertia SSR server.
pub const Config = struct {
    /// The SSR server's literal IP address and port.
    address: IpAddress = .{ .ip4 = .loopback(default_port) },
    /// Request path: `/` then printable ASCII without spaces.
    path: []const u8 = "/render",
    /// Total budget for connecting, sending the page, and reading the
    /// answer: 1 to `max_timeout_ms`.
    timeout_ms: u32 = 1000,
    /// Most bytes of the SSR server's response, head included.
    max_response_bytes: usize = 1 << 20,

    pub fn validate(self: Config) error{InvalidSsr}!void {
        if (self.timeout_ms == 0 or self.timeout_ms > max_timeout_ms) return error.InvalidSsr;
        if (self.max_response_bytes == 0) return error.InvalidSsr;
        if (self.path.len == 0 or self.path.len > max_path_bytes or self.path[0] != '/') return error.InvalidSsr;
        for (self.path) |c| {
            if (c <= ' ' or c >= 0x7f) return error.InvalidSsr;
        }
    }
};

/// Why a render produced no page. The plugin reports it and falls back.
pub const Failure = error{
    /// Not Linux.
    SsrUnsupported,
    /// The socket could not be created or the connection was refused.
    SsrConnectFailed,
    /// `timeout_ms` passed before the answer was complete.
    SsrTimeout,
    /// Sending or receiving failed after connecting.
    SsrIoFailed,
    /// The answer exceeded `max_response_bytes`.
    SsrResponseTooLarge,
    /// The answer's status was not 200.
    SsrBadStatus,
    /// The answer was not HTTP/1.x with a `{head, body}` JSON body.
    SsrMalformedResponse,
    /// The rendered document exceeded the response body limit.
    SsrPageTooLarge,
};

/// A rendered page, owned by the allocator passed to `render`.
pub const Page = struct {
    /// The `head` elements, joined with newlines.
    head: []u8,
    /// The root element markup, inserted as is.
    body: []u8,

    pub fn deinit(self: Page, allocator: std.mem.Allocator) void {
        allocator.free(self.head);
        allocator.free(self.body);
    }
};

/// Renders the page JSON `page` through the SSR server. Allocation failures
/// are `error.OutOfMemory`; everything else is a `Failure`.
pub fn render(allocator: std.mem.Allocator, config: Config, page: []const u8) (Failure || error{OutOfMemory})!Page {
    if (comptime !supported) return error.SsrUnsupported;
    const raw = try exchange(allocator, config, page);
    defer allocator.free(raw);
    return parse(allocator, raw);
}

fn exchange(allocator: std.mem.Allocator, config: Config, page: []const u8) (Failure || error{OutOfMemory})![]u8 {
    const deadline = now() + @as(i128, config.timeout_ms) * std.time.ns_per_ms;
    var head: std.Io.Writer.Allocating = .init(allocator);
    defer head.deinit();
    head.writer.print(
        "POST {s} HTTP/1.1\r\nHost: {f}\r\nContent-Type: application/json\r\nAccept: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ config.path, config.address, page.len },
    ) catch return error.OutOfMemory;

    const fd = try connect(config.address, deadline);
    defer _ = linux.close(fd);
    try sendAll(fd, head.written(), deadline);
    try sendAll(fd, page, deadline);

    // `Connection: close`: the answer ends when the server closes.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        const n = try receive(fd, &buffer, deadline);
        if (n == 0) break;
        if (n > config.max_response_bytes - out.items.len) return error.SsrResponseTooLarge;
        try out.appendSlice(allocator, buffer[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

fn now() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn connect(address: IpAddress, deadline: i128) Failure!i32 {
    var in4: linux.sockaddr.in = undefined;
    var in6: linux.sockaddr.in6 = undefined;
    const family: u32, const addr: *const anyopaque, const len: linux.socklen_t = switch (address) {
        .ip4 => |a| blk: {
            in4 = .{ .port = std.mem.nativeToBig(u16, a.port), .addr = @bitCast(a.bytes) };
            break :blk .{ linux.AF.INET, &in4, @sizeOf(linux.sockaddr.in) };
        },
        .ip6 => |a| blk: {
            in6 = .{ .port = std.mem.nativeToBig(u16, a.port), .flowinfo = a.flow, .addr = a.bytes, .scope_id = a.interface.index };
            break :blk .{ linux.AF.INET6, &in6, @sizeOf(linux.sockaddr.in6) };
        },
    };
    const rc = linux.socket(family, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SsrConnectFailed;
    const fd: i32 = @intCast(rc);
    errdefer _ = linux.close(fd);
    switch (linux.errno(linux.connect(fd, addr, len))) {
        .SUCCESS => return fd,
        // An interrupted non-blocking connect keeps going, like one in progress.
        .INPROGRESS, .INTR => {},
        else => return error.SsrConnectFailed,
    }
    try wait(fd, linux.POLL.OUT, deadline);
    var err: i32 = 0;
    var err_len: linux.socklen_t = @sizeOf(i32);
    const got = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&err), &err_len);
    if (linux.errno(got) != .SUCCESS or err != 0) return error.SsrConnectFailed;
    return fd;
}

/// Waits until `fd` is ready for `events` or the deadline passes.
fn wait(fd: i32, events: i16, deadline: i128) Failure!void {
    while (true) {
        const remaining = deadline - now();
        if (remaining <= 0) return error.SsrTimeout;
        const ms: i32 = @intCast(@min(std.math.divCeil(i128, remaining, std.time.ns_per_ms) catch unreachable, max_timeout_ms));
        var fds = [1]linux.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        const rc = linux.poll(&fds, 1, ms);
        switch (linux.errno(rc)) {
            // Ready, or an error the next syscall reports; 0 rechecks the deadline.
            .SUCCESS => if (rc != 0) return,
            .INTR => {},
            else => return error.SsrIoFailed,
        }
    }
}

fn sendAll(fd: i32, bytes: []const u8, deadline: i128) Failure!void {
    var rest = bytes;
    while (rest.len != 0) {
        if (now() >= deadline) return error.SsrTimeout;
        const rc = linux.sendto(fd, rest.ptr, rest.len, linux.MSG.NOSIGNAL, null, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => rest = rest[rc..],
            .AGAIN => try wait(fd, linux.POLL.OUT, deadline),
            .INTR => {},
            else => return error.SsrIoFailed,
        }
    }
}

fn receive(fd: i32, buffer: []u8, deadline: i128) Failure!usize {
    while (true) {
        if (now() >= deadline) return error.SsrTimeout;
        const rc = linux.read(fd, buffer.ptr, buffer.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .AGAIN => try wait(fd, linux.POLL.IN, deadline),
            .INTR => {},
            else => return error.SsrIoFailed,
        }
    }
}

/// Parses a complete HTTP/1.x answer: status 200, a body framed by
/// `Content-Length`, `Transfer-Encoding: chunked`, or the connection close,
/// and `{"head": [string], "body": string}` with a non-empty `body`.
/// `head` may be missing; other fields are ignored.
fn parse(allocator: std.mem.Allocator, raw: []const u8) (Failure || error{OutOfMemory})!Page {
    const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.SsrMalformedResponse;
    var lines = std.mem.splitSequence(u8, raw[0..head_end], "\r\n");
    const status_line = lines.first();
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 ") and !std.mem.startsWith(u8, status_line, "HTTP/1.0 ")) return error.SsrMalformedResponse;
    if (status_line.len < 12 or (status_line.len > 12 and status_line[12] != ' ')) return error.SsrMalformedResponse;
    for (status_line[9..12]) |c| {
        if (!std.ascii.isDigit(c)) return error.SsrMalformedResponse;
    }
    if (!std.mem.eql(u8, status_line[9..12], "200")) return error.SsrBadStatus;

    var content_length: ?usize = null;
    var chunked = false;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.SsrMalformedResponse;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (name.len == 0 or std.mem.indexOfAny(u8, name, " \t") != null) return error.SsrMalformedResponse;
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            if (content_length != null or value.len == 0) return error.SsrMalformedResponse;
            for (value) |c| {
                if (!std.ascii.isDigit(c)) return error.SsrMalformedResponse;
            }
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.SsrMalformedResponse;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (chunked or !std.ascii.eqlIgnoreCase(value, "chunked")) return error.SsrMalformedResponse;
            chunked = true;
        }
    }
    if (chunked and content_length != null) return error.SsrMalformedResponse;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const rest = raw[head_end + 4 ..];
    const body = if (chunked)
        try dechunk(arena.allocator(), rest)
    else if (content_length) |n| blk: {
        if (rest.len != n) return error.SsrMalformedResponse;
        break :blk rest;
    } else rest;

    const Answer = struct { head: []const []const u8 = &.{}, body: []const u8 };
    const answer = std.json.parseFromSliceLeaky(Answer, arena.allocator(), body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SsrMalformedResponse,
    };
    if (answer.body.len == 0) return error.SsrMalformedResponse;
    const head = try std.mem.join(allocator, "\n", answer.head);
    errdefer allocator.free(head);
    return .{ .head = head, .body = try allocator.dupe(u8, answer.body) };
}

/// Decodes a complete chunked body: hex sizes with optional extensions,
/// CRLF after each chunk, then optional trailers and the final CRLF.
fn dechunk(arena: std.mem.Allocator, data: []const u8) (Failure || error{OutOfMemory})![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = data;
    while (true) {
        const line_end = std.mem.indexOf(u8, rest, "\r\n") orelse return error.SsrMalformedResponse;
        const line = rest[0..line_end];
        const size_text = line[0 .. std.mem.indexOfScalar(u8, line, ';') orelse line.len];
        if (size_text.len == 0 or size_text.len > 16) return error.SsrMalformedResponse;
        for (size_text) |c| {
            if (!std.ascii.isHex(c)) return error.SsrMalformedResponse;
        }
        const size = std.fmt.parseInt(usize, size_text, 16) catch return error.SsrMalformedResponse;
        rest = rest[line_end + 2 ..];
        if (size == 0) break;
        if (rest.len < size or rest.len - size < 2 or !std.mem.eql(u8, rest[size..][0..2], "\r\n")) return error.SsrMalformedResponse;
        try out.appendSlice(arena, rest[0..size]);
        rest = rest[size + 2 ..];
    }
    while (true) {
        const line_end = std.mem.indexOf(u8, rest, "\r\n") orelse return error.SsrMalformedResponse;
        if (line_end == 0) {
            if (rest.len != 2) return error.SsrMalformedResponse;
            return out.items;
        }
        rest = rest[line_end + 2 ..];
    }
}

/// A one-connection SSR server for tests: it accepts once, reads the
/// request, waits `delay_ms`, writes `reply`, and closes.
pub const TestServer = struct {
    listener: i32,
    port: u16,
    reply: []const u8,
    delay_ms: i32,
    thread: std.Thread = undefined,
    request: [8192]u8 = undefined,
    request_len: usize = 0,

    pub fn start(self: *TestServer, reply: []const u8, delay_ms: i32) !void {
        const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return error.Unexpected;
        const fd: i32 = @intCast(rc);
        errdefer _ = linux.close(fd);
        var addr: linux.sockaddr.in = .{ .port = 0, .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
        var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        if (linux.errno(linux.bind(fd, @ptrCast(&addr), len)) != .SUCCESS) return error.Unexpected;
        if (linux.errno(linux.listen(fd, 1)) != .SUCCESS) return error.Unexpected;
        if (linux.errno(linux.getsockname(fd, @ptrCast(&addr), &len)) != .SUCCESS) return error.Unexpected;
        self.* = .{ .listener = fd, .port = std.mem.bigToNative(u16, addr.port), .reply = reply, .delay_ms = delay_ms };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    pub fn config(self: *const TestServer) Config {
        return .{ .address = .{ .ip4 = .loopback(self.port) } };
    }

    /// Waits for the connection to finish and returns the request received.
    pub fn finish(self: *TestServer) []const u8 {
        self.thread.join();
        _ = linux.close(self.listener);
        return self.request[0..self.request_len];
    }

    fn serve(self: *TestServer) void {
        const rc = linux.accept4(self.listener, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return;
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        while (self.request_len < self.request.len and !requestComplete(self.request[0..self.request_len])) {
            const n = linux.read(fd, self.request[self.request_len..].ptr, self.request.len - self.request_len);
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            self.request_len += n;
        }
        if (self.delay_ms > 0) _ = linux.poll(undefined, 0, self.delay_ms);
        var rest = self.reply;
        while (rest.len != 0) {
            const n = linux.sendto(fd, rest.ptr, rest.len, linux.MSG.NOSIGNAL, null, 0);
            if (linux.errno(n) != .SUCCESS) return;
            rest = rest[n..];
        }
    }

    fn requestComplete(bytes: []const u8) bool {
        const end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return false;
        const marker = "Content-Length: ";
        const at = std.mem.indexOf(u8, bytes[0..end], marker) orelse return true;
        const digits = bytes[at + marker.len ..];
        const length = std.fmt.parseInt(usize, digits[0 .. std.mem.indexOfScalar(u8, digits, '\r') orelse return false], 10) catch return true;
        return bytes.len - end - 4 >= length;
    }
};

const testing = std.testing;
const ok_json = "{\"head\":[\"<title>Hi</title>\",\"<meta name=\\\"x\\\">\"],\"body\":\"<div id=\\\"app\\\">Hi</div>\"}";

fn okReply(comptime body: []const u8) []const u8 {
    return std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

test "render posts the page and returns the joined head and body" {
    if (!supported) return error.SkipZigTest;
    var server: TestServer = undefined;
    try server.start(okReply(ok_json), 0);
    const page = try render(testing.allocator, server.config(), "{\"component\":\"Home\"}");
    defer page.deinit(testing.allocator);
    const request = server.finish();
    try testing.expectEqualStrings("<title>Hi</title>\n<meta name=\"x\">", page.head);
    try testing.expectEqualStrings("<div id=\"app\">Hi</div>", page.body);
    try testing.expect(std.mem.startsWith(u8, request, "POST /render HTTP/1.1\r\nHost: 127.0.0.1:"));
    try testing.expect(std.mem.indexOf(u8, request, "\r\nContent-Type: application/json\r\nAccept: application/json\r\nContent-Length: 20\r\nConnection: close\r\n\r\n{\"component\":\"Home\"}") != null);
}

test "render reads chunked and close-delimited answers" {
    if (!supported) return error.SkipZigTest;
    const replies = [_][]const u8{
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10;x=y\r\n{\"body\":\"<p>a</p\r\n3\r\n>\"}\r\n0\r\nX-Trailer: 1\r\n\r\n",
        "HTTP/1.0 200 OK\r\n\r\n{\"body\":\"<p>a</p>\",\"extra\":1}",
    };
    for (replies) |reply| {
        var server: TestServer = undefined;
        try server.start(reply, 0);
        const page = try render(testing.allocator, server.config(), "{}");
        defer page.deinit(testing.allocator);
        _ = server.finish();
        try testing.expectEqualStrings("", page.head);
        try testing.expectEqualStrings("<p>a</p>", page.body);
    }
}

test "a slow SSR server times out within the budget" {
    if (!supported) return error.SkipZigTest;
    var server: TestServer = undefined;
    try server.start(okReply(ok_json), 500);
    var config = server.config();
    config.timeout_ms = 50;
    const started = now();
    try testing.expectError(error.SsrTimeout, render(testing.allocator, config, "{}"));
    const elapsed_ms = @divFloor(now() - started, std.time.ns_per_ms);
    _ = server.finish();
    try testing.expect(elapsed_ms >= 50 and elapsed_ms < 400);
}

test "refused connections, oversized and malformed answers are failures" {
    if (!supported) return error.SkipZigTest;
    // A bound socket that never listens refuses connections.
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    try testing.expect(linux.errno(rc) == .SUCCESS);
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var addr: linux.sockaddr.in = .{ .port = 0, .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    try testing.expect(linux.errno(linux.bind(fd, @ptrCast(&addr), len)) == .SUCCESS);
    try testing.expect(linux.errno(linux.getsockname(fd, @ptrCast(&addr), &len)) == .SUCCESS);
    const port = std.mem.bigToNative(u16, addr.port);
    try testing.expectError(error.SsrConnectFailed, render(testing.allocator, .{ .address = .{ .ip4 = .loopback(port) } }, "{}"));

    var big: TestServer = undefined;
    try big.start(okReply(ok_json), 0);
    var limited = big.config();
    limited.max_response_bytes = 32;
    try testing.expectError(error.SsrResponseTooLarge, render(testing.allocator, limited, "{}"));
    _ = big.finish();

    const cases = .{
        .{ "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 2\r\n\r\n{}", error.SsrBadStatus },
        .{ "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n", error.SsrMalformedResponse },
        .{ "HTTP/2 200\r\n\r\n{\"body\":\"x\"}", error.SsrMalformedResponse },
        .{ "HTTP/1.1 2x0 OK\r\n\r\n{\"body\":\"x\"}", error.SsrMalformedResponse },
        .{ "HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\n{\"body\":\"x\"}", error.SsrMalformedResponse },
        .{ "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx", error.SsrMalformedResponse },
        .{ "HTTP/1.1 200 OK\r\nContent-Length: +12\r\n\r\n{\"body\":\"x\"}", error.SsrMalformedResponse },
        .{ "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n{\"body\":\"x\"}", error.SsrMalformedResponse },
        .{ "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n0\r\n\r\n", error.SsrMalformedResponse },
        .{ "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n{}\r\n0\r\n\r\n", error.SsrMalformedResponse },
        .{ "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}", error.SsrMalformedResponse },
        .{ "HTTP/1.1 200 OK\r\n\r\nnot json", error.SsrMalformedResponse },
        .{ "HTTP/1.1 200 OK\r\n\r\n{\"head\":[]}", error.SsrMalformedResponse },
        .{ "HTTP/1.1 200 OK\r\n\r\n{\"head\":[1],\"body\":\"x\"}", error.SsrMalformedResponse },
        .{ "HTTP/1.1 200 OK\r\n\r\n{\"body\":\"\"}", error.SsrMalformedResponse },
    };
    inline for (cases) |case| {
        var server: TestServer = undefined;
        try server.start(case[0], 0);
        try testing.expectError(case[1], render(testing.allocator, server.config(), "{}"));
        _ = server.finish();
    }
}

test "SSR settings are validated" {
    try (Config{}).validate();
    const bad = [_]Config{
        .{ .timeout_ms = 0 },
        .{ .timeout_ms = max_timeout_ms + 1 },
        .{ .max_response_bytes = 0 },
        .{ .path = "" },
        .{ .path = "render" },
        .{ .path = "/a b" },
        .{ .path = "/a\r\nX: y" },
        .{ .path = "/" ++ "a" ** max_path_bytes },
    };
    for (bad) |config| try testing.expectError(error.InvalidSsr, config.validate());
}
