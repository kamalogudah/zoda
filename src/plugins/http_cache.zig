//! Explicit HTTP cache policy and conditional GET helpers.
//!
//! Nothing here runs by default. No middleware applies a policy, so a route
//! sends exactly the `Cache-Control` it sets, or none. Session-backed and
//! other personalized responses therefore never become cacheable by accident:
//! `public` is refused when the response sets a cookie, and also when the
//! request carries `Authorization` or `Cookie` unless the route opts in.
//!
//! Call order in a route: build the complete 2xx response, set the policy,
//! validator, and `Vary` (and save the session), then call `evaluate` last.
//! A matching `If-None-Match` turns the response into `304 Not Modified`
//! with every header kept, the body and content type dropped, and no
//! Content-Length on the wire. HEAD is treated like GET; routes still answer
//! HEAD explicitly because there is no HEAD-to-GET fallback.
//!
//! Only `If-None-Match` is evaluated. `If-Modified-Since`, `If-Match`,
//! `If-Unmodified-Since`, and ranges are unsupported. Preconditions on unsafe
//! methods must be checked before acting, so `evaluate` ignores them.
const std = @import("std");
const router = @import("../router.zig");
const response = @import("../response.zig");

/// RFC 9111 §1.2.2: caches treat larger delta-seconds as this value.
pub const max_delta_seconds: u32 = 2147483648;
/// Longest opaque tag accepted by `setETag`, quotes excluded.
pub const max_tag_bytes = 128;

/// `private`: only the client's own cache may store the response.
pub const Private = struct {
    /// `max-age` in seconds; null omits it.
    max_age: ?u32 = null,
    /// `no-cache`: store, but revalidate before every reuse.
    no_cache: bool = false,
    must_revalidate: bool = false,
    immutable: bool = false,
};

/// `public`: shared caches may store the response for every user.
pub const Public = struct {
    max_age: ?u32 = null,
    /// `s-maxage`: shared-cache lifetime, overriding `max_age` there.
    s_maxage: ?u32 = null,
    no_cache: bool = false,
    must_revalidate: bool = false,
    immutable: bool = false,
    /// Permits `public` on a request carrying `Authorization` or `Cookie`.
    /// Set it only when the body does not depend on those credentials.
    allow_credentials: bool = false,
};

pub const Policy = union(enum) {
    /// `no-store`: no cache may keep any part of the response.
    no_store,
    private: Private,
    public: Public,
};

pub const PolicyError = response.HeaderError || error{
    CacheControlAlreadySet,
    InvalidMaxAge,
    SharedCacheWithCredentials,
    SharedCacheWithSetCookie,
};

/// Appends one `Cache-Control` field for `policy`. Refuses a second policy,
/// lifetimes above `max_delta_seconds`, and `public` on personalized
/// responses (see `Public.allow_credentials`). A failure leaves the
/// response unchanged. Response header limits apply.
pub fn setCacheControl(req: *const router.Request, res: *response.Response, policy: Policy) PolicyError!void {
    var existing = res.getAllHeaders("Cache-Control");
    if (existing.next() != null) return error.CacheControlAlreadySet;

    var buffer: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    switch (policy) {
        .no_store => w.writeAll("no-store") catch unreachable,
        .private => |p| {
            w.writeAll("private") catch unreachable;
            try writeDirectives(&w, p.max_age, null, p.no_cache, p.must_revalidate, p.immutable);
        },
        .public => |p| {
            var cookies = res.getAllHeaders("Set-Cookie");
            if (cookies.next() != null) return error.SharedCacheWithSetCookie;
            if (!p.allow_credentials and (hasHeader(req, "Authorization") or hasHeader(req, "Cookie"))) {
                return error.SharedCacheWithCredentials;
            }
            w.writeAll("public") catch unreachable;
            try writeDirectives(&w, p.max_age, p.s_maxage, p.no_cache, p.must_revalidate, p.immutable);
        },
    }
    try res.setHeader("Cache-Control", w.buffered());
}

