//! Application dispatch and typed handler context (ADR-0001 §3.2, §5.2).
//!
//! An `App(Plugins)` wires a set of plugin instances into a handler context,
//! initializes per-request plugin state, invokes the configured route, and
//! supplies a fallback 404 when the route leaves the response unhandled.
//!
//! `RequestState(Plugins)` is generated from the plugin struct: one field is
//! emitted for every plugin instance that declares a non-`void` `State` type
//! and an `initRequest` hook. Initialization runs in declaration order; cleanup
//! runs in reverse order, including partial initialization failures.
const std = @import("std");
const router = @import("router.zig");
const response = @import("response.zig");
const request = @import("request.zig");
const Json = @import("plugins/json.zig").Json;

/// Re-export the JSON plugin instance type so downstream code can write
/// `const Plugins = struct { json: zoda.Json = .{} };`.
pub const json = Json;

/// Immutable application configuration. Applications may add fields here as
/// long as the values remain valid for the lifetime of the app.
pub const AppConfig = struct {
    name: []const u8 = "zoda",
};

/// Generates a struct containing one field per plugin instance that declares a
/// non-`void` `State` type and an `initRequest` hook. Field names match the
/// plugin instance names.
pub fn RequestState(comptime Plugins: type) type {
    const fields = std.meta.fields(Plugins);
    const count = comptime blk: {
        var c: usize = 0;
        for (fields) |f| {
            const PT = f.type;
            if (@hasDecl(PT, "State") and PT.State != void and @hasDecl(PT, "initRequest")) c += 1;
        }
        break :blk c;
    };
    var names: [count][]const u8 = undefined;
    var types: [count]type = undefined;
    var attrs: [count]std.builtin.Type.StructField.Attributes = undefined;
    var i: usize = 0;
    inline for (fields) |f| {
        const PT = f.type;
        if (@hasDecl(PT, "State") and PT.State != void and @hasDecl(PT, "initRequest")) {
            names[i] = f.name;
            types[i] = PT.State;
            attrs[i] = .{};
            i += 1;
        }
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

/// Initializes the per-request state for `Plugins` in declaration order. If a
/// later hook fails, already-initialized states are deinitialized in reverse
/// order before the error is returned.
pub fn initRequestState(
    comptime Plugins: type,
    plugins: *const Plugins,
    req: *router.Request,
    state: *RequestState(Plugins),
) !void {
    const fields = std.meta.fields(Plugins);
    var initialized = [1]bool{false} ** fields.len;

    errdefer {
        inline for (0..fields.len) |rev_offset| {
            const idx = fields.len - 1 - rev_offset;
            const f = fields[idx];
            const PT = f.type;
            if (initialized[idx] and @hasDecl(PT, "deinitRequest")) {
                @field(plugins, f.name).deinitRequest(&@field(state, f.name));
            }
        }
    }

    inline for (fields, 0..) |f, idx| {
        const PT = f.type;
        if (@hasDecl(PT, "State") and PT.State != void and @hasDecl(PT, "initRequest")) {
            const plugin_ptr = &@field(plugins, f.name);
            @field(state, f.name) = try plugin_ptr.initRequest(req);
            initialized[idx] = true;
        }
    }
}

/// Deinitializes the per-request state for `Plugins` in reverse declaration
/// order. Cleanup is infallible and does not write responses.
pub fn deinitRequestState(
    comptime Plugins: type,
    plugins: *const Plugins,
    state: *RequestState(Plugins),
) void {
    const fields = std.meta.fields(Plugins);
    inline for (0..fields.len) |rev_offset| {
        const idx = fields.len - 1 - rev_offset;
        const f = fields[idx];
        const PT = f.type;
        if (@hasDecl(PT, "State") and PT.State != void and @hasDecl(PT, "deinitRequest")) {
            @field(plugins, f.name).deinitRequest(&@field(state, f.name));
        }
    }
}

/// Returned by `Next.call` when a continuation is invoked more than once
/// (ADR-0001 §3.6). Downstream middleware and the route do not run again.
pub const NextError = error{NextAlreadyCalled};

/// A typed application: `Plugins` is a struct of plugin instances, and the
/// route receives a typed context exposing those instances, application
/// configuration, and per-request state.
///
/// Middleware (ADR-0001 §3.3, §3.6) is configured per app with `init`. Each
/// request enters the entries in registration order and unwinds in reverse;
/// the innermost continuation runs the route and the default 404.
pub fn App(comptime Plugins: type) type {
    return struct {
        const Self = @This();
        pub const State = RequestState(Plugins);
        pub const Context = struct {
            plugins: *const Plugins,
            config: *const AppConfig,
            state: *State,
        };
        pub const RouteFn = *const fn (*Context, *router.Request, *response.Response) anyerror!void;

        /// Single-use continuation handed to a middleware entry. Copies share
        /// one private invocation frame, so they also share its `called` flag:
        /// the first `call` runs the rest of the chain, and any later call on
        /// the same continuation or a copy returns `error.NextAlreadyCalled`
        /// without re-executing downstream code.
        ///
        /// A `Next` is valid only while the middleware invocation that
        /// received it is running. It must not be stored, returned, or called
        /// after that invocation returns, and must not be called concurrently
        /// from another thread. Zig cannot enforce this; it is a caller
        /// obligation.
        pub const Next = struct {
            frame: *anyopaque,
            invoke: *const fn (*anyopaque, *Context, *router.Request, *response.Response) anyerror!void,

            pub fn call(self: Next, ctx: *Context, req: *router.Request, res: *response.Response) anyerror!void {
                return self.invoke(self.frame, ctx, req, res);
            }
        };

        /// A configured middleware entry. `config` is passed back to `invoke`
        /// unchanged; it is caller-owned, must stay immutable, and must remain
        /// valid until the app is shut down with `deinit`.
        ///
        /// `invoke` short-circuits by returning without calling `next`. It
        /// should run success post-processing only after `try next.call(...)`
        /// succeeds, and use `defer` for cleanup that must also run on errors.
        pub const Middleware = struct {
            config: *const anyopaque,
            invoke: *const fn (
                *const anyopaque,
                *Context,
                *router.Request,
                *response.Response,
                Next,
            ) anyerror!void,
        };

        /// Private per-invocation frame shared by every copy of one `Next`.
        const Frame = struct {
            app: *const Self,
            next_index: usize,
            called: bool = false,
        };

        pub const Options = struct {
            response_allocator: std.mem.Allocator,
            config: AppConfig = .{},
            plugins: Plugins,
            route_fn: RouteFn,
            /// Ordered entries; the first is outermost. `init` copies this
            /// slice, so the caller's array may be reused afterwards.
            middleware: []const Middleware = &.{},
        };

        response_allocator: std.mem.Allocator,
        config: AppConfig,
        plugins: Plugins,
        route_fn: RouteFn,
        /// App-owned copy of the ordered middleware entries; set by `init`.
        middleware: []const Middleware = &.{},
        /// Allocator that owns `middleware`; null when no copy was made.
        middleware_allocator: ?std.mem.Allocator = null,

        /// Builds an app and copies the ordered middleware entry list into
        /// storage owned by `allocator`. The entries' configuration objects
        /// are not copied; they stay caller-owned until `deinit`.
        pub fn init(allocator: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Self {
            const entries = try allocator.dupe(Middleware, options.middleware);
            return .{
                .response_allocator = options.response_allocator,
                .config = options.config,
                .plugins = options.plugins,
                .route_fn = options.route_fn,
                .middleware = entries,
                .middleware_allocator = allocator,
            };
        }

        /// Shuts the app down and releases the copied entry list. No dispatch
        /// may be running or start afterwards.
        pub fn deinit(self: *Self) void {
            if (self.middleware_allocator) |allocator| allocator.free(self.middleware);
            self.* = undefined;
        }

        /// Dispatches a request through the middleware chain and route, and
        /// returns an independently owned response. The caller owns `req` and
        /// must keep it alive until `dispatch` returns; the returned response
        /// must be released with `res.deinit()`.
        pub fn dispatch(self: *const Self, req: *router.Request) !response.Response {
            var state: State = undefined;
            try initRequestState(Plugins, &self.plugins, req, &state);
            defer deinitRequestState(Plugins, &self.plugins, &state);

            var ctx = Context{
                .plugins = &self.plugins,
                .config = &self.config,
                .state = &state,
            };
            var res = response.Response.init(self.response_allocator);
            errdefer res.deinit();
            try self.runFrom(0, &ctx, req, &res);
            // A middleware short circuit can leave the response unhandled.
            if (!res.handled) try res.text(404, "Not Found");
            return res;
        }

        fn runFrom(
            self: *const Self,
            index: usize,
            ctx: *Context,
            req: *router.Request,
            res: *response.Response,
        ) anyerror!void {
            if (index == self.middleware.len) {
                // Terminal continuation: route, then the default 404 before
                // control returns to middleware.
                try self.route_fn(ctx, req, res);
                if (!res.handled) try res.text(404, "Not Found");
                return;
            }
            const entry = self.middleware[index];
            var frame = Frame{ .app = self, .next_index = index + 1 };
            return entry.invoke(entry.config, ctx, req, res, .{ .frame = &frame, .invoke = invokeNext });
        }

        fn invokeNext(
            opaque_frame: *anyopaque,
            ctx: *Context,
            req: *router.Request,
            res: *response.Response,
        ) anyerror!void {
            const frame: *Frame = @ptrCast(@alignCast(opaque_frame));
            if (frame.called) return error.NextAlreadyCalled;
            frame.called = true;
            return frame.app.runFrom(frame.next_index, ctx, req, res);
        }
    };
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

const TrackingPlugin = struct {
    tag: u8,
    init_order: *std.ArrayList(u8),
    deinit_order: *std.ArrayList(u8),
    call_count: *usize,
    fail_after: ?usize,

    pub const State = struct { tag: u8 };

    pub fn initRequest(self: *const @This(), _: *router.Request) !State {
        self.call_count.* += 1;
        if (self.fail_after) |limit| {
            if (self.call_count.* > limit) return error.TestInitFail;
        }
        try self.init_order.append(std.testing.allocator, self.tag);
        return .{ .tag = self.tag };
    }

    pub fn deinitRequest(self: *const @This(), state: *State) void {
        self.deinit_order.append(std.testing.allocator, state.tag) catch unreachable;
    }
};

fn makeTrackingPlugin(
    tag: u8,
    init_order: *std.ArrayList(u8),
    deinit_order: *std.ArrayList(u8),
    call_count: *usize,
    fail_after: ?usize,
) TrackingPlugin {
    return .{
        .tag = tag,
        .init_order = init_order,
        .deinit_order = deinit_order,
        .call_count = call_count,
        .fail_after = fail_after,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "request state initializes in order and cleans up in reverse on failure" {
    var init_order: std.ArrayList(u8) = .empty;
    defer init_order.deinit(std.testing.allocator);
    var deinit_order: std.ArrayList(u8) = .empty;
    defer deinit_order.deinit(std.testing.allocator);

    var alpha_calls: usize = 0;
    var beta_calls: usize = 0;
    var gamma_calls: usize = 0;

    const Plugins = struct {
        alpha: TrackingPlugin,
        beta: TrackingPlugin,
        gamma: TrackingPlugin,
    };
    const plugins = Plugins{
        .alpha = makeTrackingPlugin('A', &init_order, &deinit_order, &alpha_calls, null),
        .beta = makeTrackingPlugin('B', &init_order, &deinit_order, &beta_calls, null),
        .gamma = makeTrackingPlugin('G', &init_order, &deinit_order, &gamma_calls, 0),
    };

    const State = RequestState(Plugins);
    var req_arena = try request.parseOriginForm(std.testing.allocator, .default, "/");
    defer req_arena.deinit();
    var req = req_arena.requestView(.get);

    var state: State = undefined;
    const result = initRequestState(Plugins, &plugins, &req, &state);
    try std.testing.expectError(error.TestInitFail, result);
    try std.testing.expectEqualSlices(u8, "AB", init_order.items);
    try std.testing.expectEqualSlices(u8, "BA", deinit_order.items);
}

test "demo app route outcomes" {
    const User = struct { id: []const u8, name: []const u8 };
    const Plugins = struct { json: Json = .{} };
    const Demo = App(Plugins);

    const route = struct {
        fn run(ctx: *Demo.Context, req: *router.Request, res: *response.Response) !void {
            if (req.isRoot() and req.isGet()) return res.text(200, "hello from zoda");
            if (req.onLiteral("users")) {
                if (req.onSegment()) |id| {
                    if (req.isRoot() and req.isGet()) {
                        return ctx.plugins.json.render(res, User, .{ .id = id, .name = "unknown" });
                    }
                }
                return;
            }
        }
    }.run;

    const app = Demo{
        .response_allocator = std.testing.allocator,
        .config = .{ .name = "demo" },
        .plugins = .{},
        .route_fn = route,
    };

    {
        var arena = try request.parseOriginForm(std.testing.allocator, .default, "/");
        defer arena.deinit();
        var req = arena.requestView(.get);
        var res = try app.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 200), res.status_code);
        try std.testing.expectEqualStrings("hello from zoda", res.body);
        try std.testing.expectEqualStrings("text/plain", res.content_type);
    }

    {
        var arena = try request.parseOriginForm(std.testing.allocator, .default, "/users/42");
        defer arena.deinit();
        var req = arena.requestView(.get);
        var res = try app.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 200), res.status_code);
        try std.testing.expectEqualStrings("application/json", res.content_type);
        try std.testing.expectEqualStrings("{\"id\":\"42\",\"name\":\"unknown\"}", res.body);
    }

    {
        var arena = try request.parseOriginForm(std.testing.allocator, .default, "/users");
        defer arena.deinit();
        var req = arena.requestView(.get);
        var res = try app.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 404), res.status_code);
        try std.testing.expectEqualStrings("text/plain", res.content_type);
        try std.testing.expectEqualStrings("Not Found", res.body);
    }

    {
        var arena = try request.parseOriginForm(std.testing.allocator, .default, "/users/42/extra");
        defer arena.deinit();
        var req = arena.requestView(.get);
        var res = try app.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 404), res.status_code);
        try std.testing.expectEqualStrings("text/plain", res.content_type);
        try std.testing.expectEqualStrings("Not Found", res.body);
    }

    {
        var arena = try request.parseOriginForm(std.testing.allocator, .default, "/users/42/");
        defer arena.deinit();
        var req = arena.requestView(.get);
        var res = try app.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 404), res.status_code);
        try std.testing.expectEqualStrings("text/plain", res.content_type);
        try std.testing.expectEqualStrings("Not Found", res.body);
    }

    {
        var arena = try request.parseOriginForm(std.testing.allocator, .default, "/users/42");
        defer arena.deinit();
        var req = arena.requestView(.post);
        var res = try app.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 404), res.status_code);
        try std.testing.expectEqualStrings("text/plain", res.content_type);
        try std.testing.expectEqualStrings("Not Found", res.body);
    }
}

