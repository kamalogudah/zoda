//! Opt-in Content-Security-Policy, Permissions-Policy, and
//! Strict-Transport-Security response headers.
//!
//! Nothing is emitted unless configured. `middleware(App, &config)` validates
//! every policy string and the header budget at setup, then adds the
//! configured fields after downstream succeeds, on the response classes each
//! policy selects. A field the response already carries wins, whether a route
//! or an inner `default_headers` entry set it. Either all selected fields are
//! added or, when the response's header limits cannot hold them, none are.
//!
//! Coverage follows middleware order: an entry covers static files, error
//! recovery, status pages, and the default 404 only when it is registered
//! before them. Errors that propagate past it get no policy headers.
//!
//! HSTS is sent only when the configured `https` signal accepts the request.
//! Zoda terminates no TLS and reads no `X-Forwarded-Proto` or `Forwarded`
//! field, so the application must supply a signal it can authenticate.
const std = @import("std");
const router = @import("../router.zig");
const response = @import("../response.zig");

pub const content_security_policy_header = "Content-Security-Policy";
pub const content_security_policy_report_only_header = "Content-Security-Policy-Report-Only";
pub const permissions_policy_header = "Permissions-Policy";
pub const hsts_header = "Strict-Transport-Security";

/// HSTS preload lists require at least one year.
pub const min_preload_max_age: u32 = 31536000;

/// Response classes a policy is added to, by status. Dispatch turns an
/// unhandled response into the default 404 after middleware unwinds, so an
/// unhandled response counts as a client error.
pub const ResponseClasses = struct {
    /// 1xx and 2xx, including static-file hits.
    success: bool = true,
    /// 3xx, including 304 Not Modified.
    redirection: bool = true,
    /// 4xx, including the default and short-circuit 404.
    client_error: bool = true,
    /// 5xx, including `error_handler`'s recovery 500.
    server_error: bool = true,

    pub const all: ResponseClasses = .{};

    pub fn includes(self: ResponseClasses, status: u16) bool {
        return switch (status) {
            0 => self.client_error,
            100...299 => self.success,
            300...399 => self.redirection,
            400...499 => self.client_error,
            500...599 => self.server_error,
            else => false,
        };
    }

    fn any(self: ResponseClasses) bool {
        return self.success or self.redirection or self.client_error or self.server_error;
    }
};

/// One serialized policy. `value` is borrowed and must outlive the app.
pub const Policy = struct {
    value: []const u8,
    classes: ResponseClasses = .all,
};

pub fn Config(comptime AppT: type) type {
    return struct {
        /// Sent as `Content-Security-Policy`: one policy, `;`-separated
        /// directives, no `,` policy lists.
        content_security_policy: ?Policy = null,
        /// Sent as `Content-Security-Policy-Report-Only`. May be combined
        /// with an enforced policy to trial a stricter one.
        content_security_policy_report_only: ?Policy = null,
        /// Sent as `Permissions-Policy`: a structured-field dictionary such
        /// as `camera=(), geolocation=(self "https://maps.example")`.
        permissions_policy: ?Policy = null,
        hsts: ?Hsts = null,
        /// The response limits the app enforces; configured fields must fit
        /// in them together. `App.dispatch` uses `response.Limits.default`.
        limits: response.Limits = .default,

        /// Returns true only when the application can authenticate that this
        /// request reached it over HTTPS, for example because the listener is
        /// reachable only through a TLS terminator, or because the terminator
        /// proves itself with a secret it strips from client input. A
        /// client-supplied forwarded scheme is not such a signal.
        pub const HttpsSignal = *const fn (*AppT.Context, *const router.Request) bool;

        pub const Hsts = struct {
            max_age: u32,
            include_subdomains: bool = false,
            /// Requires `include_subdomains` and `max_age >= min_preload_max_age`.
            preload: bool = false,
            /// Required: there is deliberately no default signal.
            https: HttpsSignal,
            classes: ResponseClasses = .all,
        };
    };
}

