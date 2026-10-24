//! Adversarial HTTP/1.1 and resource-recovery tests (ADR-0001 §4 Phase 2b).
//!
//! Every scenario runs `server.serve` on a real loopback listener with a
//! counting allocator and caller-owned `server.Stats`. After each scenario the
//! harness waits for the admission count to reach zero and asserts that no
//! allocation made through the server or application remains live. Clients
//! read with their own socket timeout so a server hang fails the test instead
//! of stalling the suite.
//!
//! Run only this suite with `zig build test-hardening`.
const std = @import("std");
const server = @import("server.zig");
const response = @import("response.zig");
const router = @import("router.zig");

const Io = std.Io;
const net = Io.net;
const testing = std.testing;

/// Upper bound for any single client wait; a hang fails instead of blocking.
const client_timeout_ms = 3000;
/// Upper bound for the server to return to baseline after a scenario.
const idle_timeout_ms = 3000;

pub fn ms(n: i64) Io.Clock.Duration {
    return .{ .raw = .fromMilliseconds(n), .clock = .awake };
}

pub fn elapsedMs(io: Io, started: Io.Clock.Timestamp) i64 {
    return @intCast(@divFloor(started.durationFromNow(io).raw.nanoseconds, std.time.ns_per_ms) * -1);
}

pub fn elapsedUs(io: Io, started: Io.Clock.Timestamp) u64 {
    const nanos = started.durationFromNow(io).raw.nanoseconds * -1;
    return @intCast(@divFloor(nanos, std.time.ns_per_us));
}

/// Thread-safe allocation accounting over the leak-checking testing allocator.
const CountingAllocator = struct {
    child: std.mem.Allocator,
    live_allocations: std.atomic.Value(isize) = .init(0),
    live_bytes: std.atomic.Value(isize) = .init(0),
    peak_bytes: std.atomic.Value(isize) = .init(0),

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn grow(self: *CountingAllocator, delta: isize) void {
        const now = self.live_bytes.fetchAdd(delta, .acq_rel) + delta;
        _ = self.peak_bytes.fetchMax(now, .monotonic);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        _ = self.live_allocations.fetchAdd(1, .acq_rel);
        self.grow(@intCast(len));
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.grow(@as(isize, @intCast(new_len)) - @as(isize, @intCast(memory.len)));
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.grow(@as(isize, @intCast(new_len)) - @as(isize, @intCast(memory.len)));
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        _ = self.live_allocations.fetchSub(1, .acq_rel);
        self.grow(-@as(isize, @intCast(memory.len)));
    }
};

const Counters = struct {
    dispatches: std.atomic.Value(usize) = .init(0),
    blocked: std.atomic.Value(usize) = .init(0),
};

/// Application used by every scenario. Routes:
/// `GET|HEAD /` → "ok"; `POST /echo` → request body; `GET /big` → a body of
/// `big_body_len` bytes; `GET /block` → parks in dispatch until canceled.
const TestApp = struct {
    allocator: std.mem.Allocator,
    io: Io,
    counters: *Counters,
    big_body_len: usize = 0,

    pub fn dispatch(self: *const TestApp, req: *router.Request) !response.Response {
        _ = self.counters.dispatches.fetchAdd(1, .acq_rel);
        var res = response.Response.initWithLimits(self.allocator, .{
            .max_body_bytes = @max(self.big_body_len, 1024 * 1024),
        });
        errdefer res.deinit();

        if (req.isRoot() and (req.isGet() or req.method == .head)) {
            try res.text(200, "ok");
        } else if (req.isLiteral("echo") and req.method == .post) {
            try res.text(200, req.body);
        } else if (req.isLiteral("big") and req.isGet()) {
            const body = try self.allocator.alloc(u8, self.big_body_len);
            defer self.allocator.free(body);
            @memset(body, 'z');
            try res.text(200, body);
        } else if (req.isLiteral("block") and req.isGet()) {
            _ = self.counters.blocked.fetchAdd(1, .acq_rel);
            try Io.sleep(self.io, .fromSeconds(30), .awake);
            try res.text(200, "late");
        } else {
            try res.text(404, "Not Found");
        }
        return res;
    }
};