test "two differently configured apps are independent" {
    const Plugins = struct { json: Json = .{} };
    const Demo = App(Plugins);

    const route = struct {
        fn run(ctx: *Demo.Context, req: *router.Request, res: *response.Response) !void {
            if (req.isRoot() and req.isGet()) return res.text(200, ctx.config.name);
        }
    }.run;

    const app_a = Demo{
        .response_allocator = std.testing.allocator,
        .config = .{ .name = "alpha" },
        .plugins = .{},
        .route_fn = route,
    };
    const app_b = Demo{
        .response_allocator = std.testing.allocator,
        .config = .{ .name = "beta" },
        .plugins = .{},
        .route_fn = route,
    };

    {
        var arena = try request.parseOriginForm(std.testing.allocator, .default, "/");
        defer arena.deinit();
        var req = arena.requestView(.get);
        var res = try app_a.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqualStrings("alpha", res.body);
    }

    {
        var arena = try request.parseOriginForm(std.testing.allocator, .default, "/");
        defer arena.deinit();
        var req = arena.requestView(.get);
        var res = try app_b.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqualStrings("beta", res.body);
    }
}

test "sequential requests through one app get distinct per-request state" {
    // A small configured stateful plugin whose per-request state captures the
    // request's `v` query value. Two dispatches through the same app must each
    // initialize, use, and clean up their own state with no leakage between
    // requests (ADR-0001 §3.2).
    const Capture = struct {
        deinit_order: *std.ArrayList([]const u8),
        init_calls: *usize,

        pub const State = struct { value: []const u8 };

        pub fn initRequest(self: *const @This(), req: *router.Request) !State {
            self.init_calls.* += 1;
            const value = (try req.getOne("v")) orelse "";
            return .{ .value = value };
        }

        pub fn deinitRequest(self: *const @This(), state: *State) void {
            // Copy the arena-borrowed value so the recorded entry stays valid
            // after the request arena is destroyed.
            const owned = std.testing.allocator.dupe(u8, state.value) catch unreachable;
            self.deinit_order.append(std.testing.allocator, owned) catch unreachable;
        }
    };

    var deinit_order: std.ArrayList([]const u8) = .empty;
    defer deinit_order.deinit(std.testing.allocator);
    defer for (deinit_order.items) |value| std.testing.allocator.free(value);
    var init_calls: usize = 0;

    const Plugins = struct { cap: Capture };
    const CapApp = App(Plugins);

    const route = struct {
        fn run(ctx: *CapApp.Context, req: *router.Request, res: *response.Response) !void {
            if (req.isRoot() and req.isGet()) {
                return res.text(200, ctx.state.cap.value);
            }
        }
    }.run;

    const app = CapApp{
        .response_allocator = std.testing.allocator,
        .config = .{},
        .plugins = .{ .cap = .{ .deinit_order = &deinit_order, .init_calls = &init_calls } },
        .route_fn = route,
    };

    {
        var arena = try request.parseOriginForm(std.testing.allocator, .default, "/?v=first");
        defer arena.deinit();
        var req = arena.requestView(.get);
        var res = try app.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqualStrings("first", res.body);
    }

    {
        var arena = try request.parseOriginForm(std.testing.allocator, .default, "/?v=second");
        defer arena.deinit();
        var req = arena.requestView(.get);
        var res = try app.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqualStrings("second", res.body);
    }

    // Both requests initialized their own state and each one was released when
    // its own dispatch unwound; neither request read the other's value.
    try std.testing.expectEqual(@as(usize, 2), init_calls);
    try std.testing.expectEqual(@as(usize, 2), deinit_order.items.len);
    try std.testing.expectEqualStrings("first", deinit_order.items[0]);
    try std.testing.expectEqualStrings("second", deinit_order.items[1]);
}

