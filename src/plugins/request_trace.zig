//! Request IDs and one synchronous access record per middleware completion.
//! Register `middleware(App, "trace")` outermost. The plugin creates its ID
//! before middleware begins and stores it in request-local `ctx.state.trace`.
const std = @import("std");
const router = @import("../router.zig");
const response = @import("../response.zig");
const timing = @import("../timing.zig");

pub const header_name = "X-Request-Id";
pub const max_id_bytes = 64;

/// `ignore` always generates an ID. `accept_valid` accepts exactly one
/// bounded, ASCII token; malformed or repeated values cause generation.
pub const Incoming = enum { ignore, accept_valid };

/// A source fills 16 unpredictable bytes. Custom sources must be safe for
/// concurrent calls, as must the access sink.
pub const IdSource = union(enum) {
    io: std.Io,
    custom: struct {
        context: *anyopaque,
        fill: *const fn (*anyopaque, *[16]u8) anyerror!void,
    },

    pub fn fill(self: IdSource, bytes: *[16]u8) !void {
        switch (self) {
            .io => |io| try std.Io.randomSecure(io, bytes),
            .custom => |source| try source.fill(source.context, bytes),
        }
    }
};

/// No request or response headers, bodies, or query strings are included, so
/// Authorization, Cookie, and session values never reach the sink. `path` is
/// the request target before any `?`. A failed continuation has
/// `status = null`, even if it left a partial response. Slices are valid only
/// for the duration of the sink call.
pub const Record = struct {
    id: []const u8,
    method: router.Method,
    path: []const u8,
    status: ?u16,
    duration_ms: u64,
    failed: bool,
};

pub const Sink = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, Record) void,
};

pub const RequestTrace = struct {
    source: IdSource,
    incoming: Incoming = .ignore,
    clock: timing.Clock,
    sink: Sink,

    pub const State = struct {
        bytes: [max_id_bytes]u8 = undefined,
        len: usize = 0,

        pub fn id(self: *const State) []const u8 {
            return self.bytes[0..self.len];
        }
    };

    pub fn initRequest(self: *const RequestTrace, req: *router.Request) !State {
        var state: State = .{};
        if (self.incoming == .accept_valid) {
            const incoming = req.getHeaderOne(header_name) catch null;
            if (incoming) |id| {
                if (validId(id)) {
                    @memcpy(state.bytes[0..id.len], id);
                    state.len = id.len;
                    return state;
                }
            }
        }
        var random: [16]u8 = undefined;
        try self.source.fill(&random);
        const hex = "0123456789abcdef";
        for (random, 0..) |byte, i| {
            state.bytes[i * 2] = hex[byte >> 4];
            state.bytes[i * 2 + 1] = hex[byte & 15];
        }
        state.len = 32;
        return state;
    }
};

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id_bytes) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

/// `name` identifies the `RequestTrace` field in the application's Plugins.
/// Place this entry before timing, static, authentication and recovery so it
/// sees their completed responses and errors. The sink is invoked exactly once
/// on successful completion or propagated error. Sink callbacks cannot fail.
pub fn middleware(comptime AppT: type, comptime name: []const u8) AppT.Middleware {
    const Impl = struct {
        const no_config: u8 = 0;

        fn invoke(_: *const anyopaque, ctx: *AppT.Context, req: *router.Request, res: *response.Response, next: AppT.Next) anyerror!void {
            const plugin = &@field(ctx.plugins, name);
            const id = @field(ctx.state, name).id();
            const path = req.target[0 .. std.mem.indexOfScalar(u8, req.target, '?') orelse req.target.len];
            const started = plugin.clock.monotonicNow();
            errdefer {
                plugin.sink.write(plugin.sink.context, .{
                    .id = id,
                    .method = req.method,
                    .path = path,
                    .status = null,
                    .duration_ms = plugin.clock.elapsedMilliseconds(started),
                    .failed = true,
                });
            }
            try next.call(ctx, req, res);
            // A silent short circuit would otherwise receive dispatch's 404
            // after this entry unwinds. Materialize it before logging.
            if (!res.handled) try res.defaultNotFound();
            try res.setHeader(header_name, id);
            plugin.sink.write(plugin.sink.context, .{
                .id = id,
                .method = req.method,
                .path = path,
                .status = res.status_code,
                .duration_ms = plugin.clock.elapsedMilliseconds(started),
                .failed = false,
            });
        }
    };
    return .{ .config = &Impl.no_config, .invoke = Impl.invoke };
}

