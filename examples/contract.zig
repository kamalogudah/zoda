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

// PLUGINS "Status and error handlers": the registration and precedence shown
// there compile and run here.
const status_handler = zoda.plugins.status_handler;
const error_handler = zoda.plugins.error_handler;
const PagePlugins = struct {};
const PageApp = zoda.app.App(PagePlugins);

fn pageRoute(_: *PageApp.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    if (req.isRoot() and req.isGet()) return res.text(200, "home");
    if (req.isLiteral("report")) return error.ReportUnavailable;
    if (req.isLiteral("gone")) return res.text(404, "this report was removed");
}

fn notFoundPage(_: *PageApp.Context, _: *zoda.router.Request, res: *zoda.response.Response) !void {
    try res.text(404, "Page not found");
}

fn serverErrorPage(_: *PageApp.Context, _: *zoda.router.Request, res: *zoda.response.Response) !void {
    try res.text(500, "Something went wrong");
}

fn logError(_: *PageApp.Context, req: *zoda.router.Request, _: *zoda.response.Response, err: anyerror) !void {
    std.log.debug("{s} failed: {t}", .{ req.target, err });
    // Writing nothing leaves the generated 500 for the status handler.
}

const pages = status_handler.Config(PageApp){ .handlers = &.{
    .{ .status = 404, .run = notFoundPage },
    .{ .status = 500, .run = serverErrorPage },
} };
const recovery = error_handler.Config(PageApp){ .handler = logError };

test "PLUGINS status and error handlers example" {
    var app = try PageApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{},
        .route_fn = pageRoute,
        // Status pages outermost so they style the recovery 500.
        .middleware = &.{ try status_handler.middleware(PageApp, &pages), error_handler.middleware(PageApp, &recovery) },
    });
    defer app.deinit();

    const cases = [_]struct { target: []const u8, status: u16, body: []const u8 }{
        .{ .target = "/", .status = 200, .body = "home" },
        .{ .target = "/missing", .status = 404, .body = "Page not found" },
        .{ .target = "/gone", .status = 404, .body = "this report was removed" },
        .{ .target = "/report", .status = 500, .body = "Something went wrong" },
    };
    for (cases) |case| {
        var arena = try zoda.request.parseOriginForm(std.testing.allocator, .default, case.target);
        defer arena.deinit();
        var req = arena.requestView(.get);
        var res = try app.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqual(case.status, res.status_code);
        try std.testing.expectEqualStrings(case.body, res.body);
    }
}

// PLUGINS "Security response policies": the registration and HTTPS gating
// shown there compile and run here.
const security_policy = zoda.plugins.security_policy;
const SecureApp = zoda.app.App(struct {});

fn secureRoute(_: *SecureApp.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    if (req.isRoot() and req.isGet()) return res.text(200, "home");
}

/// This app listens only on a loopback port that the TLS terminator reaches,
/// so every request it receives arrived over HTTPS.
fn behindTlsTerminator(_: *SecureApp.Context, _: *const zoda.router.Request) bool {
    return true;
}

const policies = security_policy.Config(SecureApp){
    .content_security_policy = .{ .value = "default-src 'self'; frame-ancestors 'none'" },
    .permissions_policy = .{ .value = "camera=(), geolocation=(), microphone=()" },
    .hsts = .{ .max_age = 31536000, .include_subdomains = true, .https = behindTlsTerminator },
};
const extra_defaults = zoda.default_headers.Config{ .headers = &.{
    .{ .name = "X-Frame-Options", .value = "DENY" },
    .{ .name = "Referrer-Policy", .value = "no-referrer" },
} };

test "PLUGINS security response policies example" {
    var app = try SecureApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{},
        .route_fn = secureRoute,
        .middleware = &.{
            try security_policy.middleware(SecureApp, &policies), // validates the config
            try zoda.default_headers.middleware(SecureApp, &extra_defaults),
        },
    });
    defer app.deinit();

    for ([_][]const u8{ "/", "/missing" }) |target| {
        var arena = try zoda.request.parseOriginForm(std.testing.allocator, .default, target);
        defer arena.deinit();
        var req = arena.requestView(.get);
        var res = try app.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqualStrings("default-src 'self'; frame-ancestors 'none'", (try res.getHeaderOne("Content-Security-Policy")).?);
        try std.testing.expectEqualStrings("camera=(), geolocation=(), microphone=()", (try res.getHeaderOne("Permissions-Policy")).?);
        try std.testing.expectEqualStrings("max-age=31536000; includeSubDomains", (try res.getHeaderOne("Strict-Transport-Security")).?);
        try std.testing.expectEqualStrings("DENY", (try res.getHeaderOne("X-Frame-Options")).?);
    }
}

// README "Sending files from routes": a route sends one confined file and
// answers 404 itself when the file is missing.
const FilesApp = zoda.app.App(struct {});
var reports_root: std.Io.Dir = undefined;