fn writeDirectives(
    w: *std.Io.Writer,
    max_age: ?u32,
    s_maxage: ?u32,
    no_cache: bool,
    must_revalidate: bool,
    immutable: bool,
) error{InvalidMaxAge}!void {
    // The buffer holds every directive at its longest value.
    if (max_age) |seconds| {
        if (seconds > max_delta_seconds) return error.InvalidMaxAge;
        w.print(", max-age={d}", .{seconds}) catch unreachable;
    }
    if (s_maxage) |seconds| {
        if (seconds > max_delta_seconds) return error.InvalidMaxAge;
        w.print(", s-maxage={d}", .{seconds}) catch unreachable;
    }
    if (no_cache) w.writeAll(", no-cache") catch unreachable;
    if (must_revalidate) w.writeAll(", must-revalidate") catch unreachable;
    if (immutable) w.writeAll(", immutable") catch unreachable;
}

fn hasHeader(req: *const router.Request, name: []const u8) bool {
    var it = req.getAllHeaders(name);
    return it.next() != null;
}

/// An entity tag. `tag` is the opaque value without quotes or `W/`.
pub const ETag = struct {
    strength: Strength,
    tag: []const u8,

    /// A strong tag promises byte-identical content; a weak tag promises
    /// only semantic equivalence. `If-None-Match` compares both weakly.
    pub const Strength = enum { strong, weak };

    pub fn strong(tag: []const u8) ETag {
        return .{ .strength = .strong, .tag = tag };
    }

    pub fn weak(tag: []const u8) ETag {
        return .{ .strength = .weak, .tag = tag };
    }
};

pub const ETagError = response.HeaderError || error{ ETagAlreadySet, InvalidETag };

/// Appends the `ETag` field. The tag must be at most `max_tag_bytes` of
/// visible ASCII other than `"` (`%x21 / %x23-7E`). Refuses a second
/// validator; a failure leaves the response unchanged.
pub fn setETag(res: *response.Response, etag: ETag) ETagError!void {
    if (etag.tag.len > max_tag_bytes) return error.InvalidETag;
    for (etag.tag) |c| if (c != 0x21 and (c < 0x23 or c > 0x7e)) return error.InvalidETag;
    var existing = res.getAllHeaders("ETag");
    if (existing.next() != null) return error.ETagAlreadySet;
    var buffer: [max_tag_bytes + 4]u8 = undefined;
    const prefix = if (etag.strength == .weak) "W/" else "";
    const value = std.fmt.bufPrint(&buffer, "{s}\"{s}\"", .{ prefix, etag.tag }) catch unreachable;
    try res.setHeader("ETag", value);
}

/// Sets a strong `ETag` derived from the current content type and body
/// (the first 128 bits of SHA-256, hex). Call after the body is final.
pub fn setBodyETag(res: *response.Response) ETagError!void {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(res.content_type);
    hash.update(&.{0});
    hash.update(res.body);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest[0..16], .lower);
    try setETag(res, .strong(&hex));
}

pub const VaryError = response.HeaderError || error{InvalidVary};

/// Adds `field_name` to `Vary` unless an existing `Vary` field already lists
/// it (case-insensitively) or lists `*`. The name must be an HTTP token;
/// `*` is refused, because a response that varies on everything should use
/// `.no_store`. A failure leaves the response unchanged.
pub fn addVary(res: *response.Response, field_name: []const u8) VaryError!void {
    response.validateHeader(field_name, "") catch return error.InvalidVary;
    if (std.mem.eql(u8, field_name, "*")) return error.InvalidVary;
    var it = res.getAllHeaders("Vary");
    while (it.next()) |value| {
        var members = std.mem.splitScalar(u8, value, ',');
        while (members.next()) |member| {
            const name = std.mem.trim(u8, member, " \t");
            if (std.mem.eql(u8, name, "*") or std.ascii.eqlIgnoreCase(name, field_name)) return;
        }
    }
    try res.setHeader("Vary", field_name);
}

pub const Outcome = enum {
    /// The response is sent as built.
    full,
    /// The response was converted to 304 Not Modified.
    not_modified,
};

pub const EvaluateError = error{ DuplicateHeaderValue, InvalidETag };

