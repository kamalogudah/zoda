//! Bounded concurrent socket runtime (ADR-0001 §4 Phase 2).
//!
//! Zig 0.16.0's `std.Io.Group.concurrent` supplies connection tasks and
//! cancellation, while the pinned POSIX socket timeout options enforce the
//! remaining absolute monotonic deadline before each syscall. The allocator passed to `serve` is used by
//! concurrent tasks and therefore must be thread-safe (`std.heap.smp_allocator`
//! is the recommended process-wide choice). Every connection has independent
//! I/O buffers, and `transport.serveConnection` creates a fresh request arena
//! for each sequential request.
const std = @import("std");
const transport = @import("transport.zig");

const Io = std.Io;
const net = Io.net;
const app_framework = @import("app.zig");
const response_types = @import("response.zig");
const router_types = @import("router.zig");
const Json = @import("plugins/json.zig").Json;

const SocketUser = struct { id: []const u8, name: []const u8 };
const SocketPlugins = struct { json: Json = .{} };
const SocketApp = app_framework.App(SocketPlugins);

fn socketRoute(ctx: *SocketApp.Context, req: *router_types.Request, res: *response_types.Response) !void {
    if (req.isRoot() and (req.isGet() or req.method == .head)) {
        return res.text(200, "hello from zoda");
    }
    if (req.onLiteral("users")) {
        if (req.onSegment()) |id| {
            if (req.isRoot() and (req.isGet() or req.method == .head)) {
                return ctx.plugins.json.render(res, SocketUser, .{ .id = id, .name = "unknown" });
            }
        }
        return;
    }
    if (req.isLiteral("echo") and req.method == .post) return res.text(200, req.body);
    if (req.isLiteral("empty") and req.isGet()) return res.text(204, "must not be sent");
    if (req.isLiteral("fail") and req.isGet()) return error.DispatchFailed;
}

pub const Config = struct {
    max_connections: usize = 128,
    header_timeout: Io.Clock.Duration = .{ .raw = .fromSeconds(10), .clock = .awake },
    body_read_timeout: Io.Clock.Duration = .{ .raw = .fromSeconds(10), .clock = .awake },
    write_timeout: Io.Clock.Duration = .{ .raw = .fromSeconds(10), .clock = .awake },
    keep_alive_idle_timeout: Io.Clock.Duration = .{ .raw = .fromSeconds(5), .clock = .awake },
    shutdown_grace_period: Io.Clock.Duration = .{ .raw = .fromSeconds(10), .clock = .awake },
    max_requests_per_connection: usize = 100,
    request_limits: @import("request.zig").Limits = .default,
};