fn reportRoute(_: *FilesApp.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    if (req.isGet() and req.onLiteral("reports")) {
        const name = req.onSegment() orelse return;
        if (!req.isRoot()) return;
        var buffer: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&buffer, "reports/{s}.txt", .{name}) catch return res.text(404, "no such report");
        const sent = try zoda.static.sendFile(req, res, reports_root, path, .{
            .cache_control = .{ .private = .{ .no_cache = true } },
            .etag = true,
        });
        if (!sent) return res.text(404, "no such report");
    }
}

test "routes send confined files with sendFile" {
    if (!zoda.static.supported) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "reports");
    try tmp.dir.writeFile(io, .{ .sub_path = "reports/q3.txt", .data = "q3 numbers" });
    reports_root = tmp.dir;

    const files_app: FilesApp = .{ .response_allocator = std.testing.allocator, .config = .{}, .plugins = .{}, .route_fn = reportRoute };
    inline for (.{ .{ "q3", 200, "q3 numbers" }, .{ "q4", 404, "no such report" } }) |case| {
        var req: zoda.router.Request = .{ .method = .get, .segments = &.{ "reports", case[0] } };
        var res = try files_app.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, case[1]), res.status_code);
        try std.testing.expectEqualStrings(case[2], res.body);
    }
}

// PLUGINS.md "Inertia.js": registration, render, redirect, and version check.
const Shared = struct { app_name: []const u8 };
const InertiaPlugins = struct { inertia: zoda.Inertia(Shared) };
const InertiaApp = zoda.app.App(InertiaPlugins);
const inertia_layout =
    \\<!doctype html>
    \\<html><head><script type="module" src="/assets/app.js"></script></head>
    \\<body>@inertia</body></html>
;

fn inertiaRoute(ctx: *InertiaApp.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    const inertia = &ctx.plugins.inertia;
    if (req.onLiteral("users")) {
        if (!req.isRoot()) return;
        if (req.isGet()) return inertia.render(req, res, "Users/Index", .{ .users = &[_][]const u8{"ada"} });
        if (req.method == .post) return inertia.redirect(req, res, "/users");
    }
}

// PLUGINS.md "Partial reloads": `optional` and `always` props.
const InertiaReport = struct {
    fn totals(ids: []const u32, allocator: std.mem.Allocator) error{OutOfMemory}![]u32 {
        const sums = try allocator.alloc(u32, 1);
        sums[0] = 0;
        for (ids) |id| sums[0] += id;
        return sums;
    }
};

fn inertiaReportRoute(ctx: *InertiaApp.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    const ids: []const u32 = &.{ 1, 2, 3 };
    if (req.onLiteral("reports") and req.isRoot() and req.isGet()) {
        return ctx.plugins.inertia.render(req, res, "Reports/Index", .{
            .ids = ids,
            .totals = zoda.plugins.inertia.optional(ids, InertiaReport.totals),
            .notice = zoda.plugins.inertia.always("ready"),
        });
    }
}

// PLUGINS.md "Deferred props".
const InertiaDashboard = struct {
    fn count(ids: []const u32, _: std.mem.Allocator) usize {
        return ids.len;
    }
};

fn inertiaDashboardRoute(ctx: *InertiaApp.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    const ids: []const u32 = &.{ 1, 2, 3 };
    if (req.onLiteral("dashboard") and req.isRoot() and req.isGet()) {
        return ctx.plugins.inertia.render(req, res, "Dashboard", .{
            .ids = ids,
            .stats = zoda.plugins.inertia.deferred(ids, InertiaDashboard.count),
            .feed = zoda.plugins.inertia.deferredGroup("social", ids, InertiaReport.totals),
        });
    }
}

// PLUGINS.md "Merge props".
const InertiaMessages = struct {
    const Message = struct { id: u32, text: []const u8 };
    const pages = [_][]const Message{
        &.{ .{ .id = 1, .text = "hi" }, .{ .id = 2, .text = "yo" } },
        &.{.{ .id = 3, .text = "hey" }},
    };

    fn activity(_: void, _: std.mem.Allocator) struct { events: []const u32 } {
        return .{ .events = &.{7} };
    }
};

fn inertiaMessagesRoute(ctx: *InertiaApp.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    if (req.onLiteral("messages") and req.isRoot() and req.isGet()) {
        const raw = (req.getOne("page") catch null) orelse "1";
        const page = std.fmt.parseInt(usize, raw, 10) catch 0;
        if (page < 1 or page > InertiaMessages.pages.len) return res.text(404, "No such page");
        const inertia = zoda.plugins.inertia;
        return ctx.plugins.inertia.render(req, res, "Messages/Index", .{
            .page = page,
            // A reload with `only: ['messages']` appends; an item with an
            // `id` the client already has replaces it in place.
            .messages = inertia.merge(InertiaMessages.pages[page - 1]).matchOn("id"),
            // Deferred, then deep-merged into the current object.
            .activity = inertia.deepMerge(inertia.deferred({}, InertiaMessages.activity)),
        });
    }
}

