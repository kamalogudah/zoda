//! Bounded Authorization Bearer parsing and an optional route guard.
//! Tokens are borrowed from request headers. Validation and identity lookup
//! belong to the application; this plugin never stores or reports tokens.
const std = @import("std");
const router = @import("../router.zig");
const response = @import("../response.zig");

pub const ParseError = error{ DuplicateAuthorization, MalformedAuthorization, CredentialTooLarge };
pub const challenge = "Bearer";

/// Parse exactly one Authorization field. The returned slice borrows `req`.
/// The scheme is case-insensitive; the separator is one SP and the credential
/// uses RFC 6750's b64token syntax (including optional trailing `=` padding).
pub fn parse(req: *const router.Request, max_token_bytes: usize) ParseError!?[]const u8 {
    const value = req.getHeaderOne("Authorization") catch return error.DuplicateAuthorization;
    const raw = value orelse return null;
    if (raw.len < 8 or !std.ascii.eqlIgnoreCase(raw[0..6], "Bearer") or raw[6] != ' ') {
        return error.MalformedAuthorization;
    }
    const token = raw[7..];
    if (token.len == 0) return error.MalformedAuthorization;
    if (token.len > max_token_bytes) return error.CredentialTooLarge;
    var padding = false;
    for (token) |c| {
        if (c == '=') {
            padding = true;
        } else if (padding or !isTokenByte(c)) {
            return error.MalformedAuthorization;
        }
    }
    return token;
}

fn isTokenByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or switch (c) {
        '-', '.', '_', '~', '+', '/' => true,
        else => false,
    };
}

pub const BearerToken = struct {
    /// Application callback. It must not retain the borrowed token slice.
    validate: *const fn ([]const u8) bool,
    max_token_bytes: usize = 4096,
    /// Set true and use `App.composeRoute` to guard the composed route.
    guard_routes: bool = false,

    pub fn token(self: *const BearerToken, req: *const router.Request) ParseError!?[]const u8 {
        return parse(req, self.max_token_bytes);
    }

    /// Invalid, absent, and malformed credentials all fail closed.
    pub fn authorized(self: *const BearerToken, req: *const router.Request) bool {
        const credential = (self.token(req) catch return false) orelse return false;
        return self.validate(credential);
    }

    /// Respond with a fixed challenge. No credential or parse detail appears
    /// in the response. Call explicitly from a route if desired.
    pub fn unauthorized(_: *const BearerToken, res: *response.Response) !void {
        try res.setHeader("WWW-Authenticate", challenge);
        try res.text(401, "Unauthorized");
    }

    pub fn wrapRoute(comptime H: type, comptime inner: H.RouteFn) H.RouteFn {
        return struct {
            fn run(ctx: *H.Context, req: *router.Request, res: *response.Response) anyerror!void {
                const self = H.plugin(ctx);
                if (self.guard_routes and !self.authorized(req)) return self.unauthorized(res);
                try inner(ctx, req, res);
            }
        }.run;
    }
};

test "bearer parser handles absent valid invalid duplicate malformed and oversized credentials" {
    const testing = std.testing;
    const empty: router.Request = .{ .method = .get, .segments = &.{} };
    try testing.expectEqual(@as(?[]const u8, null), try parse(&empty, 8));

    const valid_headers = [_]router.Header{.{ .name = "aUtHoRiZaTiOn", .value = "bEaReR a+/_~.=-" }};
    const valid: router.Request = .{ .method = .get, .segments = &.{}, .headers = &valid_headers };
    try testing.expectError(error.MalformedAuthorization, parse(&valid, 20));
    const good_headers = [_]router.Header{.{ .name = "Authorization", .value = "bEaReR a+/_~.-==" }};
    const good: router.Request = .{ .method = .get, .segments = &.{}, .headers = &good_headers };
    try testing.expectEqualStrings("a+/_~.-==", (try parse(&good, 20)).?);
    try testing.expectError(error.CredentialTooLarge, parse(&good, 3));

    const duplicates = [_]router.Header{ .{ .name = "Authorization", .value = "Bearer a" }, .{ .name = "authorization", .value = "Bearer b" } };
    const duplicate: router.Request = .{ .method = .get, .segments = &.{}, .headers = &duplicates };
    try testing.expectError(error.DuplicateAuthorization, parse(&duplicate, 20));

    for ([_][]const u8{ "Basic abc", "Bearer", "Bearer ", "Bearer  a", "Bearer\ta", "Bearer a b", "Bearer a\n", "Bearer a=b" }) |value| {
        const headers = [_]router.Header{.{ .name = "Authorization", .value = value }};
        const malformed: router.Request = .{ .method = .get, .segments = &.{}, .headers = &headers };
        try testing.expectError(error.MalformedAuthorization, parse(&malformed, 20));
    }
    const query_only: router.Request = .{ .method = .get, .segments = &.{}, .query = &.{.{ .key = "access_token", .value = "a" }} };
    try testing.expectEqual(@as(?[]const u8, null), try parse(&query_only, 20));
}

