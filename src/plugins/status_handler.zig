//! Configured responses for selected 4xx and 5xx statuses.
//!
//! `middleware(App, &config)` covers what runs downstream of its entry: inner
//! middleware (including static files and short circuits), route wrappers, the
//! route, and the default 404. Entries registered before it, and dispatch's
//! final 404 after an outer short circuit, are not covered.
//!
//! A handler runs only when downstream succeeds, the status matches, and the
//! body is empty or framework-generated (`Response.generated`). A body written
//! by a route, `NotFound`, static files, or middleware wins. Errors propagate
//! without running any handler; recover them with `error_handler`.
const std = @import("std");
const router = @import("../router.zig");
const response = @import("../response.zig");

pub const ConfigError = error{ InvalidStatus, DuplicateStatus };

pub fn Config(comptime AppT: type) type {
    return struct {
        /// Borrowed, immutable entries; the slice must outlive the app.
        handlers: []const Handler,

        pub const Handler = struct {
            /// A 4xx or 5xx status, listed at most once.
            status: u16,
            /// Receives the matched response with its status and headers
            /// intact. Writing with `text`, `replaceJson`, or another helper
            /// replaces the body, status, and content type and keeps headers;
            /// writing nothing keeps the matched response. The request cursor
            /// is wherever routing left it. Errors propagate.
            run: AppT.RouteFn,
        };
    };
}

/// Validate at setup, before the first request.
pub fn validate(comptime AppT: type, config: *const Config(AppT)) ConfigError!void {
    for (config.handlers, 0..) |handler, i| {
        if (handler.status < 400 or handler.status > 599) return error.InvalidStatus;
        for (config.handlers[0..i]) |previous| {
            if (previous.status == handler.status) return error.DuplicateStatus;
        }
    }
}

/// Returns a middleware entry borrowing `config` until app shutdown. Register
/// it outside the middleware whose responses it should cover.
pub fn middleware(comptime AppT: type, config: *const Config(AppT)) ConfigError!AppT.Middleware {
    try validate(AppT, config);
    const Impl = struct {
        fn invoke(
            raw: *const anyopaque,
            ctx: *AppT.Context,
            req: *router.Request,
            res: *response.Response,
            next: AppT.Next,
        ) anyerror!void {
            const cfg: *const Config(AppT) = @ptrCast(@alignCast(raw));
            try next.call(ctx, req, res);
            // A silent inner short circuit would otherwise receive dispatch's
            // 404 after this entry unwinds. Materialize it before matching.
            if (!res.handled) try res.defaultNotFound();
            if (res.body.len != 0 and !res.generated) return;
            for (cfg.handlers) |handler| {
                if (handler.status == res.status_code) return handler.run(ctx, req, res);
            }
        }
    };
    return .{ .config = config, .invoke = Impl.invoke };
}

const testing = std.testing;
const app_mod = @import("../app.zig");
const request = @import("../request.zig");
const static = @import("../static.zig");
const NotFound = @import("not_found.zig").NotFound;
const Plugins = struct {};
const App = app_mod.App(Plugins);

fn isTarget(req: *const router.Request, target: []const u8) bool {
    return std.mem.eql(u8, req.target, target);
}

fn route(_: *App.Context, req: *router.Request, res: *response.Response) !void {
    if (isTarget(req, "/")) return res.text(200, "home");
    if (isTarget(req, "/gone")) return res.text(404, "route 404");
    if (isTarget(req, "/forbidden")) {
        try res.text(403, "");
        return res.setHeader("X-Route", "kept");
    }
    if (isTarget(req, "/teapot")) return res.text(418, "");
    if (isTarget(req, "/expired")) return res.text(410, "");
    if (isTarget(req, "/boom")) {
        try res.text(404, "");
        return error.RouteFailed;
    }
}

