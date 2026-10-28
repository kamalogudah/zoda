//! Inertia.js page responses and redirects, inspired by inertia-roda.
//!
//! `Inertia(SharedProps)` is a registered instance. Routes choose the
//! component and pass typed props explicitly:
//!
//!     ctx.plugins.inertia.render(req, res, "Users/Show", .{ .user = user })
//!     ctx.plugins.inertia.redirect(req, res, "/users")
//!     ctx.plugins.inertia.location(req, res, "https://billing.example/")
//!
//! Implemented protocol subset:
//! - An ordinary visit gets the configured HTML layout with its single
//!   `@inertia` marker replaced by the page object
//!   `{component, props, url, version}` and an empty root element. The
//!   default `.script` form is the one Inertia v3 reads:
//!   `<script data-page="app" type="application/json">` with `<`, `>`, and
//!   `&` written as `\u003c`, `\u003e`, and `\u0026`, then `<div id="app">`.
//!   `.attribute` writes `<div id="app" data-page="...">` with the JSON
//!   HTML-attribute escaped, for v1 and v2 clients.
//! - `X-Inertia: true` gets the same page object as `application/json` with
//!   `X-Inertia: true`. Both forms add `Vary: X-Inertia`.
//! - An Inertia GET whose `X-Inertia-Version` differs from the configured
//!   version gets `409`. A missing field counts as the empty version, because
//!   clients omit it when the page version is empty. The conflict sets
//!   `X-Inertia-Location` to the request target. The check runs inside
//!   `render`, so only rendering routes perform it, and never for non-Inertia
//!   or non-GET requests.
//! - `props.errors` is always an object (`{}` unless a route or shared prop
//!   supplies it), and configured shared props are named in `sharedProps`.
//! - `redirect` sends a local path with 302 after GET/HEAD and 303 otherwise,
//!   or 409 and `X-Inertia-Redirect` for an Inertia request to a path with a
//!   fragment, which XHR would drop. `location` forces a full visit: 409 and
//!   `X-Inertia-Location` for an Inertia request, a plain 302/303 otherwise.
//!
//! Deferred: partial reloads (`X-Inertia-Partial-*` are ignored and every prop
//! is sent), top-level `flash`, deferred/optional/once/merge props, error
//! bags, history encryption, precognition, and server-side rendering.
//!
//! URL and origin policy: the page `url` and every `X-Inertia-Location` for
//! the current page are the raw origin-form request target, so path and
//! query are preserved byte for byte. No origin is derived from `Host` or
//! forwarded headers; the client resolves the relative URL against the page it
//! is already on. Targets beginning with `//` or containing `\` are refused.
//!
//! Ownership: the response owns every serialized byte. Shared values and the
//! version must outlive the instance; callback results must stay valid until
//! the call that requested them returns. Header-syntax, configuration, and
//! limit failures leave the response unchanged; allocation errors propagate.
const std = @import("std");
const router = @import("../router.zig");
const response = @import("../response.zig");
const http_cache = @import("http_cache.zig");

pub const layout_marker = "@inertia";
pub const html_content_type = "text/html; charset=utf-8";
pub const max_root_id_bytes = 64;

pub const HeaderError = error{ DuplicateInertiaHeader, MalformedInertiaHeader, DuplicateVersionHeader };
pub const ConfigError = error{ InvalidLayout, InvalidRootId };
pub const TargetError = error{ MissingRequestTarget, UnsafeRequestTarget };
pub const RenderError = HeaderError || ConfigError || TargetError || response.HeaderError || error{
    BodyTooLarge,
    InvalidComponent,
};
pub const RedirectError = HeaderError || response.RedirectError || error{InvalidLocation};

/// Reports whether `req` is an Inertia visit. Exactly one `X-Inertia` field
/// with the value `true` qualifies; a repeated field or any other value is an
/// error rather than a silent fallback to HTML.
pub fn isInertia(req: *const router.Request) HeaderError!bool {
    const value = req.getHeaderOne("X-Inertia") catch return error.DuplicateInertiaHeader;
    const raw = value orelse return false;
    if (!std.mem.eql(u8, raw, "true")) return error.MalformedInertiaHeader;
    return true;
}

/// Returns the page URL: the raw origin-form target, including its query.
pub fn requestUrl(req: *const router.Request) TargetError![]const u8 {
    const target = req.target;
    if (target.len == 0) return error.MissingRequestTarget;
    if (target[0] != '/' or (target.len > 1 and target[1] == '/')) return error.UnsafeRequestTarget;
    for (target) |c| {
        if (c <= ' ' or c >= 0x7f or c == '\\') return error.UnsafeRequestTarget;
    }
    return target;
}

