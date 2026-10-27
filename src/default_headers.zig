//! Configured default response headers for the full middleware chain.
//!
//! Register this entry before static serving and other middleware to cover
//! their short circuits. Headers are added only after downstream succeeds;
//! a response's existing field wins, regardless of its casing or repetition.
const std = @import("std");
const router = @import("router.zig");
const response = @import("response.zig");

pub const Config = struct {
    /// Borrowed, immutable fields; config and all nested slices must outlive
    /// the app. Each name may occur only once (case-insensitively).
    headers: []const response.Header,
};

pub const ConfigError = error{
    InvalidHeaderName,
    InvalidHeaderValue,
    DuplicateDefaultHeader,
    TransportOwnedHeader,
};

/// Validate at setup, before dispatch can partially add defaults. Response
/// header count and byte limits are still enforced on each actual response.
pub fn validate(config: *const Config) ConfigError!void {
    for (config.headers, 0..) |header, i| {
        try response.validateHeader(header.name, header.value);
        if (isTransportOwned(header.name)) return error.TransportOwnedHeader;
        for (config.headers[0..i]) |previous| {
            if (std.ascii.eqlIgnoreCase(previous.name, header.name)) return error.DuplicateDefaultHeader;
        }
    }
}

fn isTransportOwned(name: []const u8) bool {
    const names = [_][]const u8{
        "Content-Length",   "Transfer-Encoding", "Connection", "Keep-Alive",
        "Proxy-Connection", "TE",                "Trailer",    "Upgrade",
        "Content-Type",
    };
    for (names) |reserved| {
        if (std.ascii.eqlIgnoreCase(name, reserved)) return true;
    }
    return false;
}

/// Returns a middleware entry borrowing `config` until app shutdown. Put it
/// first to cover every downstream response, including static short circuits.
pub fn middleware(comptime AppT: type, config: *const Config) ConfigError!AppT.Middleware {
    try validate(config);
    const Impl = struct {
        fn invoke(
            raw: *const anyopaque,
            ctx: *AppT.Context,
            req: *router.Request,
            res: *response.Response,
            next: AppT.Next,
        ) anyerror!void {
            const cfg: *const Config = @ptrCast(@alignCast(raw));
            try next.call(ctx, req, res);
            for (cfg.headers) |header| {
                var existing = res.getAllHeaders(header.name);
                if (existing.next() == null) try res.setHeader(header.name, header.value);
            }
        }
    };
    return .{ .config = config, .invoke = Impl.invoke };
}

const testing = std.testing;
const app_mod = @import("app.zig");
const request = @import("request.zig");
const static = @import("static.zig");
const Plugins = struct {};
const App = app_mod.App(Plugins);

fn route(_: *App.Context, req: *router.Request, res: *response.Response) !void {
    if (req.isRoot()) {
        try res.text(200, "route");
        try res.setHeader("x-frame-options", "SAMEORIGIN");
        try res.setHeader("X-Frame-Options", "ALLOW-FROM same-origin");
    }
}

fn shortCircuit(
    _: *const anyopaque,
    _: *App.Context,
    _: *router.Request,
    res: *response.Response,
    _: App.Next,
) anyerror!void {
    try res.text(403, "blocked");
}

fn dispatch(app: *const App, target: []const u8) !response.Response {
    var arena = try request.parseOriginForm(testing.allocator, .default, target);
    defer arena.deinit();
    var req = arena.requestView(.get);
    return app.dispatch(&req);
}

test "configuration rejects invalid, duplicate, and transport-owned fields" {
    const valid = Config{ .headers = &.{.{ .name = "X-Frame-Options", .value = "DENY" }} };
    try validate(&valid);
    const invalid_name = Config{ .headers = &.{.{ .name = "bad name", .value = "x" }} };
    try testing.expectError(error.InvalidHeaderName, middleware(App, &invalid_name));
    const invalid_value = Config{ .headers = &.{.{ .name = "X-Test", .value = "a\r\nb" }} };
    try testing.expectError(error.InvalidHeaderValue, middleware(App, &invalid_value));
    const duplicate = Config{ .headers = &.{
        .{ .name = "X-Test", .value = "a" },
        .{ .name = "x-test", .value = "b" },
    } };
    try testing.expectError(error.DuplicateDefaultHeader, middleware(App, &duplicate));
    for ([_][]const u8{ "Content-Length", "transfer-encoding", "Connection", "Content-Type" }) |name| {
        const forbidden = Config{ .headers = &.{.{ .name = name, .value = "x" }} };
        try testing.expectError(error.TransportOwnedHeader, middleware(App, &forbidden));
    }
}