/// Evaluates `If-None-Match` against the response's `ETag` and converts a
/// handled 2xx GET or HEAD response to 304 when the condition is false.
/// Comparison is weak (RFC 9110 §13.1.2). Repeated request fields form one
/// list. `*` matches any 2xx representation, but only as the sole member.
/// A malformed request field voids the whole condition, so the full response
/// is sent. A response with duplicate or malformed `ETag` fields is an
/// application error.
pub fn evaluate(req: *const router.Request, res: *response.Response) EvaluateError!Outcome {
    if (req.method != .get and req.method != .head) return .full;
    if (!res.handled or res.status_code < 200 or res.status_code > 299) return .full;
    const current: ?Tag = if (try res.getHeaderOne("ETag")) |value|
        parseTag(value) orelse return error.InvalidETag
    else
        null;
    if (!ifNoneMatchFails(req, current)) return .full;
    res.notModified();
    return .not_modified;
}

const Tag = struct { weak: bool, opaque_tag: []const u8 };

/// True when `If-None-Match` is present, well formed, and matches.
fn ifNoneMatchFails(req: *const router.Request, current: ?Tag) bool {
    var members: usize = 0;
    var star = false;
    var matched = false;
    var it = req.getAllHeaders("If-None-Match");
    while (it.next()) |value| {
        var rest = value;
        while (true) {
            // RFC 9110 §5.6.1: recipients accept empty list elements.
            rest = std.mem.trimStart(u8, rest, " \t,");
            if (rest.len == 0) break;
            if (rest[0] == '*') {
                star = true;
                rest = rest[1..];
            } else {
                const tag = takeTag(&rest) orelse return false;
                if (current) |c| {
                    if (std.mem.eql(u8, c.opaque_tag, tag.opaque_tag)) matched = true;
                }
            }
            members += 1;
            rest = std.mem.trimStart(u8, rest, " \t");
            if (rest.len != 0 and rest[0] != ',') return false;
        }
    }
    if (star) return members == 1;
    return matched;
}

fn parseTag(text: []const u8) ?Tag {
    var rest = std.mem.trim(u8, text, " \t");
    const tag = takeTag(&rest) orelse return null;
    return if (rest.len == 0) tag else null;
}

/// Consumes one `entity-tag` from the front of `rest`.
fn takeTag(rest: *[]const u8) ?Tag {
    var s = rest.*;
    const weak = std.mem.startsWith(u8, s, "W/");
    if (weak) s = s[2..];
    if (s.len < 2 or s[0] != '"') return null;
    const close = std.mem.indexOfScalarPos(u8, s, 1, '"') orelse return null;
    const opaque_tag = s[1..close];
    // etagc = %x21 / %x23-7E / obs-text
    for (opaque_tag) |c| if (c != 0x21 and (c < 0x23 or c == 0x7f)) return null;
    rest.* = s[close + 1 ..];
    return .{ .weak = weak, .opaque_tag = opaque_tag };
}

const testing = std.testing;

fn testRequest(method: router.Method, headers: []const router.Header) router.Request {
    return .{ .method = method, .segments = &.{}, .headers = headers };
}

fn taggedResponse(etag: ETag) !response.Response {
    var res = response.Response.init(testing.allocator);
    errdefer res.deinit();
    try res.text(200, "representation");
    try setETag(&res, etag);
    return res;
}

test "cache policies format explicit directives" {
    const req = testRequest(.get, &.{});
    const cases = .{
        .{ Policy.no_store, "no-store" },
        .{ Policy{ .private = .{} }, "private" },
        .{ Policy{ .private = .{ .max_age = 0, .no_cache = true } }, "private, max-age=0, no-cache" },
        .{
            Policy{ .public = .{ .max_age = max_delta_seconds, .s_maxage = 60, .must_revalidate = true, .immutable = true } },
            "public, max-age=2147483648, s-maxage=60, must-revalidate, immutable",
        },
    };
    inline for (cases) |case| {
        var res = response.Response.init(testing.allocator);
        defer res.deinit();
        try setCacheControl(&req, &res, case[0]);
        try testing.expectEqualStrings(case[1], (try res.getHeaderOne("cache-control")).?);
    }
}