pub const ConfigError = error{
    EmptyConfig,
    NoResponseClasses,
    InvalidContentSecurityPolicy,
    DuplicateDirective,
    InvalidPermissionsPolicy,
    DuplicateFeature,
    InvalidHstsPreload,
    TooManyHeaders,
    HeaderBytesExceeded,
};

/// Longest HSTS value `formatHsts` can produce.
const max_hsts_bytes = "max-age=4294967295; includeSubDomains; preload".len;

/// Validate at setup, before any response is touched.
pub fn validate(comptime AppT: type, config: *const Config(AppT)) ConfigError!void {
    var count: usize = 0;
    var bytes: usize = 0;
    if (config.content_security_policy) |policy| {
        try validateContentSecurityPolicy(policy.value);
        if (!policy.classes.any()) return error.NoResponseClasses;
        count += 1;
        bytes += content_security_policy_header.len + policy.value.len;
    }
    if (config.content_security_policy_report_only) |policy| {
        try validateContentSecurityPolicy(policy.value);
        if (!policy.classes.any()) return error.NoResponseClasses;
        count += 1;
        bytes += content_security_policy_report_only_header.len + policy.value.len;
    }
    if (config.permissions_policy) |policy| {
        try validatePermissionsPolicy(policy.value);
        if (!policy.classes.any()) return error.NoResponseClasses;
        count += 1;
        bytes += permissions_policy_header.len + policy.value.len;
    }
    if (config.hsts) |hsts| {
        if (hsts.preload and (!hsts.include_subdomains or hsts.max_age < min_preload_max_age)) {
            return error.InvalidHstsPreload;
        }
        if (!hsts.classes.any()) return error.NoResponseClasses;
        var buffer: [max_hsts_bytes]u8 = undefined;
        count += 1;
        bytes += hsts_header.len + formatHsts(&buffer, hsts.max_age, hsts.include_subdomains, hsts.preload).len;
    }
    if (count == 0) return error.EmptyConfig;
    if (count > config.limits.max_headers) return error.TooManyHeaders;
    if (bytes > config.limits.header_bytes) return error.HeaderBytesExceeded;
}

/// CSP3 §2.2.1 serialized-policy: `;`-separated directives, each a name of
/// ALPHA, DIGIT, or `-` and a value of printable ASCII other than `;` and
/// `,`. Empty directives between separators are allowed; at least one
/// directive and no repeated name (browsers ignore the repeat) are required.
pub fn validateContentSecurityPolicy(value: []const u8) error{ InvalidContentSecurityPolicy, DuplicateDirective }!void {
    for (value) |c| {
        if (c == ',' or !(c == ' ' or c == '\t' or (c >= 0x21 and c <= 0x7e))) return error.InvalidContentSecurityPolicy;
    }
    var directives: usize = 0;
    var it = std.mem.splitScalar(u8, value, ';');
    while (it.next()) |raw| {
        const directive = std.mem.trim(u8, raw, " \t");
        if (directive.len == 0) continue;
        const name = directiveName(directive);
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '-') return error.InvalidContentSecurityPolicy;
        }
        var previous = std.mem.splitScalar(u8, value[0 .. @intFromPtr(raw.ptr) - @intFromPtr(value.ptr)], ';');
        while (previous.next()) |prior| {
            const prior_directive = std.mem.trim(u8, prior, " \t");
            if (prior_directive.len != 0 and std.ascii.eqlIgnoreCase(directiveName(prior_directive), name)) {
                return error.DuplicateDirective;
            }
        }
        directives += 1;
    }
    if (directives == 0) return error.InvalidContentSecurityPolicy;
}

fn directiveName(directive: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, directive, " \t") orelse directive.len;
    return directive[0..end];
}