/// Accepts connections until the listener is closed or this task is canceled.
/// Admission above `max_connections` is rejected immediately; the accept loop
/// Shutdown stops acceptance, waits `shutdown_grace_period`, then force-closes
/// registered sockets before canceling remaining connection tasks.
/// never waits for an admitted client to finish a request.
pub fn serve(
    comptime AppType: type,
    allocator: std.mem.Allocator,
    io: Io,
    listener: *net.Server,
    app: *const AppType,
    config: Config,
) !void {
    var active: std.atomic.Value(usize) = .init(0);
    var connections: Io.Group = .init;
    var registry: ConnectionRegistry = .{};
    errdefer {
        registry.closeAll(io);
        connections.cancel(io);
    }

    const Context = struct {
        allocator: std.mem.Allocator,
        io: Io,
        connection: *Connection,
        registry: *ConnectionRegistry,
        app: *const AppType,
        config: Config,
        active: *std.atomic.Value(usize),

        fn run(context: *@This()) Io.Cancelable!void {
            defer context.allocator.destroy(context);
            defer _ = context.active.fetchSub(1, .acq_rel);
            defer context.allocator.destroy(context.connection);
            defer context.registry.remove(context.connection, context.io);
            defer context.connection.close(context.io);

            var read_buffer: [8192]u8 = undefined;
            var write_buffer: [8192]u8 = undefined;
            var connection_io = ConnectionIo.init(
                context.io,
                context.connection.stream,
                &read_buffer,
                &write_buffer,
                context.config,
            );
            var http_server = std.http.Server.init(
                &connection_io.reader,
                &connection_io.writer,
            );
            transport.serveConnection(
                AppType,
                context.allocator,
                &http_server,
                context.app,
                .{
                    .request_limits = context.config.request_limits,
                    .max_requests = context.config.max_requests_per_connection,
                    .deadlines = connection_io.deadlineHooks(),
                },
            ) catch {};
        }
    };

    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.SocketNotListening => break,
            error.Canceled => {
                shutdown(&connections, &registry, &active, io, config.shutdown_grace_period);
                return error.Canceled;
            },
            else => {
                connections.cancel(io);
                return err;
            },
        };
        if (!reserve(&active, config.max_connections)) {
            stream.close(io);
            continue;
        }

        const connection = allocator.create(Connection) catch |err| {
            _ = active.fetchSub(1, .acq_rel);
            stream.close(io);
            return err;
        };
        connection.* = .{ .stream = stream };
        registry.add(connection, io);
        const context = allocator.create(Context) catch |err| {
            registry.remove(connection, io);
            connection.close(io);
            allocator.destroy(connection);
            _ = active.fetchSub(1, .acq_rel);
            return err;
        };
        context.* = .{
            .allocator = allocator,
            .io = io,
            .connection = connection,
            .registry = &registry,
            .app = app,
            .config = config,
            .active = &active,
        };
        connections.concurrent(io, Context.run, .{context}) catch |err| {
            allocator.destroy(context);
            registry.remove(connection, io);
            connection.close(io);
            allocator.destroy(connection);
            _ = active.fetchSub(1, .acq_rel);
            return err;
        };
    }

    shutdown(&connections, &registry, &active, io, config.shutdown_grace_period);
}

const Connection = struct {
    stream: net.Stream,
    closed: std.atomic.Value(bool) = .init(false),
    next: ?*Connection = null,

    fn close(self: *Connection, io: Io) void {
        if (!self.closed.swap(true, .acq_rel)) self.stream.close(io);
    }
};

const ConnectionRegistry = struct {
    mutex: Io.Mutex = .init,
    head: ?*Connection = null,

    fn add(self: *ConnectionRegistry, connection: *Connection, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        connection.next = self.head;
        self.head = connection;
    }

    fn remove(self: *ConnectionRegistry, connection: *Connection, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var cursor = &self.head;
        while (cursor.*) |current| {
            if (current == connection) {
                cursor.* = current.next;
                return;
            }
            cursor = &current.next;
        }
    }

    fn closeAll(self: *ConnectionRegistry, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var cursor = self.head;
        while (cursor) |connection| : (cursor = connection.next) {
            connection.close(io);
        }
    }
};

fn shutdown(
    connections: *Io.Group,
    registry: *ConnectionRegistry,
    active: *std.atomic.Value(usize),
    io: Io,
    grace_period: Io.Clock.Duration,
) void {
    if (active.load(.acquire) != 0) {
        const old_protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(old_protection);
        grace_period.sleep(io) catch {};
        registry.closeAll(io);
    }
    connections.cancel(io);
}

