//! Synchronizer tokens bound to the authenticated cookie session.
//! Issue on a safe request, explicitly save the session, then require the
//! token on each state-changing request before running the protected action.
const std = @import("std");
const router = @import("../router.zig");
const response = @import("../response.zig");
const sessions = @import("sessions.zig");

pub const header_name = "X-CSRF-Token";
/// The header Inertia's HTTP client and axios send, holding the value of the
/// `xsrf_cookie_name` cookie.
pub const xsrf_header_name = "X-XSRF-TOKEN";
/// The cookie Inertia's HTTP client and axios read the token from.
pub const xsrf_cookie_name = "XSRF-TOKEN";
pub const token_bytes = std.base64.url_safe_no_pad.Encoder.calcSize(32);

/// Returns a session-bound token. A new token dirties the session and needs
/// `Sessions.save` on the response before the browser can submit it.
pub fn token(io: std.Io, state: *sessions.Sessions.State) std.Io.RandomSecureError![]const u8 {
    if (!state.csrf_present) {
        try std.Io.randomSecure(io, &state.csrf_secret);
        state.csrf_present = true;
        state.dirty = true;
        state.clearing = false;
    }
    return std.base64.url_safe_no_pad.Encoder.encode(&state.csrf_token, &state.csrf_secret);
}

/// Rejects absent, duplicate, malformed, and cross-session tokens. Call this
/// before any protected side effect. Only one header field is accepted.
pub fn valid(req: *const router.Request, state: *const sessions.Sessions.State) bool {
    return validHeader(req, state, header_name);
}

/// `valid` reading the token from the header `name`, such as
/// `xsrf_header_name`. Only that header is read, and it must appear once.
pub fn validHeader(req: *const router.Request, state: *const sessions.Sessions.State, name: []const u8) bool {
    const supplied = (req.getHeaderOne(name) catch return false) orelse return false;
    return validToken(state, supplied);
}

/// Appends a `Set-Cookie` field that hands `issued`, a value from `token`, to
/// script on this origin as the `xsrf_cookie_name` cookie, with `Path=/`,
/// `Secure`, and `SameSite=Lax` but without `HttpOnly`, so the client can
/// copy it into `xsrf_header_name`. It expires with the browser session; the
/// session cookie, not this one, decides whether a token is valid. Anything
/// but a `token` value is `error.InvalidToken` and leaves the response
/// unchanged.
pub fn setXsrfCookie(res: *response.Response, issued: []const u8) (error{InvalidToken} || response.HeaderError)!void {
    if (issued.len != token_bytes) return error.InvalidToken;
    for (issued) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return error.InvalidToken;
    }
    const attributes = "; Path=/; Secure; SameSite=Lax";
    var header: [xsrf_cookie_name.len + 1 + token_bytes + attributes.len]u8 = undefined;
    const value = std.fmt.bufPrint(&header, xsrf_cookie_name ++ "={s}" ++ attributes, .{issued}) catch unreachable;
    try res.setHeader("Set-Cookie", value);
}

/// Use when the application has already extracted a token from a form body.
/// Reject duplicate form fields before calling this function.
pub fn validToken(state: *const sessions.Sessions.State, supplied: []const u8) bool {
    if (!state.csrf_present or supplied.len != token_bytes) return false;
    var expected: [token_bytes]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&expected, &state.csrf_secret);
    var actual: [token_bytes]u8 = undefined;
    @memcpy(&actual, supplied);
    return std.crypto.timing_safe.eql([token_bytes]u8, actual, expected);
}