test "defaults cover route and 404 while existing repeated field wins" {
    const config = Config{ .headers = &.{
        .{ .name = "X-Frame-Options", .value = "DENY" },
        .{ .name = "Cache-Control", .value = "no-store" },
    } };
    var app = try App.init(testing.allocator, .{
        .response_allocator = testing.allocator,
        .plugins = .{},
        .route_fn = route,
        .middleware = &.{try middleware(App, &config)},
    });
    defer app.deinit();

    var ok = try dispatch(&app, "/");
    defer ok.deinit();
    try testing.expectEqual(@as(u16, 200), ok.status_code);
    var repeated = ok.getAllHeaders("X-Frame-Options");
    try testing.expectEqualStrings("SAMEORIGIN", repeated.next().?);
    try testing.expectEqualStrings("ALLOW-FROM same-origin", repeated.next().?);
    try testing.expect(repeated.next() == null);
    try testing.expectEqualStrings("no-store", (try ok.getHeaderOne("cache-control")).?);

    var miss = try dispatch(&app, "/missing");
    defer miss.deinit();
    try testing.expectEqual(@as(u16, 404), miss.status_code);
    try testing.expectEqualStrings("DENY", (try miss.getHeaderOne("X-Frame-Options")).?);
    try testing.expectEqualStrings("no-store", (try miss.getHeaderOne("Cache-Control")).?);
}

test "outer defaults cover middleware short circuits" {
    const config = Config{ .headers = &.{.{ .name = "X-Test", .value = "default" }} };
    const no_config: u8 = 0;
    var app = try App.init(testing.allocator, .{
        .response_allocator = testing.allocator,
        .plugins = .{},
        .route_fn = route,
        .middleware = &.{ try middleware(App, &config), .{ .config = &no_config, .invoke = shortCircuit } },
    });
    defer app.deinit();
    var res = try dispatch(&app, "/");
    defer res.deinit();
    try testing.expectEqual(@as(u16, 403), res.status_code);
    try testing.expectEqualStrings("default", (try res.getHeaderOne("X-Test")).?);
}

test "outer defaults cover confined static hits" {
    if (!static.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "asset.txt", .data = "asset" });
    const static_config = static.Config{ .root = tmp.dir };
    try static.checkSupport(tmp.dir);
    const config = Config{ .headers = &.{.{ .name = "Cache-Control", .value = "public, max-age=60" }} };
    var app = try App.init(testing.allocator, .{
        .response_allocator = testing.allocator,
        .plugins = .{},
        .route_fn = route,
        .middleware = &.{ try middleware(App, &config), static.middleware(App, &static_config) },
    });
    defer app.deinit();
    var res = try dispatch(&app, "/asset.txt");
    defer res.deinit();
    try testing.expectEqualStrings("asset", res.body);
    try testing.expectEqualStrings("public, max-age=60", (try res.getHeaderOne("Cache-Control")).?);
}

test "response header limits still apply to defaults" {
    const config = Config{ .headers = &.{.{ .name = "X-Test", .value = "default" }} };
    const entry = try middleware(App, &config);
    var res = response.Response.initWithLimits(testing.allocator, .{ .max_headers = 0 });
    defer res.deinit();
    const next_impl = struct {
        fn run(_: *anyopaque, _: *App.Context, _: *router.Request, out: *response.Response) anyerror!void {
            try out.text(200, "ok");
        }
    };
    var frame: u8 = 0;
    const plugins: Plugins = .{};
    var state: App.State = .{};
    const app_config: app_mod.AppConfig = .{};
    var ctx = App.Context{ .plugins = &plugins, .config = &app_config, .state = &state };
    var req = router.Request{ .method = .get, .segments = &.{} };
    const next = App.Next{ .frame = &frame, .invoke = next_impl.run };
    try testing.expectError(error.TooManyHeaders, entry.invoke(entry.config, &ctx, &req, &res, next));
    try testing.expectEqual(@as(usize, 0), res.header_count);

    var byte_limited = response.Response.initWithLimits(testing.allocator, .{ .header_bytes = 3 });
    defer byte_limited.deinit();
    try testing.expectError(error.HeaderBytesExceeded, entry.invoke(entry.config, &ctx, &req, &byte_limited, next));
    try testing.expectEqual(@as(usize, 0), byte_limited.header_count);
}
