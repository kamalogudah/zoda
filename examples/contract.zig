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

// README "Typed JSON requests": this route and its plugin registration compile
// as part of `zig build test-examples`.
const JsonInput = struct { name: []const u8 };
const JsonPlugins = struct { json_parser: zoda.JsonParser = .{} };
const JsonApp = zoda.app.App(JsonPlugins);

fn jsonRoute(ctx: *JsonApp.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    if (req.isLiteral("names") and req.method == .post) {
        var parsed = ctx.plugins.json_parser.parse(res.allocator, req, JsonInput) catch |err| switch (err) {
            error.BodyTooLarge => return res.text(413, "body too large"),
            error.OutOfMemory => return err,
            else => return res.text(400, "invalid JSON request"),
        };
        defer parsed.deinit();
        return res.text(201, parsed.value.name);
    }
}

test "typed JSON route uses registered parser" {
    const json_app: JsonApp = .{ .response_allocator = std.testing.allocator, .config = .{}, .plugins = .{}, .route_fn = jsonRoute };
    const headers = [_]zoda.router.Header{.{ .name = "Content-Type", .value = "application/json" }};
    var req: zoda.router.Request = .{ .method = .post, .segments = &.{"names"}, .headers = &headers, .body = "{\"name\":\"Ada\"}" };
    var res = try json_app.dispatch(&req);
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 201), res.status_code);
    try std.testing.expectEqualStrings("Ada", res.body);
}

fn route(ctx: *App.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    if (req.isRoot() and req.isGet()) return res.text(200, "hello from zoda");
    if (req.isLiteral("old")) {
        if (req.isGet()) return res.redirectPath(.found, "/new");
        if (req.method == .post) return res.redirectPath(.temporary_redirect, "/new");
    }

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
    inline for (.{ .{ zoda.router.Method.get, @as(u16, 302) }, .{ zoda.router.Method.post, @as(u16, 307) } }) |case| {
        var res = try dispatch(&app, case[0], "/old");
        defer res.deinit();
        try std.testing.expectEqual(case[1], res.status_code);
        try std.testing.expectEqualStrings("/new", (try res.getHeaderOne("Location")).?);
        try std.testing.expectEqualStrings("", res.body);
    }
}

// PLUGINS.md "Request IDs and access logs": the same registration, compiled here.
const TraceLog = struct {
    count: usize = 0,
    last_status: ?u16 = null,

    fn write(raw: *anyopaque, record: zoda.plugins.request_trace.Record) void {
        const self: *TraceLog = @ptrCast(@alignCast(raw));
        // A real sink would emit a line such as:
        // std.log.info("id={s} method={t} path={s} status={?d} ms={d} failed={}", .{
        //     record.id, record.method, record.path, record.status, record.duration_ms, record.failed,
        // });
        self.count += 1;
        self.last_status = record.status;
    }
};

const TracePlugins = struct { trace: zoda.RequestTrace };
const TraceApp = zoda.app.App(TracePlugins);

fn traceRoute(ctx: *TraceApp.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    if (req.isRoot() and req.isGet()) return res.text(200, ctx.state.trace.id());
}

test "PLUGINS request trace example" {
    var log: TraceLog = .{};
    var app = try TraceApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .config = .{ .clock = .monotonic(std.testing.io) },
        .plugins = .{ .trace = .{
            .source = .{ .io = std.testing.io },
            .incoming = .accept_valid,
            .clock = .monotonic(std.testing.io),
            .sink = .{ .context = &log, .write = TraceLog.write },
        } },
        .route_fn = traceRoute,
        // Outermost, so the record sees timing, static, and auth outcomes.
        .middleware = &.{ zoda.plugins.request_trace.middleware(TraceApp, "trace"), zoda.timing.middleware(TraceApp) },
    });
    defer app.deinit();

    var arena = try zoda.request.parseOriginForm(std.testing.allocator, .default, "/");
    defer arena.deinit();
    var req = arena.requestView(.get);
    var res = try app.dispatch(&req);
    defer res.deinit();
    try std.testing.expectEqualStrings(res.body, (try res.getHeaderOne(zoda.plugins.request_trace.header_name)).?);
    try std.testing.expectEqual(@as(usize, 1), log.count);
    try std.testing.expectEqual(@as(?u16, 200), log.last_status);
}

// PLUGINS.md "HTTP caching": explicit policy, validator, and conditional GET.
const http_cache = zoda.plugins.http_cache;
const CachePlugins = struct {};
const CacheApp = zoda.app.App(CachePlugins);

fn cacheRoute(_: *CacheApp.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    if (req.isLiteral("report") and (req.isGet() or req.method == .head)) {
        try res.text(200, "report v42");
        try http_cache.setCacheControl(req, res, .{ .private = .{ .no_cache = true } });
        try http_cache.setBodyETag(res);
        try http_cache.addVary(res, "Accept-Encoding");
        _ = try http_cache.evaluate(req, res);
        return;
    }
    if (req.isLiteral("plain") and req.isGet()) return res.text(200, "no policy");
}