// PLUGINS.md "Scroll props".
const InertiaUsers = struct {
    const Member = struct { id: u32, name: []const u8 };
    const all = [_]Member{
        .{ .id = 1, .name = "Ada" },    .{ .id = 2, .name = "Grace" },
        .{ .id = 3, .name = "Edsger" }, .{ .id = 4, .name = "Barbara" },
        .{ .id = 5, .name = "Ken" },
    };
};

fn inertiaUsersRoute(ctx: *InertiaApp.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    if (req.onLiteral("users") and req.isRoot() and req.isGet()) {
        const per_page = 2;
        const users = &InertiaUsers.all;
        const last: u32 = @max(1, (users.len + per_page - 1) / per_page);
        // The route owns pagination: `<InfiniteScroll>` only sets `?page=`.
        const raw = (req.getOne("page") catch null) orelse "1";
        const page = std.fmt.parseInt(u32, raw, 10) catch 0;
        if (page < 1 or page > last) return res.text(404, "No such page");
        const start = (page - 1) * per_page;
        const inertia = zoda.plugins.inertia;
        return ctx.plugins.inertia.render(req, res, "Users/Index", .{
            .users = inertia.scroll(users[start..@min(start + per_page, users.len)], .{
                .previous = if (page > 1) page - 1 else null,
                .next = if (page < last) page + 1 else null,
                .current = page,
            }).matchOn("id"),
        });
    }
}

// PLUGINS.md "Once props".
const InertiaBilling = struct {
    const Store = struct { plans: []const []const u8, rate: u32 };
    var store: Store = .{ .plans = &.{ "free", "pro" }, .rate = 7 };
    var loads: usize = 0;

    const Plans = struct {
        fn load(s: *const Store, _: std.mem.Allocator) []const []const u8 {
            loads += 1;
            return s.plans;
        }
    };
    const Rates = struct {
        fn load(s: *const Store, _: std.mem.Allocator) u32 {
            loads += 1;
            return s.rate;
        }
    };

    fn unixMilliseconds() i64 {
        return 1_767_222_000_000;
    }
};

fn inertiaBillingRoute(ctx: *InertiaApp.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    const user = "ada";
    const store: *const InertiaBilling.Store = &InertiaBilling.store;
    const Plans = InertiaBilling.Plans;
    const Rates = InertiaBilling.Rates;
    if (req.onLiteral("plans") and req.isRoot() and req.isGet()) {
        const inertia = zoda.plugins.inertia;
        return ctx.plugins.inertia.render(req, res, "Billing/Plans", .{
            .user = user,
            // Resolved on the first visit, then reused by the client.
            .plans = inertia.once(store, Plans.load),
            // Shared with any other page that uses the key "rates"; the client
            // fetches it again after an hour.
            .exchange = inertia.once(store, Rates.load).as("rates").expiresIn(60 * 60 * 1000),
        });
    }
}

fn inertiaVisit(app: *const InertiaApp, method: zoda.router.Method, target: []const u8, headers: []const zoda.request.Header) !zoda.response.Response {
    var arena = try zoda.request.parseOriginForm(std.testing.allocator, .default, target);
    defer arena.deinit();
    try arena.copyHeaders(headers);
    var req = arena.requestView(method);
    return app.dispatch(&req);
}

test "PLUGINS Inertia.js example" {
    var app = try InertiaApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{ .inertia = .{
            .layout = inertia_layout,
            .version = .{ .value = "1" },
            .shared = .{ .value = .{ .app_name = "Zoda" } },
        } },
        .route_fn = inertiaRoute,
    });
    defer app.deinit();
    try app.plugins.inertia.validate();

    var page = try inertiaVisit(&app, .get, "/users?page=2", &.{});
    defer page.deinit();
    try std.testing.expectEqualStrings("text/html; charset=utf-8", page.content_type);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "<script data-page=\"app\" type=\"application/json\">{\"component\":\"Users/Index\"") != null);

    var json = try inertiaVisit(&app, .get, "/users?page=2", &.{ .{ .name = "X-Inertia", .value = "true" }, .{ .name = "X-Inertia-Version", .value = "1" } });
    defer json.deinit();
    try std.testing.expectEqualStrings(
        "{\"component\":\"Users/Index\",\"props\":{\"app_name\":\"Zoda\",\"users\":[\"ada\"],\"errors\":{}},\"url\":\"/users?page=2\",\"version\":\"1\",\"sharedProps\":[\"app_name\"]}",
        json.body,
    );

    var stale = try inertiaVisit(&app, .get, "/users?page=2", &.{ .{ .name = "X-Inertia", .value = "true" }, .{ .name = "X-Inertia-Version", .value = "0" } });
    defer stale.deinit();
    try std.testing.expectEqual(@as(u16, 409), stale.status_code);
    try std.testing.expectEqualStrings("/users?page=2", (try stale.getHeaderOne("X-Inertia-Location")).?);

    var created = try inertiaVisit(&app, .post, "/users", &.{.{ .name = "X-Inertia", .value = "true" }});
    defer created.deinit();
    try std.testing.expectEqual(@as(u16, 303), created.status_code);
    try std.testing.expectEqualStrings("/users", (try created.getHeaderOne("Location")).?);
}