test "state cleanup runs after handler failure" {
    var init_dummy: std.ArrayList(u8) = .empty;
    defer init_dummy.deinit(std.testing.allocator);
    var deinit_order: std.ArrayList(u8) = .empty;
    defer deinit_order.deinit(std.testing.allocator);
    var calls: usize = 0;

    const Plugins = struct { track: TrackingPlugin };
    const FailApp = App(Plugins);

    const route = struct {
        fn run(_: *FailApp.Context, _: *router.Request, res: *response.Response) !void {
            // Write a partial response, then fail: dispatch must release the
            // response storage as well as the request state on the way out.
            try res.text(500, "partial");
            try res.setHeader("X-Trace", "abc");
            return error.Boom;
        }
    }.run;

    const plugins = Plugins{
        .track = makeTrackingPlugin('X', &init_dummy, &deinit_order, &calls, null),
    };
    const app = FailApp{
        .response_allocator = std.testing.allocator,
        .config = .{},
        .plugins = plugins,
        .route_fn = route,
    };

    var arena = try request.parseOriginForm(std.testing.allocator, .default, "/");
    defer arena.deinit();
    var req = arena.requestView(.get);
    try std.testing.expectError(error.Boom, app.dispatch(&req));
    try std.testing.expectEqualSlices(u8, "X", deinit_order.items);
    // `std.testing.allocator` reports a leak if the partial response body and
    // header are not released when dispatch unwinds after the handler error.
}

test "response remains valid after the request arena is destroyed" {
    const User = struct { id: []const u8, name: []const u8 };
    const Plugins = struct { json: Json = .{} };
    const Demo = App(Plugins);

    const route = struct {
        fn run(ctx: *Demo.Context, req: *router.Request, res: *response.Response) !void {
            if (req.onLiteral("users")) {
                if (req.onSegment()) |id| {
                    if (req.isRoot() and req.isGet()) {
                        return ctx.plugins.json.render(res, User, .{ .id = id, .name = "unknown" });
                    }
                }
            }
        }
    }.run;

    const app = Demo{
        .response_allocator = std.testing.allocator,
        .config = .{},
        .plugins = .{},
        .route_fn = route,
    };

    var res: response.Response = undefined;
    {
        var arena = try request.parseOriginForm(std.testing.allocator, .default, "/users/42");
        defer arena.deinit();
        var req = arena.requestView(.get);
        res = try app.dispatch(&req);
    }
    defer res.deinit();
    try std.testing.expectEqualStrings("{\"id\":\"42\",\"name\":\"unknown\"}", res.body);
}

test "stateless json plugin leaves request state empty" {
    const Plugins = struct { json: Json = .{} };
    const State = RequestState(Plugins);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(State));
}

// ---------------------------------------------------------------------------
// Middleware (ADR-0001 §3.3, §3.5, §3.6)
// ---------------------------------------------------------------------------

const MwPlugins = struct { json: Json = .{} };
const MwApp = App(MwPlugins);

/// Test middleware configuration. The configuration itself is immutable; the
/// log it points at is an external resource owned by the test.
const LogConfig = struct {
    enter: u8,
    exit: u8,
    log: *std.ArrayList(u8),
};

fn logMiddleware(
    raw: *const anyopaque,
    ctx: *MwApp.Context,
    req: *router.Request,
    res: *response.Response,
    next: MwApp.Next,
) anyerror!void {
    const cfg: *const LogConfig = @ptrCast(@alignCast(raw));
    try cfg.log.append(std.testing.allocator, cfg.enter);
    // Cleanup via defer runs on success and error.
    defer cfg.log.append(std.testing.allocator, cfg.exit) catch unreachable;
    try next.call(ctx, req, res);
}

fn logEntry(cfg: *const LogConfig) MwApp.Middleware {
    return .{ .config = cfg, .invoke = logMiddleware };
}

fn dispatchPath(app: *const MwApp, method: router.Method, path: []const u8) !response.Response {
    var arena = try request.parseOriginForm(std.testing.allocator, .default, path);
    defer arena.deinit();
    var req = arena.requestView(method);
    return app.dispatch(&req);
}