/// RFC 8941 dictionary as used by Permissions Policy: `feature=allowlist`
/// members separated by `,`, where an allowlist is a token (`*`, `self`), a
/// string origin, or an inner list of those, with optional parameters. A
/// bare `feature` (boolean true) is not an allowlist and is rejected, as is a
/// repeated feature (the last would silently win).
pub fn validatePermissionsPolicy(value: []const u8) error{ InvalidPermissionsPolicy, DuplicateFeature }!void {
    var parser = SfParser{ .input = value };
    parser.skip(' ');
    if (parser.done()) return error.InvalidPermissionsPolicy;
    while (true) {
        const key = parser.key() orelse return error.InvalidPermissionsPolicy;
        var prior = SfParser{ .input = value[0 .. parser.pos - key.len] };
        while (prior.nextKey()) |earlier| {
            if (std.mem.eql(u8, earlier, key)) return error.DuplicateFeature;
        }
        if (!parser.eat('=')) return error.InvalidPermissionsPolicy;
        if (parser.peek() == '(') {
            if (!parser.innerList()) return error.InvalidPermissionsPolicy;
        } else if (!parser.allowlistItem()) return error.InvalidPermissionsPolicy;
        if (!parser.parameters()) return error.InvalidPermissionsPolicy;
        parser.skipOws();
        if (parser.done()) return;
        if (!parser.eat(',')) return error.InvalidPermissionsPolicy;
        parser.skipOws();
        if (parser.done()) return error.InvalidPermissionsPolicy;
    }
}

/// Just enough of an RFC 8941 parser for Permissions-Policy values.
const SfParser = struct {
    input: []const u8,
    pos: usize = 0,

    fn done(self: *const SfParser) bool {
        return self.pos == self.input.len;
    }

    fn peek(self: *const SfParser) ?u8 {
        return if (self.done()) null else self.input[self.pos];
    }

    fn eat(self: *SfParser, c: u8) bool {
        if (self.peek() != c) return false;
        self.pos += 1;
        return true;
    }

    fn skip(self: *SfParser, c: u8) void {
        while (self.eat(c)) {}
    }

    fn skipOws(self: *SfParser) void {
        while (self.peek()) |c| {
            if (c != ' ' and c != '\t') return;
            self.pos += 1;
        }
    }

    /// key = ( lcalpha / "*" ) *( lcalpha / DIGIT / "_" / "-" / "." / "*" )
    fn key(self: *SfParser) ?[]const u8 {
        const start = self.pos;
        const first = self.peek() orelse return null;
        if (!std.ascii.isLower(first) and first != '*') return null;
        self.pos += 1;
        while (self.peek()) |c| {
            if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and std.mem.indexOfScalar(u8, "_-.*", c) == null) break;
            self.pos += 1;
        }
        return self.input[start..self.pos];
    }

    /// Yields the member keys of an already validated dictionary prefix.
    fn nextKey(self: *SfParser) ?[]const u8 {
        self.skipOws();
        const found = self.key() orelse return null;
        // Skip to the next top-level `,`, outside strings.
        var in_string = false;
        while (self.peek()) |c| : (self.pos += 1) {
            if (in_string) {
                if (c == '\\') self.pos += 1 else if (c == '"') in_string = false;
            } else if (c == '"') {
                in_string = true;
            } else if (c == ',') {
                self.pos += 1;
                break;
            }
        }
        return found;
    }

    /// An allowlist member: a token or a string.
    fn allowlistItem(self: *SfParser) bool {
        return if (self.peek() == '"') self.string() else self.token();
    }

    /// token = ( ALPHA / "*" ) *( tchar / ":" / "/" )
    fn token(self: *SfParser) bool {
        const first = self.peek() orelse return false;
        if (!std.ascii.isAlphabetic(first) and first != '*') return false;
        self.pos += 1;
        while (self.peek()) |c| {
            if (!isTchar(c) and c != ':' and c != '/') break;
            self.pos += 1;
        }
        return true;
    }

    /// sf-string: printable ASCII in quotes, escaping only `"` and `\`.
    fn string(self: *SfParser) bool {
        if (!self.eat('"')) return false;
        while (self.peek()) |c| {
            self.pos += 1;
            switch (c) {
                '"' => return true,
                '\\' => {
                    const escaped = self.peek() orelse return false;
                    if (escaped != '"' and escaped != '\\') return false;
                    self.pos += 1;
                },
                0x20...0x21, 0x23...0x5b, 0x5d...0x7e => {},
                else => return false,
            }
        }
        return false;
    }

    /// inner-list = "(" *SP [ item *( 1*SP item ) *SP ] ")" with per-item
    /// parameters.
    fn innerList(self: *SfParser) bool {
        if (!self.eat('(')) return false;
        self.skip(' ');
        while (!self.eat(')')) {
            if (!self.allowlistItem() or !self.parameters()) return false;
            const before = self.pos;
            self.skip(' ');
            if (self.peek() == ')') continue;
            if (self.pos == before) return false;
        }
        return true;
    }

    /// parameters = *( ";" *SP key [ "=" bare-item ] ), with token, string,
    /// boolean, or integer values.
    fn parameters(self: *SfParser) bool {
        while (self.eat(';')) {
            self.skip(' ');
            _ = self.key() orelse return false;
            if (!self.eat('=')) continue;
            const c = self.peek() orelse return false;
            if (c == '?') {
                self.pos += 1;
                if (!self.eat('0') and !self.eat('1')) return false;
            } else if (c == '-' or std.ascii.isDigit(c)) {
                _ = self.eat('-');
                const start = self.pos;
                while (self.peek()) |d| {
                    if (!std.ascii.isDigit(d)) break;
                    self.pos += 1;
                }
                if (self.pos == start or self.pos - start > 15) return false;
            } else if (!self.allowlistItem()) return false;
        }
        return true;
    }
};