/// A running server bound to an ephemeral loopback port. Must not move after
/// `start`; the server task holds pointers into it.
pub const Harness = struct {
    io: Io,
    counting: CountingAllocator,
    listener: net.Server,
    stats: server.Stats = .{},
    counters: Counters = .{},
    app: TestApp,
    future: Io.Future(anyerror!void),
    stopped: bool,

    fn run(allocator: std.mem.Allocator, io: Io, listener: *net.Server, app: *const TestApp, config: server.Config) anyerror!void {
        return server.serve(TestApp, allocator, io, listener, app, config);
    }

    pub fn start(self: *Harness, config: server.Config, big_body_len: usize) !void {
        const io = testing.io;
        self.io = io;
        self.counting = .{ .child = testing.allocator };
        self.stats = .{};
        self.counters = .{};
        const loopback: net.IpAddress = .{ .ip4 = .loopback(0) };
        self.listener = try loopback.listen(io, .{ .reuse_address = true });
        errdefer self.listener.deinit(io);
        self.app = .{
            .allocator = self.counting.allocator(),
            .io = io,
            .counters = &self.counters,
            .big_body_len = big_body_len,
        };
        var effective = config;
        effective.stats = &self.stats;
        self.stopped = false;
        self.future = try io.concurrent(run, .{ self.counting.allocator(), io, &self.listener, &self.app, effective });
    }

    fn address(self: *const Harness) *const net.IpAddress {
        return &self.listener.socket.address;
    }

    pub fn connect(self: *const Harness) !Client {
        return Client.connect(self.io, self.address());
    }

    pub fn dispatches(self: *const Harness) usize {
        return self.counters.dispatches.load(.acquire);
    }

    /// Waits until every connection has been released, then asserts that all
    /// server and application allocations have been returned.
    pub fn expectBaseline(self: *Harness) !void {
        const started = Io.Clock.Timestamp.now(self.io, .awake);
        while (self.stats.active.load(.acquire) != 0) {
            if (elapsedMs(self.io, started) > idle_timeout_ms) return error.ConnectionsDidNotDrain;
            try Io.sleep(self.io, .fromMilliseconds(2), .awake);
        }
        try testing.expectEqual(@as(isize, 0), self.counting.live_allocations.load(.acquire));
        try testing.expectEqual(@as(isize, 0), self.counting.live_bytes.load(.acquire));
    }

    pub fn waitActive(self: *Harness, count: usize) !void {
        const started = Io.Clock.Timestamp.now(self.io, .awake);
        while (self.stats.active.load(.acquire) != count) {
            if (elapsedMs(self.io, started) > idle_timeout_ms) return error.AdmissionTimedOut;
            try Io.sleep(self.io, .fromMilliseconds(2), .awake);
        }
    }

    /// Cancels the server (stop accepting, grace, force close) and asserts a
    /// bounded shutdown that releases every connection and allocation.
    pub fn stop(self: *Harness) !void {
        const started = Io.Clock.Timestamp.now(self.io, .awake);
        self.deinit();
        try testing.expect(elapsedMs(self.io, started) < 2000);
        try testing.expectEqual(@as(usize, 0), self.stats.active.load(.acquire));
        try testing.expectEqual(@as(isize, 0), self.counting.live_allocations.load(.acquire));
    }

    /// Idempotent teardown so a failed assertion never leaves the server task
    /// running against a dead stack frame.
    pub fn deinit(self: *Harness) void {
        if (self.stopped) return;
        self.stopped = true;
        _ = self.future.cancel(self.io) catch {};
        self.listener.deinit(self.io);
    }
};

const Reply = struct {
    status: u16,
    close: bool,
    content_length: ?usize,
    body: []u8,

    pub fn deinit(self: Reply) void {
        testing.allocator.free(self.body);
    }
};

