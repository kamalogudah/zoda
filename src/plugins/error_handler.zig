//! Recovery for errors propagated from downstream middleware, route wrappers,
//! routes, and status handlers.
//!
//! `middleware(App, &config)` catches an error from `next`, clears the partial
//! response with `Response.clear`, and runs the configured handler. If the
//! handler writes nothing, or there is none, the response becomes a generated
//! `500 Internal Server Error` that an outer status handler may replace.
//! Errors named in `passthrough` (allocation, cancellation, and transport
//! failures by default) propagate unchanged, as do errors from entries
//! registered before this one.
const std = @import("std");
const router = @import("../router.zig");
const response = @import("../response.zig");

/// Allocation, cancellation, and I/O failures are not application errors.
/// They propagate unless a config names its own `passthrough` list.
pub const default_passthrough = [_]anyerror{
    error.OutOfMemory,
    error.Canceled,
    error.ReadFailed,
    error.WriteFailed,
    error.BrokenPipe,
    error.ConnectionResetByPeer,
    error.ConnectionTimedOut,
};

pub fn Config(comptime AppT: type) type {
    return struct {
        const Self = @This();

        /// Receives a cleared response and the caught error. Its own errors
        /// propagate; writing nothing yields the generated 500. A cleared
        /// response has no headers, so it must redo `Set-Cookie` or other
        /// fields it needs (for example after `Flash.reset` and a save).
        handler: ?Handler = null,
        /// Errors that propagate without recovery. Borrowed and immutable;
        /// the slice must outlive the app. `&.{}` recovers every error.
        passthrough: []const anyerror = &default_passthrough,

        pub const Handler = *const fn (*AppT.Context, *router.Request, *response.Response, anyerror) anyerror!void;

        pub fn recovers(self: *const Self, err: anyerror) bool {
            for (self.passthrough) |passed| {
                if (passed == err) return false;
            }
            return true;
        }
    };
}

/// Returns a middleware entry borrowing `config` until app shutdown. Register
/// it outside the entries whose errors it should recover.
pub fn middleware(comptime AppT: type, config: *const Config(AppT)) AppT.Middleware {
    const Impl = struct {
        fn invoke(
            raw: *const anyopaque,
            ctx: *AppT.Context,
            req: *router.Request,
            res: *response.Response,
            next: AppT.Next,
        ) anyerror!void {
            const cfg: *const Config(AppT) = @ptrCast(@alignCast(raw));
            next.call(ctx, req, res) catch |err| {
                if (!cfg.recovers(err)) return err;
                res.clear();
                if (cfg.handler) |handler| try handler(ctx, req, res, err);
                if (!res.handled) {
                    try res.text(500, "Internal Server Error");
                    res.generated = true;
                }
            };
        }
    };
    return .{ .config = config, .invoke = Impl.invoke };
}

const testing = std.testing;
const app_mod = @import("../app.zig");
const request = @import("../request.zig");
const status_handler = @import("status_handler.zig");
const Plugins = struct { guard: Guard = .{} };
const App = app_mod.App(Plugins);

/// A route wrapper that fails on "/wrapper-fail" before the route runs.
const Guard = struct {
    pub fn wrapRoute(comptime H: type, comptime inner: H.RouteFn) H.RouteFn {
        return struct {
            fn run(ctx: *H.Context, req: *router.Request, res: *response.Response) anyerror!void {
                if (isTarget(req, "/wrapper-fail")) {
                    try res.text(401, "partial");
                    return error.WrapperFailed;
                }
                return inner(ctx, req, res);
            }
        }.run;
    }
};

fn isTarget(req: *const router.Request, target: []const u8) bool {
    return std.mem.eql(u8, req.target, target);
}