fn isTchar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) != null;
}

fn formatHsts(buffer: *[max_hsts_bytes]u8, max_age: u32, include_subdomains: bool, preload: bool) []const u8 {
    return std.fmt.bufPrint(buffer, "max-age={d}{s}{s}", .{
        max_age,
        if (include_subdomains) "; includeSubDomains" else "",
        if (preload) "; preload" else "",
    }) catch unreachable;
}

/// Returns a middleware entry borrowing `config` until app shutdown. Register
/// it before the entries whose responses it should cover: static files,
/// `error_handler`, `status_handler`, and inner `default_headers`.
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
            try apply(AppT, cfg, ctx, req, res);
        }
    };
    return .{ .config = config, .invoke = Impl.invoke };
}

fn apply(
    comptime AppT: type,
    cfg: *const Config(AppT),
    ctx: *AppT.Context,
    req: *const router.Request,
    res: *response.Response,
) response.HeaderError!void {
    var hsts_buffer: [max_hsts_bytes]u8 = undefined;
    var fields: [4]response.Header = undefined;
    var count: usize = 0;
    const policies = [_]struct { name: []const u8, policy: ?Policy }{
        .{ .name = content_security_policy_header, .policy = cfg.content_security_policy },
        .{ .name = content_security_policy_report_only_header, .policy = cfg.content_security_policy_report_only },
        .{ .name = permissions_policy_header, .policy = cfg.permissions_policy },
    };
    for (policies) |entry| {
        const policy = entry.policy orelse continue;
        if (!policy.classes.includes(res.status_code) or present(res, entry.name)) continue;
        fields[count] = .{ .name = entry.name, .value = policy.value };
        count += 1;
    }
    if (cfg.hsts) |hsts| {
        if (hsts.classes.includes(res.status_code) and !present(res, hsts_header) and hsts.https(ctx, req)) {
            fields[count] = .{
                .name = hsts_header,
                .value = formatHsts(&hsts_buffer, hsts.max_age, hsts.include_subdomains, hsts.preload),
            };
            count += 1;
        }
    }

    // Check the whole set first so a limit never leaves a partial policy.
    var bytes: usize = 0;
    for (fields[0..count]) |field| bytes += field.name.len + field.value.len;
    if (res.header_count + count > res.limits.max_headers) return error.TooManyHeaders;
    if (res.header_bytes_used + bytes > res.limits.header_bytes) return error.HeaderBytesExceeded;
    for (fields[0..count]) |field| try res.setHeader(field.name, field.value);
}

fn present(res: *const response.Response, name: []const u8) bool {
    var existing = res.getAllHeaders(name);
    return existing.next() != null;
}

const testing = std.testing;
const app_mod = @import("../app.zig");
const request = @import("../request.zig");
const static = @import("../static.zig");
const default_headers = @import("../default_headers.zig");
const error_handler = @import("error_handler.zig");
const Plugins = struct {};
const App = app_mod.App(Plugins);
const AppConfig = Config(App);