/// Minimal HTTP/1.1 client with a bounded read timeout on every syscall.
pub const Client = struct {
    io: Io,
    stream: net.Stream,
    buffer: [16 * 1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    pub fn connect(io: Io, address: *const net.IpAddress) !Client {
        const stream = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
        errdefer stream.close(io);
        const timeout = std.posix.timeval{
            .sec = @divFloor(client_timeout_ms, 1000),
            .usec = @mod(client_timeout_ms, 1000) * 1000,
        };
        try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
        return .{ .io = io, .stream = stream };
    }

    pub fn close(self: *Client) void {
        self.stream.close(self.io);
    }

    /// Closes with SO_LINGER 0 so the peer observes a TCP reset.
    fn reset(self: *Client) void {
        const linger = extern struct { onoff: c_int, linger: c_int }{ .onoff = 1, .linger = 0 };
        std.posix.setsockopt(self.stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.LINGER, std.mem.asBytes(&linger)) catch {};
        self.close();
    }

    pub fn send(self: *Client, bytes: []const u8) !void {
        var writer = self.stream.writer(self.io, &.{});
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
    }

    /// Returns 0 on orderly close or reset.
    fn fill(self: *Client) !usize {
        if (self.start == self.end) {
            self.start = 0;
            self.end = 0;
        } else if (self.end == self.buffer.len) {
            if (self.start == 0) return error.ClientBufferFull;
            std.mem.copyForwards(u8, &self.buffer, self.buffer[self.start..self.end]);
            self.end -= self.start;
            self.start = 0;
        }
        const n = std.posix.read(self.stream.socket.handle, self.buffer[self.end..]) catch |err| switch (err) {
            error.WouldBlock => return error.ClientTimeout,
            error.ConnectionResetByPeer => return 0,
            else => return err,
        };
        self.end += n;
        return n;
    }

    fn readLine(self: *Client) ![]const u8 {
        while (true) {
            if (std.mem.indexOf(u8, self.buffer[self.start..self.end], "\r\n")) |offset| {
                const line = self.buffer[self.start .. self.start + offset];
                self.start += offset + 2;
                return line;
            }
            if (try self.fill() == 0) return error.UnexpectedClose;
        }
    }

    fn readExact(self: *Client, dest: []u8) !void {
        var copied: usize = 0;
        while (copied < dest.len) {
            if (self.start == self.end and try self.fill() == 0) return error.UnexpectedClose;
            const n = @min(dest.len - copied, self.end - self.start);
            @memcpy(dest[copied..][0..n], self.buffer[self.start..][0..n]);
            self.start += n;
            copied += n;
        }
    }

    pub fn readResponse(self: *Client, head_request: bool) !Reply {
        const status_line = try self.readLine();
        const http10 = std.mem.startsWith(u8, status_line, "HTTP/1.0 ");
        if (!(http10 or std.mem.startsWith(u8, status_line, "HTTP/1.1 ")) or status_line.len < 12) return error.BadStatusLine;
        const status = try std.fmt.parseInt(u16, status_line[9..12], 10);
        // HTTP/1.0 closes unless the response opts into keep-alive.
        var closing = http10;
        var content_length: ?usize = null;
        while (true) {
            const line = try self.readLine();
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadHeader;
            const name = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                if (content_length != null) return error.DuplicateContentLength;
                content_length = try std.fmt.parseInt(usize, value, 10);
            } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                return error.UnexpectedTransferEncoding;
            } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
                closing = std.ascii.eqlIgnoreCase(value, "close");
            }
        }
        const body_len = if (head_request) 0 else content_length orelse return error.MissingContentLength;
        const body = try testing.allocator.alloc(u8, body_len);
        errdefer testing.allocator.free(body);
        try self.readExact(body);
        return .{ .status = status, .close = closing, .content_length = content_length, .body = body };
    }

    pub fn expectResponse(self: *Client, status: u16, body: []const u8) !Reply {
        const reply = try self.readResponse(false);
        errdefer reply.deinit();
        try testing.expectEqual(status, reply.status);
        try testing.expectEqualStrings(body, reply.body);
        return reply;
    }

    /// Asserts the peer closes without sending further bytes, e.g. a response
    /// to a smuggled request after a protocol rejection.
    pub fn expectClosed(self: *Client) !void {
        if (self.start != self.end) return error.UnexpectedData;
        if (try self.fill() != 0) return error.UnexpectedData;
    }
};

/// Asserts one rejection status, connection closure, and that nothing queued
/// behind the rejected request was dispatched or answered.
fn expectRejected(h: *Harness, payload: []const u8, status: u16) !void {
    const before = h.dispatches();
    var client = try h.connect();
    defer client.close();
    // A request pipelined behind the payload must never be answered.
    client.send(payload) catch {};
    client.send("GET /smuggled HTTP/1.1\r\nHost: t\r\n\r\n") catch {};
    const reply = client.readResponse(false) catch |err| {
        std.debug.print("payload {f}: {t}\n", .{ std.ascii.hexEscape(payload, .lower), err });
        return err;
    };
    defer reply.deinit();
    if (reply.status != status) {
        std.debug.print("payload {f}: expected {d}, got {d}\n", .{ std.ascii.hexEscape(payload, .lower), status, reply.status });
        return error.UnexpectedStatus;
    }
    if (!reply.close) return error.MissingConnectionClose;
    try client.expectClosed();
    if (before != h.dispatches()) {
        std.debug.print("payload {f}: reached dispatch\n", .{std.ascii.hexEscape(payload, .lower)});
        return error.UnexpectedDispatch;
    }
}