pub fn Inertia(comptime SharedProps: type) type {
    comptime if (@typeInfo(SharedProps) != .@"struct") @compileError("Inertia shared props must be a struct");
    return struct {
        const Self = @This();

        /// Props merged into every page. Route props with the same name win.
        pub const Shared = union(enum) {
            none,
            value: SharedProps,
            callback: *const fn (*const router.Request) SharedProps,
        };

        /// Asset version. `.none` sends `"version":null` and skips the check.
        pub const Version = union(enum) {
            none,
            value: []const u8,
            callback: *const fn (*const router.Request) []const u8,
        };

        /// Complete HTML document containing `@inertia` exactly once. It owns
        /// the page layout and asset tags and is copied verbatim.
        layout: []const u8,
        /// `id` of the generated root element: 1-64 `[A-Za-z0-9_-]` bytes.
        root_id: []const u8 = "app",
        /// Where the initial page object goes; match the client's version.
        initial_page: InitialPage = .script,
        version: Version = .none,
        shared: Shared = .none,

        /// Checks the layout and root id. `render` repeats the check, so
        /// calling this at startup only reports mistakes earlier.
        pub fn validate(self: *const Self) ConfigError!void {
            _ = try self.layoutParts();
            if (self.root_id.len == 0 or self.root_id.len > max_root_id_bytes) return error.InvalidRootId;
            for (self.root_id) |c| {
                if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return error.InvalidRootId;
            }
        }

        /// Renders `component` with the struct `props`, as HTML or as an
        /// Inertia JSON page depending on `X-Inertia`, with status 200. A
        /// stale asset version on an Inertia GET produces the 409 conflict
        /// instead.
        pub fn render(
            self: *const Self,
            req: *const router.Request,
            res: *response.Response,
            component: []const u8,
            props: anytype,
        ) RenderError!void {
            comptime {
                const info = @typeInfo(@TypeOf(props));
                if (info != .@"struct" or (info.@"struct".is_tuple and info.@"struct".fields.len != 0)) {
                    @compileError("Inertia props must be a struct with named fields");
                }
            }
            try self.validate();
            const inertia = try isInertia(req);
            const url = try requestUrl(req);
            const version = self.currentVersion(req);
            if (inertia and req.method == .get) {
                if (version) |current| {
                    const sent = req.getHeaderOne("X-Inertia-Version") catch return error.DuplicateVersionHeader;
                    if (!std.mem.eql(u8, sent orelse "", current)) return conflict(res, url);
                }
            }
            if (component.len == 0) return error.InvalidComponent;

            const page = try self.pageJson(res.allocator, req, component, props, url, version);
            if (inertia) {
                var committed = false;
                defer if (!committed) res.allocator.free(page);
                if (page.len > res.limits.max_body_bytes) return error.BodyTooLarge;
                try reserveHeaders(res, 1, "X-Inertia".len + "true".len);
                try res.setHeader("X-Inertia", "true");
                try addInertiaVary(res);
                try commitBody(res, response.json_content_type, page);
                committed = true;
                return;
            }

            defer res.allocator.free(page);
            const body = try self.htmlBody(res, page);
            var committed = false;
            defer if (!committed) res.allocator.free(body);
            try reserveHeaders(res, 0, 0);
            try addInertiaVary(res);
            try commitBody(res, html_content_type, body);
            committed = true;
        }

        /// Redirects to a local path (the `Response.redirectPath` rules) with
        /// 302 after GET/HEAD and 303 after any other method, so the browser
        /// and the Inertia client follow with GET. XHR drops the fragment of
        /// a followed redirect, so an Inertia request for a path with `#`
        /// instead gets 409 and `X-Inertia-Redirect`, which v3 clients visit
        /// with GET while keeping the fragment.
        pub fn redirect(
            _: *const Self,
            req: *const router.Request,
            res: *response.Response,
            path: []const u8,
        ) RedirectError!void {
            const inertia = try isInertia(req);
            if (!inertia or std.mem.indexOfScalar(u8, path, '#') == null) {
                return res.redirectPath(followUpStatus(req), path);
            }
            try response.validateRedirectPath(path);
            var existing = res.getAllHeaders("X-Inertia-Redirect");
            if (existing.next() != null) return error.LocationAlreadySet;
            try reserveHeaders(res, 1, "X-Inertia-Redirect".len + path.len);
            try res.setHeader("X-Inertia-Redirect", path);
            try addInertiaVary(res);
            emptyBody(res, 409);
        }

        /// Forces a full page visit to a local path or an absolute `http(s)`
        /// URL without userinfo. Inertia requests get 409 and
        /// `X-Inertia-Location`; other requests get a 302/303 `Location`.
        pub fn location(
            _: *const Self,
            req: *const router.Request,
            res: *response.Response,
            destination: []const u8,
        ) RedirectError!void {
            try validateLocation(destination);
            const inertia = try isInertia(req);
            var existing = res.getAllHeaders(if (inertia) "X-Inertia-Location" else "Location");
            if (existing.next() != null) return error.LocationAlreadySet;
            if (!inertia) {
                try res.setHeader("Location", destination);
                emptyBody(res, @intFromEnum(followUpStatus(req)));
                return;
            }
            try reserveHeaders(res, 1, "X-Inertia-Location".len + destination.len);
            try res.setHeader("X-Inertia-Location", destination);
            try addInertiaVary(res);
            emptyBody(res, 409);
        }

        fn layoutParts(self: *const Self) ConfigError!struct { []const u8, []const u8 } {
            const at = std.mem.indexOf(u8, self.layout, layout_marker) orelse return error.InvalidLayout;
            const after = self.layout[at + layout_marker.len ..];
            if (std.mem.indexOf(u8, after, layout_marker) != null) return error.InvalidLayout;
            return .{ self.layout[0..at], after };
        }

        fn currentVersion(self: *const Self, req: *const router.Request) ?[]const u8 {
            return switch (self.version) {
                .none => null,
                .value => |value| value,
                .callback => |callback| callback(req),
            };
        }

        fn pageJson(
            self: *const Self,
            allocator: std.mem.Allocator,
            req: *const router.Request,
            component: []const u8,
            props: anytype,
            url: []const u8,
            version: ?[]const u8,
        ) error{OutOfMemory}![]u8 {
            const shared: ?SharedProps = switch (self.shared) {
                .none => null,
                .value => |value| value,
                .callback => |callback| callback(req),
            };
            var out: std.Io.Writer.Allocating = .init(allocator);
            defer out.deinit();
            var json: std.json.Stringify = .{ .writer = &out.writer };
            writePage(&json, component, shared, props, url, version) catch return error.OutOfMemory;
            return out.toOwnedSlice();
        }

        fn writePage(
            json: *std.json.Stringify,
            component: []const u8,
            shared: ?SharedProps,
            props: anytype,
            url: []const u8,
            version: ?[]const u8,
        ) std.json.Stringify.Error!void {
            const P = @TypeOf(props);
            try json.beginObject();
            try json.objectField("component");
            try json.write(component);
            try json.objectField("props");
            try json.beginObject();
            if (shared) |value| {
                inline for (std.meta.fields(SharedProps)) |field| {
                    if (comptime !@hasField(P, field.name)) {
                        try json.objectField(field.name);
                        try json.write(@field(value, field.name));
                    }
                }
            }
            inline for (std.meta.fields(P)) |field| {
                try json.objectField(field.name);
                try json.write(@field(props, field.name));
            }
            // Clients treat `errors` as always present, as Laravel sends it.
            const shared_errors = shared != null and @hasField(SharedProps, "errors");
            if (comptime !@hasField(P, "errors")) {
                if (!shared_errors) {
                    try json.objectField("errors");
                    try json.beginObject();
                    try json.endObject();
                }
            }
            try json.endObject();
            try json.objectField("url");
            try json.write(url);
            try json.objectField("version");
            try json.write(version);
            if (shared != null) {
                // v3 carries these props over to instant client-side visits.
                try json.objectField("sharedProps");
                try json.beginArray();
                inline for (std.meta.fields(SharedProps)) |field| try json.write(field.name);
                try json.endArray();
            }
            try json.endObject();
        }

        fn htmlBody(self: *const Self, res: *const response.Response, page: []const u8) RenderError![]u8 {
            const before, const after = try self.layoutParts();
            const id = self.root_id;
            // The escaped JSON goes between `head` and `tail`.
            const head: [4][]const u8, const tail: [4][]const u8 = switch (self.initial_page) {
                .script => .{
                    .{ before, "<script data-page=\"", id, "\" type=\"application/json\">" },
                    .{ "</script><div id=\"", id, "\"></div>", after },
                },
                .attribute => .{
                    .{ before, "<div id=\"", id, "\" data-page=\"" },
                    .{ "\"></div>", after, "", "" },
                },
            };
            var len: usize = 0;
            for (head ++ tail) |part| len += part.len;
            for (page) |c| len += if (self.initial_page.escape(c)) |e| e.len else 1;
            if (len > res.limits.max_body_bytes) return error.BodyTooLarge;

            const body = try res.allocator.alloc(u8, len);
            var i: usize = 0;
            for (head) |part| {
                @memcpy(body[i..][0..part.len], part);
                i += part.len;
            }
            for (page) |c| {
                if (self.initial_page.escape(c)) |e| {
                    @memcpy(body[i..][0..e.len], e);
                    i += e.len;
                } else {
                    body[i] = c;
                    i += 1;
                }
            }
            for (tail) |part| {
                @memcpy(body[i..][0..part.len], part);
                i += part.len;
            }
            std.debug.assert(i == len);
            return body;
        }
    };
}