const csp = "default-src 'self'; img-src 'self' https://img.example; frame-ancestors 'none'";
const permissions = "camera=(), geolocation=(self \"https://maps.example\"), fullscreen=*";

fn neverHttps(_: *App.Context, _: *const router.Request) bool {
    return false;
}

fn alwaysHttps(_: *App.Context, _: *const router.Request) bool {
    return true;
}

/// Test-only proxy contract: the terminator proves itself with a shared
/// secret it strips from client input.
fn proxySecretHttps(_: *App.Context, req: *const router.Request) bool {
    const proof = (req.getHeaderOne("X-Proxy-Secret") catch return false) orelse return false;
    return std.mem.eql(u8, proof, "s3cret");
}

fn route(_: *App.Context, req: *router.Request, res: *response.Response) !void {
    if (req.isRoot()) return res.text(200, "home");
    if (req.isLiteral("own-csp")) {
        try res.text(200, "own");
        return res.setHeader("content-security-policy", "default-src 'none'");
    }
    if (req.isLiteral("moved")) return res.redirectPath(.see_other, "/");
    if (req.isLiteral("denied")) return res.text(403, "denied");
    if (req.isLiteral("boom")) {
        try res.text(200, "partial");
        return error.RouteFailed;
    }
}

fn dispatchWith(app: *const App, target: []const u8, headers: []const router.Header) !response.Response {
    var arena = try request.parseOriginForm(testing.allocator, .default, target);
    defer arena.deinit();
    var req = arena.requestView(.get);
    req.headers = headers;
    return app.dispatch(&req);
}

fn dispatch(app: *const App, target: []const u8) !response.Response {
    return dispatchWith(app, target, &.{});
}

fn initApp(entries: []const App.Middleware) !App {
    return App.init(testing.allocator, .{
        .response_allocator = testing.allocator,
        .plugins = .{},
        .route_fn = route,
        .middleware = entries,
    });
}

test "content security policy validation" {
    for ([_][]const u8{
        csp,
        "default-src 'self'",
        "default-src 'self';",
        "  script-src 'nonce-abc123' 'strict-dynamic' ;; upgrade-insecure-requests",
        "report-to csp-endpoint",
    }) |valid| try validateContentSecurityPolicy(valid);

    for ([_][]const u8{
        "",
        " ; ",
        "default-src 'self', img-src *",
        "default-src 'self'\r\nX-Injected: 1",
        "default-src 'self' \x00",
        "default-src https://ex\xc3\xa4mple.test",
        "default_src 'self'",
        "default-src: 'self'",
    }) |invalid| try testing.expectError(error.InvalidContentSecurityPolicy, validateContentSecurityPolicy(invalid));

    try testing.expectError(error.DuplicateDirective, validateContentSecurityPolicy("script-src 'self'; img-src *; SCRIPT-SRC 'none'"));
}

test "permissions policy validation" {
    for ([_][]const u8{
        permissions,
        "camera=()",
        "geolocation=self",
        "fullscreen=*, payment=(  )",
        "camera=(self \"https://a.example\" \"https://b.example\");report-to=endpoint",
        "picture-in-picture=(\"https://q\\\"uote.example\")",
        "camera=();a=?1;b=-12",
    }) |valid| try validatePermissionsPolicy(valid);

    for ([_][]const u8{
        "",
        "Camera=()",
        "camera",
        "camera=",
        "camera=(),",
        ", camera=()",
        "camera=(self\"https://a.example\")",
        "camera=(self",
        "camera=\"unterminated",
        "camera=(\"bad\\escape\")",
        "camera=1",
        "camera=() geolocation=()",
        "camera=()\r\nX-Injected: 1",
        "camera=();a=",
    }) |invalid| try testing.expectError(error.InvalidPermissionsPolicy, validatePermissionsPolicy(invalid));

    try testing.expectError(error.DuplicateFeature, validatePermissionsPolicy("camera=(), geolocation=(\"a,camera\"), camera=*"));
    // A key inside a string is not a member.
    try validatePermissionsPolicy("geolocation=(\"x, camera=\"), camera=()");
}

