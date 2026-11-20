//! Declarative route table that makes protection visible at registration.
//!
//! Every route states its `access` (`.public` or `.protected`) with no
//! default, so omitting the decision is a compile error. The table runs, in
//! this order, before any handler code:
//!
//!   1. authentication for `.protected` routes  -> 401
//!   2. CSRF proof for unsafe methods           -> 403
//!   3. the handler (which may then read the body and cause side effects)
//!
//! Unsafe methods (everything except GET, HEAD, OPTIONS, TRACE) require CSRF
//! proof unless the route says `.csrf = .exempt`. The table is plain comptime
//! data, so tests can enumerate the same array the router dispatches on.
//!
//! The table protects only what it dispatches. A responder that runs before
//! the route function (static files, an earlier middleware that short
//! circuits) is not covered; use `gate` for those. See PLUGINS.md.
const std = @import("std");
const router = @import("router.zig");
const response = @import("response.zig");
const csrf = @import("plugins/csrf.zig");
const bearer_token = @import("plugins/bearer_token.zig");

pub const Access = enum { public, protected };
pub const CsrfPolicy = enum {
    /// Require proof. This is also what an unset policy means for unsafe methods.
    required,
    /// An explicit, reviewable opt-out, e.g. for bearer-token API clients that
    /// carry no ambient credential, or a webhook authenticated another way.
    exempt,
};

/// True for methods that RFC 9110 defines as safe.
pub fn isSafe(method: router.Method) bool {
    return switch (method) {
        .get, .head, .options, .trace => true,
        else => false,
    };
}

/// One row of the route map, for tests and documentation.
pub const Entry = struct {
    method: router.Method,
    path: []const u8,
    access: Access,
    csrf_required: bool,
};

/// Captured `:name` segments of the matched route, borrowed from the request.
pub const Params = struct {
    items: []const []const u8 = &.{},

    pub fn get(self: Params, index: usize) []const u8 {
        return self.items[index];
    }

    pub fn int(self: Params, comptime T: type, index: usize) ?T {
        return std.fmt.parseInt(T, self.items[index], 10) catch null;
    }
};

pub fn Options(comptime AppT: type) type {
    return struct {
        /// Decides whether the request is authenticated. Required when any
        /// route is `.protected`. It must fail closed.
        authenticate: ?*const fn (*AppT.Context, *const router.Request) bool = null,
        /// Value of `WWW-Authenticate` on 401, e.g. `bearer_token.challenge`.
        challenge: ?[]const u8 = null,
        /// Name of the `Sessions` plugin field whose CSRF secret is checked.
        /// Required when any route enforces CSRF.
        csrf_sessions: ?[]const u8 = null,
        /// Header carrying the token (`csrf.header_name` or
        /// `csrf.xsrf_header_name`).
        csrf_header: []const u8 = csrf.header_name,
    };
}

/// An authenticator for `BearerToken` registered as plugin `name`.
pub fn bearerAuth(comptime AppT: type, comptime name: []const u8) *const fn (*AppT.Context, *const router.Request) bool {
    return struct {
        fn run(ctx: *AppT.Context, req: *const router.Request) bool {
            return @field(ctx.plugins, name).authorized(req);
        }
    }.run;
}

/// An authenticator for a revocable cookie session registered as plugin
/// `name`: true only when the session is bound to a subject. Without a
/// configured `Sessions.store` no session has a subject, so it fails closed.
pub fn sessionAuth(comptime AppT: type, comptime name: []const u8) *const fn (*AppT.Context, *const router.Request) bool {
    return struct {
        fn run(ctx: *AppT.Context, _: *const router.Request) bool {
            return @field(ctx.state, name).subject().len > 0;
        }
    }.run;
}

