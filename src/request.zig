//! Owned request storage and strict origin-form target/query parsing
//! (ADR-0001 §3.4, §5.1).
//!
//! A `RequestArena` owns, for the lifetime of the request, copies of the raw
//! target, decoded path segments, ordered query pairs, repeated headers, and
//! body. Construction (`parseOriginForm`) propagates allocation failures as
//! errors — never as "no route matched" (§3.1). Dispatch borrows the `Request`
//! view produced by `requestView` and keeps it alive until it returns; returned
//! capture slices must not outlive the request.
//!
//! Parsing rules implemented here:
//! - Only origin-form targets (`/path?query`) are accepted for application
//!   routes; control bytes, raw spaces, `#` fragments, and missing leading
//!   slashes are rejected.
//! - The query is split from the path before any decoding.
//! - The path is split on literal `/` bytes and each segment is percent-decoded
//!   exactly once. Rejected: malformed escapes (`%` not followed by two hex
//!   digits), decoded `/`, any `\` (raw or decoded), decoded NUL, and the dot
//!   segments `.` and `..` (raw or decoded, e.g. `%2E`).
//! - `/` is the root (zero segments); trailing and repeated slashes preserve
//!   their empty segments, so `/users/` and `/users` are distinct routes.
//! - In the query, `+` means space and percent escapes decode once. Order and
//!   duplicates survive. Decoded NUL is rejected; decoded `/` and `\` remain
//!   legal data. The router's `Request.getAll`/`getOne` read the pairs
//!   allocation-free.
//! - Headers and body are copied into the arena (repeated header fields are
//!   retained verbatim as a list); the configured `Limits` are enforced at copy
//!   time. Header name lookup is case-insensitive and returns every repeated
//!   value.
//!
//! Limits and error→status mapping are the transport contract (#7); this
//! module only reports structured errors (`TargetTooLong`, `TooManyHeaders`,
//! `BodyTooLarge`, `TooManyPathSegments`, `TooManyQueryPairs`, and the
//! malformed-syntax errors).
const std = @import("std");
const router = @import("router.zig");

pub const Method = router.Method;
pub const QueryPair = router.QueryPair;

/// Configurable request bounds (§3.4 defaults). The transport exposes these
/// incrementally while reading (phase 0.5, #7); here they bound target parsing
/// and the arena's header/body copies.
pub const Limits = struct {
    /// Maximum raw target length, enforced before allocation (§3.4: 8 KiB).
    target_bytes: usize = 8 * 1024,
    /// Maximum number of repeated header fields.
    max_headers: usize = 100,
    /// Maximum total header name+value bytes.
    header_bytes: usize = 32 * 1024,
    /// Maximum number of decoded path segments.
    max_path_segments: usize = 128,
    /// Maximum number of query pairs.
    max_query_pairs: usize = 256,
    /// Maximum request body bytes.
    max_body_bytes: usize = 1024 * 1024,

    pub const default: Limits = .{};
};

/// A single header field. Repeated fields with the same name are retained as
/// separate entries, preserving order (§3.4).
pub const Header = router.Header;

/// Errors produced while constructing a request arena from an origin-form
/// target. Reading/limits and their protocol status mappings are transport
/// concerns (#7); allocation failures always surface as `OutOfMemory`.
pub const ParseError = error{
    /// Target is not origin-form (empty, missing leading `/`, contains a
    /// fragment `#`, a raw space, or a control byte).
    InvalidTarget,
    /// Raw target exceeds `Limits.target_bytes`. (Status mapping 414 is #7.)
    TargetTooLong,
    /// A `%` is not followed by two hexadecimal digits.
    MalformedPercentEncoding,
    /// A decoded `/`, any `\`, or a decoded NUL appeared in a path segment.
    ForbiddenPathCharacter,
    /// A path segment decoded to exactly `.` or `..`.
    DotSegment,
    /// More path segments than `Limits.max_path_segments`.
    TooManyPathSegments,
    /// More query pairs than `Limits.max_query_pairs`.
    TooManyQueryPairs,
    OutOfMemory,
};

