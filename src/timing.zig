//! Injected application clock and response-timing middleware
//! (ADR-0001 §4 Phase 2e, §5.4).
//!
//! `Clock` is the application's time source. `Clock.monotonic(io)` reads the
//! pinned toolchain's monotonic clock (`Io.Clock.awake`, `CLOCK_MONOTONIC` on
//! Linux) through the application's `Io`. Tests inject a `Clock.Source` to
//! make timing deterministic. The clock is set on `AppConfig.clock` and is
//! reached from middleware through `ctx.config.clock`.
//!
//! `middleware(App)` returns an entry that reads the clock before calling
//! `next` and, only when `next.call` succeeds, adds `X-Response-Time-Ms` with
//! the elapsed whole milliseconds. The value is formatted with
//! `Response.setHeaderFmt`, which copies the bytes into response-owned storage:
//! nothing formatted during the request outlives it except that copy. On an
//! error the header is not added and the error propagates unchanged (§3.5).
//!
//! Register the entry first so it is outermost and times every other entry,
//! the route, and the default 404 applied by the terminal continuation. A
//! short circuit that writes nothing is still timed; dispatch's fallback 404
//! keeps the header because `Response.text` replaces only the body, status,
//! and content type.
const std = @import("std");
const Io = std.Io;
const router = @import("router.zig");
const response = @import("response.zig");

/// Header added by the timing middleware.
pub const header_name = "X-Response-Time-Ms";

/// Returned by the timing middleware when `AppConfig.clock` is unset. The
/// request fails before any downstream code runs.
pub const TimingError = error{ClockNotConfigured};

/// An application time source. Reads must be monotonic: a later reading is
/// never earlier than a previous one. Elapsed time is clamped at zero in case
/// an injected source breaks that rule.
///
/// Concurrency: an app serving concurrent requests reads its clock from
/// several threads at once. `monotonic` is safe for that. An injected
/// `Source` must be too, or the app must not serve concurrently.
pub const Clock = union(enum) {
    /// The pinned toolchain's monotonic clock, read through `Io`.
    io: Io,
    /// An injected source, for deterministic tests.
    source: Source,

    pub const Source = struct {
        context: *anyopaque,
        now: *const fn (context: *anyopaque) Io.Timestamp,
    };

    /// Clock backed by `Io.Clock.awake` (`CLOCK_MONOTONIC` on Linux).
    pub fn monotonic(io: Io) Clock {
        return .{ .io = io };
    }

    pub fn monotonicNow(self: Clock) Io.Timestamp {
        return switch (self) {
            .io => |io| Io.Clock.awake.now(io),
            .source => |s| s.now(s.context),
        };
    }

    /// Whole milliseconds since `start`, truncated, and never negative.
    pub fn elapsedMilliseconds(self: Clock, start: Io.Timestamp) u64 {
        const elapsed = start.durationTo(self.monotonicNow()).toMilliseconds();
        return if (elapsed < 0) 0 else @intCast(elapsed);
    }
};

/// Returns a response-timing entry for `AppT`. The entry has no configuration
/// of its own; it reads `ctx.config.clock`.
pub fn middleware(comptime AppT: type) AppT.Middleware {
    const Impl = struct {
        const no_config: u8 = 0;

        fn invoke(
            _: *const anyopaque,
            ctx: *AppT.Context,
            req: *router.Request,
            res: *response.Response,
            next: AppT.Next,
        ) anyerror!void {
            const clock = ctx.config.clock orelse return error.ClockNotConfigured;
            const start = clock.monotonicNow();
            try next.call(ctx, req, res);
            // Copies the formatted value into response storage.
            try res.setHeaderFmt(header_name, "{d}", .{clock.elapsedMilliseconds(start)});
        }
    };
    return .{ .config = &Impl.no_config, .invoke = Impl.invoke };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const app_mod = @import("app.zig");
const request = @import("request.zig");

const TestApp = app_mod.App(struct {});

/// Deterministic clock: reads return `now`, which only the test advances.
const ManualClock = struct {
    now: Io.Timestamp = .zero,
    reads: usize = 0,

    fn read(context: *anyopaque) Io.Timestamp {
        const self: *ManualClock = @ptrCast(@alignCast(context));
        self.reads += 1;
        return self.now;
    }

    fn clock(self: *ManualClock) Clock {
        return .{ .source = .{ .context = self, .now = read } };
    }

    fn advanceMs(self: *ManualClock, ms: i64) void {
        self.now = self.now.addDuration(.fromMilliseconds(ms));
    }
};

/// The route advances the manual clock to simulate work.
const timed_route = struct {
    var manual: ?*ManualClock = null;

    fn run(_: *TestApp.Context, req: *router.Request, res: *response.Response) !void {
        if (manual) |m| m.advanceMs(42);
        if (req.isRoot() and req.isGet()) return res.text(200, "root");
        if (req.isLiteral("boom")) return error.Boom;
    }
};

fn dispatchPath(app: *const TestApp, path: []const u8) !response.Response {
    var arena = try request.parseOriginForm(std.testing.allocator, .default, path);
    defer arena.deinit();
    var req = arena.requestView(.get);
    return app.dispatch(&req);
}

fn initTimedApp(manual: *ManualClock, extra: []const TestApp.Middleware) !TestApp {
    var entries: [4]TestApp.Middleware = undefined;
    entries[0] = middleware(TestApp);
    @memcpy(entries[1..][0..extra.len], extra);
    return TestApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .config = .{ .clock = manual.clock() },
        .plugins = .{},
        .route_fn = timed_route.run,
        .middleware = entries[0 .. 1 + extra.len],
    });
}