fn baseRoute(_: *App.Context, req: *router.Request, res: *response.Response) !void {
    if (isTarget(req, "/")) return res.text(200, "home");
    if (isTarget(req, "/boom")) {
        try res.text(200, "partial");
        try res.setHeader("X-Partial", "discard me");
        return error.RouteFailed;
    }
    if (isTarget(req, "/oom")) return error.OutOfMemory;
    if (isTarget(req, "/canceled")) return error.Canceled;
    if (isTarget(req, "/handler-fail")) return error.Rethrow;
    if (isTarget(req, "/handler-silent")) return error.Silent;
}
const route = App.composeRoute(baseRoute);

fn recover(_: *App.Context, req: *router.Request, res: *response.Response, err: anyerror) !void {
    if (err == error.Rethrow) return error.HandlerFailed;
    if (err == error.Silent) return res.setHeader("X-Recovered", "silent");
    try res.text(503, @errorName(err));
    try res.setHeader("X-Recovered", req.target);
}

const recover_config = Config(App){ .handler = recover };

/// Fails on "/<prefix>-fail" with a partial response instead of calling next.
const Failing = struct {
    prefix: []const u8,

    fn invoke(raw: *const anyopaque, ctx: *App.Context, req: *router.Request, res: *response.Response, next: App.Next) anyerror!void {
        const self: *const Failing = @ptrCast(@alignCast(raw));
        if (std.mem.startsWith(u8, req.target[1..], self.prefix) and std.mem.eql(u8, req.target[1 + self.prefix.len ..], "-fail")) {
            try res.text(200, "partial");
            return error.MiddlewareFailed;
        }
        return next.call(ctx, req, res);
    }

    fn entry(self: *const Failing) App.Middleware {
        return .{ .config = self, .invoke = invoke };
    }
};

/// Adds a header after downstream succeeds, including after a recovery.
fn markAfter(_: *const anyopaque, ctx: *App.Context, req: *router.Request, res: *response.Response, next: App.Next) anyerror!void {
    try next.call(ctx, req, res);
    try res.setHeader("X-After", "1");
}
const no_config: u8 = 0;
const mark_after = App.Middleware{ .config = &no_config, .invoke = markAfter };

fn dispatchTo(app: *const App, target: []const u8) !response.Response {
    var arena = try request.parseOriginForm(testing.allocator, .default, target);
    defer arena.deinit();
    var req = arena.requestView(.get);
    return app.dispatch(&req);
}

fn initApp(entries: []const App.Middleware) !App {
    return App.init(testing.allocator, .{
        .response_allocator = testing.allocator,
        .plugins = .{},
        .route_fn = route,
        .middleware = entries,
    });
}

test "recovery clears a partial response before the handler replaces it" {
    var app = try initApp(&.{middleware(App, &recover_config)});
    defer app.deinit();

    var ok = try dispatchTo(&app, "/");
    defer ok.deinit();
    try testing.expectEqualStrings("home", ok.body);

    var res = try dispatchTo(&app, "/boom");
    defer res.deinit();
    try testing.expectEqual(@as(u16, 503), res.status_code);
    try testing.expectEqualStrings("RouteFailed", res.body);
    try testing.expect((try res.getHeaderOne("X-Partial")) == null);
    try testing.expectEqualStrings("/boom", (try res.getHeaderOne("X-Recovered")).?);
    try testing.expectEqual(@as(usize, 1), res.header_count);

    // Route misses are not errors.
    var miss = try dispatchTo(&app, "/missing");
    defer miss.deinit();
    try testing.expectEqual(@as(u16, 404), miss.status_code);
}

test "without a handler, or when it writes nothing, recovery is a generated 500" {
    const bare = Config(App){};
    var app = try initApp(&.{middleware(App, &bare)});
    defer app.deinit();
    var res = try dispatchTo(&app, "/boom");
    defer res.deinit();
    try testing.expectEqual(@as(u16, 500), res.status_code);
    try testing.expectEqualStrings("Internal Server Error", res.body);
    try testing.expect(res.generated);
    try testing.expectEqual(@as(usize, 0), res.header_count);

    var recovering = try initApp(&.{middleware(App, &recover_config)});
    defer recovering.deinit();
    var silent = try dispatchTo(&recovering, "/handler-silent");
    defer silent.deinit();
    try testing.expectEqual(@as(u16, 500), silent.status_code);
    try testing.expectEqualStrings("silent", (try silent.getHeaderOne("X-Recovered")).?);
}