test "PLUGINS Inertia.js partial reload example" {
    var app = try InertiaApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{ .inertia = .{ .layout = inertia_layout, .shared = .{ .value = .{ .app_name = "Zoda" } } } },
        .route_fn = inertiaReportRoute,
    });
    defer app.deinit();

    var full = try inertiaVisit(&app, .get, "/reports", &.{.{ .name = "X-Inertia", .value = "true" }});
    defer full.deinit();
    try std.testing.expectEqualStrings(
        "{\"component\":\"Reports/Index\",\"props\":{\"app_name\":\"Zoda\",\"ids\":[1,2,3],\"notice\":\"ready\",\"errors\":{}},\"url\":\"/reports\",\"version\":null,\"sharedProps\":[\"app_name\"]}",
        full.body,
    );

    // router.reload({ only: ['totals'] })
    var partial = try inertiaVisit(&app, .get, "/reports", &.{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Partial-Component", .value = "Reports/Index" },
        .{ .name = "X-Inertia-Partial-Data", .value = "totals" },
    });
    defer partial.deinit();
    try std.testing.expectEqualStrings(
        "{\"component\":\"Reports/Index\",\"props\":{\"totals\":[6],\"notice\":\"ready\",\"errors\":{}},\"url\":\"/reports\",\"version\":null,\"sharedProps\":[\"app_name\"]}",
        partial.body,
    );
}

test "PLUGINS Inertia.js deferred props example" {
    var app = try InertiaApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{ .inertia = .{ .layout = inertia_layout } },
        .route_fn = inertiaDashboardRoute,
    });
    defer app.deinit();

    var full = try inertiaVisit(&app, .get, "/dashboard", &.{.{ .name = "X-Inertia", .value = "true" }});
    defer full.deinit();
    try std.testing.expectEqualStrings(
        "{\"component\":\"Dashboard\",\"props\":{\"ids\":[1,2,3],\"errors\":{}},\"url\":\"/dashboard\",\"version\":null,\"deferredProps\":{\"default\":[\"stats\"],\"social\":[\"feed\"]}}",
        full.body,
    );

    // What the client sends for the "social" group.
    var social = try inertiaVisit(&app, .get, "/dashboard", &.{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Partial-Component", .value = "Dashboard" },
        .{ .name = "X-Inertia-Partial-Data", .value = "feed" },
    });
    defer social.deinit();
    try std.testing.expectEqualStrings(
        "{\"component\":\"Dashboard\",\"props\":{\"feed\":[6],\"errors\":{}},\"url\":\"/dashboard\",\"version\":null}",
        social.body,
    );
}

test "PLUGINS Inertia.js merge props example" {
    var app = try InertiaApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{ .inertia = .{ .layout = inertia_layout } },
        .route_fn = inertiaMessagesRoute,
    });
    defer app.deinit();

    var full = try inertiaVisit(&app, .get, "/messages", &.{.{ .name = "X-Inertia", .value = "true" }});
    defer full.deinit();
    try std.testing.expectEqualStrings(
        "{\"component\":\"Messages/Index\",\"props\":{\"page\":1,\"messages\":[{\"id\":1,\"text\":\"hi\"},{\"id\":2,\"text\":\"yo\"}],\"errors\":{}}," ++
            "\"url\":\"/messages\",\"version\":null,\"mergeProps\":[\"messages\"],\"matchPropsOn\":[\"messages.id\"],\"deferredProps\":{\"default\":[\"activity\"]}}",
        full.body,
    );

    // `router.reload({ data: { page: 2 }, only: ['messages', 'page'] })`.
    var next = try inertiaVisit(&app, .get, "/messages?page=2", &.{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Partial-Component", .value = "Messages/Index" },
        .{ .name = "X-Inertia-Partial-Data", .value = "messages,page" },
    });
    defer next.deinit();
    try std.testing.expectEqualStrings(
        "{\"component\":\"Messages/Index\",\"props\":{\"page\":2,\"messages\":[{\"id\":3,\"text\":\"hey\"}],\"errors\":{}}," ++
            "\"url\":\"/messages?page=2\",\"version\":null,\"mergeProps\":[\"messages\"],\"matchPropsOn\":[\"messages.id\"]}",
        next.body,
    );

    // `router.reload({ reset: ['messages'] })` replaces the list instead.
    var reset = try inertiaVisit(&app, .get, "/messages", &.{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Partial-Component", .value = "Messages/Index" },
        .{ .name = "X-Inertia-Partial-Data", .value = "messages" },
        .{ .name = "X-Inertia-Reset", .value = "messages" },
    });
    defer reset.deinit();
    try std.testing.expectEqualStrings(
        "{\"component\":\"Messages/Index\",\"props\":{\"messages\":[{\"id\":1,\"text\":\"hi\"},{\"id\":2,\"text\":\"yo\"}],\"errors\":{}},\"url\":\"/messages\",\"version\":null}",
        reset.body,
    );

    var activity = try inertiaVisit(&app, .get, "/messages", &.{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Partial-Component", .value = "Messages/Index" },
        .{ .name = "X-Inertia-Partial-Data", .value = "activity" },
    });
    defer activity.deinit();
    try std.testing.expectEqualStrings(
        "{\"component\":\"Messages/Index\",\"props\":{\"activity\":{\"events\":[7]},\"errors\":{}},\"url\":\"/messages\",\"version\":null,\"deepMergeProps\":[\"activity\"]}",
        activity.body,
    );
}