/// Errors produced by copying headers into the arena. 431 mapping is #7.
pub const HeaderStoreError = error{
    OutOfMemory,
    TooManyHeaders,
    HeaderBytesExceeded,
};

/// Errors produced by copying a body into the arena. 413 mapping is #7.
pub const BodyStoreError = error{
    OutOfMemory,
    BodyTooLarge,
};

/// Owns all request storage. All slices (`target`, `segments`, `query`,
/// `headers`, `body`) point into the arena and stay valid until `deinit`. The
/// arena is append-only during the request: do not free allocations taken from
/// `allocator()` while constructed slices are still borrowed.
pub const RequestArena = struct {
    backing: std.heap.ArenaAllocator,
    limits: Limits,
    /// Raw target, preserved verbatim (§3.4).
    target: []const u8 = &.{},
    /// Decoded path segments; `/` parses to zero segments.
    segments: []const []const u8 = &.{},
    /// Ordered query pairs, decoded once with `+` as space.
    query: []const QueryPair = &.{},
    /// Repeated header fields retained in request order.
    headers: []const Header = &.{},
    /// Owned copy of the request body.
    body: []const u8 = &.{},

    pub fn init(gpa: std.mem.Allocator, limits: Limits) RequestArena {
        return .{
            .backing = std.heap.ArenaAllocator.init(gpa),
            .limits = limits,
        };
    }

    /// Allocator for append-only request storage (body accumulation, transport
    /// scratch). Frees are permitted only while the returned slices are not
    /// borrowed; see the type docs.
    pub fn allocator(self: *RequestArena) std.mem.Allocator {
        return self.backing.allocator();
    }

    pub fn deinit(self: *RequestArena) void {
        self.backing.deinit();
    }

    /// Copies repeated header fields into the arena, enforcing the configured
    /// header count and byte bounds. Order and duplicates are preserved.
    pub fn copyHeaders(self: *RequestArena, headers: []const Header) HeaderStoreError!void {
        const al = self.backing.allocator();
        if (headers.len > self.limits.max_headers) return error.TooManyHeaders;
        var total_bytes: usize = 0;
        for (headers) |h| total_bytes += h.name.len + h.value.len;
        if (total_bytes > self.limits.header_bytes) return error.HeaderBytesExceeded;

        const copied = try al.alloc(Header, headers.len);
        for (headers, 0..) |h, i| {
            copied[i] = .{
                .name = try al.dupe(u8, h.name),
                .value = try al.dupe(u8, h.value),
            };
        }
        self.headers = copied;
    }

    /// Copies the request body into the arena, enforcing the configured bound.
    pub fn copyBody(self: *RequestArena, body: []const u8) BodyStoreError!void {
        if (body.len > self.limits.max_body_bytes) return error.BodyTooLarge;
        self.body = try self.backing.allocator().dupe(u8, body);
    }

    /// A routing view borrowed from this arena's own storage, suitable for the
    /// allocation-free router matchers. The returned `router.Request` must not
    /// outlive the arena (§3.4).
    pub fn requestView(self: *const RequestArena, method: Method) router.Request {
        return .{
            .method = method,
            .target = self.target,
            .segments = self.segments,
            .query = self.query,
            .headers = self.headers,
            .body = self.body,
        };
    }

    /// Iterates every header value for `name`, case-insensitively, in request
    /// order, including repeated values.
    pub const HeaderIterator = struct {
        headers: []const Header,
        name: []const u8,
        index: usize = 0,

        pub fn next(self: *HeaderIterator) ?[]const u8 {
            while (self.index < self.headers.len) {
                const header = self.headers[self.index];
                self.index += 1;
                if (std.ascii.eqlIgnoreCase(header.name, self.name)) return header.value;
            }
            return null;
        }
    };

    /// Returns every value for a header name, case-insensitively, preserving
    /// repeated fields. Allocation-free.
    pub fn getAllHeaders(self: *const RequestArena, name: []const u8) HeaderIterator {
        return .{ .headers = self.headers, .name = name };
    }

    /// Returns the single value for a header name, `null` when absent, and
    /// `error.DuplicateHeaderValue` when the field repeats — mirroring the
    /// query `getOne` contract instead of silently choosing a value.
    pub fn getHeaderOne(self: *const RequestArena, name: []const u8) error{DuplicateHeaderValue}!?[]const u8 {
        var found: ?[]const u8 = null;
        var it = self.getAllHeaders(name);
        while (it.next()) |value| {
            if (found != null) return error.DuplicateHeaderValue;
            found = value;
        }
        return found;
    }

    fn parsePathAndQuery(self: *RequestArena, raw_target: []const u8) ParseError!void {
        if (raw_target.len == 0 or raw_target[0] != '/') return error.InvalidTarget;
        if (raw_target.len > self.limits.target_bytes) return error.TargetTooLong;

        // Whole-target validity: origin-form carries no fragment, raw space, or
        // control bytes. A `\` is rejected per segment during path decoding,
        // but remains legal data in the query.
        for (raw_target) |c| {
            if (c == '#' or c < 0x21 or c == 0x7f) return error.InvalidTarget;
        }

        // The raw target is preserved verbatim, then the query is split off
        // before any decoding: the first `?` separates the query; later `?`
        // bytes belong to the query string (§3.4).
        const query_idx = std.mem.indexOfScalar(u8, raw_target, '?');
        const raw_path = if (query_idx) |i| raw_target[0..i] else raw_target;
        const raw_query = if (query_idx) |i| raw_target[i + 1 ..] else null;

        const al = self.backing.allocator();
        self.target = try al.dupe(u8, raw_target);

        try self.parsePath(raw_path);
        if (raw_query) |q| try self.parseQuery(q);
    }

    fn parsePath(self: *RequestArena, path: []const u8) ParseError!void {
        if (path.len == 1) {
            // "/" is the root: zero segments.
            self.segments = &.{};
            return;
        }
        const tail = path[1..];
        var count: usize = 1;
        for (tail) |c| {
            if (c == '/') count += 1;
        }
        if (count > self.limits.max_path_segments) return error.TooManyPathSegments;

        const al = self.backing.allocator();
        const segments = try al.alloc([]const u8, count);
        var i: usize = 0;
        var it = std.mem.splitScalar(u8, tail, '/');
        while (it.next()) |raw_seg| : (i += 1) {
            segments[i] = try self.decodeSegment(raw_seg);
        }
        self.segments = segments;
    }

    fn parseQuery(self: *RequestArena, raw_query: []const u8) ParseError!void {
        if (raw_query.len == 0) return; // trailing `?` carries no pairs

        var count: usize = 1;
        for (raw_query) |c| {
            if (c == '&') count += 1;
        }
        if (count > self.limits.max_query_pairs) return error.TooManyQueryPairs;

        const al = self.backing.allocator();
        const pairs = try al.alloc(QueryPair, count);
        var i: usize = 0;
        var it = std.mem.splitScalar(u8, raw_query, '&');
        while (it.next()) |raw_pair| : (i += 1) {
            const eq = std.mem.indexOfScalar(u8, raw_pair, '=');
            const raw_key = if (eq) |e| raw_pair[0..e] else raw_pair;
            const raw_value = if (eq) |e| raw_pair[e + 1 ..] else "";
            pairs[i] = .{
                .key = try self.decode(raw_key, .query),
                .value = try self.decode(raw_value, .query),
            };
        }
        self.query = pairs;
    }

    fn decodeSegment(self: *RequestArena, raw: []const u8) ParseError![]const u8 {
        const decoded = try self.decode(raw, .path);
        if (std.mem.eql(u8, decoded, ".") or std.mem.eql(u8, decoded, "..")) {
            return error.DotSegment;
        }
        return decoded;
    }

    const DecodeMode = enum { path, query };

    /// Percent-decodes `raw` exactly once into a fresh arena allocation.
    /// Mode controls `+` handling and the forbidden decoded bytes.
    fn decode(self: *RequestArena, raw: []const u8, mode: DecodeMode) ParseError![]const u8 {
        if (raw.len == 0) return raw;
        const al = self.backing.allocator();
        // A decoded byte never exceeds a raw byte (%XX is 3 raw → 1 decoded),
        // so raw.len is a safe capacity.
        const out = try al.alloc(u8, raw.len);
        var n: usize = 0;
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (c == '%') {
                if (i + 2 >= raw.len) return error.MalformedPercentEncoding;
                const hi = hex(raw[i + 1]) orelse return error.MalformedPercentEncoding;
                const lo = hex(raw[i + 2]) orelse return error.MalformedPercentEncoding;
                const decoded_byte = hi * 16 + lo;
                if (mode == .path) {
                    if (decoded_byte == '/' or decoded_byte == '\\' or decoded_byte == 0) {
                        return error.ForbiddenPathCharacter;
                    }
                } else if (decoded_byte == 0) {
                    return error.ForbiddenPathCharacter;
                }
                out[n] = decoded_byte;
                n += 1;
                i += 3;
            } else if (c == '+' and mode == .query) {
                out[n] = ' ';
                n += 1;
                i += 1;
            } else {
                if (mode == .path and c == '\\') return error.ForbiddenPathCharacter;
                out[n] = c;
                n += 1;
                i += 1;
            }
        }
        return out[0..n];
    }
};