const route_log = struct {
    var log: ?*std.ArrayList(u8) = null;

    fn run(_: *MwApp.Context, req: *router.Request, res: *response.Response) !void {
        if (log) |l| try l.append(std.testing.allocator, 'R');
        if (req.isRoot() and req.isGet()) return res.text(200, "root");
        if (req.isLiteral("boom")) return error.Boom;
    }
};

test "middleware enters in registration order and unwinds in reverse" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(std.testing.allocator);
    route_log.log = &log;
    defer route_log.log = null;

    const a = LogConfig{ .enter = 'a', .exit = 'A', .log = &log };
    const b = LogConfig{ .enter = 'b', .exit = 'B', .log = &log };
    const c = LogConfig{ .enter = 'c', .exit = 'C', .log = &log };

    var app = try MwApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{},
        .route_fn = route_log.run,
        .middleware = &.{ logEntry(&a), logEntry(&b), logEntry(&c) },
    });
    defer app.deinit();

    var res = try dispatchPath(&app, .get, "/");
    defer res.deinit();
    try std.testing.expectEqualStrings("root", res.body);
    try std.testing.expectEqualStrings("abcRCBA", log.items);
}

test "app copies the entry list but borrows caller-owned configuration" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(std.testing.allocator);

    const a = LogConfig{ .enter = 'a', .exit = 'A', .log = &log };
    const b = LogConfig{ .enter = 'b', .exit = 'B', .log = &log };

    var entries = [_]MwApp.Middleware{ logEntry(&a), logEntry(&b) };
    var app = try MwApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{},
        .route_fn = route_log.run,
        .middleware = &entries,
    });
    defer app.deinit();

    // Reusing the caller's array after init must not change the app's order.
    entries = .{ logEntry(&b), logEntry(&b) };

    try std.testing.expect(app.middleware.ptr != &entries);
    // Configuration objects are borrowed, not copied.
    try std.testing.expectEqual(@as(*const anyopaque, &a), app.middleware[0].config);

    var res = try dispatchPath(&app, .get, "/");
    defer res.deinit();
    try std.testing.expectEqualStrings("abBA", log.items);
}

test "app without middleware dispatches straight to the route" {
    var app = try MwApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{},
        .route_fn = route_log.run,
    });
    defer app.deinit();

    var ok = try dispatchPath(&app, .get, "/");
    defer ok.deinit();
    try std.testing.expectEqualStrings("root", ok.body);

    var missing = try dispatchPath(&app, .get, "/nope");
    defer missing.deinit();
    try std.testing.expectEqual(@as(u16, 404), missing.status_code);
}

test "short circuit skips downstream middleware and the route" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(std.testing.allocator);
    route_log.log = &log;
    defer route_log.log = null;

    const Deny = struct {
        log: *std.ArrayList(u8),
        respond: bool,

        fn invoke(
            raw: *const anyopaque,
            _: *MwApp.Context,
            _: *router.Request,
            res: *response.Response,
            _: MwApp.Next,
        ) anyerror!void {
            const cfg: *const @This() = @ptrCast(@alignCast(raw));
            try cfg.log.append(std.testing.allocator, 'x');
            if (cfg.respond) try res.text(401, "denied");
        }
    };

    const outer = LogConfig{ .enter = 'a', .exit = 'A', .log = &log };
    const inner = LogConfig{ .enter = 'c', .exit = 'C', .log = &log };

    {
        const deny = Deny{ .log = &log, .respond = true };
        var app = try MwApp.init(std.testing.allocator, .{
            .response_allocator = std.testing.allocator,
            .plugins = .{},
            .route_fn = route_log.run,
            .middleware = &.{
                logEntry(&outer),
                .{ .config = &deny, .invoke = Deny.invoke },
                logEntry(&inner),
            },
        });
        defer app.deinit();

        var res = try dispatchPath(&app, .get, "/");
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 401), res.status_code);
        try std.testing.expectEqualStrings("denied", res.body);
        try std.testing.expectEqualStrings("axA", log.items);
    }

    log.clearRetainingCapacity();

    {
        // An unhandled short circuit still gets dispatch's fallback 404.
        const silent = Deny{ .log = &log, .respond = false };
        var app = try MwApp.init(std.testing.allocator, .{
            .response_allocator = std.testing.allocator,
            .plugins = .{},
            .route_fn = route_log.run,
            .middleware = &.{ logEntry(&outer), .{ .config = &silent, .invoke = Deny.invoke } },
        });
        defer app.deinit();

        var res = try dispatchPath(&app, .get, "/");
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 404), res.status_code);
        try std.testing.expectEqualStrings("Not Found", res.body);
        try std.testing.expectEqualStrings("axA", log.items);
    }
}

test "a second next call is rejected before downstream runs again" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(std.testing.allocator);
    route_log.log = &log;
    defer route_log.log = null;

    const Twice = struct {
        log: *std.ArrayList(u8),
        use_copy: bool,
        swallow: bool,

        fn invoke(
            raw: *const anyopaque,
            ctx: *MwApp.Context,
            req: *router.Request,
            res: *response.Response,
            next: MwApp.Next,
        ) anyerror!void {
            const cfg: *const @This() = @ptrCast(@alignCast(raw));
            const copy = next;
            try next.call(ctx, req, res);
            const second = if (cfg.use_copy) copy.call(ctx, req, res) else next.call(ctx, req, res);
            if (cfg.swallow) {
                try std.testing.expectError(error.NextAlreadyCalled, second);
                try cfg.log.append(std.testing.allocator, '!');
            } else {
                try second;
            }
        }
    };

    const inner = LogConfig{ .enter = 'c', .exit = 'C', .log = &log };

    inline for (.{ false, true }) |use_copy| {
        log.clearRetainingCapacity();
        const twice = Twice{ .log = &log, .use_copy = use_copy, .swallow = true };
        var app = try MwApp.init(std.testing.allocator, .{
            .response_allocator = std.testing.allocator,
            .plugins = .{},
            .route_fn = route_log.run,
            .middleware = &.{ .{ .config = &twice, .invoke = Twice.invoke }, logEntry(&inner) },
        });
        defer app.deinit();

        var res = try dispatchPath(&app, .get, "/");
        defer res.deinit();
        try std.testing.expectEqualStrings("root", res.body);
        // Downstream ran exactly once; the rejected call produced no `cRC`.
        try std.testing.expectEqualStrings("cRC!", log.items);
    }

    {
        // Unrecovered, the error propagates out of dispatch.
        log.clearRetainingCapacity();
        const twice = Twice{ .log = &log, .use_copy = false, .swallow = false };
        var app = try MwApp.init(std.testing.allocator, .{
            .response_allocator = std.testing.allocator,
            .plugins = .{},
            .route_fn = route_log.run,
            .middleware = &.{ .{ .config = &twice, .invoke = Twice.invoke }, logEntry(&inner) },
        });
        defer app.deinit();

        try std.testing.expectError(error.NextAlreadyCalled, dispatchPath(&app, .get, "/"));
        try std.testing.expectEqualStrings("cRC", log.items);
    }
}