test "PLUGINS Inertia.js scroll props example" {
    var app = try InertiaApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{ .inertia = .{ .layout = inertia_layout } },
        .route_fn = inertiaUsersRoute,
    });
    defer app.deinit();

    var first = try inertiaVisit(&app, .get, "/users", &.{.{ .name = "X-Inertia", .value = "true" }});
    defer first.deinit();
    try std.testing.expectEqualStrings(
        "{\"component\":\"Users/Index\",\"props\":{\"users\":[{\"id\":1,\"name\":\"Ada\"},{\"id\":2,\"name\":\"Grace\"}],\"errors\":{}}," ++
            "\"url\":\"/users\",\"version\":null,\"mergeProps\":[\"users\"],\"matchPropsOn\":[\"users.id\"]," ++
            "\"scrollProps\":{\"users\":{\"pageName\":\"page\",\"previousPage\":null,\"nextPage\":2,\"currentPage\":1,\"reset\":false}}}",
        first.body,
    );

    // What `<InfiniteScroll data="users">` sends for the next page.
    var next = try inertiaVisit(&app, .get, "/users?page=2", &.{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Partial-Component", .value = "Users/Index" },
        .{ .name = "X-Inertia-Partial-Data", .value = "users" },
        .{ .name = "X-Inertia-Infinite-Scroll-Merge-Intent", .value = "append" },
    });
    defer next.deinit();
    try std.testing.expectEqualStrings(
        "{\"component\":\"Users/Index\",\"props\":{\"users\":[{\"id\":3,\"name\":\"Edsger\"},{\"id\":4,\"name\":\"Barbara\"}],\"errors\":{}}," ++
            "\"url\":\"/users?page=2\",\"version\":null,\"mergeProps\":[\"users\"],\"matchPropsOn\":[\"users.id\"]," ++
            "\"scrollProps\":{\"users\":{\"pageName\":\"page\",\"previousPage\":1,\"nextPage\":3,\"currentPage\":2,\"reset\":false}}}",
        next.body,
    );

    // Opened at `?page=3`, scrolling up prepends page 2.
    var previous = try inertiaVisit(&app, .get, "/users?page=2", &.{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Partial-Component", .value = "Users/Index" },
        .{ .name = "X-Inertia-Partial-Data", .value = "users" },
        .{ .name = "X-Inertia-Infinite-Scroll-Merge-Intent", .value = "prepend" },
    });
    defer previous.deinit();
    try std.testing.expect(std.mem.indexOf(u8, previous.body, "\"prependProps\":[\"users\"],\"matchPropsOn\":[\"users.id\"],\"scrollProps\"") != null);

    var bad = try inertiaVisit(&app, .get, "/users?page=4", &.{.{ .name = "X-Inertia", .value = "true" }});
    defer bad.deinit();
    try std.testing.expectEqual(@as(u16, 404), bad.status_code);
    try std.testing.expectError(error.MalformedPartialHeader, inertiaVisit(&app, .get, "/users?page=2", &.{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Partial-Component", .value = "Users/Index" },
        .{ .name = "X-Inertia-Infinite-Scroll-Merge-Intent", .value = "down" },
    }));
}