fn reserve(active: *std.atomic.Value(usize), limit: usize) bool {
    var current = active.load(.acquire);
    while (current < limit) {
        if (active.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |observed| {
            current = observed;
        } else return true;
    }
    return false;
}

const Phase = enum { header, idle_header, body, write };

const ConnectionIo = struct {
    io: Io,
    stream: net.Stream,
    config: Config,
    phase: Phase = .header,
    deadline: Io.Clock.Timestamp,
    reader: Io.Reader,
    writer: Io.Writer,
    read_error: ?ReadError = null,
    write_error: ?WriteError = null,

    const ReadError = net.Stream.Reader.Error || Io.ConcurrentError || error{Timeout};
    const WriteError = net.Stream.Writer.Error || Io.ConcurrentError || error{Timeout};

    fn init(
        io: Io,
        stream: net.Stream,
        read_buffer: []u8,
        write_buffer: []u8,
        config: Config,
    ) ConnectionIo {
        return .{
            .io = io,
            .stream = stream,
            .config = config,
            .deadline = deadlineFromNow(io, config.header_timeout),
            .reader = .{
                .vtable = &.{ .stream = streamRead, .readVec = readVec },
                .buffer = read_buffer,
                .seek = 0,
                .end = 0,
            },
            .writer = .{
                .vtable = &.{ .drain = drain },
                .buffer = write_buffer,
            },
        };
    }

    fn deadlineHooks(self: *ConnectionIo) transport.Deadlines {
        return .{
            .context = self,
            .begin_header = beginHeader,
            .begin_body = beginBody,
            .begin_write = beginWrite,
        };
    }

    fn beginHeader(context: *anyopaque, keep_alive: bool, buffered: bool) void {
        const self: *ConnectionIo = @ptrCast(@alignCast(context));
        if (keep_alive and !buffered) {
            self.phase = .idle_header;
            self.deadline = deadlineFromNow(self.io, self.config.keep_alive_idle_timeout);
        } else {
            self.phase = .header;
            self.deadline = deadlineFromNow(self.io, self.config.header_timeout);
        }
    }

    fn beginBody(context: *anyopaque) void {
        const self: *ConnectionIo = @ptrCast(@alignCast(context));
        self.phase = .body;
        self.deadline = deadlineFromNow(self.io, self.config.body_read_timeout);
    }

    fn beginWrite(context: *anyopaque) void {
        const self: *ConnectionIo = @ptrCast(@alignCast(context));
        self.phase = .write;
        self.deadline = deadlineFromNow(self.io, self.config.write_timeout);
    }

    fn streamRead(reader: *Io.Reader, writer: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const dest = limit.slice(try writer.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(reader, &data);
        writer.advance(n);
        return n;
    }

    fn readVec(reader: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const self: *ConnectionIo = @alignCast(@fieldParentPtr("reader", reader));
        var vectors_buffer: [8][]u8 = undefined;
        const vector_count, const data_size = try reader.writableVector(&vectors_buffer, data);
        const vectors = vectors_buffer[0..vector_count];
        setSocketTimeout(self.stream.socket.handle, false, self.deadline, self.io) catch {
            self.read_error = error.Unexpected;
            return error.ReadFailed;
        };
        const n = readSocket(self.io, self.stream, vectors) catch |err| {
            self.read_error = err;
            return error.ReadFailed;
        };
        if (n == 0) return error.EndOfStream;
        if (self.phase == .idle_header) {
            self.phase = .header;
            self.deadline = deadlineFromNow(self.io, self.config.header_timeout);
        }
        if (n > data_size) {
            reader.end += n - data_size;
            return data_size;
        }
        return n;
    }

    fn drain(writer: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *ConnectionIo = @alignCast(@fieldParentPtr("writer", writer));
        setSocketTimeout(self.stream.socket.handle, true, self.deadline, self.io) catch {
            self.write_error = error.Unexpected;
            return error.WriteFailed;
        };
        const n = writeSocket(self.io, self.stream, writer.buffered(), data, splat) catch |err| {
            self.write_error = err;
            return error.WriteFailed;
        };
        return writer.consume(n);
    }
};

fn deadlineFromNow(io: Io, duration: Io.Clock.Duration) Io.Clock.Timestamp {
    return Io.Clock.Timestamp.now(io, .awake).addDuration(duration);
}

fn setSocketTimeout(handle: net.Socket.Handle, write: bool, deadline: Io.Clock.Timestamp, io: Io) !void {
    if (comptime @import("builtin").os.tag == .windows) return;
    const remaining = deadline.durationFromNow(io).raw.nanoseconds;
    const nanos = @max(remaining, @as(i96, 1_000));
    const timeval = std.posix.timeval{
        .sec = @intCast(@divFloor(nanos, std.time.ns_per_s)),
        .usec = @intCast(@divFloor(@mod(nanos, std.time.ns_per_s), std.time.ns_per_us)),
    };
    const bytes = std.mem.asBytes(&timeval);
    try std.posix.setsockopt(handle, std.posix.SOL.SOCKET, if (write) std.posix.SO.SNDTIMEO else std.posix.SO.RCVTIMEO, bytes);
}

fn readSocket(io: Io, stream: net.Stream, vectors: [][]u8) ConnectionIo.ReadError!usize {
    if (comptime @import("builtin").os.tag == .windows) return io.vtable.netRead(io.userdata, stream.socket.handle, vectors);
    return std.posix.read(stream.socket.handle, vectors[0]) catch |err| switch (err) {
        error.WouldBlock => error.Timeout,
        error.Canceled => error.Canceled,
        else => error.Unexpected,
    };
}

fn writeSocket(io: Io, stream: net.Stream, header: []const u8, data: []const []const u8, splat: usize) ConnectionIo.WriteError!usize {
    const n = try io.vtable.netWrite(io.userdata, stream.socket.handle, header, data, splat);
    return n;
}

test "defaults match the Phase 2 connection contract" {
    const config: Config = .{};
    try std.testing.expectEqual(@as(usize, 128), config.max_connections);
    try std.testing.expectEqual(@as(i96, 10 * std.time.ns_per_s), config.header_timeout.raw.nanoseconds);
    try std.testing.expectEqual(@as(i96, 10 * std.time.ns_per_s), config.body_read_timeout.raw.nanoseconds);
    try std.testing.expectEqual(@as(i96, 10 * std.time.ns_per_s), config.write_timeout.raw.nanoseconds);
    try std.testing.expectEqual(@as(i96, 5 * std.time.ns_per_s), config.keep_alive_idle_timeout.raw.nanoseconds);
    try std.testing.expectEqual(@as(i96, 10 * std.time.ns_per_s), config.shutdown_grace_period.raw.nanoseconds);
    try std.testing.expectEqual(@as(usize, 100), config.max_requests_per_connection);
}

test "admission never exceeds its configured cap" {
    var active: std.atomic.Value(usize) = .init(0);
    try std.testing.expect(reserve(&active, 2));
    try std.testing.expect(reserve(&active, 2));
    try std.testing.expect(!reserve(&active, 2));
    try std.testing.expectEqual(@as(usize, 2), active.load(.acquire));
    _ = active.fetchSub(1, .acq_rel);
    try std.testing.expect(reserve(&active, 2));
    try std.testing.expectEqual(@as(usize, 2), active.load(.acquire));
}

test "header reads use one total deadline across bytes" {
    const io = std.testing.io;
    const address: net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    const client = try net.IpAddress.connect(&listener.socket.address, io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    defer client.close(io);
    const accepted = try listener.accept(io);
    defer accepted.close(io);

    const short: Io.Clock.Duration = .{ .raw = .fromMilliseconds(30), .clock = .awake };
    var read_buffer: [16]u8 = undefined;
    var write_buffer: [16]u8 = undefined;
    var connection = ConnectionIo.init(io, accepted, &read_buffer, &write_buffer, .{
        .header_timeout = short,
    });
    ConnectionIo.beginHeader(&connection, false, false);

    var client_buffer: [16]u8 = undefined;
    var client_writer = client.writer(io, &client_buffer);
    try client_writer.interface.writeByte('a');
    try client_writer.interface.flush();
    try std.testing.expectEqual(@as(u8, 'a'), try connection.reader.takeByte());

    try Io.sleep(io, .fromMilliseconds(45), .awake);
    try std.testing.expectError(error.ReadFailed, connection.reader.takeByte());
    try std.testing.expectEqual(error.Timeout, connection.read_error.?);
}

test "a stalled connection does not block a second client" {
    const response = @import("response.zig");
    const router = @import("router.zig");
    const TestApp = struct {
        allocator: std.mem.Allocator,

        pub fn dispatch(self: *const @This(), _: *router.Request) !response.Response {
            var result = response.Response.init(self.allocator);
            errdefer result.deinit();
            try result.text(200, "ok");
            return result;
        }
    };

    const Runner = struct {
        fn run(allocator: std.mem.Allocator, run_io: Io, run_listener: *net.Server, run_app: *const TestApp, run_config: Config) !void {
            return serve(TestApp, allocator, run_io, run_listener, run_app, run_config);
        }
    };

    const io = std.testing.io;
    const address: net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const app: TestApp = .{ .allocator = std.testing.allocator };
    var server_future = try io.concurrent(Runner.run, .{
        std.testing.allocator,
        io,
        &listener,
        &app,
        Config{
            .max_connections = 2,
            .header_timeout = .{ .raw = .fromSeconds(1), .clock = .awake },
            .shutdown_grace_period = .{ .raw = .fromMilliseconds(25), .clock = .awake },
        },
    });

    const stalled = try net.IpAddress.connect(&listener.socket.address, io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    var stalled_buffer: [64]u8 = undefined;
    var stalled_writer = stalled.writer(io, &stalled_buffer);
    try stalled_writer.interface.writeAll("GET / HTTP/1.1\r\nHost:");
    try stalled_writer.interface.flush();

    const healthy = try net.IpAddress.connect(&listener.socket.address, io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    defer stalled.close(io);
    defer healthy.close(io);
    var healthy_buffer: [128]u8 = undefined;
    var healthy_writer = healthy.writer(io, &healthy_buffer);
    try healthy_writer.interface.writeAll("GET / HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n");
    try healthy_writer.interface.flush();

    var healthy_read_buffer: [1024]u8 = undefined;
    var healthy_reader = healthy.reader(io, &healthy_read_buffer);
    const n = try healthy_reader.interface.readSliceShort(&healthy_read_buffer);
    try std.testing.expect(std.mem.startsWith(u8, healthy_read_buffer[0..n], "HTTP/1.1 200 OK"));
    const shutdown_started = Io.Clock.Timestamp.now(io, .awake);
    _ = server_future.cancel(io) catch {};
    const shutdown_elapsed = shutdown_started.durationFromNow(io);
    try std.testing.expect(shutdown_elapsed.raw.nanoseconds < @as(i96, std.time.ns_per_s));
}

fn expectSocketResponse(reader: *Io.Reader, expected_status: u16, expected_body: []const u8, representation_length: usize) !void {
    const status_line = std.mem.trim(u8, try reader.takeDelimiterInclusive('\n'), "\r\n");
    var expected_status_line: [32]u8 = undefined;
    const status_text = try std.fmt.bufPrint(&expected_status_line, "HTTP/1.1 {d}", .{expected_status});
    try std.testing.expect(std.mem.startsWith(u8, status_line, status_text));

    var content_length: ?usize = null;
    while (true) {
        const line = std.mem.trim(u8, try reader.takeDelimiterInclusive('\n'), "\r\n");
        if (line.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            content_length = try std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " \t\r\n"), 10);
        }
    }
    try std.testing.expectEqual(representation_length, content_length.?);
    if (expected_body.len != 0) {
        var body: [256]u8 = undefined;
        try std.testing.expect(expected_body.len <= body.len);
        try reader.readSliceAll(body[0..expected_body.len]);
        try std.testing.expectEqualStrings(expected_body, body[0..expected_body.len]);
    }
}

test "JSON vertical slice runs over real sockets" {
    const Runner = struct {
        fn run(allocator: std.mem.Allocator, run_io: Io, run_listener: *net.Server, run_app: *const SocketApp, run_config: Config) !void {
            return serve(SocketApp, allocator, run_io, run_listener, run_app, run_config);
        }
    };

    const io = std.testing.io;
    const address: net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const socket_app: SocketApp = .{ .response_allocator = std.testing.allocator, .config = .{ .name = "socket-test" }, .plugins = .{}, .route_fn = socketRoute };
    var server_future = try io.concurrent(Runner.run, .{ std.testing.allocator, io, &listener, &socket_app, Config{ .shutdown_grace_period = .{ .raw = .fromMilliseconds(25), .clock = .awake } } });

    const client = try net.IpAddress.connect(&listener.socket.address, io, .{ .mode = .stream, .protocol = .tcp });
    defer client.close(io);
    var write_buffer: [1024]u8 = undefined;
    var writer = client.writer(io, &write_buffer);
    var read_buffer: [2048]u8 = undefined;
    var reader = client.reader(io, &read_buffer);
    const requests = .{
        .{ "GET / HTTP/1.1\r\nHost: test\r\n\r\n", @as(u16, 200), "hello from zoda", @as(usize, 15) },
        .{ "GET /users/42 HTTP/1.1\r\nHost: test\r\n\r\n", @as(u16, 200), "{\"id\":\"42\",\"name\":\"unknown\"}", @as(usize, 28) },
        .{ "GET /users HTTP/1.1\r\nHost: test\r\n\r\n", @as(u16, 404), "Not Found", @as(usize, 9) },
        .{ "GET /users/42/extra HTTP/1.1\r\nHost: test\r\n\r\n", @as(u16, 404), "Not Found", @as(usize, 9) },
        .{ "GET /users/42/ HTTP/1.1\r\nHost: test\r\n\r\n", @as(u16, 404), "Not Found", @as(usize, 9) },
        .{ "POST /users/42 HTTP/1.1\r\nHost: test\r\nContent-Length: 0\r\n\r\n", @as(u16, 404), "Not Found", @as(usize, 9) },
        .{ "POST /echo HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n", @as(u16, 200), "hello", @as(usize, 5) },
        .{ "HEAD / HTTP/1.1\r\nHost: test\r\n\r\n", @as(u16, 200), "", @as(usize, 15) },
        .{ "GET /empty HTTP/1.1\r\nHost: test\r\n\r\n", @as(u16, 204), "", @as(usize, 0) },
    };
    inline for (requests) |request_case| {
        try writer.interface.writeAll(request_case[0]);
        try writer.interface.flush();
        try expectSocketResponse(&reader.interface, request_case[1], request_case[2], request_case[3]);
    }
    _ = server_future.cancel(io) catch {};
}

test "real socket dispatch failure is generic and closes" {
    const Runner = struct {
        fn run(allocator: std.mem.Allocator, run_io: Io, run_listener: *net.Server, run_app: *const SocketApp, run_config: Config) !void {
            return serve(SocketApp, allocator, run_io, run_listener, run_app, run_config);
        }
    };
    const io = std.testing.io;
    const address: net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const socket_app: SocketApp = .{ .response_allocator = std.testing.allocator, .config = .{ .name = "socket-test" }, .plugins = .{}, .route_fn = socketRoute };
    var server_future = try io.concurrent(Runner.run, .{ std.testing.allocator, io, &listener, &socket_app, Config{ .shutdown_grace_period = .{ .raw = .fromMilliseconds(25), .clock = .awake } } });
    const client = try net.IpAddress.connect(&listener.socket.address, io, .{ .mode = .stream, .protocol = .tcp });
    defer client.close(io);
    var write_buffer: [256]u8 = undefined;
    var writer = client.writer(io, &write_buffer);
    try writer.interface.writeAll("GET /fail HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n");
    try writer.interface.flush();
    var read_buffer: [512]u8 = undefined;
    var reader = client.reader(io, &read_buffer);
    try expectSocketResponse(&reader.interface, 500, "Internal Server Error", 21);
    _ = server_future.cancel(io) catch {};
}