const handlers = struct {
    fn notFound(_: *App.Context, req: *router.Request, res: *response.Response) !void {
        try res.text(404, "styled 404");
        try res.setHeader("X-Styled", req.target);
    }
    fn forbidden(_: *App.Context, _: *router.Request, res: *response.Response) !void {
        try res.text(403, "styled 403");
    }
    fn unauthorized(_: *App.Context, _: *router.Request, res: *response.Response) !void {
        try res.text(401, "styled 401");
    }
    fn failing(_: *App.Context, _: *router.Request, _: *response.Response) !void {
        return error.HandlerFailed;
    }
    fn silent(_: *App.Context, _: *router.Request, _: *response.Response) !void {}
};

const test_config = Config(App){ .handlers = &.{
    .{ .status = 404, .run = handlers.notFound },
    .{ .status = 403, .run = handlers.forbidden },
    .{ .status = 401, .run = handlers.unauthorized },
    .{ .status = 410, .run = handlers.failing },
    .{ .status = 500, .run = handlers.silent },
} };

/// Short circuits on "/<prefix>-silent" (writes nothing) and
/// "/<prefix>-deny" (401 with a body) or "/<prefix>-empty" (401, no body).
const Short = struct {
    prefix: []const u8,

    fn invoke(raw: *const anyopaque, ctx: *App.Context, req: *router.Request, res: *response.Response, next: App.Next) anyerror!void {
        const self: *const Short = @ptrCast(@alignCast(raw));
        if (std.mem.startsWith(u8, req.target, "/") and std.mem.startsWith(u8, req.target[1..], self.prefix)) {
            const rest = req.target[1 + self.prefix.len ..];
            if (std.mem.eql(u8, rest, "-silent")) return;
            if (std.mem.eql(u8, rest, "-deny")) return res.text(401, "denied");
            if (std.mem.eql(u8, rest, "-empty")) return res.text(401, "");
        }
        return next.call(ctx, req, res);
    }

    fn entry(self: *const Short) App.Middleware {
        return .{ .config = self, .invoke = invoke };
    }
};

fn dispatchTo(app: anytype, target: []const u8) !response.Response {
    var arena = try request.parseOriginForm(testing.allocator, .default, target);
    defer arena.deinit();
    var req = arena.requestView(.get);
    return app.dispatch(&req);
}

fn expectResponse(app: *const App, target: []const u8, status: u16, body: []const u8) !void {
    var res = try dispatchTo(app, target);
    defer res.deinit();
    try testing.expectEqual(status, res.status_code);
    try testing.expectEqualStrings(body, res.body);
}

test "configuration accepts only distinct 4xx and 5xx statuses" {
    try validate(App, &test_config);
    for ([_]u16{ 0, 200, 204, 304, 399, 600 }) |status| {
        const bad = Config(App){ .handlers = &.{.{ .status = status, .run = handlers.silent }} };
        try testing.expectError(error.InvalidStatus, middleware(App, &bad));
    }
    const duplicate = Config(App){ .handlers = &.{
        .{ .status = 404, .run = handlers.silent },
        .{ .status = 404, .run = handlers.notFound },
    } };
    try testing.expectError(error.DuplicateStatus, middleware(App, &duplicate));
}

test "handlers replace the default 404 and empty selected statuses only" {
    var app = try App.init(testing.allocator, .{
        .response_allocator = testing.allocator,
        .plugins = .{},
        .route_fn = route,
        .middleware = &.{try middleware(App, &test_config)},
    });
    defer app.deinit();

    try expectResponse(&app, "/", 200, "home");
    // A route miss gets the generated 404, which the handler replaces.
    {
        var res = try dispatchTo(&app, "/missing");
        defer res.deinit();
        try testing.expectEqual(@as(u16, 404), res.status_code);
        try testing.expectEqualStrings("styled 404", res.body);
        try testing.expectEqualStrings("/missing", (try res.getHeaderOne("X-Styled")).?);
        try testing.expect(!res.generated);
    }
    // A route-written body wins over the handler for the same status.
    try expectResponse(&app, "/gone", 404, "route 404");
    // An empty selected status is replaced and keeps the route's headers.
    {
        var res = try dispatchTo(&app, "/forbidden");
        defer res.deinit();
        try testing.expectEqualStrings("styled 403", res.body);
        try testing.expectEqualStrings("kept", (try res.getHeaderOne("X-Route")).?);
    }
    // Unselected statuses pass through unchanged.
    try expectResponse(&app, "/teapot", 418, "");
    // A handler that writes nothing keeps the matched response.
    const silent_config = Config(App){ .handlers = &.{.{ .status = 404, .run = handlers.silent }} };
    var silent_app = try App.init(testing.allocator, .{
        .response_allocator = testing.allocator,
        .plugins = .{},
        .route_fn = route,
        .middleware = &.{try middleware(App, &silent_config)},
    });
    defer silent_app.deinit();
    try expectResponse(&silent_app, "/missing", 404, "Not Found");
}