test "cache policy refuses invalid, repeated, and personalized shared caching" {
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try res.text(200, "body");
    const plain = testRequest(.get, &.{});
    try testing.expectError(error.InvalidMaxAge, setCacheControl(&plain, &res, .{ .private = .{ .max_age = max_delta_seconds + 1 } }));
    try testing.expectError(error.InvalidMaxAge, setCacheControl(&plain, &res, .{ .public = .{ .s_maxage = std.math.maxInt(u32) } }));
    try testing.expectEqual(@as(usize, 0), res.header_count);

    const credentials = [_][]const router.Header{
        &.{.{ .name = "authorization", .value = "Bearer abc" }},
        &.{.{ .name = "Cookie", .value = "__Host-zoda_session=x" }},
    };
    for (credentials) |headers| {
        const req = testRequest(.get, headers);
        try testing.expectError(error.SharedCacheWithCredentials, setCacheControl(&req, &res, .{ .public = .{ .max_age = 60 } }));
        try testing.expectEqual(@as(usize, 0), res.header_count);
    }
    const cookie_req = testRequest(.get, credentials[1]);
    try setCacheControl(&cookie_req, &res, .{ .public = .{ .max_age = 60, .allow_credentials = true } });
    try testing.expectError(error.CacheControlAlreadySet, setCacheControl(&plain, &res, .no_store));

    var session = response.Response.init(testing.allocator);
    defer session.deinit();
    try session.setHeader("Set-Cookie", "sid=1");
    try testing.expectError(
        error.SharedCacheWithSetCookie,
        setCacheControl(&plain, &session, .{ .public = .{ .allow_credentials = true } }),
    );
    try setCacheControl(&plain, &session, .{ .private = .{ .no_cache = true } });
    try testing.expectEqual(@as(usize, 2), session.header_count);
}

test "validators format strong and weak tags and reject invalid values" {
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    const bad = [_][]const u8{ "a\"b", "with space", "tab\t", "\x7f", "é", "a\r\nX: y", "x" ** (max_tag_bytes + 1) };
    for (bad) |tag| try testing.expectError(error.InvalidETag, setETag(&res, .strong(tag)));
    try testing.expectEqual(@as(usize, 0), res.header_count);
    try setETag(&res, .weak("v1-!#~"));
    try testing.expectEqualStrings("W/\"v1-!#~\"", (try res.getHeaderOne("etag")).?);
    try testing.expectError(error.ETagAlreadySet, setETag(&res, .strong("v2")));

    var empty = response.Response.init(testing.allocator);
    defer empty.deinit();
    try setETag(&empty, .strong(""));
    try testing.expectEqualStrings("\"\"", (try empty.getHeaderOne("ETag")).?);
}

test "body validators depend on content type and body" {
    var a = response.Response.init(testing.allocator);
    defer a.deinit();
    try a.text(200, "same");
    try setBodyETag(&a);
    var b = response.Response.init(testing.allocator);
    defer b.deinit();
    try b.text(200, "same");
    try setBodyETag(&b);
    var c = response.Response.init(testing.allocator);
    defer c.deinit();
    try c.replaceJson(200, []const u8, "same");
    try setBodyETag(&c);
    const tag_a = (try a.getHeaderOne("ETag")).?;
    try testing.expectEqual(@as(usize, 34), tag_a.len);
    try testing.expectEqualStrings(tag_a, (try b.getHeaderOne("ETag")).?);
    try testing.expect(!std.mem.eql(u8, tag_a, (try c.getHeaderOne("ETag")).?));
}

test "vary merges names across repeated fields and rejects invalid names" {
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try addVary(&res, "Accept-Encoding");
    try addVary(&res, "accept-encoding");
    try res.setHeader("Vary", "Origin, \tAccept-Language");
    try addVary(&res, "ACCEPT-LANGUAGE");
    try addVary(&res, "Cookie");
    try testing.expectEqual(@as(usize, 3), res.header_count);
    var it = res.getAllHeaders("vary");
    try testing.expectEqualStrings("Accept-Encoding", it.next().?);
    try testing.expectEqualStrings("Origin, \tAccept-Language", it.next().?);
    try testing.expectEqualStrings("Cookie", it.next().?);
    for ([_][]const u8{ "", "*", "Bad Name", "a,b", "a\r\n" }) |name| {
        try testing.expectError(error.InvalidVary, addVary(&res, name));
    }

    var star = response.Response.init(testing.allocator);
    defer star.deinit();
    try star.setHeader("Vary", "*");
    try addVary(&star, "Origin");
    try testing.expectEqual(@as(usize, 1), star.header_count);
}