test "errors propagate and skip success post-processing but run deferred cleanup" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(std.testing.allocator);
    route_log.log = &log;
    defer route_log.log = null;

    const PostProcess = struct {
        log: *std.ArrayList(u8),

        fn invoke(
            raw: *const anyopaque,
            ctx: *MwApp.Context,
            req: *router.Request,
            res: *response.Response,
            next: MwApp.Next,
        ) anyerror!void {
            const cfg: *const @This() = @ptrCast(@alignCast(raw));
            defer cfg.log.append(std.testing.allocator, 'd') catch unreachable;
            try next.call(ctx, req, res);
            // Ordinary success post-processing.
            try res.setHeader("X-Post", "yes");
            try cfg.log.append(std.testing.allocator, 'p');
        }
    };

    const post = PostProcess{ .log = &log };
    const outer = LogConfig{ .enter = 'a', .exit = 'A', .log = &log };
    var app = try MwApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{},
        .route_fn = route_log.run,
        .middleware = &.{ logEntry(&outer), .{ .config = &post, .invoke = PostProcess.invoke } },
    });
    defer app.deinit();

    {
        var res = try dispatchPath(&app, .get, "/");
        defer res.deinit();
        try std.testing.expectEqualStrings("yes", (try res.getHeaderOne("x-post")).?);
        try std.testing.expectEqualStrings("aRpdA", log.items);
    }

    log.clearRetainingCapacity();

    // The route fails: no post-processing, cleanup still runs in reverse, and
    // the partial response is released (the testing allocator checks leaks).
    try std.testing.expectError(error.Boom, dispatchPath(&app, .get, "/boom"));
    try std.testing.expectEqualStrings("aRdA", log.items);
}

test "middleware recovering an error replaces the partial response" {
    const Recover = struct {
        fn invoke(
            _: *const anyopaque,
            ctx: *MwApp.Context,
            req: *router.Request,
            res: *response.Response,
            next: MwApp.Next,
        ) anyerror!void {
            next.call(ctx, req, res) catch |err| {
                res.clear();
                try res.text(503, @errorName(err));
            };
        }
    };
    const route = struct {
        fn run(_: *MwApp.Context, _: *router.Request, res: *response.Response) !void {
            try res.text(200, "partial");
            try res.setHeader("X-Partial", "1");
            return error.Unavailable;
        }
    }.run;

    const unused: u8 = 0;
    var app = try MwApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{},
        .route_fn = route,
        .middleware = &.{.{ .config = &unused, .invoke = Recover.invoke }},
    });
    defer app.deinit();

    var res = try dispatchPath(&app, .get, "/");
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 503), res.status_code);
    try std.testing.expectEqualStrings("Unavailable", res.body);
    try std.testing.expectEqual(@as(usize, 0), res.header_count);
}

test "terminal continuation applies the default 404 before middleware unwinds" {
    const Observe = struct {
        seen: *?u16,

        fn invoke(
            raw: *const anyopaque,
            ctx: *MwApp.Context,
            req: *router.Request,
            res: *response.Response,
            next: MwApp.Next,
        ) anyerror!void {
            const cfg: *const @This() = @ptrCast(@alignCast(raw));
            try next.call(ctx, req, res);
            cfg.seen.* = if (res.handled) res.status_code else null;
            try res.setHeader("X-Seen", "1");
        }
    };

    var seen: ?u16 = null;
    const observe = Observe{ .seen = &seen };
    var app = try MwApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{},
        .route_fn = route_log.run,
        .middleware = &.{.{ .config = &observe, .invoke = Observe.invoke }},
    });
    defer app.deinit();

    var res = try dispatchPath(&app, .get, "/missing");
    defer res.deinit();
    try std.testing.expectEqual(@as(?u16, 404), seen);
    try std.testing.expectEqual(@as(u16, 404), res.status_code);
    // Middleware decorated the default 404 on the way out.
    try std.testing.expectEqualStrings("1", (try res.getHeaderOne("x-seen")).?);
}

test "middleware shares the per-request context and plugin state" {
    const Tag = struct {
        pub const State = struct { value: []const u8 };
        pub fn initRequest(_: *const @This(), req: *router.Request) !State {
            return .{ .value = (try req.getOne("v")) orelse "" };
        }
        pub fn deinitRequest(_: *const @This(), _: *State) void {}
    };
    const Plugins = struct { tag: Tag = .{} };
    const TagApp = App(Plugins);

    const Echo = struct {
        fn invoke(
            _: *const anyopaque,
            ctx: *TagApp.Context,
            req: *router.Request,
            res: *response.Response,
            next: TagApp.Next,
        ) anyerror!void {
            try next.call(ctx, req, res);
            try res.setHeader("X-App", ctx.config.name);
            try res.setHeader("X-Tag", ctx.state.tag.value);
        }
    };
    const route = struct {
        fn run(ctx: *TagApp.Context, _: *router.Request, res: *response.Response) !void {
            return res.text(200, ctx.state.tag.value);
        }
    }.run;

    const unused: u8 = 0;
    var app = try TagApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .config = .{ .name = "tagged" },
        .plugins = .{},
        .route_fn = route,
        .middleware = &.{.{ .config = &unused, .invoke = Echo.invoke }},
    });
    defer app.deinit();

    var arena = try request.parseOriginForm(std.testing.allocator, .default, "/?v=seven");
    defer arena.deinit();
    var req = arena.requestView(.get);
    var res = try app.dispatch(&req);
    defer res.deinit();
    try std.testing.expectEqualStrings("seven", res.body);
    try std.testing.expectEqualStrings("tagged", (try res.getHeaderOne("x-app")).?);
    try std.testing.expectEqualStrings("seven", (try res.getHeaderOne("x-tag")).?);
}

test "concurrent requests use independent continuation frames" {
    // Each middleware invocation calls `next` once and then checks that a
    // second call is rejected. If frames or `called` flags were shared across
    // requests, a concurrent request's first call would be rejected too.
    const Guard = struct {
        fn invoke(
            _: *const anyopaque,
            ctx: *MwApp.Context,
            req: *router.Request,
            res: *response.Response,
            next: MwApp.Next,
        ) anyerror!void {
            try next.call(ctx, req, res);
            next.call(ctx, req, res) catch |err| switch (err) {
                error.NextAlreadyCalled => return,
                else => return err,
            };
            return error.SecondCallAccepted;
        }
    };
    const route = struct {
        fn run(_: *MwApp.Context, req: *router.Request, res: *response.Response) !void {
            const v = (try req.getOne("v")) orelse "";
            return res.text(200, v);
        }
    }.run;

    const gpa = std.heap.smp_allocator;
    const unused: u8 = 0;
    var app = try MwApp.init(gpa, .{
        .response_allocator = gpa,
        .plugins = .{},
        .route_fn = route,
        .middleware = &.{
            .{ .config = &unused, .invoke = Guard.invoke },
            .{ .config = &unused, .invoke = Guard.invoke },
        },
    });
    defer app.deinit();

    const Worker = struct {
        fn run(a: *const MwApp, id: usize, failures: *std.atomic.Value(usize)) void {
            var buf: [32]u8 = undefined;
            for (0..500) |i| {
                const path = std.fmt.bufPrint(&buf, "/?v={d}-{d}", .{ id, i }) catch unreachable;
                const ok = check(a, path) catch false;
                if (!ok) _ = failures.fetchAdd(1, .monotonic);
            }
        }

        fn check(a: *const MwApp, path: []const u8) !bool {
            var arena = try request.parseOriginForm(gpa, .default, path);
            defer arena.deinit();
            var req = arena.requestView(.get);
            var res = try a.dispatch(&req);
            defer res.deinit();
            return res.status_code == 200 and std.mem.eql(u8, res.body, path["/?v=".len..]);
        }
    };

    var failures = std.atomic.Value(usize).init(0);
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, id| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &app, id, &failures });
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(usize, 0), failures.load(.monotonic));
}

// ---------------------------------------------------------------------------
// Middleware verification (issue #23): nested chains, errors, recovery, 404
// visibility, configuration lifetimes, and concurrent isolation.
// ---------------------------------------------------------------------------