test "PLUGINS Inertia.js once props example" {
    var app = try InertiaApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{ .inertia = .{
            .layout = inertia_layout,
            .now_milliseconds = InertiaBilling.unixMilliseconds,
        } },
        .route_fn = inertiaBillingRoute,
    });
    defer app.deinit();
    InertiaBilling.loads = 0;

    const entries = "\"onceProps\":{\"plans\":{\"prop\":\"plans\",\"expiresAt\":null},\"rates\":{\"prop\":\"exchange\",\"expiresAt\":1767225600000}}}";
    var first = try inertiaVisit(&app, .get, "/plans", &.{.{ .name = "X-Inertia", .value = "true" }});
    defer first.deinit();
    try std.testing.expectEqualStrings(
        "{\"component\":\"Billing/Plans\",\"props\":{\"user\":\"ada\",\"plans\":[\"free\",\"pro\"],\"exchange\":7,\"errors\":{}}," ++
            "\"url\":\"/plans\",\"version\":null," ++ entries,
        first.body,
    );
    try std.testing.expectEqual(@as(usize, 2), InertiaBilling.loads);

    // The client holds both values, so neither is resolved again.
    var later = try inertiaVisit(&app, .get, "/plans", &.{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Except-Once-Props", .value = "plans,rates" },
    });
    defer later.deinit();
    try std.testing.expectEqualStrings(
        "{\"component\":\"Billing/Plans\",\"props\":{\"user\":\"ada\",\"errors\":{}},\"url\":\"/plans\",\"version\":null," ++ entries,
        later.body,
    );
    try std.testing.expectEqual(@as(usize, 2), InertiaBilling.loads);

    // `router.reload({ only: ['plans'] })` asks for it anyway.
    var reload = try inertiaVisit(&app, .get, "/plans", &.{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Partial-Component", .value = "Billing/Plans" },
        .{ .name = "X-Inertia-Partial-Data", .value = "plans" },
        .{ .name = "X-Inertia-Except-Once-Props", .value = "plans,rates" },
    });
    defer reload.deinit();
    try std.testing.expectEqualStrings(
        "{\"component\":\"Billing/Plans\",\"props\":{\"plans\":[\"free\",\"pro\"],\"errors\":{}},\"url\":\"/plans\",\"version\":null," ++
            "\"onceProps\":{\"plans\":{\"prop\":\"plans\",\"expiresAt\":null}}}",
        reload.body,
    );
    try std.testing.expectEqual(@as(usize, 3), InertiaBilling.loads);
}

// PLUGINS.md "Inertia.js" flash: flash on POST, redirect, and send the
// message as the page's top-level `flash` on the next render, then save.
const InertiaFlashApp = zoda.app.App(struct {
    sessions: zoda.Sessions,
    flash: zoda.Flash = .{},
    inertia: zoda.Inertia(struct {}),
});

fn inertiaFlashRoute(ctx: *InertiaFlashApp.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    const session = &ctx.state.sessions;
    const inertia = &ctx.plugins.inertia;
    if (req.onLiteral("todos") and req.isRoot()) {
        if (req.method == .post) {
            try ctx.plugins.flash.add(session, "notice", "Todo added");
            try ctx.plugins.sessions.save(session, res);
            return inertia.redirect(req, res, "/todos");
        }
        try inertia.renderWith(req, res, "Todos/Index", .{}, .{
            .flash = .{ .plugin = &ctx.plugins.flash, .session = session },
        });
        // Persists that the messages were read, so they are sent once.
        return ctx.plugins.sessions.save(session, res);
    }
}

test "PLUGINS Inertia.js flash example" {
    var app = try InertiaFlashApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{
            .sessions = .{
                .keys = &.{.{ .id = 1, .secret = "example-secret-of-at-least-32-bytes!" }},
                .lifetime_seconds = 3600,
                .now_seconds = flashClock,
            },
            .inertia = .{ .layout = inertia_layout },
        },
        .route_fn = inertiaFlashRoute,
    });
    defer app.deinit();

    var cookies: [2][zoda.plugins.sessions.max_cookie_bytes]u8 = undefined;
    const Visit = struct {
        fn run(a: *const InertiaFlashApp, method: zoda.router.Method, cookie: ?[]const u8, out: []u8) !struct { zoda.response.Response, ?[]const u8 } {
            var arena = try zoda.request.parseOriginForm(std.testing.allocator, .default, "/todos");
            defer arena.deinit();
            const headers = [_]zoda.request.Header{
                .{ .name = "X-Inertia", .value = "true" },
                .{ .name = "Cookie", .value = cookie orelse "" },
            };
            try arena.copyHeaders(if (cookie != null) &headers else headers[0..1]);
            var req = arena.requestView(method);
            const res = try a.dispatch(&req);
            const set_cookie = (try res.getHeaderOne("Set-Cookie")) orelse return .{ res, null };
            const value = set_cookie[0..std.mem.indexOfScalar(u8, set_cookie, ';').?];
            @memcpy(out[0..value.len], value);
            return .{ res, out[0..value.len] };
        }
    };

    var posted, const pending = try Visit.run(&app, .post, null, &cookies[0]);
    defer posted.deinit();
    try std.testing.expectEqual(@as(u16, 303), posted.status_code);

    var shown, const read = try Visit.run(&app, .get, pending, &cookies[1]);
    defer shown.deinit();
    try std.testing.expectEqualStrings(
        "{\"component\":\"Todos/Index\",\"props\":{\"errors\":{}},\"url\":\"/todos\",\"version\":null,\"flash\":{\"notice\":\"Todo added\"}}",
        shown.body,
    );

    var after, const unchanged = try Visit.run(&app, .get, read, &cookies[0]);
    defer after.deinit();
    try std.testing.expectEqualStrings("{\"component\":\"Todos/Index\",\"props\":{\"errors\":{}},\"url\":\"/todos\",\"version\":null}", after.body);
    try std.testing.expect(unchanged == null);
}