pub const InitialPage = enum {
    /// `<script data-page="id" type="application/json">` plus `<div id="id">`
    /// (Inertia v3).
    script,
    /// `<div id="id" data-page="...">` (Inertia v1 and v2).
    attribute,

    /// The replacement for `c`, or null to copy it. In JSON these bytes occur
    /// only inside strings, where `\uXXXX` keeps the value unchanged.
    fn escape(self: InitialPage, c: u8) ?[]const u8 {
        return switch (self) {
            .script => switch (c) {
                '<' => "\\u003c",
                '>' => "\\u003e",
                '&' => "\\u0026",
                else => null,
            },
            .attribute => switch (c) {
                '&' => "&amp;",
                '"' => "&quot;",
                '\'' => "&#39;",
                '<' => "&lt;",
                '>' => "&gt;",
                else => null,
            },
        };
    }
};

fn followUpStatus(req: *const router.Request) response.RedirectStatus {
    return switch (req.method) {
        .get, .head => .found,
        else => .see_other,
    };
}

/// Checks that `count` more fields plus `bytes`, and a possible `Vary:
/// X-Inertia`, fit the response header limits, so a limit failure never
/// leaves some Inertia headers behind.
fn reserveHeaders(res: *const response.Response, count: usize, bytes: usize) response.HeaderError!void {
    const vary: usize = if (listsInertiaVary(res)) 0 else 1;
    if (res.header_count + count + vary > res.limits.max_headers) return error.TooManyHeaders;
    const vary_bytes = vary * ("Vary".len + "X-Inertia".len);
    if (res.header_bytes_used + bytes + vary_bytes > res.limits.header_bytes) return error.HeaderBytesExceeded;
}

fn addInertiaVary(res: *response.Response) response.HeaderError!void {
    http_cache.addVary(res, "X-Inertia") catch |err| switch (err) {
        error.InvalidVary => unreachable,
        else => |e| return e,
    };
}