fn hex(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Parses an origin-form target into a fully owned request arena: raw target
/// preserved, path split on literal slashes and decoded once, query split
/// before decoding with `+` as space, order and duplicates everywhere intact.
/// Allocation failures propagate as errors; on failure nothing leaks.
pub fn parseOriginForm(
    allocator: std.mem.Allocator,
    limits: Limits,
    raw_target: []const u8,
) ParseError!RequestArena {
    var req = RequestArena.init(allocator, limits);
    errdefer req.deinit();
    try req.parsePathAndQuery(raw_target);
    return req;
}
test "root parses to zero segments with the raw target preserved" {
    var req = try parseOriginForm(std.testing.allocator, .default, "/");
    defer req.deinit();
    try std.testing.expectEqualStrings("/", req.target);
    try std.testing.expectEqual(@as(usize, 0), req.segments.len);
    try std.testing.expectEqual(@as(usize, 0), req.query.len);
}

test "slash semantics preserve root, trailing, and repeated slashes" {
    var trailing = try parseOriginForm(std.testing.allocator, .default, "/users/");
    defer trailing.deinit();
    try std.testing.expectEqual(@as(usize, 2), trailing.segments.len);
    try std.testing.expectEqualStrings("users", trailing.segments[0]);
    try std.testing.expectEqualStrings("", trailing.segments[1]);

    var repeated = try parseOriginForm(std.testing.allocator, .default, "//users");
    defer repeated.deinit();
    try std.testing.expectEqual(@as(usize, 2), repeated.segments.len);
    try std.testing.expectEqualStrings("", repeated.segments[0]);
    try std.testing.expectEqualStrings("users", repeated.segments[1]);

    var dbl = try parseOriginForm(std.testing.allocator, .default, "//");
    defer dbl.deinit();
    try std.testing.expectEqual(@as(usize, 2), dbl.segments.len);
}

test "query is split before decoding; escaped question marks stay in the path" {
    var req = try parseOriginForm(std.testing.allocator, .default, "/a%3Fb?first=1");
    defer req.deinit();
    try std.testing.expectEqual(@as(usize, 1), req.segments.len);
    try std.testing.expectEqualStrings("a?b", req.segments[0]);
    try std.testing.expectEqual(@as(usize, 1), req.query.len);
    try std.testing.expectEqualStrings("first", req.query[0].key);
    try std.testing.expectEqualStrings("1", req.query[0].value);

    var trailing = try parseOriginForm(std.testing.allocator, .default, "/x?");
    defer trailing.deinit();
    try std.testing.expectEqual(@as(usize, 0), trailing.query.len);

    var literal = try parseOriginForm(std.testing.allocator, .default, "/x?tag=a??b");
    defer literal.deinit();
    try std.testing.expectEqual(@as(usize, 1), literal.query.len);
    try std.testing.expectEqualStrings("tag", literal.query[0].key);
    try std.testing.expectEqualStrings("a??b", literal.query[0].value);
}

test "query plus means space and decoded slashes stay as data" {
    var req = try parseOriginForm(std.testing.allocator, .default, "/search?a=b+c&x=a%2Fb&q=");
    defer req.deinit();
    try std.testing.expectEqualStrings("b c", req.query[0].value);
    try std.testing.expectEqualStrings("a/b", req.query[1].value);
    try std.testing.expectEqualStrings("", req.query[2].value);

    try std.testing.expectError(
        error.ForbiddenPathCharacter,
        parseOriginForm(std.testing.allocator, .default, "/?x=a%00b"),
    );
}

test "percent escapes decode exactly once" {
    var req = try parseOriginForm(std.testing.allocator, .default, "/a%20b/%7Ex/%25%32%46");
    defer req.deinit();
    try std.testing.expectEqualStrings("a b", req.segments[0]);
    try std.testing.expectEqualStrings("~x", req.segments[1]);
    // "%252F" decodes once to the literal "%2F"; it must never recurse to "/".
    try std.testing.expectEqualStrings("%2F", req.segments[2]);
}

test "rejects malformed percent escapes" {
    try std.testing.expectError(error.MalformedPercentEncoding, parseOriginForm(std.testing.allocator, .default, "/%"));
    try std.testing.expectError(error.MalformedPercentEncoding, parseOriginForm(std.testing.allocator, .default, "/%2"));
    try std.testing.expectError(error.MalformedPercentEncoding, parseOriginForm(std.testing.allocator, .default, "/a%2G"));
    try std.testing.expectError(error.MalformedPercentEncoding, parseOriginForm(std.testing.allocator, .default, "/a%GGb"));
    try std.testing.expectError(error.MalformedPercentEncoding, parseOriginForm(std.testing.allocator, .default, "/?x=%zz"));
}

test "rejects decoded slash, backslash, and NUL in path segments" {
    try std.testing.expectError(error.ForbiddenPathCharacter, parseOriginForm(std.testing.allocator, .default, "/a%2Fb"));
    try std.testing.expectError(error.ForbiddenPathCharacter, parseOriginForm(std.testing.allocator, .default, "/a%5Cb"));
    try std.testing.expectError(error.ForbiddenPathCharacter, parseOriginForm(std.testing.allocator, .default, "/a\\b"));
    try std.testing.expectError(error.ForbiddenPathCharacter, parseOriginForm(std.testing.allocator, .default, "/a%00b"));
}

test "rejects dot segments raw and decoded" {
    try std.testing.expectError(error.DotSegment, parseOriginForm(std.testing.allocator, .default, "/."));
    try std.testing.expectError(error.DotSegment, parseOriginForm(std.testing.allocator, .default, "/.."));
    try std.testing.expectError(error.DotSegment, parseOriginForm(std.testing.allocator, .default, "/a/../b"));
    try std.testing.expectError(error.DotSegment, parseOriginForm(std.testing.allocator, .default, "/%2E"));
    try std.testing.expectError(error.DotSegment, parseOriginForm(std.testing.allocator, .default, "/a/%2e%2E/b"));
}

test "rejects non-origin-form and invalid raw targets" {
    try std.testing.expectError(error.InvalidTarget, parseOriginForm(std.testing.allocator, .default, ""));
    try std.testing.expectError(error.InvalidTarget, parseOriginForm(std.testing.allocator, .default, "users/42"));
    try std.testing.expectError(error.InvalidTarget, parseOriginForm(std.testing.allocator, .default, "http://example.com/x"));
    try std.testing.expectError(error.InvalidTarget, parseOriginForm(std.testing.allocator, .default, "/a#frag"));
    try std.testing.expectError(error.InvalidTarget, parseOriginForm(std.testing.allocator, .default, "/a b"));
    try std.testing.expectError(error.InvalidTarget, parseOriginForm(std.testing.allocator, .default, "/a\tb"));
}

test "arena owns copies that survive source mutation" {
    var buf = [_]u8{ '/', 'u', 's', 'e', 'r', 's', '/', '4', '2', '?', 't', 'a', 'g', '=', 'o', 'n', 'e' };
    var req = try parseOriginForm(std.testing.allocator, .default, &buf);
    defer req.deinit();
    @memset(&buf, 'X');
    try std.testing.expectEqualStrings("/users/42?tag=one", req.target);
    try std.testing.expectEqual(@as(usize, 2), req.segments.len);
    try std.testing.expectEqualStrings("users", req.segments[0]);
    try std.testing.expectEqualStrings("42", req.segments[1]);
    try std.testing.expectEqualStrings("one", req.query[0].value);
}

test "headers and body are owned, repeated, and looked up case-insensitively" {
    var req = try parseOriginForm(std.testing.allocator, .default, "/");
    defer req.deinit();

    const name0 = "Accept";
    const name1 = "X-Trace";
    const name2 = "accept";
    var n0: [name0.len]u8 = name0.*;
    var v0: [16]u8 = "application/json".*;
    var n1: [name1.len]u8 = name1.*;
    var v1: [1]u8 = "a".*;
    var n2: [name2.len]u8 = name2.*;
    var v2: [9]u8 = "text/html".*;
    const src_headers = [_]Header{
        .{ .name = &n0, .value = &v0 },
        .{ .name = &n1, .value = &v1 },
        .{ .name = &n2, .value = &v2 },
    };
    try req.copyHeaders(&src_headers);

    var body = [_]u8{ '{', '}' };
    try req.copyBody(&body);

    // Overwrite every source byte; the arena keeps the originals.
    @memset(&n0, 'X');
    @memset(&v0, 'X');
    @memset(&n1, 'X');
    @memset(&v1, 'X');
    @memset(&n2, 'X');
    @memset(&v2, 'X');
    @memset(&body, 'X');

    try std.testing.expectEqual(@as(usize, 3), req.headers.len);
    try std.testing.expectEqualStrings("Accept", req.headers[0].name);
    try std.testing.expectEqualStrings("application/json", req.headers[0].value);
    try std.testing.expectEqualStrings("{}", req.body);

    var it = req.getAllHeaders("accept");
    try std.testing.expectEqualStrings("application/json", it.next().?);
    try std.testing.expectEqualStrings("text/html", it.next().?);
    try std.testing.expect(it.next() == null);

    try std.testing.expectEqualStrings("a", (try req.getHeaderOne("x-trace")).?);
    try std.testing.expect((try req.getHeaderOne("absent")) == null);
    try std.testing.expectError(error.DuplicateHeaderValue, req.getHeaderOne("accept"));
}

test "request view exposes the complete arena-owned request" {
    var arena = try parseOriginForm(std.testing.allocator, .default, "/items?q=one");
    defer arena.deinit();
    try arena.copyHeaders(&.{.{ .name = "X-Test", .value = "yes" }});
    try arena.copyBody("payload");

    const view = arena.requestView(.post);
    try std.testing.expectEqualStrings("/items?q=one", view.target);
    try std.testing.expectEqualStrings("payload", view.body);
    try std.testing.expectEqualStrings("yes", (try view.getHeaderOne("x-test")).?);
    try std.testing.expectEqualStrings("one", (try view.getOne("q")).?);
}

test "limits: target, path segments, query pairs, headers, and body" {
    const seg_limits = Limits{ .max_path_segments = 2 };
    var at_segs = try parseOriginForm(std.testing.allocator, seg_limits, "/a/b");
    defer at_segs.deinit();
    try std.testing.expectEqual(@as(usize, 2), at_segs.segments.len);
    try std.testing.expectError(error.TooManyPathSegments, parseOriginForm(std.testing.allocator, seg_limits, "/a/b/c"));

    const query_limits = Limits{ .max_query_pairs = 2 };
    var at_pairs = try parseOriginForm(std.testing.allocator, query_limits, "/?a=1&b=2");
    defer at_pairs.deinit();
    try std.testing.expectEqual(@as(usize, 2), at_pairs.query.len);
    try std.testing.expectError(error.TooManyQueryPairs, parseOriginForm(std.testing.allocator, query_limits, "/?a=1&b=2&c=3"));

    const target_limits = Limits{ .target_bytes = 8 };
    var at_target = try parseOriginForm(std.testing.allocator, target_limits, "/abcdef/");
    defer at_target.deinit();
    try std.testing.expectError(error.TargetTooLong, parseOriginForm(std.testing.allocator, target_limits, "/abcdefg/"));

    var zero_headers = try parseOriginForm(std.testing.allocator, Limits{ .max_headers = 0 }, "/");
    defer zero_headers.deinit();
    try zero_headers.copyHeaders(&[_]Header{});
    try std.testing.expectError(error.TooManyHeaders, zero_headers.copyHeaders(&.{.{ .name = "a", .value = "1" }}));

    var small_bytes = try parseOriginForm(std.testing.allocator, Limits{ .header_bytes = 4 }, "/");
    defer small_bytes.deinit();
    try std.testing.expectError(error.HeaderBytesExceeded, small_bytes.copyHeaders(&.{.{ .name = "abcd", .value = "ef" }}));

    var small_body = try parseOriginForm(std.testing.allocator, Limits{ .max_body_bytes = 3 }, "/");
    defer small_body.deinit();
    try small_body.copyBody("{}");
    try std.testing.expectError(error.BodyTooLarge, small_body.copyBody("1234"));
}

test "construction propagates allocation failures without leaking" {
    const build = struct {
        fn build(allocator: std.mem.Allocator) !void {
            var req = try parseOriginForm(allocator, .default, "/users/42?a=1&a=2");
            defer req.deinit();
            try req.copyHeaders(&.{.{ .name = "x-a", .value = "1" }});
            try req.copyBody("{}");
        }
    }.build;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, build, .{});
}