// PLUGINS.md "Inertia.js" validation errors: a failed POST stores its errors
// and redirects back; the next render sends them as `props.errors` once.
fn inertiaErrorsRoute(ctx: *InertiaFlashApp.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    const session = &ctx.state.sessions;
    const inertia = &ctx.plugins.inertia;
    const source: zoda.plugins.inertia.FlashSource = .{ .plugin = &ctx.plugins.flash, .session = session };
    if (req.onLiteral("todos") and req.isRoot()) {
        if (req.method == .post) {
            // The route names the page to go back to; `Referer` is not used.
            try inertia.redirectWithErrors(req, res, source, "/todos", .{ .text = "Write something first." });
            return ctx.plugins.sessions.save(session, res);
        }
        try inertia.renderWith(req, res, "Todos/Index", .{}, .{ .flash = source });
        return ctx.plugins.sessions.save(session, res);
    }
}

test "PLUGINS Inertia.js validation errors example" {
    var app = try InertiaFlashApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{
            .sessions = .{
                .keys = &.{.{ .id = 1, .secret = "example-secret-of-at-least-32-bytes!" }},
                .lifetime_seconds = 3600,
                .now_seconds = flashClock,
            },
            .inertia = .{ .layout = inertia_layout },
        },
        .route_fn = inertiaErrorsRoute,
    });
    defer app.deinit();

    var cookies: [2][zoda.plugins.sessions.max_cookie_bytes]u8 = undefined;
    const Visit = struct {
        fn run(a: *const InertiaFlashApp, method: zoda.router.Method, cookie: ?[]const u8, out: []u8) !struct { zoda.response.Response, ?[]const u8 } {
            var arena = try zoda.request.parseOriginForm(std.testing.allocator, .default, "/todos");
            defer arena.deinit();
            const headers = [_]zoda.request.Header{
                .{ .name = "X-Inertia", .value = "true" },
                .{ .name = "X-Inertia-Error-Bag", .value = "createTodo" },
                .{ .name = "Cookie", .value = cookie orelse "" },
            };
            try arena.copyHeaders(if (cookie != null) &headers else headers[0..2]);
            var req = arena.requestView(method);
            const res = try a.dispatch(&req);
            const set_cookie = (try res.getHeaderOne("Set-Cookie")) orelse return .{ res, null };
            const value = set_cookie[0..std.mem.indexOfScalar(u8, set_cookie, ';').?];
            @memcpy(out[0..value.len], value);
            return .{ res, out[0..value.len] };
        }
    };

    var posted, const pending = try Visit.run(&app, .post, null, &cookies[0]);
    defer posted.deinit();
    try std.testing.expectEqual(@as(u16, 303), posted.status_code);
    try std.testing.expectEqualStrings("/todos", (try posted.getHeaderOne("Location")).?);

    var shown, const read = try Visit.run(&app, .get, pending, &cookies[1]);
    defer shown.deinit();
    try std.testing.expectEqualStrings(
        "{\"component\":\"Todos/Index\",\"props\":{\"errors\":{\"createTodo\":{\"text\":\"Write something first.\"}}},\"url\":\"/todos\",\"version\":null}",
        shown.body,
    );

    var after, const unchanged = try Visit.run(&app, .get, read, &cookies[0]);
    defer after.deinit();
    try std.testing.expectEqualStrings("{\"component\":\"Todos/Index\",\"props\":{\"errors\":{}},\"url\":\"/todos\",\"version\":null}", after.body);
    try std.testing.expect(unchanged == null);
}

// PLUGINS.md "Inertia.js" history encryption: every page is encrypted, a
// logout asks the page it redirects to to clear history, and an error page
// is rendered with its own status.
fn inertiaHistoryRoute(ctx: *InertiaFlashApp.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    const inertia = &ctx.plugins.inertia;
    const source: zoda.plugins.inertia.FlashSource = .{ .plugin = &ctx.plugins.flash, .session = &ctx.state.sessions };
    if (req.onLiteral("logout") and req.isRoot() and req.method == .post) {
        ctx.state.sessions.clear();
        try inertia.clearHistoryOnNextRender(source);
        try ctx.plugins.sessions.save(&ctx.state.sessions, res);
        return inertia.redirect(req, res, "/login");
    }
    if (req.onLiteral("login") and req.isRoot()) {
        try inertia.renderWith(req, res, "Auth/Login", .{}, .{ .flash = source });
        return ctx.plugins.sessions.save(&ctx.state.sessions, res);
    }
    return inertia.renderWith(req, res, "Errors/NotFound", .{ .path = req.target }, .{ .status = 404 });
}

