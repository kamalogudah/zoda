//! Full §3.3 dispatch lifecycle acceptance tests for the not-found wrapper.
const std = @import("std");
const app_mod = @import("app.zig");
const request = @import("request.zig");
const response = @import("response.zig");
const router = @import("router.zig");
const NotFound = @import("plugins/not_found.zig").NotFound;

const Trace = struct {
    log: *std.ArrayList(u8),

    pub const State = struct { id: []u8 };

    pub fn initRequest(self: *const @This(), req: *router.Request) !State {
        try self.log.append(std.testing.allocator, 's');
        return .{ .id = try std.testing.allocator.dupe(u8, (try req.getOne("id")) orelse "none") };
    }

    pub fn deinitRequest(self: *const @This(), state: *State) void {
        self.log.append(std.testing.allocator, 'S') catch unreachable;
        std.testing.allocator.free(state.id);
    }

    pub fn wrapRoute(comptime H: type, comptime inner: H.RouteFn) H.RouteFn {
        return struct {
            fn run(ctx: *H.Context, req: *router.Request, res: *response.Response) anyerror!void {
                try H.plugin(ctx).log.append(std.testing.allocator, 'w');
                defer H.plugin(ctx).log.append(std.testing.allocator, 'W') catch unreachable;
                if (try req.getOne("stop")) |mode| {
                    if (std.mem.eql(u8, mode, "empty")) return;
                    if (std.mem.eql(u8, mode, "deny")) return res.text(401, "blocked");
                }
                inner(ctx, req, res) catch |err| {
                    const recovery = (try req.getOne("recover")) orelse return err;
                    res.clear();
                    if (std.mem.eql(u8, recovery, "replace")) {
                        try res.text(503, H.state(ctx).id);
                    }
                    return;
                };
                try res.setHeaderFmt("X-Context", "{s}:{s}", .{ ctx.config.name, H.state(ctx).id });
            }
        }.run;
    }
};

const Plugins = struct { trace: Trace, not_found: NotFound };
const TestApp = app_mod.App(Plugins);

const Middleware = struct {
    log: *std.ArrayList(u8),
    enter: u8,
    exit: u8,
    header_name: []const u8,
    seen: *?u16,

    fn invoke(raw: *const anyopaque, ctx: *TestApp.Context, req: *router.Request, res: *response.Response, next: TestApp.Next) anyerror!void {
        const self: *const @This() = @ptrCast(@alignCast(raw));
        try self.log.append(std.testing.allocator, self.enter);
        defer self.log.append(std.testing.allocator, self.exit) catch unreachable;
        if (std.mem.eql(u8, self.header_name, "X-Inner") and (try req.getOne("skip")) != null) return;
        try next.call(ctx, req, res);
        self.seen.* = if (res.handled) res.status_code else null;
        try res.setHeader(self.header_name, ctx.config.name);
    }

    fn entry(self: *const @This()) TestApp.Middleware {
        return .{ .config = self, .invoke = invoke };
    }
};

const route = struct {
    fn run(ctx: *TestApp.Context, req: *router.Request, res: *response.Response) !void {
        try ctx.plugins.trace.log.append(std.testing.allocator, 'R');
        if (req.isRoot()) return res.text(200, ctx.state.trace.id);
        if (req.isLiteral("boom")) {
            try res.text(200, "partial");
            try res.setHeader("X-Partial", "discard me");
            return error.RouteFailure;
        }
    }
}.run;

// The parsed request and its arena are gone by the time the caller inspects
// the returned response; dispatch has also destroyed Trace.State.
fn dispatchPath(app: *const TestApp, path: []const u8) !response.Response {
    var arena = try request.parseOriginForm(std.testing.allocator, .default, path);
    defer arena.deinit();
    var req = arena.requestView(.get);
    return app.dispatch(&req);
}