test "configuration rejects empty, unselected, preload, and oversized policies" {
    try testing.expectError(error.EmptyConfig, middleware(App, &AppConfig{}));
    try testing.expectError(error.InvalidContentSecurityPolicy, middleware(App, &AppConfig{
        .content_security_policy_report_only = .{ .value = "a, b" },
    }));
    try testing.expectError(error.InvalidPermissionsPolicy, middleware(App, &AppConfig{
        .permissions_policy = .{ .value = "camera" },
    }));
    try testing.expectError(error.NoResponseClasses, middleware(App, &AppConfig{ .content_security_policy = .{
        .value = csp,
        .classes = .{ .success = false, .redirection = false, .client_error = false, .server_error = false },
    } }));
    for ([_]AppConfig.Hsts{
        .{ .max_age = min_preload_max_age, .preload = true, .https = alwaysHttps },
        .{ .max_age = min_preload_max_age - 1, .include_subdomains = true, .preload = true, .https = alwaysHttps },
    }) |hsts| try testing.expectError(error.InvalidHstsPreload, middleware(App, &AppConfig{ .hsts = hsts }));
    _ = try middleware(App, &AppConfig{ .hsts = .{ .max_age = 0, .https = alwaysHttps } });

    const both = AppConfig{
        .content_security_policy = .{ .value = csp },
        .permissions_policy = .{ .value = permissions },
        .limits = .{ .max_headers = 1 },
    };
    try testing.expectError(error.TooManyHeaders, middleware(App, &both));
    const tight = AppConfig{
        .content_security_policy = .{ .value = csp },
        .limits = .{ .header_bytes = content_security_policy_header.len + csp.len - 1 },
    };
    try testing.expectError(error.HeaderBytesExceeded, middleware(App, &tight));
    const hsts_tight = AppConfig{
        .hsts = .{ .max_age = 4294967295, .include_subdomains = true, .preload = true, .https = alwaysHttps },
        .limits = .{ .header_bytes = hsts_header.len + max_hsts_bytes - 1 },
    };
    try testing.expectError(error.HeaderBytesExceeded, middleware(App, &hsts_tight));
}

test "policies cover routes, redirects, default 404, and recovered errors" {
    const config = AppConfig{
        .content_security_policy = .{ .value = csp },
        .content_security_policy_report_only = .{ .value = "script-src 'none'" },
        .permissions_policy = .{ .value = permissions, .classes = .{ .client_error = false, .server_error = false } },
    };
    const recovery = error_handler.Config(App){};
    var app = try initApp(&.{ try middleware(App, &config), error_handler.middleware(App, &recovery) });
    defer app.deinit();

    const cases = [_]struct { target: []const u8, status: u16, permissions: bool }{
        .{ .target = "/", .status = 200, .permissions = true },
        .{ .target = "/moved", .status = 303, .permissions = true },
        .{ .target = "/denied", .status = 403, .permissions = false },
        .{ .target = "/missing", .status = 404, .permissions = false },
        .{ .target = "/boom", .status = 500, .permissions = false },
    };
    for (cases) |case| {
        var res = try dispatch(&app, case.target);
        defer res.deinit();
        try testing.expectEqual(case.status, res.status_code);
        try testing.expectEqualStrings(csp, (try res.getHeaderOne("content-security-policy")).?);
        try testing.expectEqualStrings("script-src 'none'", (try res.getHeaderOne(content_security_policy_report_only_header)).?);
        try testing.expectEqual(case.permissions, (try res.getHeaderOne(permissions_policy_header)) != null);
    }

    // A route's own field wins and is not repeated.
    var own = try dispatch(&app, "/own-csp");
    defer own.deinit();
    try testing.expectEqualStrings("default-src 'none'", (try own.getHeaderOne(content_security_policy_header)).?);
}