pub fn Table(comptime AppT: type, comptime opts: Options(AppT)) type {
    return struct {
        pub const Handler = *const fn (*AppT.Context, *router.Request, *response.Response, Params) anyerror!void;

        pub const Route = struct {
            method: router.Method,
            /// Absolute pattern: `/`, `/notes`, `/notes/:id`. A `:name`
            /// segment matches any one non-empty segment.
            path: []const u8,
            /// No default: every route must say whether it is public.
            access: Access,
            /// Unset means "required for unsafe methods".
            csrf: ?CsrfPolicy = null,
            handler: Handler,
        };

        pub fn csrfRequired(comptime r: Route) bool {
            return if (r.csrf) |policy| policy == .required else !isSafe(r.method);
        }

        /// The route map: what the table enforces, derived from the table.
        pub fn entries(comptime routes: []const Route) [routes.len]Entry {
            return comptime blk: {
                var out: [routes.len]Entry = undefined;
                for (routes, 0..) |r, i| out[i] = .{
                    .method = r.method,
                    .path = r.path,
                    .access = r.access,
                    .csrf_required = csrfRequired(r),
                };
                break :blk out;
            };
        }

        /// Returns the route function. Pass it through `App.composeRoute`
        /// when plugins also contribute route wrappers.
        pub fn route(comptime routes: []const Route) AppT.RouteFn {
            comptime validate(routes);
            return struct {
                fn run(ctx: *AppT.Context, req: *router.Request, res: *response.Response) anyerror!void {
                    inline for (routes) |r| {
                        if (r.method == req.method) {
                            var buffer: [maxParams(r.path)][]const u8 = undefined;
                            if (match(r.path, req, &buffer)) |params| {
                                return dispatchRoute(r, ctx, req, res, params);
                            }
                        }
                    }
                }
            }.run;
        }

        fn dispatchRoute(comptime r: Route, ctx: *AppT.Context, req: *router.Request, res: *response.Response, params: Params) anyerror!void {
            if (r.access == .protected) {
                if (!opts.authenticate.?(ctx, req)) return unauthorized(res);
            }
            if (comptime csrfRequired(r)) {
                const state = &@field(ctx.state, opts.csrf_sessions.?);
                if (!csrf.validHeader(req, state, opts.csrf_header)) {
                    return res.text(403, "Forbidden");
                }
            }
            req.cursor = req.segments.len;
            return r.handler(ctx, req, res, params);
        }

        fn unauthorized(res: *response.Response) !void {
            if (opts.challenge) |value| try res.setHeader("WWW-Authenticate", value);
            return res.text(401, "Unauthorized");
        }

        fn validate(comptime routes: []const Route) void {
            comptime {
                @setEvalBranchQuota(100_000);
                for (routes, 0..) |r, i| {
                    if (r.path.len == 0 or r.path[0] != '/') @compileError("route path must start with '/': " ++ r.path);
                    if (r.path.len > 1 and r.path[r.path.len - 1] == '/') @compileError("route path must not end with '/': " ++ r.path);
                    if (std.mem.indexOf(u8, r.path, "//") != null) @compileError("route path has an empty segment: " ++ r.path);
                    if (r.access == .protected and opts.authenticate == null) {
                        @compileError("protected route " ++ r.path ++ " needs Options.authenticate");
                    }
                    if (csrfRequired(r) and opts.csrf_sessions == null) {
                        @compileError("route " ++ r.path ++ " requires CSRF proof; set Options.csrf_sessions or mark it .csrf = .exempt");
                    }
                    for (routes[0..i]) |prior| {
                        if (prior.method == r.method and sameShape(prior.path, r.path)) {
                            @compileError("duplicate route: " ++ r.path);
                        }
                    }
                }
            }
        }

        fn sameShape(comptime a: []const u8, comptime b: []const u8) bool {
            var ia = std.mem.splitScalar(u8, a, '/');
            var ib = std.mem.splitScalar(u8, b, '/');
            while (true) {
                const sa = ia.next();
                const sb = ib.next();
                if (sa == null or sb == null) return sa == null and sb == null;
                const pa = sa.?.len > 0 and sa.?[0] == ':';
                const pb = sb.?.len > 0 and sb.?[0] == ':';
                if (pa != pb) return false;
                if (!pa and !std.mem.eql(u8, sa.?, sb.?)) return false;
            }
        }

        fn maxParams(comptime path: []const u8) usize {
            comptime {
                var n: usize = 0;
                var it = std.mem.splitScalar(u8, path, '/');
                while (it.next()) |seg| {
                    if (seg.len > 0 and seg[0] == ':') n += 1;
                }
                return n;
            }
        }

        /// Whole-path match from the request cursor: the pattern must consume
        /// every remaining segment. Does not mutate the request.
        fn match(comptime path: []const u8, req: *const router.Request, buffer: [][]const u8) ?Params {
            const remaining = req.segments[req.cursor..];
            var count: usize = 0;
            var idx: usize = 0;
            comptime var it = std.mem.splitScalar(u8, path[1..], '/');
            inline while (comptime it.next()) |seg| {
                if (comptime seg.len == 0) continue; // the root path "/"
                if (idx >= remaining.len) return null;
                const got = remaining[idx];
                if (comptime seg[0] == ':') {
                    if (got.len == 0) return null;
                    buffer[count] = got;
                    count += 1;
                } else if (!std.mem.eql(u8, seg, got)) return null;
                idx += 1;
            }
            if (idx != remaining.len) return null;
            return .{ .items = buffer[0..count] };
        }
    };
}

/// Requires authentication for requests under `prefix`, ahead of whatever
/// responds there. Register it BEFORE `static.middleware` (and after host
/// authorization) to protect files, because a middleware entry cannot guard a
/// responder that already answered. An empty prefix guards every path.
pub const Gate = struct {
    prefix: []const []const u8,
    challenge: ?[]const u8 = null,
};