test "CSRF token requires persistence and rejects missing, invalid, duplicate and cross-session submissions" {
    const plugin = sessions.Sessions{
        .keys = &.{.{ .id = 1, .secret = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }},
        .lifetime_seconds = 300,
        .now_seconds = struct {
            fn now() i64 {
                return 1000;
            }
        }.now,
    };
    var empty_req: router.Request = .{ .method = .get, .segments = &.{} };
    var first = try plugin.initRequest(&empty_req);
    const first_token = try token(std.testing.io, &first);
    try std.testing.expect(first.dirty);
    var res = response.Response.init(std.testing.allocator);
    defer res.deinit();
    try plugin.save(&first, &res);
    const cookie = res.headers[0].value[0..std.mem.indexOfScalar(u8, res.headers[0].value, ';').?];
    try std.testing.expect(std.mem.startsWith(u8, cookie, sessions.cookie_name ++ "=v2."));
    const cookie_headers = [_]router.Header{.{ .name = "Cookie", .value = cookie }};
    var loaded_req: router.Request = .{ .method = .get, .segments = &.{}, .headers = &cookie_headers };
    var loaded = try plugin.initRequest(&loaded_req);
    try std.testing.expect(!loaded.dirty);
    try std.testing.expectEqualStrings(first_token, try token(std.testing.io, &loaded));

    const good_headers = [_]router.Header{ .{ .name = "Cookie", .value = cookie }, .{ .name = header_name, .value = first_token } };
    const good: router.Request = .{ .method = .post, .segments = &.{}, .headers = &good_headers };
    try std.testing.expect(valid(&good, &loaded));
    const missing: router.Request = .{ .method = .post, .segments = &.{}, .headers = &cookie_headers };
    try std.testing.expect(!valid(&missing, &loaded));
    const bad_headers = [_]router.Header{.{ .name = header_name, .value = "invalid" }};
    const bad: router.Request = .{ .method = .post, .segments = &.{}, .headers = &bad_headers };
    try std.testing.expect(!valid(&bad, &loaded));
    const duplicate_headers = [_]router.Header{ .{ .name = header_name, .value = first_token }, .{ .name = header_name, .value = first_token } };
    const duplicate: router.Request = .{ .method = .post, .segments = &.{}, .headers = &duplicate_headers };
    try std.testing.expect(!valid(&duplicate, &loaded));

    var second = try plugin.initRequest(&empty_req);
    const second_token = try token(std.testing.io, &second);
    try std.testing.expect(!validToken(&second, first_token));
    try std.testing.expect(!std.mem.eql(u8, first_token, second_token));
    second.clear();
    try std.testing.expect(!validToken(&second, second_token));
}

test "CSRF header name is configurable and each name rejects duplicates and mismatches" {
    const plugin = sessions.Sessions{
        .keys = &.{.{ .id = 1, .secret = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }},
        .lifetime_seconds = 300,
        .now_seconds = struct {
            fn now() i64 {
                return 1000;
            }
        }.now,
    };
    var empty_req: router.Request = .{ .method = .get, .segments = &.{} };
    var state = try plugin.initRequest(&empty_req);
    const issued = try token(std.testing.io, &state);
    var other = try plugin.initRequest(&empty_req);
    const foreign = try token(std.testing.io, &other);

    inline for (.{ header_name, xsrf_header_name }, .{ xsrf_header_name, header_name }) |name, unread| {
        const good = [_]router.Header{.{ .name = name, .value = issued }};
        const good_req: router.Request = .{ .method = .post, .segments = &.{}, .headers = &good };
        try std.testing.expect(validHeader(&good_req, &state, name));
        // Only the named header is read.
        try std.testing.expect(!validHeader(&good_req, &state, unread));
        // Header names match case-insensitively.
        const lower = [_]router.Header{.{ .name = comptime lowerName(name), .value = issued }};
        const lower_req: router.Request = .{ .method = .post, .segments = &.{}, .headers = &lower };
        try std.testing.expect(validHeader(&lower_req, &state, name));

        const duplicate = [_]router.Header{ .{ .name = name, .value = issued }, .{ .name = name, .value = issued } };
        const duplicate_req: router.Request = .{ .method = .post, .segments = &.{}, .headers = &duplicate };
        try std.testing.expect(!validHeader(&duplicate_req, &state, name));
        const mismatch = [_]router.Header{.{ .name = name, .value = foreign }};
        const mismatch_req: router.Request = .{ .method = .post, .segments = &.{}, .headers = &mismatch };
        try std.testing.expect(!validHeader(&mismatch_req, &state, name));
        const missing_req: router.Request = .{ .method = .post, .segments = &.{} };
        try std.testing.expect(!validHeader(&missing_req, &state, name));
    }
    const xsrf_only = [_]router.Header{.{ .name = xsrf_header_name, .value = issued }};
    const xsrf_req: router.Request = .{ .method = .post, .segments = &.{}, .headers = &xsrf_only };
    try std.testing.expect(!valid(&xsrf_req, &state));
}