test "errors that propagate past the entry get no policy" {
    const config = AppConfig{ .content_security_policy = .{ .value = csp } };
    const recovery = error_handler.Config(App){};
    // Recovery outside the policy: the recovered 500 is not covered.
    var app = try initApp(&.{ error_handler.middleware(App, &recovery), try middleware(App, &config) });
    defer app.deinit();
    var res = try dispatch(&app, "/boom");
    defer res.deinit();
    try testing.expectEqual(@as(u16, 500), res.status_code);
    try testing.expect((try res.getHeaderOne(content_security_policy_header)) == null);

    var bare = try initApp(&.{try middleware(App, &config)});
    defer bare.deinit();
    try testing.expectError(error.RouteFailed, dispatch(&bare, "/boom"));
}

fn shortCircuit(_: *const anyopaque, ctx: *App.Context, req: *router.Request, res: *response.Response, next: App.Next) anyerror!void {
    if (std.mem.eql(u8, req.target, "/blocked")) return res.text(429, "slow down");
    if (std.mem.eql(u8, req.target, "/silent")) return;
    return next.call(ctx, req, res);
}

test "short circuits are covered, including the silent default 404" {
    const config = AppConfig{ .content_security_policy = .{ .value = csp, .classes = .{ .success = false } } };
    const no_config: u8 = 0;
    var app = try initApp(&.{ try middleware(App, &config), .{ .config = &no_config, .invoke = shortCircuit } });
    defer app.deinit();
    for ([_][]const u8{ "/blocked", "/silent" }) |target| {
        var res = try dispatch(&app, target);
        defer res.deinit();
        try testing.expect(res.status_code >= 400);
        try testing.expectEqualStrings(csp, (try res.getHeaderOne(content_security_policy_header)).?);
    }
}

test "middleware order with default headers: the inner value wins" {
    const config = AppConfig{
        .content_security_policy = .{ .value = csp },
        .permissions_policy = .{ .value = permissions },
    };
    const defaults = default_headers.Config{ .headers = &.{
        .{ .name = "Content-Security-Policy", .value = "default-src 'none'" },
        .{ .name = "X-Frame-Options", .value = "DENY" },
    } };

    var policy_outer = try initApp(&.{ try middleware(App, &config), try default_headers.middleware(App, &defaults) });
    defer policy_outer.deinit();
    var a = try dispatch(&policy_outer, "/");
    defer a.deinit();
    try testing.expectEqualStrings("default-src 'none'", (try a.getHeaderOne(content_security_policy_header)).?);
    try testing.expectEqualStrings(permissions, (try a.getHeaderOne(permissions_policy_header)).?);
    try testing.expectEqualStrings("DENY", (try a.getHeaderOne("X-Frame-Options")).?);

    var defaults_outer = try initApp(&.{ try default_headers.middleware(App, &defaults), try middleware(App, &config) });
    defer defaults_outer.deinit();
    var b = try dispatch(&defaults_outer, "/");
    defer b.deinit();
    try testing.expectEqualStrings(csp, (try b.getHeaderOne(content_security_policy_header)).?);
    try testing.expectEqualStrings("DENY", (try b.getHeaderOne("X-Frame-Options")).?);
}

test "static hits are covered only when the entry is outside static" {
    if (!static.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "app.js", .data = "1" });
    try static.checkSupport(tmp.dir);
    const static_config = static.Config{ .root = tmp.dir };
    const config = AppConfig{ .content_security_policy = .{ .value = csp } };

    var outer = try initApp(&.{ try middleware(App, &config), static.middleware(App, &static_config) });
    defer outer.deinit();
    var hit = try dispatch(&outer, "/app.js");
    defer hit.deinit();
    try testing.expectEqualStrings("1", hit.body);
    try testing.expectEqualStrings(csp, (try hit.getHeaderOne(content_security_policy_header)).?);

    var inner = try initApp(&.{ static.middleware(App, &static_config), try middleware(App, &config) });
    defer inner.deinit();
    var uncovered = try dispatch(&inner, "/app.js");
    defer uncovered.deinit();
    try testing.expect((try uncovered.getHeaderOne(content_security_policy_header)) == null);
    var routed = try dispatch(&inner, "/");
    defer routed.deinit();
    try testing.expectEqualStrings(csp, (try routed.getHeaderOne(content_security_policy_header)).?);
}

