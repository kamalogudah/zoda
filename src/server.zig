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

pub const Config = struct {
    max_connections: usize = 128,
    header_timeout: Io.Clock.Duration = .{ .raw = .fromSeconds(10), .clock = .awake },
    body_read_timeout: Io.Clock.Duration = .{ .raw = .fromSeconds(10), .clock = .awake },
    write_timeout: Io.Clock.Duration = .{ .raw = .fromSeconds(10), .clock = .awake },
    keep_alive_idle_timeout: Io.Clock.Duration = .{ .raw = .fromSeconds(5), .clock = .awake },
    max_requests_per_connection: usize = 100,
    request_limits: @import("request.zig").Limits = .default,
};

/// Accepts connections until the listener is closed or this task is canceled.
/// Admission above `max_connections` is rejected immediately; the accept loop
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
    errdefer connections.cancel(io);

    const Context = struct {
        allocator: std.mem.Allocator,
        io: Io,
        stream: net.Stream,
        app: *const AppType,
        config: Config,
        active: *std.atomic.Value(usize),

        fn run(context: *@This()) Io.Cancelable!void {
            defer context.allocator.destroy(context);
            defer _ = context.active.fetchSub(1, .acq_rel);
            defer context.stream.close(context.io);

            var read_buffer: [8192]u8 = undefined;
            var write_buffer: [8192]u8 = undefined;
            var connection_io = ConnectionIo.init(
                context.io,
                context.stream,
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
            else => return err,
        };
        if (!reserve(&active, config.max_connections)) {
            stream.close(io);
            continue;
        }

        const context = allocator.create(Context) catch |err| {
            _ = active.fetchSub(1, .acq_rel);
            stream.close(io);
            return err;
        };
        context.* = .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .app = app,
            .config = config,
            .active = &active,
        };
        connections.concurrent(io, Context.run, .{context}) catch |err| {
            allocator.destroy(context);
            _ = active.fetchSub(1, .acq_rel);
            stream.close(io);
            return err;
        };
    }

    try connections.await(io);
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
    if (comptime @import("builtin").os.tag == .windows) return io.vtable.netWrite(io.userdata, stream.socket.handle, header, data, splat);
    var total: usize = 0;
    if (header.len != 0) {
        total = writeOne(stream.socket.handle, header) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.Unexpected,
        };
        if (total != header.len) return total;
    }
    for (data[0 .. data.len - 1]) |part| {
        total += writeOne(stream.socket.handle, part) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.Unexpected,
        };
    }
    const pattern = data[data.len - 1];
    for (0..splat) |_| total += writeOne(stream.socket.handle, pattern) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
    return total;
}

fn writeOne(fd: std.posix.fd_t, bytes: []const u8) ConnectionIo.WriteError!usize {
    const rc = std.posix.system.write(fd, bytes.ptr, bytes.len);
    return switch (std.posix.errno(rc)) {
        .SUCCESS => (rc),
        .AGAIN => error.Timeout,
        .INTR => error.Canceled,
        else => error.Unexpected,
    };
}

test "defaults match the Phase 2 connection contract" {
    const config: Config = .{};
    try std.testing.expectEqual(@as(usize, 128), config.max_connections);
    try std.testing.expectEqual(@as(i96, 10 * std.time.ns_per_s), config.header_timeout.raw.nanoseconds);
    try std.testing.expectEqual(@as(i96, 10 * std.time.ns_per_s), config.body_read_timeout.raw.nanoseconds);
    try std.testing.expectEqual(@as(i96, 10 * std.time.ns_per_s), config.write_timeout.raw.nanoseconds);
    try std.testing.expectEqual(@as(i96, 5 * std.time.ns_per_s), config.keep_alive_idle_timeout.raw.nanoseconds);
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
    defer _ = server_future.cancel(io) catch {};
    var healthy_buffer: [128]u8 = undefined;
    var healthy_writer = healthy.writer(io, &healthy_buffer);
    try healthy_writer.interface.writeAll("GET / HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n");
    try healthy_writer.interface.flush();

    var healthy_read_buffer: [1024]u8 = undefined;
    var healthy_reader = healthy.reader(io, &healthy_read_buffer);
    const n = try healthy_reader.interface.readSliceShort(&healthy_read_buffer);
    try std.testing.expect(std.mem.startsWith(u8, healthy_read_buffer[0..n], "HTTP/1.1 200 OK"));
}