test "PLUGINS Inertia.js history encryption example" {
    var app = try InertiaFlashApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{
            .sessions = .{
                .keys = &.{.{ .id = 1, .secret = "example-secret-of-at-least-32-bytes!" }},
                .lifetime_seconds = 3600,
                .now_seconds = flashClock,
            },
            .inertia = .{ .layout = inertia_layout, .encrypt_history = true },
        },
        .route_fn = inertiaHistoryRoute,
    });
    defer app.deinit();

    var cookie: [zoda.plugins.sessions.max_cookie_bytes]u8 = undefined;
    const Visit = struct {
        fn run(a: *const InertiaFlashApp, method: zoda.router.Method, target: []const u8, session: ?[]const u8) !zoda.response.Response {
            var arena = try zoda.request.parseOriginForm(std.testing.allocator, .default, target);
            defer arena.deinit();
            const headers = [_]zoda.request.Header{
                .{ .name = "X-Inertia", .value = "true" },
                .{ .name = "Cookie", .value = session orelse "" },
            };
            try arena.copyHeaders(if (session != null) &headers else headers[0..1]);
            var req = arena.requestView(method);
            return a.dispatch(&req);
        }
    };

    var logged_out = try Visit.run(&app, .post, "/logout", null);
    defer logged_out.deinit();
    try std.testing.expectEqualStrings("/login", (try logged_out.getHeaderOne("Location")).?);
    const set_cookie = (try logged_out.getHeaderOne("Set-Cookie")).?;
    const value = set_cookie[0..std.mem.indexOfScalar(u8, set_cookie, ';').?];
    @memcpy(cookie[0..value.len], value);

    var login = try Visit.run(&app, .get, "/login", cookie[0..value.len]);
    defer login.deinit();
    try std.testing.expectEqualStrings(
        "{\"component\":\"Auth/Login\",\"props\":{\"errors\":{}},\"url\":\"/login\",\"version\":null,\"encryptHistory\":true,\"clearHistory\":true}",
        login.body,
    );

    var missing = try Visit.run(&app, .get, "/nope", null);
    defer missing.deinit();
    try std.testing.expectEqual(@as(u16, 404), missing.status_code);
    try std.testing.expectEqualStrings(
        "{\"component\":\"Errors/NotFound\",\"props\":{\"path\":\"/nope\",\"errors\":{}},\"url\":\"/nope\",\"version\":null,\"encryptHistory\":true}",
        missing.body,
    );
}

// PLUGINS.md "Inertia.js" precognition: the submit route validates, then
// answers a precognitive request before storing anything.
fn inertiaPrecognitionRoute(ctx: *InertiaApp.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    if (!req.onLiteral("todos") or !req.isRoot() or req.method != .post) return;
    const text = req.body;
    const problem: ?[]const u8 = if (text.len == 0) "Write something first." else null;
    if (try zoda.plugins.inertia.precognition(req) != null) {
        return ctx.plugins.inertia.answerPrecognition(req, res, .{ .text = problem });
    }
    if (problem != null) return res.text(422, "invalid");
    return res.text(201, "stored");
}

test "PLUGINS Inertia.js precognition example" {
    var app = try InertiaApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{ .inertia = .{ .layout = inertia_layout } },
        .route_fn = inertiaPrecognitionRoute,
    });
    defer app.deinit();
    const Visit = struct {
        fn run(a: *const InertiaApp, headers: []const zoda.request.Header, body: []const u8) !zoda.response.Response {
            var arena = try zoda.request.parseOriginForm(std.testing.allocator, .default, "/todos");
            defer arena.deinit();
            try arena.copyHeaders(headers);
            try arena.copyBody(body);
            var req = arena.requestView(.post);
            return a.dispatch(&req);
        }
    };
    const precognitive = [_]zoda.request.Header{
        .{ .name = "Precognition", .value = "true" },
        .{ .name = "Precognition-Validate-Only", .value = "text" },
    };

    var invalid = try Visit.run(&app, &precognitive, "");
    defer invalid.deinit();
    try std.testing.expectEqual(@as(u16, 422), invalid.status_code);
    try std.testing.expectEqualStrings("{\"errors\":{\"text\":\"Write something first.\"}}", invalid.body);
    try std.testing.expectEqualStrings("Precognition", (try invalid.getHeaderOne("Vary")).?);

    var valid = try Visit.run(&app, &precognitive, "Buy milk");
    defer valid.deinit();
    try std.testing.expectEqual(@as(u16, 204), valid.status_code);
    try std.testing.expectEqualStrings("true", (try valid.getHeaderOne("Precognition-Success")).?);

    var submitted = try Visit.run(&app, &.{}, "Buy milk");
    defer submitted.deinit();
    try std.testing.expectEqual(@as(u16, 201), submitted.status_code);
    try std.testing.expect((try submitted.getHeaderOne("Precognition")) == null);
}