test "registered plugin validates routes and guards before NotFound" {
    const app_mod = @import("../app.zig");
    const NotFound = @import("not_found.zig").NotFound;
    const Plugins = struct { bearer: BearerToken, not_found: NotFound };
    const App = app_mod.App(Plugins);
    const Handler = struct {
        var calls: usize = 0;
        fn validate(token: []const u8) bool {
            return std.mem.eql(u8, token, "accepted");
        }
        fn route(_: *App.Context, req: *router.Request, res: *response.Response) !void {
            calls += 1;
            if (req.isLiteral("private")) return res.text(200, "ok");
        }
    };
    Handler.calls = 0;
    var app = try App.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{ .bearer = .{ .validate = Handler.validate, .guard_routes = true }, .not_found = .{ .body = "missing" } },
        .route_fn = App.composeRoute(Handler.route),
    });
    defer app.deinit();

    const valid_headers = [_]router.Header{.{ .name = "Authorization", .value = "Bearer accepted" }};
    var valid_req: router.Request = .{ .method = .get, .segments = &.{"private"}, .headers = &valid_headers };
    var valid_res = try app.dispatch(&valid_req);
    defer valid_res.deinit();
    try std.testing.expectEqual(@as(u16, 200), valid_res.status_code);
    try std.testing.expectEqual(@as(usize, 1), Handler.calls);

    var absent_req: router.Request = .{ .method = .get, .segments = &.{"private"} };
    var absent_res = try app.dispatch(&absent_req);
    defer absent_res.deinit();
    try std.testing.expectEqual(@as(u16, 401), absent_res.status_code);
    try std.testing.expectEqualStrings("Bearer", absent_res.headers[0].value);
    try std.testing.expectEqualStrings("Unauthorized", absent_res.body);
    try std.testing.expectEqual(@as(usize, 1), Handler.calls);

    const invalid_headers = [_]router.Header{.{ .name = "Authorization", .value = "Bearer denied" }};
    var invalid_req: router.Request = .{ .method = .get, .segments = &.{"private"}, .headers = &invalid_headers };
    var invalid_res = try app.dispatch(&invalid_req);
    defer invalid_res.deinit();
    try std.testing.expectEqual(@as(u16, 401), invalid_res.status_code);
    try std.testing.expectEqual(@as(usize, 1), Handler.calls);

    const duplicate_headers = [_]router.Header{ .{ .name = "Authorization", .value = "Bearer accepted" }, .{ .name = "AUTHORIZATION", .value = "Bearer accepted" } };
    const rejected_headers = .{
        &[_]router.Header{.{ .name = "Authorization", .value = "Bearer a b" }},
        &[_]router.Header{.{ .name = "Authorization", .value = "Bearer " ++ ("a" ** 4097) }},
        &duplicate_headers,
    };
    inline for (rejected_headers) |headers| {
        var rejected_req: router.Request = .{ .method = .get, .segments = &.{"private"}, .headers = headers };
        var rejected_res = try app.dispatch(&rejected_req);
        defer rejected_res.deinit();
        try std.testing.expectEqual(@as(u16, 401), rejected_res.status_code);
        try std.testing.expectEqualStrings("Unauthorized", rejected_res.body);
        try std.testing.expectEqual(@as(usize, 1), Handler.calls);
    }

    var missing_req: router.Request = .{ .method = .get, .segments = &.{"missing"}, .headers = &valid_headers };
    var missing_res = try app.dispatch(&missing_req);
    defer missing_res.deinit();
    try std.testing.expectEqual(@as(u16, 404), missing_res.status_code);
    try std.testing.expectEqualStrings("missing", missing_res.body);
    try std.testing.expectEqual(@as(usize, 2), Handler.calls);

    var unauthorized_missing_req: router.Request = .{ .method = .get, .segments = &.{"missing"} };
    var unauthorized_missing_res = try app.dispatch(&unauthorized_missing_req);
    defer unauthorized_missing_res.deinit();
    try std.testing.expectEqual(@as(u16, 401), unauthorized_missing_res.status_code);
    try std.testing.expectEqual(@as(usize, 2), Handler.calls);
}

test "NotFound outside bearer guard handles unauthenticated misses" {
    const app_mod = @import("../app.zig");
    const NotFound = @import("not_found.zig").NotFound;
    const Plugins = struct { not_found: NotFound, bearer: BearerToken };
    const App = app_mod.App(Plugins);
    const Handler = struct {
        fn validate(_: []const u8) bool {
            return false;
        }
        fn route(_: *App.Context, _: *router.Request, _: *response.Response) !void {}
    };
    var app = try App.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{ .not_found = .{ .body = "missing" }, .bearer = .{ .validate = Handler.validate, .guard_routes = true } },
        .route_fn = App.composeRoute(Handler.route),
    });
    defer app.deinit();
    var req: router.Request = .{ .method = .get, .segments = &.{"missing"} };
    var res = try app.dispatch(&req);
    defer res.deinit();
    // The inner guard already handled this request, so NotFound leaves it.
    try std.testing.expectEqual(@as(u16, 401), res.status_code);
}

test "route explicitly uses registered bearer plugin without wrapper guard" {
    const app_mod = @import("../app.zig");
    const Plugins = struct { auth: BearerToken };
    const App = app_mod.App(Plugins);
    const Handler = struct {
        fn validate(token: []const u8) bool {
            return std.mem.eql(u8, token, "ok");
        }
        fn route(ctx: *App.Context, req: *router.Request, res: *response.Response) !void {
            if (!ctx.plugins.auth.authorized(req)) return ctx.plugins.auth.unauthorized(res);
            try res.text(200, "accepted");
        }
    };
    var app = try App.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{ .auth = .{ .validate = Handler.validate } },
        .route_fn = Handler.route,
    });
    defer app.deinit();
    const headers = [_]router.Header{.{ .name = "Authorization", .value = "Bearer ok" }};
    var good_req: router.Request = .{ .method = .get, .segments = &.{}, .headers = &headers };
    var good_res = try app.dispatch(&good_req);
    defer good_res.deinit();
    try std.testing.expectEqual(@as(u16, 200), good_res.status_code);
    var missing_req: router.Request = .{ .method = .get, .segments = &.{} };
    var missing_res = try app.dispatch(&missing_req);
    defer missing_res.deinit();
    try std.testing.expectEqual(@as(u16, 401), missing_res.status_code);
    try std.testing.expectEqualStrings("Bearer", missing_res.headers[0].value);
}