test "errors propagate without handlers and handler errors propagate" {
    var app = try App.init(testing.allocator, .{
        .response_allocator = testing.allocator,
        .plugins = .{},
        .route_fn = route,
        .middleware = &.{try middleware(App, &test_config)},
    });
    defer app.deinit();
    // The partial empty 404 is released by dispatch; the testing allocator
    // checks for leaks.
    try testing.expectError(error.RouteFailed, dispatchTo(&app, "/boom"));
    try testing.expectError(error.HandlerFailed, dispatchTo(&app, "/expired"));
}

test "inner short circuits are covered and outer ones are not" {
    const outer = Short{ .prefix = "outer" };
    const inner = Short{ .prefix = "inner" };
    var app = try App.init(testing.allocator, .{
        .response_allocator = testing.allocator,
        .plugins = .{},
        .route_fn = route,
        .middleware = &.{ outer.entry(), try middleware(App, &test_config), inner.entry() },
    });
    defer app.deinit();

    try expectResponse(&app, "/inner-silent", 404, "styled 404");
    try expectResponse(&app, "/inner-deny", 401, "denied");
    try expectResponse(&app, "/inner-empty", 401, "styled 401");
    try expectResponse(&app, "/outer-silent", 404, "Not Found");
    try expectResponse(&app, "/outer-empty", 401, "");
}

test "a composed NotFound wrapper body wins over a 404 handler" {
    const WrappedPlugins = struct { not_found: NotFound };
    const Wrapped = app_mod.App(WrappedPlugins);
    const wrapped = struct {
        fn run(_: *Wrapped.Context, req: *router.Request, res: *response.Response) !void {
            if (isTarget(req, "/")) return res.text(200, "home");
        }
        fn styled(_: *Wrapped.Context, _: *router.Request, res: *response.Response) !void {
            try res.text(404, "styled 404");
        }
    };
    const config = Config(Wrapped){ .handlers = &.{.{ .status = 404, .run = wrapped.styled }} };
    var app = try Wrapped.init(testing.allocator, .{
        .response_allocator = testing.allocator,
        .plugins = .{ .not_found = .{ .body = "wrapper 404" } },
        .route_fn = Wrapped.composeRoute(wrapped.run),
        .middleware = &.{try middleware(Wrapped, &config)},
    });
    defer app.deinit();
    var res = try dispatchTo(&app, "/missing");
    defer res.deinit();
    try testing.expectEqual(@as(u16, 404), res.status_code);
    try testing.expectEqualStrings("wrapper 404", res.body);
}

test "static hits are kept and static misses reach the 404 handler" {
    if (!static.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "asset.txt", .data = "asset" });
    try static.checkSupport(tmp.dir);
    const static_config = static.Config{ .root = tmp.dir };
    var app = try App.init(testing.allocator, .{
        .response_allocator = testing.allocator,
        .plugins = .{},
        .route_fn = route,
        .middleware = &.{ try middleware(App, &test_config), static.middleware(App, &static_config) },
    });
    defer app.deinit();
    try expectResponse(&app, "/asset.txt", 200, "asset");
    try expectResponse(&app, "/absent.txt", 404, "styled 404");
}