test "body limit accepts at-limit length and rejects one byte over" {
    var req = try parseOriginForm(std.testing.allocator, Limits{ .max_body_bytes = 3 }, "/");
    defer req.deinit();
    try req.copyBody("123");
    try std.testing.expectEqualStrings("123", req.body);
    try std.testing.expectError(error.BodyTooLarge, req.copyBody("1234"));
}

test "allocation failure during request construction returns OutOfMemory, not a route error" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const err = parseOriginForm(failing.allocator(), .default, "/users/42");
    try std.testing.expectError(error.OutOfMemory, err);
}

test "parsed request routes through the router with query accessors" {
    var req = try parseOriginForm(std.testing.allocator, .default, "/users/42?tag=one&sort=asc&tag=two");
    defer req.deinit();

    var r = req.requestView(.get);
    try std.testing.expect(r.onLiteral("users"));
    const id = r.onSegment().?;
    try std.testing.expectEqualStrings("42", id);
    try std.testing.expect(r.isRoot());

    var all = r.getAll("tag");
    try std.testing.expectEqualStrings("one", all.next().?);
    try std.testing.expectEqualStrings("two", all.next().?);
    try std.testing.expect(all.next() == null);
    try std.testing.expectError(error.DuplicateQueryValue, r.getOne("tag"));
    try std.testing.expectEqualStrings("asc", (try r.getOne("sort")).?);
}