pub fn gate(
    comptime AppT: type,
    comptime authenticate: *const fn (*AppT.Context, *const router.Request) bool,
    config: *const Gate,
) AppT.Middleware {
    const Impl = struct {
        fn invoke(raw: *const anyopaque, ctx: *AppT.Context, req: *router.Request, res: *response.Response, next: AppT.Next) anyerror!void {
            const cfg: *const Gate = @ptrCast(@alignCast(raw));
            const remaining = req.segments[req.cursor..];
            if (remaining.len >= cfg.prefix.len) {
                var under = true;
                for (cfg.prefix, remaining[0..cfg.prefix.len]) |want, got| {
                    if (!std.mem.eql(u8, want, got)) under = false;
                }
                if (under and !authenticate(ctx, req)) {
                    if (cfg.challenge) |value| try res.setHeader("WWW-Authenticate", value);
                    return res.text(401, "Unauthorized");
                }
            }
            return next.call(ctx, req, res);
        }
    };
    return .{ .config = config, .invoke = Impl.invoke };
}

const testing = std.testing;

test "table dispatches by method and path, captures params, and fails closed" {
    const Plugins = struct { auth: bearer_token.BearerToken };
    const A = @import("app.zig").App(Plugins);
    const T = Table(A, .{ .authenticate = bearerAuth(A, "auth"), .challenge = bearer_token.challenge });
    const H = struct {
        var calls: usize = 0;
        var last_id: ?u32 = null;
        fn validate(token: []const u8) bool {
            return std.mem.eql(u8, token, "ok");
        }
        fn open(_: *A.Context, _: *router.Request, res: *response.Response, _: Params) !void {
            calls += 1;
            try res.text(200, "open");
        }
        fn item(_: *A.Context, _: *router.Request, res: *response.Response, p: Params) !void {
            calls += 1;
            last_id = p.int(u32, 0);
            try res.text(200, "item");
        }
    };
    const routes = [_]T.Route{
        .{ .method = .get, .path = "/", .access = .public, .handler = H.open },
        .{ .method = .get, .path = "/items/:id", .access = .protected, .handler = H.item },
    };
    var app = try A.init(testing.allocator, .{
        .response_allocator = testing.allocator,
        .plugins = .{ .auth = .{ .validate = H.validate } },
        .route_fn = T.route(&routes),
    });
    defer app.deinit();

    var root: router.Request = .{ .method = .get, .segments = &.{} };
    var r1 = try app.dispatch(&root);
    defer r1.deinit();
    try testing.expectEqual(@as(u16, 200), r1.status_code);

    var anon: router.Request = .{ .method = .get, .segments = &.{ "items", "7" } };
    var r2 = try app.dispatch(&anon);
    defer r2.deinit();
    try testing.expectEqual(@as(u16, 401), r2.status_code);
    try testing.expectEqualStrings("Bearer", (try r2.getHeaderOne("WWW-Authenticate")).?);
    try testing.expectEqual(@as(usize, 1), H.calls);

    const good = [_]router.Header{.{ .name = "Authorization", .value = "Bearer ok" }};
    var authed: router.Request = .{ .method = .get, .segments = &.{ "items", "7" }, .headers = &good };
    var r3 = try app.dispatch(&authed);
    defer r3.deinit();
    try testing.expectEqual(@as(u16, 200), r3.status_code);
    try testing.expectEqual(@as(?u32, 7), H.last_id);

    // Wrong method, extra segment, and unknown path never reach a handler.
    for ([_]struct { router.Method, []const []const u8 }{
        .{ .get, &.{"items"} },
        .{ .get, &.{ "items", "7", "x" } },
        .{ .post, &.{} },
        .{ .get, &.{"nope"} },
    }) |c| {
        var req: router.Request = .{ .method = c[0], .segments = c[1], .headers = &good };
        var res = try app.dispatch(&req);
        defer res.deinit();
        try testing.expectEqual(@as(u16, 404), res.status_code);
    }
    try testing.expectEqual(@as(usize, 2), H.calls);

    const map = T.entries(&routes);
    try testing.expectEqual(Access.protected, map[1].access);
    try testing.expect(!map[1].csrf_required);
}

test "gate rejects unauthenticated requests under its prefix only" {
    const Plugins = struct { auth: bearer_token.BearerToken };
    const A = @import("app.zig").App(Plugins);
    const H = struct {
        fn validate(token: []const u8) bool {
            return std.mem.eql(u8, token, "ok");
        }
        fn route(_: *A.Context, _: *router.Request, res: *response.Response) !void {
            try res.text(200, "reached");
        }
    };
    const config: Gate = .{ .prefix = &.{"private"}, .challenge = "Bearer" };
    var app = try A.init(testing.allocator, .{
        .response_allocator = testing.allocator,
        .plugins = .{ .auth = .{ .validate = H.validate } },
        .route_fn = H.route,
        .middleware = &.{gate(A, bearerAuth(A, "auth"), &config)},
    });
    defer app.deinit();
    var denied: router.Request = .{ .method = .get, .segments = &.{ "private", "a.txt" } };
    var r1 = try app.dispatch(&denied);
    defer r1.deinit();
    try testing.expectEqual(@as(u16, 401), r1.status_code);
    var open: router.Request = .{ .method = .get, .segments = &.{"public"} };
    var r2 = try app.dispatch(&open);
    defer r2.deinit();
    try testing.expectEqual(@as(u16, 200), r2.status_code);
}