fn lowerName(comptime name: []const u8) []const u8 {
    var out: [name.len]u8 = undefined;
    _ = std.ascii.lowerString(&out, name);
    const final = out;
    return &final;
}

test "XSRF cookie is readable by script and refuses values that are not tokens" {
    const plugin = sessions.Sessions{
        .keys = &.{.{ .id = 1, .secret = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }},
        .lifetime_seconds = 300,
        .now_seconds = struct {
            fn now() i64 {
                return 1000;
            }
        }.now,
    };
    var empty_req: router.Request = .{ .method = .get, .segments = &.{} };
    var state = try plugin.initRequest(&empty_req);
    const issued = try token(std.testing.io, &state);
    var res = response.Response.init(std.testing.allocator);
    defer res.deinit();
    try setXsrfCookie(&res, issued);
    const cookie = (try res.getHeaderOne("Set-Cookie")).?;
    try std.testing.expect(std.mem.startsWith(u8, cookie, "XSRF-TOKEN="));
    try std.testing.expectEqualStrings(issued, cookie["XSRF-TOKEN=".len..][0..token_bytes]);
    try std.testing.expectEqualStrings("; Path=/; Secure; SameSite=Lax", cookie["XSRF-TOKEN=".len + token_bytes ..]);
    try std.testing.expect(std.mem.indexOf(u8, cookie, "HttpOnly") == null);

    try std.testing.expectError(error.InvalidToken, setXsrfCookie(&res, "short"));
    var bad: [token_bytes]u8 = @splat('a');
    bad[3] = ';';
    try std.testing.expectError(error.InvalidToken, setXsrfCookie(&res, &bad));
    try std.testing.expectEqual(@as(usize, 1), res.header_count);
}

test "existing v1 session upgrades when CSRF token is issued" {
    const plugin = sessions.Sessions{
        .keys = &.{.{ .id = 1, .secret = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }},
        .lifetime_seconds = 300,
        .now_seconds = struct {
            fn now() i64 {
                return 1000;
            }
        }.now,
    };
    var req: router.Request = .{ .method = .get, .segments = &.{} };
    var original = try plugin.initRequest(&req);
    try original.set("user=42");
    var res = response.Response.init(std.testing.allocator);
    defer res.deinit();
    try plugin.save(&original, &res);
    const v1 = res.headers[0].value[0..std.mem.indexOfScalar(u8, res.headers[0].value, ';').?];
    try std.testing.expect(std.mem.startsWith(u8, v1, sessions.cookie_name ++ "=v1."));

    const headers = [_]router.Header{.{ .name = "Cookie", .value = v1 }};
    var next_req: router.Request = .{ .method = .get, .segments = &.{}, .headers = &headers };
    var loaded = try plugin.initRequest(&next_req);
    try std.testing.expectEqualStrings("user=42", loaded.value());
    try std.testing.expect(!loaded.csrf_present);
    _ = try token(std.testing.io, &loaded);
    try std.testing.expect(loaded.dirty);
    try plugin.save(&loaded, &res);
    try std.testing.expect(std.mem.startsWith(u8, res.headers[1].value, sessions.cookie_name ++ "=v2."));
    try std.testing.expectEqualStrings("user=42", loaded.value());
}