/// Short-circuits without calling `next`, optionally writing a response.
const DenyConfig = struct {
    log: *std.ArrayList(u8),
    respond: bool,

    fn invoke(
        raw: *const anyopaque,
        _: *MwApp.Context,
        _: *router.Request,
        res: *response.Response,
        _: MwApp.Next,
    ) anyerror!void {
        const cfg: *const DenyConfig = @ptrCast(@alignCast(raw));
        try cfg.log.append(std.testing.allocator, 'x');
        if (cfg.respond) try res.text(401, "denied");
    }

    fn entry(cfg: *const DenyConfig) MwApp.Middleware {
        return .{ .config = cfg, .invoke = invoke };
    }
};

/// Records the status this entry observes after `next` returns; 0 means the
/// response was still unhandled.
const SeenConfig = struct {
    seen: *u16,

    fn invoke(
        raw: *const anyopaque,
        ctx: *MwApp.Context,
        req: *router.Request,
        res: *response.Response,
        next: MwApp.Next,
    ) anyerror!void {
        const cfg: *const SeenConfig = @ptrCast(@alignCast(raw));
        try next.call(ctx, req, res);
        cfg.seen.* = if (res.handled) res.status_code else 0;
    }

    fn entry(cfg: *const SeenConfig) MwApp.Middleware {
        return .{ .config = cfg, .invoke = invoke };
    }
};

/// Writes a partial header, then fails before or after `next`.
const FailConfig = struct {
    log: *std.ArrayList(u8),
    before_next: bool,

    fn invoke(
        raw: *const anyopaque,
        ctx: *MwApp.Context,
        req: *router.Request,
        res: *response.Response,
        next: MwApp.Next,
    ) anyerror!void {
        const cfg: *const FailConfig = @ptrCast(@alignCast(raw));
        defer cfg.log.append(std.testing.allocator, 'd') catch unreachable;
        try res.setHeader("X-Partial", "1");
        if (cfg.before_next) return error.Rejected;
        try next.call(ctx, req, res);
        return error.PostFailed;
    }

    fn entry(cfg: *const FailConfig) MwApp.Middleware {
        return .{ .config = cfg, .invoke = invoke };
    }
};

test "nested short circuits unwind every outer entry and leave the 404 to dispatch" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(std.testing.allocator);
    route_log.log = &log;
    defer route_log.log = null;

    const a = LogConfig{ .enter = 'a', .exit = 'A', .log = &log };
    const b = LogConfig{ .enter = 'b', .exit = 'B', .log = &log };
    const c = LogConfig{ .enter = 'c', .exit = 'C', .log = &log };

    inline for (.{ true, false }) |respond| {
        log.clearRetainingCapacity();
        var seen: u16 = 999;
        const outer = SeenConfig{ .seen = &seen };
        const deny = DenyConfig{ .log = &log, .respond = respond };
        var app = try MwApp.init(std.testing.allocator, .{
            .response_allocator = std.testing.allocator,
            .plugins = .{},
            .route_fn = route_log.run,
            .middleware = &.{ SeenConfig.entry(&outer), logEntry(&a), logEntry(&b), DenyConfig.entry(&deny), logEntry(&c) },
        });
        defer app.deinit();

        var res = try dispatchPath(&app, .get, "/");
        defer res.deinit();
        // The third entry short-circuits: the fourth entry and the route never
        // run, and both outer entries unwind in reverse.
        try std.testing.expectEqualStrings("abxBA", log.items);
        if (respond) {
            try std.testing.expectEqual(@as(u16, 401), seen);
            try std.testing.expectEqual(@as(u16, 401), res.status_code);
            try std.testing.expectEqualStrings("denied", res.body);
        } else {
            // The terminal continuation never ran, so outer middleware sees an
            // unhandled response; dispatch applies the 404 after the chain.
            try std.testing.expectEqual(@as(u16, 0), seen);
            try std.testing.expectEqual(@as(u16, 404), res.status_code);
            try std.testing.expectEqualStrings("Not Found", res.body);
        }
    }
}

test "default 404 is visible to every nested entry while unwinding" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(std.testing.allocator);
    route_log.log = &log;
    defer route_log.log = null;

    var seen_outer: u16 = 0;
    var seen_inner: u16 = 0;
    const outer = SeenConfig{ .seen = &seen_outer };
    const inner = SeenConfig{ .seen = &seen_inner };
    const a = LogConfig{ .enter = 'a', .exit = 'A', .log = &log };
    var app = try MwApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{},
        .route_fn = route_log.run,
        .middleware = &.{ SeenConfig.entry(&outer), logEntry(&a), SeenConfig.entry(&inner) },
    });
    defer app.deinit();

    var res = try dispatchPath(&app, .get, "/missing");
    defer res.deinit();
    try std.testing.expectEqualStrings("aRA", log.items);
    try std.testing.expectEqual(@as(u16, 404), seen_inner);
    try std.testing.expectEqual(@as(u16, 404), seen_outer);
    try std.testing.expectEqualStrings("Not Found", res.body);
}

test "repeated next in a nested entry runs downstream once and leaves outer frames intact" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(std.testing.allocator);
    route_log.log = &log;
    defer route_log.log = null;

    const Repeat = struct {
        log: *std.ArrayList(u8),

        fn invoke(
            raw: *const anyopaque,
            ctx: *MwApp.Context,
            req: *router.Request,
            res: *response.Response,
            next: MwApp.Next,
        ) anyerror!void {
            const cfg: *const @This() = @ptrCast(@alignCast(raw));
            try next.call(ctx, req, res);
            // A copy taken after the first call shares the same frame.
            const copy = next;
            try std.testing.expectError(error.NextAlreadyCalled, copy.call(ctx, req, res));
            try std.testing.expectError(error.NextAlreadyCalled, next.call(ctx, req, res));
            try std.testing.expectError(error.NextAlreadyCalled, copy.call(ctx, req, res));
            try cfg.log.append(std.testing.allocator, '!');
        }
    };

    const a = LogConfig{ .enter = 'a', .exit = 'A', .log = &log };
    const c = LogConfig{ .enter = 'c', .exit = 'C', .log = &log };
    const d = LogConfig{ .enter = 'd', .exit = 'D', .log = &log };
    const repeat = Repeat{ .log = &log };
    const repeat_entry: MwApp.Middleware = .{ .config = &repeat, .invoke = Repeat.invoke };

    {
        // In the middle of the chain: the inner entries and the route run once.
        log.clearRetainingCapacity();
        var app = try MwApp.init(std.testing.allocator, .{
            .response_allocator = std.testing.allocator,
            .plugins = .{},
            .route_fn = route_log.run,
            .middleware = &.{ logEntry(&a), repeat_entry, logEntry(&c), logEntry(&d) },
        });
        defer app.deinit();

        var res = try dispatchPath(&app, .get, "/");
        defer res.deinit();
        try std.testing.expectEqualStrings("root", res.body);
        try std.testing.expectEqualStrings("acdRDC!A", log.items);
    }

    {
        // Innermost: the rejected calls do not reach the route again.
        log.clearRetainingCapacity();
        var app = try MwApp.init(std.testing.allocator, .{
            .response_allocator = std.testing.allocator,
            .plugins = .{},
            .route_fn = route_log.run,
            .middleware = &.{ logEntry(&a), repeat_entry },
        });
        defer app.deinit();

        var res = try dispatchPath(&app, .get, "/");
        defer res.deinit();
        try std.testing.expectEqualStrings("root", res.body);
        try std.testing.expectEqualStrings("aR!A", log.items);
    }
}