test "ID policy validates bounds and syntax" {
    try std.testing.expect(validId("abc_DEF-09"));
    try std.testing.expect(!validId(""));
    try std.testing.expect(!validId("bad value"));
    try std.testing.expect(!validId("bad\nvalue"));
    try std.testing.expect(!validId("a" ** 65));
}

test "IDs, completion records, short circuits and errors" {
    const app_mod = @import("../app.zig");
    const Plugins = struct { trace: RequestTrace };
    const A = app_mod.App(Plugins);
    const Collector = struct {
        records: [8]Record = undefined,
        ids: [8][max_id_bytes]u8 = undefined,
        count: usize = 0,
        fn write(raw: *anyopaque, record: Record) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            @memcpy(self.ids[self.count][0..record.id.len], record.id);
            self.records[self.count] = record;
            self.records[self.count].id = self.ids[self.count][0..record.id.len];
            self.count += 1;
        }
    };
    const Source = struct {
        calls: usize = 0,
        fn fill(raw: *anyopaque, bytes: *[16]u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            @memset(bytes, @intCast(self.calls));
        }
    };
    const Route = struct {
        fn run(ctx: *A.Context, req: *router.Request, res: *response.Response) !void {
            if (std.mem.eql(u8, req.target, "/error")) return error.RouteFailed;
            if (std.mem.eql(u8, req.target, "/")) return res.text(200, ctx.state.trace.id());
        }
    };
    const Short = struct {
        fn invoke(_: *const anyopaque, ctx: *A.Context, req: *router.Request, res: *response.Response, next: A.Next) !void {
            if (std.mem.eql(u8, req.target, "/deny")) return res.text(401, "denied");
            if (std.mem.eql(u8, req.target, "/silent")) return;
            return next.call(ctx, req, res);
        }
    };
    const Clock = struct {
        fn now(_: *anyopaque) std.Io.Timestamp {
            return .zero;
        }
    };
    var source: Source = .{};
    var collector: Collector = .{};
    var app = try A.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{ .trace = .{
            .source = .{ .custom = .{ .context = &source, .fill = Source.fill } },
            .incoming = .accept_valid,
            .clock = .{ .source = .{ .context = &source, .now = Clock.now } },
            .sink = .{ .context = &collector, .write = Collector.write },
        } },
        .route_fn = Route.run,
        .middleware = &.{ middleware(A, "trace"), .{ .config = &source, .invoke = Short.invoke } },
    });
    defer app.deinit();

    const cases = [_]struct { target: []const u8, incoming: ?[]const u8, status: ?u16 }{
        .{ .target = "/", .incoming = null, .status = 200 },
        .{ .target = "/", .incoming = "Client_123", .status = 200 },
        .{ .target = "/", .incoming = "bad value", .status = 200 },
        .{ .target = "/missing", .incoming = null, .status = 404 },
        .{ .target = "/deny", .incoming = null, .status = 401 },
        .{ .target = "/silent", .incoming = null, .status = 404 },
        .{ .target = "/error", .incoming = null, .status = null },
    };
    for (cases, 0..) |case, i| {
        const headers = [_]router.Header{.{ .name = header_name, .value = case.incoming orelse "" }};
        var req: router.Request = .{
            .method = .get,
            .target = case.target,
            .segments = &.{},
            .headers = if (case.incoming != null) &headers else &.{},
        };
        if (case.status) |status| {
            var res = try app.dispatch(&req);
            defer res.deinit();
            try std.testing.expectEqual(status, res.status_code);
            const id = (try res.getHeaderOne(header_name)).?;
            try std.testing.expectEqualStrings(id, collector.records[i].id);
            if (i == 1) try std.testing.expectEqualStrings("Client_123", id);
            if (i == 2) try std.testing.expect(!std.mem.eql(u8, "bad value", id));
        } else {
            try std.testing.expectError(error.RouteFailed, app.dispatch(&req));
        }
        try std.testing.expectEqual(i + 1, collector.count);
        try std.testing.expectEqual(case.status, collector.records[i].status);
        try std.testing.expectEqual(case.status == null, collector.records[i].failed);
        try std.testing.expectEqualStrings(case.target, collector.records[i].path);
    }
    try std.testing.expectEqual(@as(usize, 6), source.calls);
}