test "matching validators produce 304 for GET and HEAD and keep headers" {
    const matches = [_][]const u8{
        "\"v1\"",
        "W/\"v1\"",
        "\"other\", \"v1\"",
        " ,, \"other\",W/\"v1\" , ",
        "*",
    };
    for ([_]router.Method{ .get, .head }) |method| {
        for (matches) |value| {
            const headers = [_]router.Header{.{ .name = "If-None-Match", .value = value }};
            const req = testRequest(method, &headers);
            var res = try taggedResponse(.strong("v1"));
            defer res.deinit();
            try res.setHeader("Vary", "Accept-Encoding");
            try setCacheControl(&req, &res, .{ .private = .{ .no_cache = true } });
            try testing.expectEqual(Outcome.not_modified, try evaluate(&req, &res));
            try testing.expectEqual(@as(u16, 304), res.status_code);
            try testing.expectEqualStrings("", res.body);
            try testing.expectEqualStrings("", res.content_type);
            try testing.expectEqualStrings("\"v1\"", (try res.getHeaderOne("ETag")).?);
            try testing.expectEqualStrings("Accept-Encoding", (try res.getHeaderOne("Vary")).?);
            try testing.expectEqualStrings("private, no-cache", (try res.getHeaderOne("Cache-Control")).?);
        }
    }
    // A weak response validator also matches a strong request tag.
    const headers = [_]router.Header{.{ .name = "if-none-match", .value = "\"v1\"" }};
    const req = testRequest(.get, &headers);
    var weak = try taggedResponse(.weak("v1"));
    defer weak.deinit();
    try testing.expectEqual(Outcome.not_modified, try evaluate(&req, &weak));
}

test "repeated If-None-Match fields form one list" {
    const headers = [_]router.Header{
        .{ .name = "If-None-Match", .value = "\"a\"" },
        .{ .name = "if-none-match", .value = "\"b\", \"v1\"" },
    };
    const req = testRequest(.get, &headers);
    var res = try taggedResponse(.strong("v1"));
    defer res.deinit();
    try testing.expectEqual(Outcome.not_modified, try evaluate(&req, &res));

    // `*` is valid only as the whole list, including across fields.
    const stars = [_][]const router.Header{
        &.{ .{ .name = "If-None-Match", .value = "*" }, .{ .name = "If-None-Match", .value = "\"x\"" } },
        &.{ .{ .name = "If-None-Match", .value = "*" }, .{ .name = "If-None-Match", .value = "*" } },
        &.{.{ .name = "If-None-Match", .value = "*, \"v1\"" }},
    };
    for (stars) |star_headers| {
        const star_req = testRequest(.get, star_headers);
        var full = try taggedResponse(.strong("v1"));
        defer full.deinit();
        try testing.expectEqual(Outcome.full, try evaluate(&star_req, &full));
        try testing.expectEqual(@as(u16, 200), full.status_code);
    }
}