test "concurrent keep-alive clients reuse their connections safely" {
    var h: Harness = undefined;
    try h.start(.{ .shutdown_grace_period = ms(25) }, 0);
    defer h.deinit();

    const clients = 16;
    const requests = 25;
    const Task = struct {
        fn run(harness: *Harness, id: usize, result: *?anyerror) void {
            exchange(harness, id) catch |err| {
                result.* = err;
            };
        }

        fn exchange(harness: *Harness, id: usize) !void {
            var client = try harness.connect();
            defer client.close();
            var request_buffer: [256]u8 = undefined;
            var body_buffer: [32]u8 = undefined;
            for (0..requests) |index| {
                const body = try std.fmt.bufPrint(&body_buffer, "client-{d}-request-{d}", .{ id, index });
                // Alternate framings so each connection crosses both body
                // readers before being reused.
                const wire = if (index % 2 == 0)
                    try std.fmt.bufPrint(&request_buffer, "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body })
                else
                    try std.fmt.bufPrint(&request_buffer, "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n{x}\r\n{s}\r\n0\r\n\r\n", .{ body.len, body });
                try client.send(wire);
                const reply = try client.expectResponse(200, body);
                defer reply.deinit();
                if (reply.close) return error.UnexpectedClose;
            }
        }
    };

    var results: [clients]?anyerror = @splat(null);
    var group: Io.Group = .init;
    for (&results, 0..) |*result, id| try group.concurrent(h.io, Task.run, .{ &h, id, result });
    try group.await(h.io);
    for (results) |result| if (result) |err| return err;

    try testing.expectEqual(@as(usize, clients * requests), h.dispatches());
    // One admission per client proves every request reused its connection.
    try testing.expectEqual(@as(usize, clients), h.stats.admitted.load(.acquire));
    try testing.expect(h.stats.peak.load(.acquire) <= clients);
    try h.expectBaseline();
    try h.stop();
}

test "pipelined requests keep their boundaries and the request cap closes" {
    var h: Harness = undefined;
    try h.start(.{ .shutdown_grace_period = ms(25), .max_requests_per_connection = 4 }, 0);
    defer h.deinit();

    var client = try h.connect();
    defer client.close();
    try client.send("POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 3\r\n\r\none" ++
        "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n3\r\ntwo\r\n0\r\nX-Trailer: yes\r\n\r\n" ++
        "HEAD / HTTP/1.1\r\nHost: t\r\n\r\n" ++
        "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 4\r\n\r\nfour" ++
        "GET / HTTP/1.1\r\nHost: t\r\n\r\n");
    const one = try client.expectResponse(200, "one");
    defer one.deinit();
    try testing.expect(!one.close);
    const two = try client.expectResponse(200, "two");
    defer two.deinit();
    const head = try client.readResponse(true);
    defer head.deinit();
    try testing.expectEqual(@as(u16, 200), head.status);
    try testing.expectEqual(@as(?usize, 2), head.content_length);
    const four = try client.expectResponse(200, "four");
    defer four.deinit();
    // The fourth request exhausts `max_requests_per_connection`; the fifth is
    // never read or answered.
    try testing.expect(four.close);
    try client.expectClosed();
    try testing.expectEqual(@as(usize, 4), h.dispatches());

    try h.expectBaseline();
    try h.stop();
}

test "malformed and ambiguous framing is rejected, closed, and never dispatched" {
    var h: Harness = undefined;
    try h.start(.{ .shutdown_grace_period = ms(25) }, 0);
    defer h.deinit();

    const bad_request = [_][]const u8{
        // Content-Length and Transfer-Encoding together, in both orders.
        "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
        "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n0\r\n\r\n",
        // Conflicting, list-valued, signed, non-numeric, and overflowing lengths.
        "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab",
        "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 1, 2\r\n\r\nab",
        "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: -1\r\n\r\n",
        "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: +1\r\n\r\na",
        "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: abc\r\n\r\n",
        "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 99999999999999999999999\r\n\r\n",
        // Unsupported or obfuscated transfer codings.
        "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n",
        "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: xchunked\r\n\r\n0\r\n\r\n",
        "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked, identity\r\n\r\n0\r\n\r\n",
        "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
        "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding : chunked\r\n\r\n0\r\n\r\n",
        // Malformed chunk framing.
        "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nab\r\n0\r\n\r\n",
        "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabcX\r\n0\r\n\r\n",
        "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\nfffffffffffffffffffff\r\na\r\n0\r\n\r\n",
        "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n-1\r\na\r\n0\r\n\r\n",
        "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n0\r\nContent-Length: 9\r\n\r\n",
        // Leniencies of the pinned std ChunkParser: non-hex "digits", an
        // empty size, bare LF, and bytes that are not a `;` extension.
        "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\ng\r\n0123456789abcdef\r\n0\r\n\r\n",
        "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n\r\nGET /smuggled HTTP/1.1\r\n\r\n",
        "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n3\nabc\r\n0\r\n\r\n",
        "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n3 x\r\nabc\r\n0\r\n\r\n",
        "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r",
        // Transfer-Encoding is not defined for HTTP/1.0 requests.
        "POST /echo HTTP/1.0\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n",
        // Malformed header lines.
        "GET / HTTP/1.1\r\nHost: t\r\nX-Folded: a\r\n b\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: t\r\nNoColon\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: t\r\nX-Nul: a\x00b\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: t\r\nX Space: a\r\n\r\n",
        // Malformed request lines and non-origin targets.
        "GET  / HTTP/1.1\r\nHost: t\r\n\r\n",
        "GET /\r\nHost: t\r\n\r\n",
        "G@T / HTTP/1.1\r\nHost: t\r\n\r\n",
        "GET http://t/ HTTP/1.1\r\nHost: t\r\n\r\n",
        "GET /a%zz HTTP/1.1\r\nHost: t\r\n\r\n",
        // Unsupported expectations are rejected before any body is read.
        "POST /echo HTTP/1.1\r\nHost: t\r\nExpect: 100-continue\r\nContent-Length: 1\r\n\r\na",
    };
    // Report every accepted payload, not just the first.
    var failures: usize = 0;
    for (bad_request) |payload| expectRejected(&h, payload, 400) catch {
        failures += 1;
    };
    try testing.expectEqual(@as(usize, 0), failures);
    try h.expectBaseline();
    try h.stop();
}

test "limits reject oversized heads and bodies with bounded memory" {
    var h: Harness = undefined;
    try h.start(.{
        .shutdown_grace_period = ms(25),
        .request_limits = .{ .max_body_bytes = 1024, .target_bytes = 256, .max_headers = 8, .header_bytes = 512 },
    }, 0);
    defer h.deinit();

    // Declared Content-Length above the limit is refused before reading.
    try expectRejected(&h, "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 1025\r\n\r\n", 413);

    // Many small chunks whose decoded total crosses the limit.
    {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(testing.allocator);
        try payload.appendSlice(testing.allocator, "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n");
        for (0..64) |_| try payload.appendSlice(testing.allocator, "20\r\n" ++ "c" ** 32 ++ "\r\n");
        try payload.appendSlice(testing.allocator, "0\r\n\r\n");
        try expectRejected(&h, payload.items, 413);
    }

    // One chunk announcing far more than the limit; the server must answer
    // once the limit is crossed, not wait for the announced size.
    {
        var client = try h.connect();
        defer client.close();
        try client.send("POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n40000000\r\n");
        try client.send("c" ** 2048);
        const reply = try client.readResponse(false);
        defer reply.deinit();
        try testing.expectEqual(@as(u16, 413), reply.status);
        try client.expectClosed();
    }

    // Head limits: target, header count, header bytes, and wire head size.
    try expectRejected(&h, "GET /" ++ "a" ** 300 ++ " HTTP/1.1\r\nHost: t\r\n\r\n", 414);
    try expectRejected(&h, "GET / HTTP/1.1\r\nA: 1\r\nB: 1\r\nC: 1\r\nD: 1\r\nE: 1\r\nF: 1\r\nG: 1\r\nH: 1\r\nI: 1\r\n\r\n", 431);
    try expectRejected(&h, "GET / HTTP/1.1\r\nX-Big: " ++ "v" ** 600 ++ "\r\n\r\n", 431);
    try expectRejected(&h, "GET / HTTP/1.1\r\nX-Big: " ++ "v" ** 4096 ++ "\r\n\r\n", 431);

    try testing.expectEqual(@as(usize, 0), h.dispatches());
    try h.expectBaseline();
    // Nothing near the announced 1 GiB chunk or the 2 KiB oversized payload
    // is ever buffered: request storage stays within its configured limits.
    try testing.expect(h.counting.peak_bytes.load(.acquire) < 16 * 1024);
    try h.stop();
}

test "slow trickles cannot extend total header, body, or idle budgets" {
    var h: Harness = undefined;
    const budget_ms = 250;
    try h.start(.{
        .shutdown_grace_period = ms(25),
        .header_timeout = ms(budget_ms),
        .body_read_timeout = ms(budget_ms),
        .keep_alive_idle_timeout = ms(budget_ms),
    }, 0);
    defer h.deinit();

    const Trickle = struct {
        /// Sends one byte every 20 ms (well inside any per-read timeout) and
        /// returns how long the server tolerated it.
        fn run(harness: *Harness, client: *Client, prefix: []const u8) !i64 {
            try client.send(prefix);
            // A loopback connect completes before `accept`; only an admitted
            // connection has a budget to measure.
            try harness.waitActive(1);
            const started = Io.Clock.Timestamp.now(harness.io, .awake);
            while (elapsedMs(harness.io, started) < client_timeout_ms) {
                client.send("a") catch break;
                if (harness.stats.active.load(.acquire) == 0) break;
                try Io.sleep(harness.io, .fromMilliseconds(20), .awake);
            }
            const elapsed = elapsedMs(harness.io, started);
            try harness.expectBaseline();
            return elapsed;
        }
    };

    inline for (.{
        // Header trickle: an unterminated header value.
        "GET / HTTP/1.1\r\nHost: t\r\nX-Slow: ",
        // Body trickle: a declared length that is never completed in time.
        "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 100000\r\n\r\n",
        // Chunked body trickle inside one large chunk.
        "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n100000\r\n",
    }) |prefix| {
        var client = try h.connect();
        defer client.close();
        const tolerated = try Trickle.run(&h, &client, prefix);
        try testing.expect(tolerated >= budget_ms - 50);
        try testing.expect(tolerated < budget_ms + 1000);
    }

    // An idle keep-alive connection is closed after its idle budget.
    {
        var client = try h.connect();
        defer client.close();
        try client.send("GET / HTTP/1.1\r\nHost: t\r\n\r\n");
        const reply = try client.expectResponse(200, "ok");
        defer reply.deinit();
        const started = Io.Clock.Timestamp.now(h.io, .awake);
        try client.expectClosed();
        const idle = elapsedMs(h.io, started);
        try testing.expect(idle >= budget_ms - 50);
        try testing.expect(idle < budget_ms + 1000);
    }

    try testing.expectEqual(@as(usize, 1), h.dispatches());
    try h.expectBaseline();
    try h.stop();
}

test "a reader that never drains cannot hold a connection past the write budget" {
    var h: Harness = undefined;
    // Larger than loopback send plus receive buffers, so the write must block.
    try h.start(.{ .shutdown_grace_period = ms(25), .write_timeout = ms(250) }, 32 * 1024 * 1024);
    defer h.deinit();

    var stalled = try h.connect();
    defer stalled.close();
    try stalled.send("GET /big HTTP/1.1\r\nHost: t\r\n\r\n");
    try h.waitActive(1);

    // The accept loop and other clients proceed while the write is blocked.
    {
        var healthy = try h.connect();
        defer healthy.close();
        try healthy.send("GET / HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
        const reply = try healthy.expectResponse(200, "ok");
        defer reply.deinit();
        try healthy.expectClosed();
    }

    const started = Io.Clock.Timestamp.now(h.io, .awake);
    try h.waitActive(0);
    try testing.expect(elapsedMs(h.io, started) < 1500);
    try h.expectBaseline();
    try h.stop();
}

test "abrupt disconnects release resources and the server keeps serving" {
    var h: Harness = undefined;
    try h.start(.{ .shutdown_grace_period = ms(25) }, 1024 * 1024);
    defer h.deinit();

    const scenarios = [_][]const u8{
        "",
        "GET / HT",
        "GET / HTTP/1.1\r\nHost: t\r\n",
        "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 10\r\n\r\nabc",
        "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nab",
        // Complete requests whose responses are written after the peer left.
        "GET / HTTP/1.1\r\nHost: t\r\n\r\n",
        "GET /big HTTP/1.1\r\nHost: t\r\n\r\n",
    };
    for (scenarios) |payload| {
        inline for (.{ false, true }) |use_reset| {
            var client = try h.connect();
            if (payload.len != 0) try client.send(payload);
            try h.waitActive(1);
            if (use_reset) client.reset() else client.close();
            try h.expectBaseline();
        }
    }

    // Server still serves normally after every disconnect shape.
    var client = try h.connect();
    defer client.close();
    try client.send("GET / HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    const reply = try client.expectResponse(200, "ok");
    defer reply.deinit();
    try client.expectClosed();
    try h.expectBaseline();
    try h.stop();
}

test "admission stays bounded above the default connection cap" {
    var h: Harness = undefined;
    const config: server.Config = .{ .shutdown_grace_period = ms(25) };
    const cap = config.max_connections;
    const excess = 32;
    try h.start(config, 0);
    defer h.deinit();

    const held = try testing.allocator.alloc(Client, cap);
    defer testing.allocator.free(held);
    var opened: usize = 0;
    defer for (held[0..opened]) |*client| client.close();
    while (opened < cap) : (opened += 1) {
        held[opened] = try h.connect();
        try held[opened].send("GET / HTTP/1.1\r\n");
    }
    try h.waitActive(cap);

    // Overflow sockets are accepted and closed at once without a response.
    for (0..excess) |_| {
        var client = try h.connect();
        defer client.close();
        try client.expectClosed();
    }
    try testing.expectEqual(@as(usize, excess), h.stats.rejected.load(.acquire));
    try testing.expectEqual(cap, h.stats.peak.load(.acquire));
    try testing.expectEqual(cap, h.stats.active.load(.acquire));

    // Admitted connections still complete, then capacity is reusable.
    for (held[0..opened]) |*client| {
        try client.send("Host: t\r\nConnection: close\r\n\r\n");
        const reply = try client.expectResponse(200, "ok");
        reply.deinit();
    }
    try h.expectBaseline();
    var client = try h.connect();
    defer client.close();
    try client.send("GET / HTTP/1.1\r\nHost: t\r\n\r\n");
    const reply = try client.expectResponse(200, "ok");
    defer reply.deinit();
    try testing.expect(h.stats.peak.load(.acquire) <= cap);
    try h.stop();
}

test "shutdown during active requests closes every connection within grace" {
    var h: Harness = undefined;
    try h.start(.{ .shutdown_grace_period = ms(50) }, 0);
    defer h.deinit();

    // One client of each lifecycle state when shutdown begins.
    var in_dispatch = try h.connect();
    defer in_dispatch.close();
    try in_dispatch.send("GET /block HTTP/1.1\r\nHost: t\r\n\r\n");

    var mid_body = try h.connect();
    defer mid_body.close();
    try mid_body.send("POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 100\r\n\r\npartial");

    var mid_head = try h.connect();
    defer mid_head.close();
    try mid_head.send("GET / HTTP/1.1\r\nHost:");

    var idle = try h.connect();
    defer idle.close();
    try idle.send("GET / HTTP/1.1\r\nHost: t\r\n\r\n");
    const reply = try idle.expectResponse(200, "ok");
    reply.deinit();

    try h.waitActive(4);
    const started = Io.Clock.Timestamp.now(h.io, .awake);
    while (h.counters.blocked.load(.acquire) == 0) {
        if (elapsedMs(h.io, started) > idle_timeout_ms) return error.DispatchNotReached;
        try Io.sleep(h.io, .fromMilliseconds(2), .awake);
    }
    try h.stop();

    // Every client observes closure; a canceled dispatch may still report a
    // generic 500 before closing but never its late success body.
    for ([_]*Client{ &mid_body, &mid_head, &idle }) |client| try client.expectClosed();
    if (in_dispatch.readResponse(false)) |late| {
        defer late.deinit();
        try testing.expectEqual(@as(u16, 500), late.status);
        try in_dispatch.expectClosed();
    } else |err| switch (err) {
        error.UnexpectedClose => {},
        else => return err,
    }
}