test "records omit credentials, cookies, and query values" {
    const app_mod = @import("../app.zig");
    const request = @import("../request.zig");
    const Plugins = struct { trace: RequestTrace };
    const A = app_mod.App(Plugins);
    const LineSink = struct {
        line: [256]u8 = undefined,
        len: usize = 0,
        fn write(raw: *anyopaque, record: Record) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const out = std.fmt.bufPrint(&self.line, "{s} {t} {s} {?d} {d} {}", .{
                record.id, record.method, record.path, record.status, record.duration_ms, record.failed,
            }) catch unreachable;
            self.len = out.len;
        }
    };
    const Route = struct {
        fn run(_: *A.Context, _: *router.Request, res: *response.Response) !void {
            return res.text(200, "ok");
        }
    };
    var sink: LineSink = .{};
    var app = try A.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{ .trace = .{
            .source = .{ .io = std.testing.io },
            .clock = .monotonic(std.testing.io),
            .sink = .{ .context = &sink, .write = LineSink.write },
        } },
        .route_fn = Route.run,
        .middleware = &.{middleware(A, "trace")},
    });
    defer app.deinit();

    var arena = try request.parseOriginForm(std.testing.allocator, .default, "/account?token=query-secret");
    defer arena.deinit();
    var req = arena.requestView(.post);
    const headers = [_]router.Header{
        .{ .name = "Authorization", .value = "Bearer bearer-secret" },
        .{ .name = "Cookie", .value = "zoda_session=session-secret" },
        .{ .name = header_name, .value = "cookie-secret" },
    };
    req.headers = &headers;
    var res = try app.dispatch(&req);
    defer res.deinit();

    const line = sink.line[0..sink.len];
    try std.testing.expect(std.mem.indexOf(u8, line, "/account") != null);
    for ([_][]const u8{ "secret", "Bearer", "zoda_session", "token=" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, line, needle) == null);
    }
}

test "concurrent dispatch keeps request IDs request-local" {
    const app_mod = @import("../app.zig");
    const request = @import("../request.zig");
    const gpa = std.heap.smp_allocator;
    const Plugins = struct { trace: RequestTrace };
    const A = app_mod.App(Plugins);
    const CountSink = struct {
        count: std.atomic.Value(usize) = .init(0),
        fn write(raw: *anyopaque, record: Record) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(validId(record.id));
            _ = self.count.fetchAdd(1, .monotonic);
        }
    };
    const Route = struct {
        fn run(ctx: *A.Context, _: *router.Request, res: *response.Response) !void {
            return res.text(200, ctx.state.trace.id());
        }
    };
    const Worker = struct {
        fn run(a: *const A, id: usize, failures: *std.atomic.Value(usize)) void {
            for (0..250) |i| {
                const ok = check(a, id, i) catch false;
                if (!ok) _ = failures.fetchAdd(1, .monotonic);
            }
        }

        fn check(a: *const A, id: usize, i: usize) !bool {
            var buf: [32]u8 = undefined;
            const incoming = try std.fmt.bufPrint(&buf, "worker-{d}-{d}", .{ id, i });
            var arena = try request.parseOriginForm(gpa, .default, "/");
            defer arena.deinit();
            var req = arena.requestView(.get);
            const headers = [_]router.Header{.{ .name = header_name, .value = incoming }};
            // Odd iterations send no ID and receive a generated one.
            if (i % 2 == 0) req.headers = &headers;
            var res = try a.dispatch(&req);
            defer res.deinit();
            const echoed = (try res.getHeaderOne(header_name)) orelse return false;
            if (!std.mem.eql(u8, echoed, res.body)) return false;
            return if (i % 2 == 0) std.mem.eql(u8, incoming, echoed) else echoed.len == 32;
        }
    };
    var sink: CountSink = .{};
    var app = try A.init(gpa, .{
        .response_allocator = gpa,
        .plugins = .{ .trace = .{
            .source = .{ .io = std.testing.io },
            .incoming = .accept_valid,
            .clock = .monotonic(std.testing.io),
            .sink = .{ .context = &sink, .write = CountSink.write },
        } },
        .route_fn = Route.run,
        .middleware = &.{middleware(A, "trace")},
    });
    defer app.deinit();

    var failures = std.atomic.Value(usize).init(0);
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, id| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &app, id, &failures });
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(usize, 0), failures.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 4 * 250), sink.count.load(.monotonic));
}