test "nonmatching, invalid, and inapplicable conditions keep the full response" {
    const values = [_][]const u8{
        "\"v2\"",
        "W/\"v2\", \"v10\"",
        "",
        "v1",
        "\"v1",
        "w/\"v1\"",
        "\"v1\" \"v2\"",
        "\"v1\"x",
        "\"v1\";",
        "\"v\x011\"",
        "\"v1\", garbage",
        "**",
    };
    for (values) |value| {
        const headers = [_]router.Header{.{ .name = "If-None-Match", .value = value }};
        const req = testRequest(.get, &headers);
        var res = try taggedResponse(.strong("v1"));
        defer res.deinit();
        try testing.expectEqual(Outcome.full, try evaluate(&req, &res));
        try testing.expectEqual(@as(u16, 200), res.status_code);
        try testing.expectEqualStrings("representation", res.body);
    }
    // A malformed field voids the condition even when another field matches.
    const mixed = [_]router.Header{
        .{ .name = "If-None-Match", .value = "\"v1\"" },
        .{ .name = "If-None-Match", .value = "bogus" },
    };
    const mixed_req = testRequest(.get, &mixed);
    var mixed_res = try taggedResponse(.strong("v1"));
    defer mixed_res.deinit();
    try testing.expectEqual(Outcome.full, try evaluate(&mixed_req, &mixed_res));

    const match = [_]router.Header{.{ .name = "If-None-Match", .value = "\"v1\"" }};
    for ([_]router.Method{ .post, .put, .delete, .patch }) |method| {
        const req = testRequest(method, &match);
        var res = try taggedResponse(.strong("v1"));
        defer res.deinit();
        try testing.expectEqual(Outcome.full, try evaluate(&req, &res));
    }
    const req = testRequest(.get, &match);
    var missing = try taggedResponse(.strong("v1"));
    defer missing.deinit();
    missing.status_code = 404;
    try testing.expectEqual(Outcome.full, try evaluate(&req, &missing));
    var untagged = response.Response.init(testing.allocator);
    defer untagged.deinit();
    try untagged.text(200, "no validator");
    try testing.expectEqual(Outcome.full, try evaluate(&req, &untagged));
    var unhandled = response.Response.init(testing.allocator);
    defer unhandled.deinit();
    try testing.expectEqual(Outcome.full, try evaluate(&req, &unhandled));
    try testing.expectEqual(Outcome.full, try evaluate(&testRequest(.get, &.{}), &missing));
}

test "invalid response validators are application errors" {
    const match = [_]router.Header{.{ .name = "If-None-Match", .value = "*" }};
    const req = testRequest(.get, &match);
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try res.text(200, "x");
    try res.setHeader("ETag", "unquoted");
    try testing.expectError(error.InvalidETag, evaluate(&req, &res));
    try res.setHeader("ETag", "\"v1\"");
    try testing.expectError(error.DuplicateHeaderValue, evaluate(&req, &res));
    try testing.expectEqual(@as(u16, 200), res.status_code);
}

test "helpers honor response header limits without partial changes" {
    const req = testRequest(.get, &.{});
    var counted = response.Response.initWithLimits(testing.allocator, .{ .max_headers = 0 });
    defer counted.deinit();
    try testing.expectError(error.TooManyHeaders, setCacheControl(&req, &counted, .no_store));
    try testing.expectError(error.TooManyHeaders, setETag(&counted, .strong("v1")));
    try testing.expectError(error.TooManyHeaders, addVary(&counted, "Origin"));
    var sized = response.Response.initWithLimits(testing.allocator, .{ .header_bytes = 8 });
    defer sized.deinit();
    try testing.expectError(error.HeaderBytesExceeded, setCacheControl(&req, &sized, .{ .private = .{ .max_age = 60 } }));
    try testing.expectError(error.HeaderBytesExceeded, setBodyETag(&sized));
    try testing.expectEqual(@as(usize, 0), counted.header_count + sized.header_count);

    // A 304 releases the body, so it fits any body limit.
    var bounded = response.Response.initWithLimits(testing.allocator, .{ .max_body_bytes = 14 });
    defer bounded.deinit();
    try bounded.text(200, "representation");
    try setETag(&bounded, .strong("v1"));
    const match = [_]router.Header{.{ .name = "If-None-Match", .value = "\"v1\"" }};
    try testing.expectEqual(Outcome.not_modified, try evaluate(&testRequest(.head, &match), &bounded));
    try testing.expectEqual(@as(usize, 0), bounded.body.len);
}

test "helpers propagate allocation failures without leaking" {
    const build = struct {
        fn build(allocator: std.mem.Allocator) !void {
            const match = [_]router.Header{.{ .name = "If-None-Match", .value = "\"v1\"" }};
            const req = testRequest(.get, &match);
            var res = response.Response.init(allocator);
            defer res.deinit();
            try res.text(200, "x");
            try setCacheControl(&req, &res, .{ .private = .{ .no_cache = true } });
            try setETag(&res, .strong("v1"));
            try addVary(&res, "Cookie");
            _ = try evaluate(&req, &res);
        }
    }.build;
    try testing.checkAllAllocationFailures(testing.allocator, build, .{});
}