test "elapsedMilliseconds truncates and clamps a backwards reading to zero" {
    var manual = ManualClock{ .now = .fromNanoseconds(10 * std.time.ns_per_ms) };
    const clock = manual.clock();
    const start = clock.monotonicNow();
    manual.now = manual.now.addDuration(.fromNanoseconds(7 * std.time.ns_per_ms + 999_999));
    try std.testing.expectEqual(@as(u64, 7), clock.elapsedMilliseconds(start));
    manual.now = .zero;
    try std.testing.expectEqual(@as(u64, 0), clock.elapsedMilliseconds(start));
}

test "monotonic clock reads the pinned toolchain clock and never goes backwards" {
    const clock = Clock.monotonic(std.testing.io);
    // Bracketed by direct `awake` reads, so it is that clock and not `real`.
    const before = Io.Clock.awake.now(std.testing.io);
    const reading = clock.monotonicNow();
    const after = Io.Clock.awake.now(std.testing.io);
    try std.testing.expect(before.nanoseconds <= reading.nanoseconds);
    try std.testing.expect(reading.nanoseconds <= after.nanoseconds);

    var previous = clock.monotonicNow();
    for (0..1000) |_| {
        const now = clock.monotonicNow();
        try std.testing.expect(now.nanoseconds >= previous.nanoseconds);
        previous = now;
    }
    const start = clock.monotonicNow();
    try Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    try std.testing.expect(clock.elapsedMilliseconds(start) >= 5);
}

test "ordinary response gets the injected clock's elapsed milliseconds" {
    var manual = ManualClock{};
    timed_route.manual = &manual;
    defer timed_route.manual = null;

    var app = try initTimedApp(&manual, &.{});
    defer app.deinit();

    var res = try dispatchPath(&app, "/");
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 200), res.status_code);
    try std.testing.expectEqualStrings("root", res.body);
    try std.testing.expectEqualStrings("42", (try res.getHeaderOne(header_name)).?);
    // One read before `next`, one after.
    try std.testing.expectEqual(@as(usize, 2), manual.reads);
}

test "fallback 404 from the terminal continuation is timed" {
    var manual = ManualClock{};
    timed_route.manual = &manual;
    defer timed_route.manual = null;

    var app = try initTimedApp(&manual, &.{});
    defer app.deinit();

    var res = try dispatchPath(&app, "/missing");
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 404), res.status_code);
    try std.testing.expectEqualStrings("Not Found", res.body);
    try std.testing.expectEqualStrings("42", (try res.getHeaderOne(header_name)).?);
}

test "empty short circuit keeps the header through dispatch's fallback 404" {
    const Silent = struct {
        fn invoke(
            _: *const anyopaque,
            _: *TestApp.Context,
            _: *router.Request,
            _: *response.Response,
            _: TestApp.Next,
        ) anyerror!void {}
    };
    const Deny = struct {
        fn invoke(
            _: *const anyopaque,
            _: *TestApp.Context,
            _: *router.Request,
            res: *response.Response,
            _: TestApp.Next,
        ) anyerror!void {
            return res.text(401, "unauthorized");
        }
    };
    var manual = ManualClock{ .now = .fromNanoseconds(5 * std.time.ns_per_s) };

    {
        var app = try initTimedApp(&manual, &.{.{ .config = &manual, .invoke = Silent.invoke }});
        defer app.deinit();
        var res = try dispatchPath(&app, "/");
        defer res.deinit();
        // The route never ran, so no time passed; dispatch applied the 404.
        try std.testing.expectEqual(@as(u16, 404), res.status_code);
        try std.testing.expectEqualStrings("0", (try res.getHeaderOne(header_name)).?);
    }
    {
        var app = try initTimedApp(&manual, &.{.{ .config = &manual, .invoke = Deny.invoke }});
        defer app.deinit();
        var res = try dispatchPath(&app, "/");
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 401), res.status_code);
        try std.testing.expectEqualStrings("0", (try res.getHeaderOne(header_name)).?);
    }
}

