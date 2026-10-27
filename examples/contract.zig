//! Compiling counterparts to ADR-0001 §5.1–§5.4. Run with `zig build test-examples`.
const std = @import("std");
const zoda = @import("zoda");

const User = struct { id: []const u8, name: []const u8 };

const RequestId = struct {
    prefix: []const u8,
    pub const State = struct { value: []const u8 };

    pub fn initRequest(self: *const RequestId, _: *zoda.router.Request) !State {
        return .{ .value = self.prefix };
    }

    pub fn deinitRequest(_: *const RequestId, _: *State) void {}
};

const Plugins = struct {
    json: zoda.Json = .{},
    request_id: RequestId = .{ .prefix = "example" },
};
const App = zoda.app.App(Plugins);

fn route(ctx: *App.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    if (req.isRoot() and req.isGet()) return res.text(200, "hello from zoda");

    // §5.1: mark/restore rewinds only the cursor. Try alternatives before writes.
    const saved = req.mark();
    if (req.isLiteral("health") and req.isGet()) return res.text(200, "ok");
    req.restore(saved);

    // §5.3: this prefix commits the branch. Every miss here returns to dispatch.
    if (req.onLiteral("users")) {
        if (req.onSegment()) |id| {
            if (req.isRoot() and req.isGet()) {
                return ctx.plugins.json.render(res, User, .{ .id = id, .name = "unknown" });
            }
        }
        return;
    }
    if (req.isLiteral("search") and req.isGet()) {
        const q = (try req.getOne("q")) orelse "";
        return res.text(200, q);
    }
}

const HeaderConfig = struct { name: []const u8 };

// §5.4: an app-owned entry borrows this immutable config until app.deinit().
fn addRequestId(
    raw: *const anyopaque,
    ctx: *App.Context,
    req: *zoda.router.Request,
    res: *zoda.response.Response,
    next: App.Next,
) anyerror!void {
    const cfg: *const HeaderConfig = @ptrCast(@alignCast(raw));
    try next.call(ctx, req, res);
    try res.setHeader(cfg.name, ctx.state.request_id.value);
}

fn dispatch(app: *const App, method: zoda.router.Method, target: []const u8) !zoda.response.Response {
    // §5.2: request storage ends after dispatch; returned response owns its bytes.
    var arena = try zoda.request.parseOriginForm(std.testing.allocator, .default, target);
    defer arena.deinit();
    var req = arena.requestView(method);
    return app.dispatch(&req);
}

test "ADR section 5 examples: routing, plugin state, ownership, timing" {
    const header: HeaderConfig = .{ .name = "X-Request-Id" };
    const defaults: zoda.default_headers.Config = .{
        .headers = &.{.{ .name = "X-App", .value = "zoda" }},
    };
    var app = try App.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .config = .{ .clock = .monotonic(std.testing.io) },
        .plugins = .{},
        .route_fn = route,
        .middleware = &.{
            try zoda.default_headers.middleware(App, &defaults),
            zoda.timing.middleware(App),
            .{ .config = &header, .invoke = addRequestId },
        },
    });
    defer app.deinit();

    const cases = .{
        .{ .method = zoda.router.Method.get, .target = "/", .status = @as(u16, 200), .type = "text/plain", .body = "hello from zoda" },
        .{ .method = zoda.router.Method.get, .target = "/users/42", .status = @as(u16, 200), .type = "application/json", .body = "{\"id\":\"42\",\"name\":\"unknown\"}" },
        .{ .method = zoda.router.Method.get, .target = "/users", .status = @as(u16, 404), .type = "text/plain", .body = "Not Found" },
        .{ .method = zoda.router.Method.get, .target = "/users/42/extra", .status = @as(u16, 404), .type = "text/plain", .body = "Not Found" },
        .{ .method = zoda.router.Method.get, .target = "/users/42/", .status = @as(u16, 404), .type = "text/plain", .body = "Not Found" },
        .{ .method = zoda.router.Method.post, .target = "/users/42", .status = @as(u16, 404), .type = "text/plain", .body = "Not Found" },
        .{ .method = zoda.router.Method.get, .target = "/search?q=zig+lang", .status = @as(u16, 200), .type = "text/plain", .body = "zig lang" },
    };
    inline for (cases) |case| {
        var res = try dispatch(&app, case.method, case.target);
        defer res.deinit();
        try std.testing.expectEqual(case.status, res.status_code);
        try std.testing.expectEqualStrings(case.type, res.content_type);
        try std.testing.expectEqualStrings(case.body, res.body);
        try std.testing.expectEqualStrings("example", (try res.getHeaderOne("X-Request-Id")).?);
        try std.testing.expectEqualStrings("zoda", (try res.getHeaderOne("X-App")).?);
        _ = try std.fmt.parseInt(u64, (try res.getHeaderOne(zoda.timing.header_name)).?, 10);
    }
    try std.testing.expectError(error.DuplicateQueryValue, dispatch(&app, .get, "/search?q=a&q=b"));
}