fn listsInertiaVary(res: *const response.Response) bool {
    var it = res.getAllHeaders("Vary");
    while (it.next()) |value| {
        var members = std.mem.splitScalar(u8, value, ',');
        while (members.next()) |member| {
            const name = std.mem.trim(u8, member, " \t");
            if (std.mem.eql(u8, name, "*") or std.ascii.eqlIgnoreCase(name, "X-Inertia")) return true;
        }
    }
    return false;
}

fn commitBody(res: *response.Response, content_type: []const u8, body: []u8) error{ OutOfMemory, BodyTooLarge }!void {
    res.replaceOwnedBody(200, content_type, body) catch |err| switch (err) {
        error.InvalidContentType => unreachable,
        else => |e| return e,
    };
}

fn conflict(res: *response.Response, url: []const u8) RenderError!void {
    try reserveHeaders(res, 1, "X-Inertia-Location".len + url.len);
    try res.setHeader("X-Inertia-Location", url);
    try addInertiaVary(res);
    emptyBody(res, 409);
}

/// Replaces the body and content type with nothing, like `redirectPath`.
fn emptyBody(res: *response.Response, status: u16) void {
    if (res.body.len != 0) res.allocator.free(res.body);
    if (res.content_type.len != 0) res.allocator.free(@constCast(res.content_type));
    res.body = &.{};
    res.content_type = &.{};
    res.status_code = status;
    res.handled = true;
    res.generated = false;
}

/// Accepts a local path under the `redirectPath` rules or an absolute
/// `http`/`https` URL with a non-empty host, no userinfo, and printable ASCII
/// without `\` and with well-formed percent escapes.
fn validateLocation(destination: []const u8) error{InvalidLocation}!void {
    if (destination.len != 0 and destination[0] == '/') {
        response.validateRedirectPath(destination) catch return error.InvalidLocation;
        return;
    }
    const rest = if (startsWithIgnoreCase(destination, "https://"))
        destination["https://".len..]
    else if (startsWithIgnoreCase(destination, "http://"))
        destination["http://".len..]
    else
        return error.InvalidLocation;
    const host_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..host_end];
    if (authority.len == 0) return error.InvalidLocation;
    for (authority) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == ':' or c == '[' or c == ']')) {
            return error.InvalidLocation;
        }
    }
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const c = rest[i];
        if (c <= ' ' or c >= 0x7f or c == '\\') return error.InvalidLocation;
        if (c == '%') {
            if (rest.len - i < 3 or !std.ascii.isHex(rest[i + 1]) or !std.ascii.isHex(rest[i + 2])) {
                return error.InvalidLocation;
            }
            i += 2;
        }
    }
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    return haystack.len >= prefix.len and std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

const testing = std.testing;
const test_layout = "<!doctype html><html><head><script src=\"/app.js\"></script></head><body>@inertia</body></html>";
const TestShared = struct { app_name: []const u8, user: ?[]const u8 = null };
const TestInertia = Inertia(TestShared);

fn testRequest(method: router.Method, target: []const u8, headers: []const router.Header) router.Request {
    return .{ .method = method, .segments = &.{}, .target = target, .headers = headers };
}

const inertia_headers = [_]router.Header{
    .{ .name = "X-Inertia", .value = "true" },
    .{ .name = "X-Inertia-Version", .value = "v1" },
};