test "middleware errors before or after next propagate and release the response" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(std.testing.allocator);
    route_log.log = &log;
    defer route_log.log = null;

    const a = LogConfig{ .enter = 'a', .exit = 'A', .log = &log };

    {
        // Failing before `next` skips the route; outer cleanup still runs.
        const fail = FailConfig{ .log = &log, .before_next = true };
        var app = try MwApp.init(std.testing.allocator, .{
            .response_allocator = std.testing.allocator,
            .plugins = .{},
            .route_fn = route_log.run,
            .middleware = &.{ logEntry(&a), FailConfig.entry(&fail) },
        });
        defer app.deinit();

        log.clearRetainingCapacity();
        try std.testing.expectError(error.Rejected, dispatchPath(&app, .get, "/"));
        try std.testing.expectEqualStrings("adA", log.items);
    }

    {
        // Failing after the route wrote a body still releases the response.
        const fail = FailConfig{ .log = &log, .before_next = false };
        var app = try MwApp.init(std.testing.allocator, .{
            .response_allocator = std.testing.allocator,
            .plugins = .{},
            .route_fn = route_log.run,
            .middleware = &.{ logEntry(&a), FailConfig.entry(&fail) },
        });
        defer app.deinit();

        log.clearRetainingCapacity();
        try std.testing.expectError(error.PostFailed, dispatchPath(&app, .get, "/"));
        try std.testing.expectEqualStrings("aRdA", log.items);
    }
    // `std.testing.allocator` reports a leak if either partial response survives.
}

test "outer recovery clears an inner failure before replacing or falling back to 404" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(std.testing.allocator);
    route_log.log = &log;
    defer route_log.log = null;

    const Recover = struct {
        replace: bool,

        fn invoke(
            raw: *const anyopaque,
            ctx: *MwApp.Context,
            req: *router.Request,
            res: *response.Response,
            next: MwApp.Next,
        ) anyerror!void {
            const cfg: *const @This() = @ptrCast(@alignCast(raw));
            next.call(ctx, req, res) catch |err| {
                res.clear();
                if (cfg.replace) try res.text(503, @errorName(err));
            };
            // Post-processing continues after a recovery.
            try res.setHeader("X-Outer", "1");
        }
    };

    const fail = FailConfig{ .log = &log, .before_next = false };

    inline for (.{ true, false }) |replace| {
        log.clearRetainingCapacity();
        const recover = Recover{ .replace = replace };
        var app = try MwApp.init(std.testing.allocator, .{
            .response_allocator = std.testing.allocator,
            .plugins = .{},
            .route_fn = route_log.run,
            .middleware = &.{ .{ .config = &recover, .invoke = Recover.invoke }, FailConfig.entry(&fail) },
        });
        defer app.deinit();

        var res = try dispatchPath(&app, .get, "/");
        defer res.deinit();
        try std.testing.expectEqualStrings("Rd", log.items);
        // The inner header and the route's body were cleared.
        try std.testing.expect((try res.getHeaderOne("x-partial")) == null);
        try std.testing.expectEqualStrings("1", (try res.getHeaderOne("x-outer")).?);
        try std.testing.expectEqual(@as(usize, 1), res.header_count);
        if (replace) {
            try std.testing.expectEqual(@as(u16, 503), res.status_code);
            try std.testing.expectEqualStrings("PostFailed", res.body);
        } else {
            // Cleared without a replacement: dispatch's fallback 404 applies.
            try std.testing.expectEqual(@as(u16, 404), res.status_code);
            try std.testing.expectEqualStrings("Not Found", res.body);
        }
    }
}

// The README middleware example, with test-local type paths.
const ApiKey = struct { expected: []const u8 };

fn requireKey(
    raw: *const anyopaque,
    ctx: *MwApp.Context,
    req: *router.Request,
    res: *response.Response,
    next: MwApp.Next,
) anyerror!void {
    const cfg: *const ApiKey = @ptrCast(@alignCast(raw));
    const key = (try req.getHeaderOne("x-api-key")) orelse "";
    // Short circuit: return without calling `next`.
    if (!std.mem.eql(u8, key, cfg.expected)) return res.text(401, "unauthorized");

    try next.call(ctx, req, res);
    // Success post-processing runs only if `next.call` succeeded.
    try res.setHeader("X-Authenticated", "1");
}

/// Static configuration: lives for the whole program.
const static_key: ApiKey = .{ .expected = "static" };

fn dispatchWithKey(app: *const MwApp, path: []const u8, key: ?[]const u8) !response.Response {
    var arena = try request.parseOriginForm(std.testing.allocator, .default, path);
    defer arena.deinit();
    if (key) |k| try arena.copyHeaders(&.{.{ .name = "X-Api-Key", .value = k }});
    var req = arena.requestView(.get);
    return app.dispatch(&req);
}

test "configured middleware reads its own entry configuration" {
    const alpha: ApiKey = .{ .expected = "alpha" };
    const beta: ApiKey = .{ .expected = "beta" };

    // The same function in two apps with different configuration.
    var app_a = try MwApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{},
        .route_fn = route_log.run,
        .middleware = &.{.{ .config = &alpha, .invoke = requireKey }},
    });
    defer app_a.deinit();
    var app_b = try MwApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{},
        .route_fn = route_log.run,
        .middleware = &.{.{ .config = &beta, .invoke = requireKey }},
    });
    defer app_b.deinit();

    {
        var res = try dispatchWithKey(&app_a, "/", "alpha");
        defer res.deinit();
        try std.testing.expectEqualStrings("root", res.body);
        try std.testing.expectEqualStrings("1", (try res.getHeaderOne("x-authenticated")).?);
    }
    {
        var res = try dispatchWithKey(&app_b, "/", "alpha");
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 401), res.status_code);
        try std.testing.expect((try res.getHeaderOne("x-authenticated")) == null);
    }
    {
        var res = try dispatchWithKey(&app_b, "/", null);
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 401), res.status_code);
    }
    {
        // An authenticated miss is the default 404, decorated while unwinding.
        var res = try dispatchWithKey(&app_b, "/missing", "beta");
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 404), res.status_code);
        try std.testing.expectEqualStrings("1", (try res.getHeaderOne("x-authenticated")).?);
    }
}

test "supported configuration lifetimes: static, heap, shared, and a discarded entry array" {
    // Heap configuration freed after the app: this `defer` is registered
    // before `app.deinit()`, so it runs after it.
    const heap_key = try std.testing.allocator.create(ApiKey);
    defer std.testing.allocator.destroy(heap_key);
    heap_key.* = .{ .expected = "heap" };

    var static_app = blk: {
        var entries = [_]MwApp.Middleware{.{ .config = &static_key, .invoke = requireKey }};
        const app = try MwApp.init(std.testing.allocator, .{
            .response_allocator = std.testing.allocator,
            .plugins = .{},
            .route_fn = route_log.run,
            .middleware = &entries,
        });
        // The caller's entry array is dead after `init`; poison it.
        @memset(std.mem.asBytes(&entries), 0xaa);
        break :blk app;
    };
    defer static_app.deinit();

    var heap_app = try MwApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{},
        .route_fn = route_log.run,
        .middleware = &.{.{ .config = heap_key, .invoke = requireKey }},
    });
    defer heap_app.deinit();

    // One immutable configuration object shared by a second app.
    var shared_app = try MwApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{},
        .route_fn = route_log.run,
        .middleware = &.{.{ .config = heap_key, .invoke = requireKey }},
    });
    defer shared_app.deinit();

    const cases = [_]struct { app: *const MwApp, key: []const u8 }{
        .{ .app = &static_app, .key = "static" },
        .{ .app = &heap_app, .key = "heap" },
        .{ .app = &shared_app, .key = "heap" },
    };
    for (cases) |case| {
        var res = try dispatchWithKey(case.app, "/", case.key);
        defer res.deinit();
        try std.testing.expectEqualStrings("root", res.body);
    }
}

test "init failure copies nothing and leaks nothing" {
    const a = ApiKey{ .expected = "a" };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, MwApp.init(failing.allocator(), .{
        .response_allocator = std.testing.allocator,
        .plugins = .{},
        .route_fn = route_log.run,
        .middleware = &.{.{ .config = &a, .invoke = requireKey }},
    }));
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
}