test "allocation and cancellation errors propagate unless configured" {
    var app = try initApp(&.{middleware(App, &recover_config)});
    defer app.deinit();
    try testing.expectError(error.OutOfMemory, dispatchTo(&app, "/oom"));
    try testing.expectError(error.Canceled, dispatchTo(&app, "/canceled"));
    // Handler failures propagate too; dispatch releases the response.
    try testing.expectError(error.HandlerFailed, dispatchTo(&app, "/handler-fail"));

    const everything = Config(App){ .handler = recover, .passthrough = &.{} };
    var all = try initApp(&.{middleware(App, &everything)});
    defer all.deinit();
    var res = try dispatchTo(&all, "/oom");
    defer res.deinit();
    try testing.expectEqualStrings("OutOfMemory", res.body);
}

test "recovery covers inner middleware and wrappers, not outer middleware" {
    const outer = Failing{ .prefix = "outer" };
    const inner = Failing{ .prefix = "inner" };
    var app = try initApp(&.{ mark_after, outer.entry(), middleware(App, &recover_config), inner.entry() });
    defer app.deinit();

    // Outer post-processing runs after a recovery, as after any success.
    var inner_res = try dispatchTo(&app, "/inner-fail");
    defer inner_res.deinit();
    try testing.expectEqualStrings("MiddlewareFailed", inner_res.body);
    try testing.expectEqualStrings("1", (try inner_res.getHeaderOne("X-After")).?);

    var wrapper_res = try dispatchTo(&app, "/wrapper-fail");
    defer wrapper_res.deinit();
    try testing.expectEqual(@as(u16, 503), wrapper_res.status_code);
    try testing.expectEqualStrings("WrapperFailed", wrapper_res.body);

    try testing.expectError(error.MiddlewareFailed, dispatchTo(&app, "/outer-fail"));
}

test "status handler order decides whether recovery output is styled" {
    const styled = struct {
        fn serverError(_: *App.Context, _: *router.Request, res: *response.Response) !void {
            try res.text(500, "styled 500");
        }
        fn notFound(_: *App.Context, _: *router.Request, _: *response.Response) !void {
            return error.StatusHandlerFailed;
        }
    };
    const statuses = status_handler.Config(App){ .handlers = &.{
        .{ .status = 500, .run = styled.serverError },
        .{ .status = 404, .run = styled.notFound },
    } };
    const bare = Config(App){};

    // Status handler outside recovery: the generated 500 is styled.
    var outside = try initApp(&.{ try status_handler.middleware(App, &statuses), middleware(App, &bare) });
    defer outside.deinit();
    var styled_res = try dispatchTo(&outside, "/boom");
    defer styled_res.deinit();
    try testing.expectEqualStrings("styled 500", styled_res.body);
    // ...but its own failures are not recovered.
    try testing.expectError(error.StatusHandlerFailed, dispatchTo(&outside, "/missing"));

    // Status handler inside recovery: its failures are recovered, and the
    // recovery 500 is not styled.
    var inside = try initApp(&.{ middleware(App, &bare), try status_handler.middleware(App, &statuses) });
    defer inside.deinit();
    var plain = try dispatchTo(&inside, "/boom");
    defer plain.deinit();
    try testing.expectEqualStrings("Internal Server Error", plain.body);
    var recovered = try dispatchTo(&inside, "/missing");
    defer recovered.deinit();
    try testing.expectEqual(@as(u16, 500), recovered.status_code);
}