test "errors propagate without a timing header and leak nothing" {
    var manual = ManualClock{};
    timed_route.manual = &manual;
    defer timed_route.manual = null;

    var app = try initTimedApp(&manual, &.{});
    defer app.deinit();

    try std.testing.expectError(error.Boom, dispatchPath(&app, "/boom"));
    // Started, but success post-processing never read the clock again.
    try std.testing.expectEqual(@as(usize, 1), manual.reads);
}

test "an inner recovery is a success and is timed" {
    const Recover = struct {
        fn invoke(
            _: *const anyopaque,
            ctx: *TestApp.Context,
            req: *router.Request,
            res: *response.Response,
            next: TestApp.Next,
        ) anyerror!void {
            next.call(ctx, req, res) catch {
                res.clear();
                return res.text(503, "unavailable");
            };
        }
    };
    var manual = ManualClock{};
    timed_route.manual = &manual;
    defer timed_route.manual = null;

    var app = try initTimedApp(&manual, &.{.{ .config = &manual, .invoke = Recover.invoke }});
    defer app.deinit();

    var res = try dispatchPath(&app, "/boom");
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 503), res.status_code);
    try std.testing.expectEqualStrings("42", (try res.getHeaderOne(header_name)).?);
}

test "a header-limit failure after next propagates and releases the response" {
    const Fill = struct {
        fn invoke(
            _: *const anyopaque,
            ctx: *TestApp.Context,
            req: *router.Request,
            res: *response.Response,
            next: TestApp.Next,
        ) anyerror!void {
            try next.call(ctx, req, res);
            // Leave no room for the timing header.
            while (res.header_count < res.limits.max_headers) try res.setHeader("X-Fill", "1");
        }
    };
    var manual = ManualClock{};
    var app = try initTimedApp(&manual, &.{.{ .config = &manual, .invoke = Fill.invoke }});
    defer app.deinit();

    try std.testing.expectError(error.TooManyHeaders, dispatchPath(&app, "/"));
}

test "missing clock fails the request before downstream runs" {
    var manual = ManualClock{};
    timed_route.manual = &manual;
    defer timed_route.manual = null;

    var app = try TestApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{},
        .route_fn = timed_route.run,
        .middleware = &.{middleware(TestApp)},
    });
    defer app.deinit();

    try std.testing.expectError(error.ClockNotConfigured, dispatchPath(&app, "/"));
    // The route never advanced the clock.
    try std.testing.expectEqual(@as(i96, 0), manual.now.nanoseconds);
}

test "timing value is response-owned and outlives the request and the frame" {
    var manual = ManualClock{};
    timed_route.manual = &manual;
    defer timed_route.manual = null;

    var app = try initTimedApp(&manual, &.{});
    defer app.deinit();

    var res = blk: {
        var arena = try request.parseOriginForm(std.testing.allocator, .default, "/");
        var req = arena.requestView(.get);
        const out = try app.dispatch(&req);
        // Release the request before reading the response.
        arena.deinit();
        break :blk out;
    };
    defer res.deinit();
    const value = (try res.getHeaderOne(header_name)).?;
    try std.testing.expectEqualStrings("42", value);
    // The value lives in the response's own header storage.
    try std.testing.expectEqual(value.ptr, res.headers[0].value.ptr);
}

test "real monotonic clock times requests through the default 404 and a 200" {
    var app = try TestApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .config = .{ .clock = .monotonic(std.testing.io) },
        .plugins = .{},
        .route_fn = timed_route.run,
        .middleware = &.{middleware(TestApp)},
    });
    defer app.deinit();

    inline for (.{ "/", "/missing" }) |path| {
        var res = try dispatchPath(&app, path);
        defer res.deinit();
        const value = (try res.getHeaderOne(header_name)).?;
        _ = try std.fmt.parseInt(u64, value, 10);
    }
}