test "PLUGINS HTTP caching example" {
    var app = try CacheApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{},
        .route_fn = cacheRoute,
    });
    defer app.deinit();

    var first_arena = try zoda.request.parseOriginForm(std.testing.allocator, .default, "/report");
    defer first_arena.deinit();
    var first_req = first_arena.requestView(.get);
    var first = try app.dispatch(&first_req);
    defer first.deinit();
    try std.testing.expectEqual(@as(u16, 200), first.status_code);
    try std.testing.expectEqualStrings("private, no-cache", (try first.getHeaderOne("Cache-Control")).?);
    const etag = (try first.getHeaderOne("ETag")).?;

    for ([_]zoda.router.Method{ .get, .head }) |method| {
        var arena = try zoda.request.parseOriginForm(std.testing.allocator, .default, "/report");
        defer arena.deinit();
        try arena.copyHeaders(&.{.{ .name = "If-None-Match", .value = etag }});
        var req = arena.requestView(method);
        var res = try app.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 304), res.status_code);
        try std.testing.expectEqualStrings("", res.body);
        try std.testing.expectEqualStrings(etag, (try res.getHeaderOne("ETag")).?);
        try std.testing.expectEqualStrings("Accept-Encoding", (try res.getHeaderOne("Vary")).?);
    }

    // Routes that set no policy send no Cache-Control.
    var plain_arena = try zoda.request.parseOriginForm(std.testing.allocator, .default, "/plain");
    defer plain_arena.deinit();
    var plain_req = plain_arena.requestView(.get);
    var plain = try app.dispatch(&plain_req);
    defer plain.deinit();
    try std.testing.expect((try plain.getHeaderOne("Cache-Control")) == null);
}

// PLUGINS.md "Flash messages": register Sessions and Flash, queue a message on
// POST, and read it once on the redirected GET. Both responses save.
const FlashPlugins = struct { sessions: zoda.Sessions, flash: zoda.Flash = .{} };
const FlashApp = zoda.app.App(FlashPlugins);

fn flashClock() i64 {
    return 1_700_000_000;
}

fn flashRoute(ctx: *FlashApp.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    const session = &ctx.state.sessions;
    if (req.isLiteral("items") and req.method == .post) {
        try ctx.plugins.flash.add(session, "notice", "Item created");
        try ctx.plugins.sessions.save(session, res);
        return res.redirectPath(.see_other, "/");
    }
    if (req.isRoot() and req.isGet()) {
        var body: [zoda.plugins.flash.max_bytes]u8 = undefined;
        var len: usize = 0;
        var messages = ctx.plugins.flash.read(session);
        while (messages.next()) |message| {
            len += (try std.fmt.bufPrint(body[len..], "{s}: {s}\n", .{ message.kind, message.text })).len;
        }
        try ctx.plugins.sessions.save(session, res); // consume what was shown
        return res.text(200, body[0..len]);
    }
}

fn flashVisit(app: *const FlashApp, method: zoda.router.Method, target: []const u8, cookie: []const u8, cookie_out: []u8) !struct { zoda.response.Response, ?[]const u8 } {
    var arena = try zoda.request.parseOriginForm(std.testing.allocator, .default, target);
    defer arena.deinit();
    if (cookie.len > 0) try arena.copyHeaders(&.{.{ .name = "Cookie", .value = cookie }});
    var req = arena.requestView(method);
    const res = try app.dispatch(&req);
    const set_cookie = (try res.getHeaderOne("Set-Cookie")) orelse return .{ res, null };
    const value = set_cookie[0..std.mem.indexOfScalar(u8, set_cookie, ';').?];
    @memcpy(cookie_out[0..value.len], value);
    return .{ res, cookie_out[0..value.len] };
}

test "PLUGINS flash messages example" {
    var app = try FlashApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{ .sessions = .{
            .keys = &.{.{ .id = 1, .secret = "example-secret-of-at-least-32-bytes!" }},
            .lifetime_seconds = 3600,
            .now_seconds = flashClock,
        } },
        .route_fn = flashRoute,
    });
    defer app.deinit();
    var first: [zoda.plugins.sessions.max_cookie_bytes]u8 = undefined;
    var second: [zoda.plugins.sessions.max_cookie_bytes]u8 = undefined;

    var created, const flash_cookie = try flashVisit(&app, .post, "/items", "", &first);
    defer created.deinit();
    try std.testing.expectEqual(@as(u16, 303), created.status_code);

    var shown, const consumed_cookie = try flashVisit(&app, .get, "/", flash_cookie.?, &second);
    defer shown.deinit();
    try std.testing.expectEqualStrings("notice: Item created\n", shown.body);

    var after, _ = try flashVisit(&app, .get, "/", consumed_cookie.?, &first);
    defer after.deinit();
    try std.testing.expectEqualStrings("", after.body);
}