test "HSTS is gated on the configured HTTPS signal, never forwarded headers" {
    const forwarded = [_]router.Header{
        .{ .name = "X-Forwarded-Proto", .value = "https" },
        .{ .name = "Forwarded", .value = "proto=https" },
    };

    const never = AppConfig{ .hsts = .{ .max_age = 600, .https = neverHttps } };
    var plain = try initApp(&.{try middleware(App, &never)});
    defer plain.deinit();
    var a = try dispatchWith(&plain, "/", &forwarded);
    defer a.deinit();
    try testing.expect((try a.getHeaderOne(hsts_header)) == null);

    const proxied = AppConfig{ .hsts = .{
        .max_age = min_preload_max_age,
        .include_subdomains = true,
        .preload = true,
        .https = proxySecretHttps,
    } };
    var app = try initApp(&.{try middleware(App, &proxied)});
    defer app.deinit();
    var spoofed = try dispatchWith(&app, "/", &forwarded);
    defer spoofed.deinit();
    try testing.expect((try spoofed.getHeaderOne(hsts_header)) == null);
    var wrong = try dispatchWith(&app, "/", &.{.{ .name = "X-Proxy-Secret", .value = "guess" }});
    defer wrong.deinit();
    try testing.expect((try wrong.getHeaderOne(hsts_header)) == null);
    var trusted = try dispatchWith(&app, "/missing", &.{.{ .name = "X-Proxy-Secret", .value = "s3cret" }});
    defer trusted.deinit();
    try testing.expectEqual(@as(u16, 404), trusted.status_code);
    try testing.expectEqualStrings("max-age=31536000; includeSubDomains; preload", (try trusted.getHeaderOne(hsts_header)).?);

    const minimal = AppConfig{ .hsts = .{ .max_age = 0, .https = alwaysHttps, .classes = .{ .client_error = false } } };
    var cleared = try initApp(&.{try middleware(App, &minimal)});
    defer cleared.deinit();
    var ok = try dispatch(&cleared, "/");
    defer ok.deinit();
    try testing.expectEqualStrings("max-age=0", (try ok.getHeaderOne(hsts_header)).?);
    var miss = try dispatch(&cleared, "/missing");
    defer miss.deinit();
    try testing.expect((try miss.getHeaderOne(hsts_header)) == null);
}

test "response header limits add every selected policy or none" {
    const config = AppConfig{
        .content_security_policy = .{ .value = csp },
        .permissions_policy = .{ .value = permissions },
        .hsts = .{ .max_age = 600, .https = alwaysHttps },
    };
    const entry = try middleware(App, &config);
    const next_impl = struct {
        fn run(_: *anyopaque, _: *App.Context, _: *router.Request, out: *response.Response) anyerror!void {
            try out.text(200, "ok");
            try out.setHeader("X-Existing", "1");
        }
    };
    var frame: u8 = 0;
    const plugins: Plugins = .{};
    var state: App.State = .{};
    const app_config: app_mod.AppConfig = .{};
    var ctx = App.Context{ .plugins = &plugins, .config = &app_config, .state = &state };
    var req = router.Request{ .method = .get, .segments = &.{} };
    const next = App.Next{ .frame = &frame, .invoke = next_impl.run };

    var counted = response.Response.initWithLimits(testing.allocator, .{ .max_headers = 3 });
    defer counted.deinit();
    try testing.expectError(error.TooManyHeaders, entry.invoke(entry.config, &ctx, &req, &counted, next));
    try testing.expectEqual(@as(usize, 1), counted.header_count);

    var sized = response.Response.initWithLimits(testing.allocator, .{ .header_bytes = 64 });
    defer sized.deinit();
    try testing.expectError(error.HeaderBytesExceeded, entry.invoke(entry.config, &ctx, &req, &sized, next));
    try testing.expectEqual(@as(usize, 1), sized.header_count);

    var roomy = response.Response.initWithLimits(testing.allocator, .{ .max_headers = 4 });
    defer roomy.deinit();
    try entry.invoke(entry.config, &ctx, &req, &roomy, next);
    try testing.expectEqual(@as(usize, 4), roomy.header_count);
}