test "ordinary visit embeds the page in a JSON script element for Inertia v3" {
    const plugin: TestInertia = .{ .layout = test_layout, .version = .{ .value = "v1" } };
    const req = testRequest(.get, "/users?q=a&b=%22x%22", &.{});
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try plugin.render(&req, &res, "Users/Index", .{ .title = "</script><!-- & 'q'" });

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expectEqualStrings(html_content_type, res.content_type);
    try testing.expectEqualStrings("X-Inertia", (try res.getHeaderOne("Vary")).?);
    try testing.expectEqual(@as(?[]const u8, null), try res.getHeaderOne("X-Inertia"));
    const json = "{\"component\":\"Users/Index\",\"props\":{\"title\":\"\\u003c/script\\u003e\\u003c!-- \\u0026 'q'\",\"errors\":{}}," ++
        "\"url\":\"/users?q=a\\u0026b=%22x%22\",\"version\":\"v1\"}";
    try testing.expectEqualStrings(
        "<!doctype html><html><head><script src=\"/app.js\"></script></head><body>" ++
            "<script data-page=\"app\" type=\"application/json\">" ++ json ++ "</script><div id=\"app\"></div>" ++
            "</body></html>",
        res.body,
    );

    // The escaped JSON still decodes to the original values.
    const start = std.mem.indexOf(u8, res.body, json).?;
    const Page = struct { props: struct { title: []const u8 }, url: []const u8 };
    const parsed = try std.json.parseFromSlice(Page, testing.allocator, res.body[start..][0..json.len], .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings("</script><!-- & 'q'", parsed.value.props.title);
    try testing.expectEqualStrings("/users?q=a&b=%22x%22", parsed.value.url);
}

test "attribute initial page escapes the JSON for v1 and v2 clients" {
    const plugin: TestInertia = .{ .layout = test_layout, .version = .{ .value = "v1" }, .initial_page = .attribute };
    const req = testRequest(.get, "/users?q=a&b=%22x%22", &.{});
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try plugin.render(&req, &res, "Users/Index", .{ .title = "<script>alert('x')</script> & \"q\"" });

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expectEqualStrings(html_content_type, res.content_type);
    try testing.expectEqualStrings("X-Inertia", (try res.getHeaderOne("Vary")).?);
    try testing.expectEqual(@as(?[]const u8, null), try res.getHeaderOne("X-Inertia"));
    try testing.expectEqualStrings(
        "<!doctype html><html><head><script src=\"/app.js\"></script></head><body>" ++
            "<div id=\"app\" data-page=\"{&quot;component&quot;:&quot;Users/Index&quot;," ++
            "&quot;props&quot;:{&quot;title&quot;:&quot;&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; \\&quot;q\\&quot;&quot;,&quot;errors&quot;:{}}," ++
            "&quot;url&quot;:&quot;/users?q=a&amp;b=%22x%22&quot;,&quot;version&quot;:&quot;v1&quot;}\"></div>" ++
            "</body></html>",
        res.body,
    );
}

test "Inertia visit returns the JSON page with shared props overridden by route props" {
    const plugin: TestInertia = .{
        .layout = test_layout,
        .version = .{ .value = "v1" },
        .shared = .{ .value = .{ .app_name = "zoda", .user = "shared" } },
    };
    const req = testRequest(.get, "/users/7?tab=posts&tab=likes", &inertia_headers);
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try plugin.render(&req, &res, "Users/Show", .{ .user = "ada", .id = @as(u32, 7) });

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expectEqualStrings("application/json", res.content_type);
    try testing.expectEqualStrings("true", (try res.getHeaderOne("X-Inertia")).?);
    try testing.expectEqualStrings("X-Inertia", (try res.getHeaderOne("Vary")).?);
    try testing.expectEqualStrings(
        "{\"component\":\"Users/Show\",\"props\":{\"app_name\":\"zoda\",\"user\":\"ada\",\"id\":7,\"errors\":{}}," ++
            "\"url\":\"/users/7?tab=posts&tab=likes\",\"version\":\"v1\",\"sharedProps\":[\"app_name\",\"user\"]}",
        res.body,
    );
}

test "shared props callback and version callback read the request" {
    const Callbacks = struct {
        fn shared(req: *const router.Request) TestShared {
            return .{ .app_name = "cb", .user = req.getHeaderOne("X-User") catch null };
        }
        fn version(_: *const router.Request) []const u8 {
            return "build-2";
        }
    };
    const plugin: TestInertia = .{
        .layout = test_layout,
        .version = .{ .callback = Callbacks.version },
        .shared = .{ .callback = Callbacks.shared },
    };
    const headers = [_]router.Header{
        .{ .name = "x-inertia", .value = "true" },
        .{ .name = "x-inertia-version", .value = "build-2" },
        .{ .name = "X-User", .value = "grace" },
    };
    const req = testRequest(.get, "/", &headers);
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try plugin.render(&req, &res, "Home", .{});
    try testing.expectEqualStrings(
        "{\"component\":\"Home\",\"props\":{\"app_name\":\"cb\",\"user\":\"grace\",\"errors\":{}},\"url\":\"/\",\"version\":\"build-2\",\"sharedProps\":[\"app_name\",\"user\"]}",
        res.body,
    );

    const none: Inertia(struct {}) = .{ .layout = "@inertia" };
    var plain = response.Response.init(testing.allocator);
    defer plain.deinit();
    try none.render(&req, &plain, "Home", .{});
    try testing.expectEqualStrings("{\"component\":\"Home\",\"props\":{\"errors\":{}},\"url\":\"/\",\"version\":null}", plain.body);
}

test "stale version on an Inertia GET returns 409 with the current URL" {
    const plugin: TestInertia = .{ .layout = test_layout, .version = .{ .value = "v2" } };
    const stale = [_]router.Header{ .{ .name = "X-Inertia", .value = "true" }, .{ .name = "X-Inertia-Version", .value = "v1" } };
    const missing = [_]router.Header{.{ .name = "X-Inertia", .value = "true" }};
    inline for (.{ &stale, &missing }) |headers| {
        const req = testRequest(.get, "/search?q=zig+lang&page=2", headers);
        var res = response.Response.init(testing.allocator);
        defer res.deinit();
        try res.text(200, "partial");
        try plugin.render(&req, &res, "Search", .{});
        try testing.expectEqual(@as(u16, 409), res.status_code);
        try testing.expectEqualStrings("", res.body);
        try testing.expectEqualStrings("", res.content_type);
        try testing.expectEqualStrings("/search?q=zig+lang&page=2", (try res.getHeaderOne("X-Inertia-Location")).?);
        try testing.expectEqualStrings("X-Inertia", (try res.getHeaderOne("Vary")).?);
    }

    // Clients omit the header for an empty version, so that is no conflict.
    const empty: TestInertia = .{ .layout = test_layout, .version = .{ .value = "" } };
    const unversioned = testRequest(.get, "/", &missing);
    var current = response.Response.init(testing.allocator);
    defer current.deinit();
    try empty.render(&unversioned, &current, "Home", .{});
    try testing.expectEqual(@as(u16, 200), current.status_code);

    // Ordinary visits and non-GET Inertia requests never get the conflict.
    const ordinary = testRequest(.get, "/search", &.{});
    var html = response.Response.init(testing.allocator);
    defer html.deinit();
    try plugin.render(&ordinary, &html, "Search", .{});
    try testing.expectEqual(@as(u16, 200), html.status_code);
    const post = testRequest(.post, "/search", &stale);
    var json = response.Response.init(testing.allocator);
    defer json.deinit();
    try plugin.render(&post, &json, "Search", .{});
    try testing.expectEqual(@as(u16, 200), json.status_code);
    try testing.expectEqualStrings("true", (try json.getHeaderOne("X-Inertia")).?);
}

test "malformed and duplicate Inertia headers fail without changing the response" {
    const plugin: TestInertia = .{ .layout = test_layout, .version = .{ .value = "v1" } };
    const cases = .{
        .{ &[_]router.Header{.{ .name = "X-Inertia", .value = "false" }}, error.MalformedInertiaHeader, true },
        .{ &[_]router.Header{.{ .name = "X-Inertia", .value = "TRUE" }}, error.MalformedInertiaHeader, true },
        .{ &[_]router.Header{.{ .name = "X-Inertia", .value = "" }}, error.MalformedInertiaHeader, true },
        .{ &[_]router.Header{ .{ .name = "X-Inertia", .value = "true" }, .{ .name = "x-inertia", .value = "true" } }, error.DuplicateInertiaHeader, true },
        // `location` does not read the version, so only `render` rejects this.
        .{ &[_]router.Header{ .{ .name = "X-Inertia", .value = "true" }, .{ .name = "X-Inertia-Version", .value = "v1" }, .{ .name = "X-Inertia-Version", .value = "v1" } }, error.DuplicateVersionHeader, false },
    };
    inline for (cases) |case| {
        const req = testRequest(.get, "/", case[0]);
        var res = response.Response.init(testing.allocator);
        defer res.deinit();
        try res.text(201, "keep");
        try testing.expectError(case[1], plugin.render(&req, &res, "Home", .{}));
        if (case[2]) try testing.expectError(case[1], plugin.location(&req, &res, "/elsewhere"));
        try testing.expectEqual(@as(u16, 201), res.status_code);
        try testing.expectEqualStrings("keep", res.body);
        try testing.expectEqual(@as(usize, 0), res.header_count);
    }
}

test "unsafe targets, components, and configuration are rejected" {
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    const good: TestInertia = .{ .layout = test_layout };
    for ([_][]const u8{ "//evil.test/x", "relative", "/a\\b", "/a b", "/\x7f" }) |target| {
        const req = testRequest(.get, target, &.{});
        try testing.expectError(error.UnsafeRequestTarget, good.render(&req, &res, "Home", .{}));
    }
    const untargeted = testRequest(.get, "", &.{});
    try testing.expectError(error.MissingRequestTarget, good.render(&untargeted, &res, "Home", .{}));
    const req = testRequest(.get, "/", &.{});
    try testing.expectError(error.InvalidComponent, good.render(&req, &res, "", .{}));

    for ([_][]const u8{ "<body></body>", "@inertia @inertia" }) |layout| {
        const bad: TestInertia = .{ .layout = layout };
        try testing.expectError(error.InvalidLayout, bad.validate());
        try testing.expectError(error.InvalidLayout, bad.render(&req, &res, "Home", .{}));
    }
    for ([_][]const u8{ "", "a\"b", "a b", "x" ** 65 }) |root_id| {
        const bad: TestInertia = .{ .layout = test_layout, .root_id = root_id };
        try testing.expectError(error.InvalidRootId, bad.validate());
    }
    const custom: TestInertia = .{ .layout = "@inertia", .root_id = "root_1-x" };
    try custom.render(&req, &res, "Home", .{});
    try testing.expect(std.mem.startsWith(u8, res.body, "<script data-page=\"root_1-x\" type=\"application/json\">"));
    try testing.expect(std.mem.endsWith(u8, res.body, "</script><div id=\"root_1-x\"></div>"));
    const attribute: TestInertia = .{ .layout = "@inertia", .root_id = "root_1-x", .initial_page = .attribute };
    try attribute.render(&req, &res, "Home", .{});
    try testing.expect(std.mem.startsWith(u8, res.body, "<div id=\"root_1-x\" data-page=\""));
}

test "configured body and header limits are honored before changing the response" {
    const plugin: TestInertia = .{ .layout = test_layout, .version = .{ .value = "v1" } };
    const ordinary = testRequest(.get, "/", &.{});
    const inertia = testRequest(.get, "/", &inertia_headers);
    const stale_headers = [_]router.Header{.{ .name = "X-Inertia", .value = "true" }};
    const stale = testRequest(.get, "/", &stale_headers);

    const cases = .{
        .{ ordinary, response.Limits{ .max_body_bytes = test_layout.len }, error.BodyTooLarge },
        .{ inertia, response.Limits{ .max_body_bytes = 20 }, error.BodyTooLarge },
        .{ ordinary, response.Limits{ .max_headers = 0 }, error.TooManyHeaders },
        .{ inertia, response.Limits{ .max_headers = 1 }, error.TooManyHeaders },
        .{ inertia, response.Limits{ .header_bytes = 20 }, error.HeaderBytesExceeded },
        .{ stale, response.Limits{ .max_headers = 1 }, error.TooManyHeaders },
    };
    inline for (cases) |case| {
        var res = response.Response.initWithLimits(testing.allocator, case[1]);
        defer res.deinit();
        try res.text(202, "keep");
        try testing.expectError(case[2], plugin.render(&case[0], &res, "Home", .{ .name = "ada" }));
        try testing.expectEqual(@as(u16, 202), res.status_code);
        try testing.expectEqualStrings("keep", res.body);
        try testing.expectEqual(@as(usize, 0), res.header_count);
    }

    // An existing `Vary: X-Inertia` is reused, so it needs no extra room.
    var reused = response.Response.initWithLimits(testing.allocator, .{ .max_headers = 1 });
    defer reused.deinit();
    try reused.setHeader("Vary", "Accept-Encoding, x-inertia");
    try plugin.render(&ordinary, &reused, "Home", .{});
    try testing.expectEqual(@as(usize, 1), reused.header_count);

    var tiny: [0]u8 = .{};
    var fba = std.heap.FixedBufferAllocator.init(&tiny);
    var oom = response.Response.init(fba.allocator());
    defer oom.deinit();
    try testing.expectError(error.OutOfMemory, plugin.render(&inertia, &oom, "Home", .{}));
}

test "redirects use 302 after GET and 303 after other methods for local paths" {
    const plugin: TestInertia = .{ .layout = test_layout };
    const methods = .{ .{ router.Method.get, @as(u16, 302) }, .{ router.Method.head, @as(u16, 302) }, .{ router.Method.post, @as(u16, 303) }, .{ router.Method.put, @as(u16, 303) }, .{ router.Method.patch, @as(u16, 303) }, .{ router.Method.delete, @as(u16, 303) } };
    inline for (methods) |case| {
        const req = testRequest(case[0], "/users", &inertia_headers);
        var res = response.Response.init(testing.allocator);
        defer res.deinit();
        try res.text(200, "old");
        try plugin.redirect(&req, &res, "/users/7?saved=1");
        try testing.expectEqual(case[1], res.status_code);
        try testing.expectEqualStrings("/users/7?saved=1", (try res.getHeaderOne("Location")).?);
        try testing.expectEqualStrings("", res.body);
    }
    const req = testRequest(.post, "/users", &inertia_headers);
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    for ([_][]const u8{ "https://evil.test/", "//evil.test/", "relative", "/\r\nX: y" }) |bad| {
        try testing.expectError(error.InvalidRedirectPath, plugin.redirect(&req, &res, bad));
    }
    try testing.expectEqual(@as(usize, 0), res.header_count);
}

test "errors is always an object and route errors win over shared errors" {
    const req = testRequest(.get, "/", &inertia_headers);
    const WithErrors = Inertia(struct { errors: struct { base: []const u8 } });
    const shared: WithErrors = .{ .layout = test_layout, .shared = .{ .value = .{ .errors = .{ .base = "shared" } } } };
    var from_shared = response.Response.init(testing.allocator);
    defer from_shared.deinit();
    try shared.render(&req, &from_shared, "Home", .{});
    try testing.expectEqualStrings(
        "{\"component\":\"Home\",\"props\":{\"errors\":{\"base\":\"shared\"}},\"url\":\"/\",\"version\":null,\"sharedProps\":[\"errors\"]}",
        from_shared.body,
    );
    var from_route = response.Response.init(testing.allocator);
    defer from_route.deinit();
    try shared.render(&req, &from_route, "Home", .{ .errors = .{ .text = "route" } });
    try testing.expectEqualStrings(
        "{\"component\":\"Home\",\"props\":{\"errors\":{\"text\":\"route\"}},\"url\":\"/\",\"version\":null,\"sharedProps\":[\"errors\"]}",
        from_route.body,
    );
    // Shared errors are declared but not configured, so the default applies.
    const unset: WithErrors = .{ .layout = test_layout };
    var defaulted = response.Response.init(testing.allocator);
    defer defaulted.deinit();
    try unset.render(&req, &defaulted, "Home", .{});
    try testing.expectEqualStrings("{\"component\":\"Home\",\"props\":{\"errors\":{}},\"url\":\"/\",\"version\":null}", defaulted.body);
}

test "fragment redirects use X-Inertia-Redirect for Inertia requests" {
    const plugin: TestInertia = .{ .layout = test_layout };
    const inertia = testRequest(.post, "/todos", &inertia_headers);
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try res.text(200, "old");
    try plugin.redirect(&inertia, &res, "/todos?filter=done#todo-3");
    try testing.expectEqual(@as(u16, 409), res.status_code);
    try testing.expectEqualStrings("", res.body);
    try testing.expectEqualStrings("/todos?filter=done#todo-3", (try res.getHeaderOne("X-Inertia-Redirect")).?);
    try testing.expectEqualStrings("X-Inertia", (try res.getHeaderOne("Vary")).?);
    try testing.expectEqual(@as(?[]const u8, null), try res.getHeaderOne("Location"));
    try testing.expectError(error.LocationAlreadySet, plugin.redirect(&inertia, &res, "/again#x"));

    // Browsers keep the fragment themselves on ordinary redirects.
    const ordinary = testRequest(.post, "/todos", &.{});
    var plain = response.Response.init(testing.allocator);
    defer plain.deinit();
    try plugin.redirect(&ordinary, &plain, "/todos#todo-3");
    try testing.expectEqual(@as(u16, 303), plain.status_code);
    try testing.expectEqualStrings("/todos#todo-3", (try plain.getHeaderOne("Location")).?);

    var rejected = response.Response.init(testing.allocator);
    defer rejected.deinit();
    for ([_][]const u8{ "//evil.test/#x", "https://evil.test/#x", "/a b#x", "/%2f#x" }) |bad| {
        try testing.expectError(error.InvalidRedirectPath, plugin.redirect(&inertia, &rejected, bad));
    }
    const malformed_headers = [_]router.Header{.{ .name = "X-Inertia", .value = "1" }};
    const malformed = testRequest(.post, "/todos", &malformed_headers);
    try testing.expectError(error.MalformedInertiaHeader, plugin.redirect(&malformed, &rejected, "/todos"));
    try testing.expectEqual(@as(usize, 0), rejected.header_count);

    var limited = response.Response.initWithLimits(testing.allocator, .{ .max_headers = 1 });
    defer limited.deinit();
    try testing.expectError(error.TooManyHeaders, plugin.redirect(&inertia, &limited, "/todos#x"));
    try testing.expectEqual(@as(usize, 0), limited.header_count);
}

test "location forces full visits for Inertia requests and validates destinations" {
    const plugin: TestInertia = .{ .layout = test_layout };
    const inertia = testRequest(.post, "/checkout", &inertia_headers);
    var conflict_res = response.Response.init(testing.allocator);
    defer conflict_res.deinit();
    try conflict_res.text(200, "old");
    try plugin.location(&inertia, &conflict_res, "https://billing.example:8443/pay?id=1%20a");
    try testing.expectEqual(@as(u16, 409), conflict_res.status_code);
    try testing.expectEqualStrings("", conflict_res.body);
    try testing.expectEqualStrings("https://billing.example:8443/pay?id=1%20a", (try conflict_res.getHeaderOne("X-Inertia-Location")).?);
    try testing.expectEqual(@as(?[]const u8, null), try conflict_res.getHeaderOne("Location"));
    try testing.expectEqualStrings("X-Inertia", (try conflict_res.getHeaderOne("Vary")).?);

    const ordinary_get = testRequest(.get, "/checkout", &.{});
    var get_res = response.Response.init(testing.allocator);
    defer get_res.deinit();
    try plugin.location(&ordinary_get, &get_res, "HTTP://billing.example");
    try testing.expectEqual(@as(u16, 302), get_res.status_code);
    try testing.expectEqualStrings("HTTP://billing.example", (try get_res.getHeaderOne("Location")).?);

    const ordinary_post = testRequest(.post, "/checkout", &.{});
    var post_res = response.Response.init(testing.allocator);
    defer post_res.deinit();
    try plugin.location(&ordinary_post, &post_res, "/legacy/page");
    try testing.expectEqual(@as(u16, 303), post_res.status_code);
    try testing.expectError(error.LocationAlreadySet, plugin.location(&ordinary_post, &post_res, "/again"));

    var rejected = response.Response.init(testing.allocator);
    defer rejected.deinit();
    for ([_][]const u8{
        "",                      "relative",                "javascript:alert(1)",     "ftp://files.example/",
        "https://",              "https:///path",           "https://user@evil.test/", "https://a.test\\@evil.test/",
        "https://a.test/ space", "https://a.test/\r\nX: y", "https://a.test/%zz",      "//evil.test/",
        "/%2f/evil",
        "https://a.test/é",
    }) |bad| {
        try testing.expectError(error.InvalidLocation, plugin.location(&inertia, &rejected, bad));
    }
    try testing.expectEqual(@as(usize, 0), rejected.header_count);

    var limited = response.Response.initWithLimits(testing.allocator, .{ .max_headers = 1 });
    defer limited.deinit();
    try testing.expectError(error.TooManyHeaders, plugin.location(&inertia, &limited, "/next"));
    try testing.expectEqual(@as(usize, 0), limited.header_count);
}

test "registered instance renders through app dispatch with errors propagating" {
    const app_mod = @import("../app.zig");
    const Plugins = struct { inertia: TestInertia };
    const App = app_mod.App(Plugins);
    const Routes = struct {
        fn route(ctx: *App.Context, req: *router.Request, res: *response.Response) !void {
            if (req.onLiteral("users")) {
                if (req.isRoot() and req.isGet()) {
                    return ctx.plugins.inertia.render(req, res, "Users/Index", .{ .users = &[_][]const u8{ "ada", "grace" } });
                }
                if (req.isRoot() and req.method == .post) return ctx.plugins.inertia.redirect(req, res, "/users");
            }
        }
    };
    var app = try App.init(testing.allocator, .{
        .response_allocator = testing.allocator,
        .plugins = .{ .inertia = .{ .layout = test_layout, .version = .{ .value = "v1" }, .shared = .{ .value = .{ .app_name = "zoda" } } } },
        .route_fn = Routes.route,
    });
    defer app.deinit();

    var json_req: router.Request = .{ .method = .get, .segments = &.{"users"}, .target = "/users", .headers = &inertia_headers };
    var json_res = try app.dispatch(&json_req);
    defer json_res.deinit();
    try testing.expectEqualStrings(
        "{\"component\":\"Users/Index\",\"props\":{\"app_name\":\"zoda\",\"user\":null,\"users\":[\"ada\",\"grace\"],\"errors\":{}},\"url\":\"/users\",\"version\":\"v1\",\"sharedProps\":[\"app_name\",\"user\"]}",
        json_res.body,
    );

    var post_req: router.Request = .{ .method = .post, .segments = &.{"users"}, .target = "/users", .headers = &inertia_headers };
    var post_res = try app.dispatch(&post_req);
    defer post_res.deinit();
    try testing.expectEqual(@as(u16, 303), post_res.status_code);

    const bad_headers = [_]router.Header{.{ .name = "X-Inertia", .value = "yes" }};
    var bad_req: router.Request = .{ .method = .get, .segments = &.{"users"}, .target = "/users", .headers = &bad_headers };
    try testing.expectError(error.MalformedInertiaHeader, app.dispatch(&bad_req));

    var miss_req: router.Request = .{ .method = .get, .segments = &.{"missing"}, .target = "/missing", .headers = &inertia_headers };
    var miss_res = try app.dispatch(&miss_req);
    defer miss_res.deinit();
    try testing.expectEqual(@as(u16, 404), miss_res.status_code);
}