test "a request dispatched from inside middleware gets its own frames" {
    // Deterministic frame isolation: while the outer request holds an unused
    // `next`, a second request runs the whole chain through the same app. If
    // frames were shared between requests, the inner request would consume
    // the outer request's continuation.
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(std.testing.allocator);
    route_log.log = &log;
    defer route_log.log = null;

    const Nest = struct {
        log: *std.ArrayList(u8),

        var app: *const MwApp = undefined;

        fn invoke(
            raw: *const anyopaque,
            ctx: *MwApp.Context,
            req: *router.Request,
            res: *response.Response,
            next: MwApp.Next,
        ) anyerror!void {
            const cfg: *const @This() = @ptrCast(@alignCast(raw));
            if (try req.getOne("inner") == null) {
                try cfg.log.append(std.testing.allocator, '[');
                var inner = try dispatchPath(app, .get, "/missing?inner=1");
                defer inner.deinit();
                try std.testing.expectEqual(@as(u16, 404), inner.status_code);
                try cfg.log.append(std.testing.allocator, ']');
            }
            try next.call(ctx, req, res);
            try std.testing.expectError(error.NextAlreadyCalled, next.call(ctx, req, res));
        }
    };

    const nest = Nest{ .log = &log };
    const a = LogConfig{ .enter = 'a', .exit = 'A', .log = &log };
    var app = try MwApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{},
        .route_fn = route_log.run,
        .middleware = &.{ .{ .config = &nest, .invoke = Nest.invoke }, logEntry(&a) },
    });
    defer app.deinit();
    Nest.app = &app;

    var res = try dispatchPath(&app, .get, "/");
    defer res.deinit();
    try std.testing.expectEqualStrings("root", res.body);
    // The inner request ran the full chain once, then the outer one did.
    try std.testing.expectEqualStrings("[aRA]aRA", log.items);
}

test "concurrent requests keep frames, plugin state, and outcomes independent" {
    // Each request's `v` query value is `<kind>-<thread>-<i>`. The kind picks
    // an outcome: `o` 200 echo, `s` inner short circuit, `e` route error
    // recovered by the outer entry, `m` route miss and default 404. Every entry
    // checks that `ctx.state` belongs to its own request before and after
    // `next`, and that a second `next` call is rejected.
    const Counters = struct {
        inits: std.atomic.Value(usize) = .init(0),
        deinits: std.atomic.Value(usize) = .init(0),
    };
    const Tag = struct {
        counters: *Counters,

        pub const State = struct { value: []const u8 };
        pub fn initRequest(self: *const @This(), req: *router.Request) !State {
            _ = self.counters.inits.fetchAdd(1, .monotonic);
            return .{ .value = (try req.getOne("v")) orelse "" };
        }
        pub fn deinitRequest(self: *const @This(), _: *State) void {
            _ = self.counters.deinits.fetchAdd(1, .monotonic);
        }
    };
    const Plugins = struct { tag: Tag };
    const TagApp = App(Plugins);

    const Mw = struct {
        fn ownState(ctx: *TagApp.Context, req: *router.Request) !void {
            const v = (try req.getOne("v")) orelse "";
            if (!std.mem.eql(u8, v, ctx.state.tag.value)) return error.StateMismatch;
        }

        fn recover(
            _: *const anyopaque,
            ctx: *TagApp.Context,
            req: *router.Request,
            res: *response.Response,
            next: TagApp.Next,
        ) anyerror!void {
            try ownState(ctx, req);
            next.call(ctx, req, res) catch |err| switch (err) {
                error.Boom => {
                    res.clear();
                    try res.text(503, "recovered");
                },
                else => return err,
            };
            try ownState(ctx, req);
        }

        fn guard(
            _: *const anyopaque,
            ctx: *TagApp.Context,
            req: *router.Request,
            res: *response.Response,
            next: TagApp.Next,
        ) anyerror!void {
            try ownState(ctx, req);
            try next.call(ctx, req, res);
            const copy = next;
            copy.call(ctx, req, res) catch |err| switch (err) {
                error.NextAlreadyCalled => return ownState(ctx, req),
                else => return err,
            };
            return error.SecondCallAccepted;
        }

        fn deny(
            _: *const anyopaque,
            ctx: *TagApp.Context,
            req: *router.Request,
            res: *response.Response,
            next: TagApp.Next,
        ) anyerror!void {
            try ownState(ctx, req);
            if (ctx.state.tag.value[0] == 's') return res.text(403, ctx.state.tag.value);
            try next.call(ctx, req, res);
        }
    };
    const route = struct {
        fn run(ctx: *TagApp.Context, _: *router.Request, res: *response.Response) !void {
            const v = ctx.state.tag.value;
            switch (v[0]) {
                'e' => {
                    try res.text(200, "partial");
                    try res.setHeader("X-Partial", "1");
                    return error.Boom;
                },
                'm' => return,
                else => return res.text(200, v),
            }
        }
    }.run;

    var debug: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    const gpa = debug.allocator();
    var counters: Counters = .{};
    // One configuration object shared by every entry and thread.
    const shared: u8 = 0;

    var app = try TagApp.init(gpa, .{
        .response_allocator = gpa,
        .plugins = .{ .tag = .{ .counters = &counters } },
        .route_fn = route,
        .middleware = &.{
            .{ .config = &shared, .invoke = Mw.recover },
            .{ .config = &shared, .invoke = Mw.guard },
            .{ .config = &shared, .invoke = Mw.deny },
            .{ .config = &shared, .invoke = Mw.guard },
        },
    });

    const per_thread = 400;
    const Worker = struct {
        fn run(a: *const TagApp, alloc: std.mem.Allocator, id: usize, failures: *std.atomic.Value(usize)) void {
            var buf: [32]u8 = undefined;
            for (0..per_thread) |i| {
                const kind = "osem"[(i + id) % 4];
                const v = std.fmt.bufPrint(&buf, "{c}-{d}-{d}", .{ kind, id, i }) catch unreachable;
                const ok = check(a, alloc, kind, v) catch false;
                if (!ok) _ = failures.fetchAdd(1, .monotonic);
            }
        }

        fn check(a: *const TagApp, alloc: std.mem.Allocator, kind: u8, v: []const u8) !bool {
            var target: [40]u8 = undefined;
            const path = try std.fmt.bufPrint(&target, "/?v={s}", .{v});
            var arena = try request.parseOriginForm(alloc, .default, path);
            defer arena.deinit();
            var req = arena.requestView(.get);
            var res = try a.dispatch(&req);
            defer res.deinit();
            if ((try res.getHeaderOne("x-partial")) != null) return false;
            return switch (kind) {
                'o' => res.status_code == 200 and std.mem.eql(u8, res.body, v),
                's' => res.status_code == 403 and std.mem.eql(u8, res.body, v),
                'e' => res.status_code == 503 and std.mem.eql(u8, res.body, "recovered"),
                'm' => res.status_code == 404 and std.mem.eql(u8, res.body, "Not Found"),
                else => unreachable,
            };
        }
    };

    var failures = std.atomic.Value(usize).init(0);
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, id| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &app, gpa, id, &failures });
    for (threads) |t| t.join();
    app.deinit();

    try std.testing.expectEqual(@as(usize, 0), failures.load(.monotonic));
    try std.testing.expectEqual(@as(usize, threads.len * per_thread), counters.inits.load(.monotonic));
    try std.testing.expectEqual(@as(usize, threads.len * per_thread), counters.deinits.load(.monotonic));
    try std.testing.expectEqual(std.heap.Check.ok, debug.deinit());
}