test "registered session plugin persists CSRF token and gates protected route" {
    const app_mod = @import("../app.zig");
    const Plugins = struct { sessions: sessions.Sessions };
    const A = app_mod.App(Plugins);
    const Handler = struct {
        var actions: usize = 0;

        fn route(ctx: *A.Context, req: *router.Request, res: *response.Response) !void {
            if (req.method == .get and req.isLiteral("form")) {
                const issued = try token(std.testing.io, &ctx.state.sessions);
                try ctx.plugins.sessions.save(&ctx.state.sessions, res);
                return res.text(200, issued);
            }
            if (req.method == .post and req.isLiteral("submit")) {
                if (!valid(req, &ctx.state.sessions)) return res.text(403, "forbidden");
                actions += 1;
                return res.text(200, "accepted");
            }
        }
    };
    Handler.actions = 0;
    var app = try A.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{ .sessions = .{
            .keys = &.{.{ .id = 1, .secret = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }},
            .lifetime_seconds = 300,
            .now_seconds = struct {
                fn now() i64 {
                    return 1000;
                }
            }.now,
        } },
        .route_fn = Handler.route,
    });
    defer app.deinit();

    var form_req: router.Request = .{ .method = .get, .segments = &.{"form"} };
    var form_res = try app.dispatch(&form_req);
    defer form_res.deinit();
    try std.testing.expectEqual(@as(u16, 200), form_res.status_code);
    const session_cookie = form_res.headers[0].value[0..std.mem.indexOfScalar(u8, form_res.headers[0].value, ';').?];
    const issued = form_res.body;

    const valid_headers = [_]router.Header{ .{ .name = "Cookie", .value = session_cookie }, .{ .name = header_name, .value = issued } };
    var good_req: router.Request = .{ .method = .post, .segments = &.{"submit"}, .headers = &valid_headers };
    var good_res = try app.dispatch(&good_req);
    defer good_res.deinit();
    try std.testing.expectEqual(@as(u16, 200), good_res.status_code);
    try std.testing.expectEqual(@as(usize, 1), Handler.actions);

    const missing_headers = [_]router.Header{.{ .name = "Cookie", .value = session_cookie }};
    var missing_req: router.Request = .{ .method = .post, .segments = &.{"submit"}, .headers = &missing_headers };
    var missing_res = try app.dispatch(&missing_req);
    defer missing_res.deinit();
    try std.testing.expectEqual(@as(u16, 403), missing_res.status_code);

    const invalid_headers = [_]router.Header{ .{ .name = "Cookie", .value = session_cookie }, .{ .name = header_name, .value = "bad" } };
    var invalid_req: router.Request = .{ .method = .post, .segments = &.{"submit"}, .headers = &invalid_headers };
    var invalid_res = try app.dispatch(&invalid_req);
    defer invalid_res.deinit();
    try std.testing.expectEqual(@as(u16, 403), invalid_res.status_code);

    var other_form_req: router.Request = .{ .method = .get, .segments = &.{"form"} };
    var other_form_res = try app.dispatch(&other_form_req);
    defer other_form_res.deinit();
    const other_cookie = other_form_res.headers[0].value[0..std.mem.indexOfScalar(u8, other_form_res.headers[0].value, ';').?];
    const cross_headers = [_]router.Header{ .{ .name = "Cookie", .value = other_cookie }, .{ .name = header_name, .value = issued } };
    var cross_req: router.Request = .{ .method = .post, .segments = &.{"submit"}, .headers = &cross_headers };
    var cross_res = try app.dispatch(&cross_req);
    defer cross_res.deinit();
    try std.testing.expectEqual(@as(u16, 403), cross_res.status_code);
    try std.testing.expectEqual(@as(usize, 1), Handler.actions);
}