test "full lifecycle: route, custom fallback, middleware short circuit, error, and recovery" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(std.testing.allocator);
    var outer_seen: ?u16 = null;
    var inner_seen: ?u16 = null;
    const outer = Middleware{ .log = &log, .enter = 'a', .exit = 'A', .header_name = "X-Outer", .seen = &outer_seen };
    const inner = Middleware{ .log = &log, .enter = 'b', .exit = 'B', .header_name = "X-Inner", .seen = &inner_seen };
    var app = try TestApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .config = .{ .name = "configured" },
        .plugins = .{ .trace = .{ .log = &log }, .not_found = .{ .body = "custom missing" } },
        .route_fn = TestApp.composeRoute(route),
        .middleware = &.{ outer.entry(), inner.entry() },
    });
    defer app.deinit();

    for ([_]struct {
        path: []const u8,
        status: u16,
        body: []const u8,
        trace: []const u8,
        outer_status: ?u16,
        inner_status: ?u16,
        context: ?[]const u8,
    }{
        .{ .path = "/?id=route", .status = 200, .body = "route", .trace = "sabwRWBAS", .outer_status = 200, .inner_status = 200, .context = "configured:route" },
        .{ .path = "/missing?id=miss", .status = 404, .body = "custom missing", .trace = "sabwRWBAS", .outer_status = 404, .inner_status = 404, .context = "configured:miss" },
        .{ .path = "/missing?stop=empty", .status = 404, .body = "Not Found", .trace = "sabwWBAS", .outer_status = 404, .inner_status = 404, .context = null },
        .{ .path = "/missing?stop=deny", .status = 401, .body = "blocked", .trace = "sabwWBAS", .outer_status = 401, .inner_status = 401, .context = null },
        .{ .path = "/missing?skip=1", .status = 404, .body = "Not Found", .trace = "sabBAS", .outer_status = null, .inner_status = null, .context = null },
        .{ .path = "/boom?id=again&recover=replace", .status = 503, .body = "again", .trace = "sabwRWBAS", .outer_status = 503, .inner_status = 503, .context = null },
        .{ .path = "/boom?recover=empty", .status = 404, .body = "Not Found", .trace = "sabwRWBAS", .outer_status = 404, .inner_status = 404, .context = null },
    }) |case| {
        log.clearRetainingCapacity();
        outer_seen = null;
        inner_seen = null;
        var res = try dispatchPath(&app, case.path);
        defer res.deinit();
        try std.testing.expectEqualStrings(case.trace, log.items);
        try std.testing.expectEqual(case.status, res.status_code);
        try std.testing.expectEqualStrings(case.body, res.body);
        try std.testing.expectEqual(case.outer_status, outer_seen);
        try std.testing.expectEqual(case.inner_status, inner_seen);
        try std.testing.expectEqualStrings("configured", (try res.getHeaderOne("x-outer")).?);
        try std.testing.expectEqual(case.inner_status != null, (try res.getHeaderOne("x-inner")) != null);
        const context = try res.getHeaderOne("x-context");
        try std.testing.expectEqual(case.context != null, context != null);
        if (case.context) |expected| try std.testing.expectEqualStrings(expected, context.?);
        try std.testing.expect((try res.getHeaderOne("x-partial")) == null);
    }

    log.clearRetainingCapacity();
    try std.testing.expectError(error.RouteFailure, dispatchPath(&app, "/boom"));
    try std.testing.expectEqualStrings("sabwRWBAS", log.items);
}

test "custom fallback response outlives request state, request arena, and app" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(std.testing.allocator);
    var app = try TestApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .config = .{ .name = "lifetime" },
        .plugins = .{ .trace = .{ .log = &log }, .not_found = .{ .body = "owned fallback" } },
        .route_fn = TestApp.composeRoute(route),
    });
    var res = dispatchPath(&app, "/absent?id=alive") catch |err| {
        app.deinit();
        return err;
    };
    app.deinit();
    defer res.deinit();

    try std.testing.expectEqualStrings("swRWS", log.items);
    try std.testing.expectEqual(@as(u16, 404), res.status_code);
    try std.testing.expectEqualStrings("owned fallback", res.body);
    try std.testing.expectEqualStrings("lifetime:alive", (try res.getHeaderOne("x-context")).?);
}
