//! Independently owned buffered responses and safe header handling
//! (ADR-0001 §3.4, §3.5).
//!
//! A `Response` owns copies of its status, body, content type, and headers
//! through an allocator supplied by the caller. Nothing in a response borrows
//! the request arena, plugin state, the connection, or I/O: the caller may
//! destroy the request before the response is written. The supplied allocator
//! must outlive the response, and `deinit` (or `clear`) releases every owned
//! byte.
//!
//! Concurrency: a single `Response` is not safe for concurrent use. The
//! supplied allocator must support concurrent use when the application serves
//! concurrent requests, or be isolated per request (PLATFORM.md §5, §6).
//!
//! Safe headers: names are validated as HTTP tokens; values reject CR, LF, and
//! NUL so a field value cannot inject framing or additional fields. Lookup is
//! case-insensitive, repeated fields are retained as separate entries (so
//! multiple `Set-Cookie` fields survive), and `getHeaderOne` reports repeats
//! instead of silently choosing a value.
//!
//! Replacement semantics: `text`/`replaceJson` copy the new body, status, and
//! content type into the response and set `handled` only on success. A
//! rejected replacement leaves the previous response untouched. `clear`
//! releases everything and returns the response to its freshly initialized
//! state for error recovery (§3.5).
//!
//! Response framing (Content-Length, Transfer-Encoding, HEAD/bodyless rules)
//! is the wire adapter's responsibility and intentionally absent here (§3.4).
//!
//! Buffered only: a `Response` holds its complete body, bounded by
//! `Limits.max_body_bytes`. Response streaming is not supported and is not
//! implied by this type (ADR-0001 §4.2.5).
const std = @import("std");

/// Configurable response bounds (§3.4 defaults: 100 headers / 32 KiB header
/// bytes / 1 MiB buffered response). Enforced before storage is committed.
pub const Limits = struct {
    /// Maximum number of header fields.
    max_headers: usize = 100,
    /// Maximum total stored header name + value bytes.
    header_bytes: usize = 32 * 1024,
    /// Maximum stored body bytes.
    max_body_bytes: usize = 1024 * 1024,

    pub const default: Limits = .{};
};

/// A single stored header field. Repeated names are kept as separate entries,
/// preserving request order and `Set-Cookie` separation (§3.4).
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Errors from body/status/content-type replacement helpers.
pub const BodyError = error{
    OutOfMemory,
    BodyTooLarge,
};

/// Errors from `replaceOwnedBody`.
pub const OwnedBodyError = BodyError || error{InvalidContentType};

/// Errors from header insertion. The bounds map to 431 at the transport (§3.4).
pub const HeaderError = error{
    OutOfMemory,
    InvalidHeaderName,
    InvalidHeaderValue,
    TooManyHeaders,
    HeaderBytesExceeded,
};

/// Content types set by the built-in helpers.
pub const text_content_type = "text/plain";
pub const json_content_type = "application/json";

/// Redirect status is chosen by the caller. 302/303 may change a follow-up
/// request to GET; 307/308 preserve its method and body.
pub const RedirectStatus = enum(u16) {
    found = 302,
    see_other = 303,
    temporary_redirect = 307,
    permanent_redirect = 308,
};

pub const RedirectError = HeaderError || error{ InvalidRedirectPath, LocationAlreadySet };

/// An independently owned buffered response. Created by `init`, released with
/// `deinit` after the transport has sent it.
pub const Response = struct {
    allocator: std.mem.Allocator,
    limits: Limits = .default,

    /// Status to send. Zero means "unset"; a handled response always sets it.
    status_code: u16 = 0,
    /// Owned body bytes.
    body: []u8 = &.{},
    /// Owned content type, empty when unset.
    content_type: []const u8 = &.{},
    /// Header field values at `[0..header_count]`; allocation length is
    /// `header_cap`. Initialized entries only below `header_count`.
    headers: []Header = &.{},
    header_count: usize = 0,
    header_cap: usize = 0,
    /// Running total of stored header name + value bytes.
    header_bytes_used: usize = 0,
    /// Whether a helper successfully produced a response.
    handled: bool = false,

    pub fn init(allocator: std.mem.Allocator) Response {
        return .{ .allocator = allocator };
    }

    pub fn initWithLimits(allocator: std.mem.Allocator, limits: Limits) Response {
        return .{ .allocator = allocator, .limits = limits };
    }

    /// Releases all owned bytes. Call after the response has been sent.
    pub fn deinit(self: *Response) void {
        self.release();
    }

    /// Safe clearing for error recovery: releases all owned bytes and resets
    /// the response to its freshly initialized state. Infallible and
    /// idempotent; use before constructing a replacement after an error
    /// (§3.5).
    pub fn clear(self: *Response) void {
        self.release();
    }

    fn release(self: *Response) void {
        if (self.body.len != 0) self.allocator.free(self.body);
        if (self.content_type.len != 0) self.allocator.free(@constCast(self.content_type));
        for (self.headers[0..self.header_count]) |header| {
            self.allocator.free(@constCast(header.name));
            self.allocator.free(@constCast(header.value));
        }
        if (self.header_cap != 0) self.allocator.free(self.headers);
        self.body = &.{};
        self.content_type = &.{};
        self.headers = &.{};
        self.header_count = 0;
        self.header_cap = 0;
        self.header_bytes_used = 0;
        self.status_code = 0;
        self.handled = false;
    }

    /// Replaces the body, status, and content type with a plain-text response
    /// and marks handled only on success.
    pub fn text(self: *Response, status_code: u16, body_text: []const u8) BodyError!void {
        if (body_text.len > self.limits.max_body_bytes) return error.BodyTooLarge;
        const body = try self.allocator.dupe(u8, body_text);
        var committed = false;
        defer if (!committed) self.allocator.free(body);
        const content_type = try self.allocator.dupe(u8, text_content_type);
        self.commit(body, status_code, content_type);
        committed = true;
    }

    /// Replaces the body, status, and content type with the JSON encoding of
    /// `value` and marks handled only on success. Serialization uses the
    /// response allocator; an encoding larger than `max_body_bytes` is
    /// rejected without altering the response.
    pub fn replaceJson(
        self: *Response,
        status_code: u16,
        comptime T: type,
        value: T,
    ) BodyError!void {
        const json = std.json.Stringify.valueAlloc(self.allocator, value, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        var committed = false;
        defer if (!committed) self.allocator.free(json);
        if (json.len > self.limits.max_body_bytes) return error.BodyTooLarge;
        const content_type = try self.allocator.dupe(u8, json_content_type);
        self.commit(json, status_code, content_type);
        committed = true;
    }

    /// Replaces the body, status, and content type with `body`, which must have
    /// been allocated from this response's allocator, and marks handled. On
    /// success the response owns `body`; on any error the response is
    /// unchanged and the caller still owns it. `content_type` is copied and
    /// must not contain CR, LF, or NUL. Used to serve a buffer without a
    /// second copy (static files).
    pub fn replaceOwnedBody(
        self: *Response,
        status_code: u16,
        content_type: []const u8,
        body: []u8,
    ) OwnedBodyError!void {
        if (body.len > self.limits.max_body_bytes) return error.BodyTooLarge;
        if (content_type.len == 0 or hasForbiddenValueByte(content_type)) return error.InvalidContentType;
        const owned_type = try self.allocator.dupe(u8, content_type);
        self.commit(body, status_code, owned_type);
    }

    /// Takes ownership of already-allocated `body`/`content_type` and replaces
    /// the previous body, status, and content type. Infallible: callers must
    /// have fully allocated the new storage first, so a replacement never
    /// destroys the old response on a failure path.
    fn commit(self: *Response, body: []u8, status_code: u16, content_type: []const u8) void {
        if (self.body.len != 0) self.allocator.free(self.body);
        if (self.content_type.len != 0) self.allocator.free(@constCast(self.content_type));
        self.body = body;
        self.content_type = content_type;
        self.status_code = status_code;
        self.handled = true;
    }

    /// Appends a copied header field. Names must be valid HTTP tokens; values
    /// must not contain CR, LF, or NUL. Repeated names append separate fields,
    /// so multiple `Set-Cookie` values are preserved. On any error the
    /// response is unchanged.
    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) HeaderError!void {
        try validateHeader(name, value);
        if (self.header_count >= self.limits.max_headers) return error.TooManyHeaders;
        const additional = name.len + value.len;
        if (self.header_bytes_used + additional > self.limits.header_bytes) {
            return error.HeaderBytesExceeded;
        }

        if (self.header_count == self.header_cap) {
            const new_cap = if (self.header_cap == 0) 4 else self.header_cap * 2;
            self.headers = try self.allocator.realloc(self.headers, new_cap);
            self.header_cap = new_cap;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);

        self.headers[self.header_count] = .{ .name = owned_name, .value = owned_value };
        self.header_count += 1;
        self.header_bytes_used += additional;
    }

    /// Sends a local, origin-relative redirect with an empty body. The path
    /// must begin with exactly one slash. Rejects URL authority/scheme forms,
    /// backslashes, controls, spaces, malformed escapes, and encoded slashes,
    /// backslashes or controls. Never derives a destination from Host or
    /// forwarded headers. A failure leaves the response unchanged.
    pub fn redirectPath(self: *Response, status: RedirectStatus, path: []const u8) RedirectError!void {
        try validateRedirectPath(path);
        var locations = self.getAllHeaders("Location");
        if (locations.next() != null) return error.LocationAlreadySet;
        try self.setHeader("Location", path);
        if (self.body.len != 0) self.allocator.free(self.body);
        if (self.content_type.len != 0) self.allocator.free(@constCast(self.content_type));
        self.body = &.{};
        self.content_type = &.{};
        self.status_code = @intFromEnum(status);
        self.handled = true;
    }

    /// Converts a handled response into `304 Not Modified`: releases the body
    /// and content type and keeps every header field, so validators, cache
    /// policy, `Vary`, and `Set-Cookie` still reach the client. Infallible.
    /// The transport omits Content-Length and Content-Type on a 304.
    pub fn notModified(self: *Response) void {
        if (self.body.len != 0) self.allocator.free(self.body);
        if (self.content_type.len != 0) self.allocator.free(@constCast(self.content_type));
        self.body = &.{};
        self.content_type = &.{};
        self.status_code = 304;
        self.handled = true;
    }

    /// Formats a value with `std.fmt` and appends it via `setHeader`. The
    /// formatted bytes are transient and never stored beyond the header byte
    /// limit; on any error the response is unchanged.
    pub fn setHeaderFmt(
        self: *Response,
        name: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) HeaderError!void {
        const formatted = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(formatted);
        try self.setHeader(name, formatted);
    }

    /// Iterates every value for `name`, case-insensitively, in insertion order.
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
    pub fn getAllHeaders(self: *const Response, name: []const u8) HeaderIterator {
        return .{ .headers = self.headers[0..self.header_count], .name = name };
    }

    /// Returns the single value for a header name, `null` when absent, and
    /// `error.DuplicateHeaderValue` when the field repeats rather than silently
    /// choosing a value.
    pub fn getHeaderOne(
        self: *const Response,
        name: []const u8,
    ) error{DuplicateHeaderValue}!?[]const u8 {
        var found: ?[]const u8 = null;
        var it = self.getAllHeaders(name);
        while (it.next()) |value| {
            if (found != null) return error.DuplicateHeaderValue;
            found = value;
        }
        return found;
    }
};

/// Checks header syntax without storing a field. Useful when validating
/// immutable middleware configuration before the first request.
pub fn validateHeader(name: []const u8, value: []const u8) error{ InvalidHeaderName, InvalidHeaderValue }!void {
    if (!isToken(name)) return error.InvalidHeaderName;
    if (hasForbiddenValueByte(value)) return error.InvalidHeaderValue;
}

/// RFC 7230 field-name: one or more `tchar`s (no separators or control bytes).
fn isToken(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9' => {},
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
            else => return false,
        }
    }
    return true;
}

/// Rejects the bytes that would split a field value or inject framing:
/// CR, LF, and NUL.
fn hasForbiddenValueByte(value: []const u8) bool {
    for (value) |c| {
        if (c == '\r' or c == '\n' or c == 0) return true;
    }
    return false;
}

fn validateRedirectPath(path: []const u8) error{InvalidRedirectPath}!void {
    if (path.len == 0 or path[0] != '/' or (path.len > 1 and path[1] == '/')) return error.InvalidRedirectPath;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        const c = path[i];
        if (c <= ' ' or c >= 0x7f or c == '\\') return error.InvalidRedirectPath;
        if (c == '%') {
            if (path.len - i < 3) return error.InvalidRedirectPath;
            const hi = std.fmt.charToDigit(path[i + 1], 16) catch return error.InvalidRedirectPath;
            const lo = std.fmt.charToDigit(path[i + 2], 16) catch return error.InvalidRedirectPath;
            const decoded = hi * 16 + lo;
            if (decoded < ' ' or decoded >= 0x7f or decoded == '/' or decoded == '\\') return error.InvalidRedirectPath;
            i += 2;
        }
    }
}

test "redirect paths and explicit method semantics" {
    const testing = std.testing;
    const cases = .{
        .{ RedirectStatus.found, @as(u16, 302) },
        .{ RedirectStatus.see_other, @as(u16, 303) },
        .{ RedirectStatus.temporary_redirect, @as(u16, 307) },
        .{ RedirectStatus.permanent_redirect, @as(u16, 308) },
    };
    inline for (cases) |case| {
        var res = Response.init(testing.allocator);
        defer res.deinit();
        try res.text(200, "old body");
        try res.redirectPath(case[0], "/new?q=1#part");
        try testing.expectEqual(case[1], res.status_code);
        try testing.expect(res.handled);
        try testing.expectEqualStrings("", res.body);
        try testing.expectEqualStrings("", res.content_type);
        try testing.expectEqualStrings("/new?q=1#part", (try res.getHeaderOne("Location")).?);
    }
    var root = Response.init(testing.allocator);
    defer root.deinit();
    try root.redirectPath(.see_other, "/");
    try testing.expectEqualStrings("/", (try root.getHeaderOne("Location")).?);
    var encoded = Response.init(testing.allocator);
    defer encoded.deinit();
    try encoded.redirectPath(.found, "/hello%20world?next=%3F");
    try testing.expectEqualStrings("/hello%20world?next=%3F", (try encoded.getHeaderOne("Location")).?);
}

test "redirect rejects unsafe destinations and preserves response" {
    const testing = std.testing;
    var res = Response.init(testing.allocator);
    defer res.deinit();
    try res.text(201, "keep");
    const bad = [_][]const u8{
        "",            "relative",         "https://evil.test/", "//evil.test/", "/\\evil.test/",
        "/space here", "/\r\nX-Evil: yes", "/\x00",              "/\x7f",
        "/é",
        "/%",          "/%2",              "/%gg",               "/%2f/evil",    "/%5c/evil",
        "/%0d%0a",
    };
    for (bad) |path| {
        try testing.expectError(error.InvalidRedirectPath, res.redirectPath(.found, path));
        try testing.expectEqual(@as(u16, 201), res.status_code);
        try testing.expectEqualStrings("keep", res.body);
        try testing.expectEqual(@as(usize, 0), res.header_count);
    }
    try res.setHeader("location", "/existing");
    try testing.expectError(error.LocationAlreadySet, res.redirectPath(.found, "/new"));
    try testing.expectEqual(@as(u16, 201), res.status_code);
    try testing.expectEqual(@as(usize, 1), res.header_count);
}

test "redirect honors header limits before changing response" {
    const testing = std.testing;
    const limits = [_]struct { limits: Limits, expected: RedirectError }{
        .{ .limits = .{ .max_headers = 0 }, .expected = error.TooManyHeaders },
        .{ .limits = .{ .header_bytes = 8 }, .expected = error.HeaderBytesExceeded },
    };
    for (limits) |case| {
        var res = Response.initWithLimits(testing.allocator, case.limits);
        defer res.deinit();
        try res.text(200, "old");
        try testing.expectError(case.expected, res.redirectPath(.temporary_redirect, "/new"));
        try testing.expectEqual(@as(u16, 200), res.status_code);
        try testing.expectEqualStrings("old", res.body);
        try testing.expectEqual(@as(usize, 0), res.header_count);
    }
    var empty_body = Response.initWithLimits(testing.allocator, .{ .max_body_bytes = 0 });
    defer empty_body.deinit();
    try empty_body.redirectPath(.permanent_redirect, "/new");
    try testing.expectEqualStrings("", empty_body.body);
}

test "notModified drops body and content type and keeps headers" {
    const testing = std.testing;
    var res = Response.init(testing.allocator);
    defer res.deinit();
    try res.text(200, "body");
    try res.setHeader("ETag", "\"v1\"");
    try res.setHeader("Set-Cookie", "a=1");
    res.notModified();
    try testing.expectEqual(@as(u16, 304), res.status_code);
    try testing.expect(res.handled);
    try testing.expectEqualStrings("", res.body);
    try testing.expectEqualStrings("", res.content_type);
    try testing.expectEqual(@as(usize, 2), res.header_count);
    res.notModified();
}

test "fresh response is empty and unhandled" {
    var res = Response.init(std.testing.allocator);
    defer res.deinit();
    try std.testing.expect(!res.handled);
    try std.testing.expectEqual(@as(u16, 0), res.status_code);
    try std.testing.expectEqual(@as(usize, 0), res.body.len);
    try std.testing.expectEqual(@as(usize, 0), res.content_type.len);
    try std.testing.expectEqual(@as(usize, 0), res.header_count);
}

test "text copies body, sets metadata, and marks handled" {
    var res = Response.init(std.testing.allocator);
    defer res.deinit();
    try res.text(201, "created");
    try std.testing.expect(res.handled);
    try std.testing.expectEqual(@as(u16, 201), res.status_code);
    try std.testing.expectEqualStrings("created", res.body);
    try std.testing.expectEqualStrings("text/plain", res.content_type);
}

test "replacement helpers fully replace body, status, and content type" {
    var res = Response.init(std.testing.allocator);
    defer res.deinit();
    try res.text(200, "first");

    const User = struct { id: u32, name: []const u8 };
    try res.replaceJson(201, User, .{ .id = 42, .name = "ada" });
    try std.testing.expectEqual(@as(u16, 201), res.status_code);
    try std.testing.expectEqualStrings("{\"id\":42,\"name\":\"ada\"}", res.body);
    try std.testing.expectEqualStrings("application/json", res.content_type);
    try std.testing.expect(res.handled);

    try res.text(204, "");
    try std.testing.expectEqual(@as(u16, 204), res.status_code);
    try std.testing.expectEqualStrings("", res.body);
    try std.testing.expectEqualStrings("text/plain", res.content_type);
}

test "a failed replacement leaves the previous response intact" {
    var res = Response.initWithLimits(std.testing.allocator, .{ .max_body_bytes = 4 });
    defer res.deinit();
    try res.text(200, "ok");
    try std.testing.expectError(error.BodyTooLarge, res.text(500, "toolong"));
    try std.testing.expectEqual(@as(u16, 200), res.status_code);
    try std.testing.expectEqualStrings("ok", res.body);
    try std.testing.expect(res.handled);

    var fresh = Response.initWithLimits(std.testing.allocator, .{ .max_body_bytes = 4 });
    defer fresh.deinit();
    try std.testing.expectError(error.BodyTooLarge, fresh.text(200, "toolong"));
    try std.testing.expectError(
        error.BodyTooLarge,
        fresh.replaceJson(200, struct { s: []const u8 }, .{ .s = "way too long" }),
    );
    try std.testing.expect(!fresh.handled);
    try std.testing.expectEqual(@as(usize, 0), fresh.body.len);
}

test "setHeader copies input, keeps repeats, and looks up case-insensitively" {
    var res = Response.init(std.testing.allocator);
    defer res.deinit();

    const name = "Set-Cookie";
    const value = "sid=one";
    var name_buf: [name.len]u8 = name.*;
    var value_buf: [value.len]u8 = value.*;
    try res.setHeader(&name_buf, &value_buf);
    try res.setHeader("set-cookie", "sid=two");
    @memset(&name_buf, 'X');
    @memset(&value_buf, 'X');

    var it = res.getAllHeaders("SET-COOKIE");
    try std.testing.expectEqualStrings("sid=one", it.next().?);
    try std.testing.expectEqualStrings("sid=two", it.next().?);
    try std.testing.expect(it.next() == null);
    try std.testing.expectError(error.DuplicateHeaderValue, res.getHeaderOne("set-cookie"));

    try res.setHeader("X-Trace", "abc");
    try std.testing.expectEqualStrings("abc", (try res.getHeaderOne("x-trace")).?);
    try std.testing.expect((try res.getHeaderOne("missing")) == null);
}

test "setHeader rejects invalid names and unsafe values" {
    var res = Response.init(std.testing.allocator);
    defer res.deinit();
    try std.testing.expectError(error.InvalidHeaderName, res.setHeader("", "x"));
    try std.testing.expectError(error.InvalidHeaderName, res.setHeader("Bad Name", "x"));
    try std.testing.expectError(error.InvalidHeaderName, res.setHeader("Bad:Name", "x"));
    try std.testing.expectError(error.InvalidHeaderName, res.setHeader("Bad\nName", "x"));
    try std.testing.expectError(error.InvalidHeaderValue, res.setHeader("X-OK", "a\r\nInjected: 1"));
    try std.testing.expectError(error.InvalidHeaderValue, res.setHeader("X-OK", "a\nb"));
    try std.testing.expectError(error.InvalidHeaderValue, res.setHeader("X-OK", "a\x00b"));
    try std.testing.expectEqual(@as(usize, 0), res.header_count);

    try res.setHeader("X-OK", "");
    try std.testing.expectEqualStrings("", (try res.getHeaderOne("x-ok")).?);
}

test "header limits are enforced without partial inserts" {
    var count_limited = Response.initWithLimits(std.testing.allocator, .{ .max_headers = 1 });
    defer count_limited.deinit();
    try count_limited.setHeader("A", "1");
    try std.testing.expectError(error.TooManyHeaders, count_limited.setHeader("B", "2"));
    try std.testing.expectEqual(@as(usize, 1), count_limited.header_count);
    try std.testing.expect((try count_limited.getHeaderOne("B")) == null);

    var bytes_limited = Response.initWithLimits(std.testing.allocator, .{ .header_bytes = 6 });
    defer bytes_limited.deinit();
    try bytes_limited.setHeader("AA", "1");
    try bytes_limited.setHeader("BB", "2");
    try std.testing.expectError(error.HeaderBytesExceeded, bytes_limited.setHeader("C", "3"));
    try std.testing.expectEqual(@as(usize, 2), bytes_limited.header_count);
}

test "setHeaderFmt formats and stores a copied value" {
    var res = Response.init(std.testing.allocator);
    defer res.deinit();
    try res.setHeaderFmt("X-Response-Time-Ms", "{d}", .{17});
    try std.testing.expectEqualStrings("17", (try res.getHeaderOne("x-response-time-ms")).?);
}

test "clear releases storage and resets state for error recovery" {
    var res = Response.init(std.testing.allocator);
    defer res.deinit();
    try res.text(200, "hello");
    try res.setHeader("X-A", "1");
    try res.setHeader("Set-Cookie", "a=1");
    res.clear();
    try std.testing.expect(!res.handled);
    try std.testing.expectEqual(@as(u16, 0), res.status_code);
    try std.testing.expectEqual(@as(usize, 0), res.body.len);
    try std.testing.expectEqual(@as(usize, 0), res.content_type.len);
    try std.testing.expectEqual(@as(usize, 0), res.header_count);
    try std.testing.expect((try res.getHeaderOne("X-A")) == null);

    try res.text(500, "oops");
    try std.testing.expectEqualStrings("oops", res.body);
    res.clear();
    res.clear();
}

test "response storage is independent of the request arena" {
    const request = @import("request.zig");
    var req = try request.parseOriginForm(std.testing.allocator, .default, "/greet/ada?tag=one");

    var res = Response.init(std.testing.allocator);
    defer res.deinit();
    try res.text(200, req.segments[1]);
    try res.setHeader("X-Path", req.target);

    req.deinit();

    try std.testing.expectEqualStrings("ada", res.body);
    try std.testing.expectEqualStrings("/greet/ada?tag=one", (try res.getHeaderOne("x-path")).?);
}

test "response helpers propagate allocation failures without leaking" {
    const build = struct {
        fn build(allocator: std.mem.Allocator) !void {
            var res = Response.init(allocator);
            defer res.deinit();
            try res.text(200, "hello");
            try res.setHeader("X-A", "1");
            try res.setHeader("Set-Cookie", "a=1");
            try res.setHeader("Set-Cookie", "b=2");
            try res.setHeaderFmt("X-Response-Time-Ms", "{d}", .{7});
            try res.replaceJson(200, struct { ok: bool }, .{ .ok = true });
            res.clear();
            try res.text(404, "nope");
        }
    }.build;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, build, .{});
}

test "body limit accepts at-limit length and rejects one byte over" {
    var res = Response.initWithLimits(std.testing.allocator, .{ .max_body_bytes = 5 });
    defer res.deinit();
    try res.text(200, "12345");
    try std.testing.expectEqualStrings("12345", res.body);
    try std.testing.expectError(error.BodyTooLarge, res.text(200, "123456"));
    try std.testing.expectEqualStrings("12345", res.body);
}

test "replaceOwnedBody takes ownership only on success" {
    var res = Response.initWithLimits(std.testing.allocator, .{ .max_body_bytes = 5 });
    defer res.deinit();
    try res.text(200, "first");

    const too_large = try std.testing.allocator.dupe(u8, "123456");
    defer std.testing.allocator.free(too_large);
    try std.testing.expectError(error.BodyTooLarge, res.replaceOwnedBody(200, "text/css", too_large));
    const bad_type = try std.testing.allocator.dupe(u8, "body");
    defer std.testing.allocator.free(bad_type);
    try std.testing.expectError(error.InvalidContentType, res.replaceOwnedBody(200, "text/css\r\nX: y", bad_type));
    try std.testing.expectEqualStrings("first", res.body);
    try std.testing.expectEqualStrings(text_content_type, res.content_type);

    const owned = try std.testing.allocator.dupe(u8, "a{}");
    try res.replaceOwnedBody(201, "text/css", owned);
    try std.testing.expectEqual(owned.ptr, res.body.ptr);
    try std.testing.expectEqual(@as(u16, 201), res.status_code);
    try std.testing.expectEqualStrings("text/css", res.content_type);
    try std.testing.expect(res.handled);
}

test "allocation failure during response replacement leaves prior response intact" {
    const build = struct {
        fn build(allocator: std.mem.Allocator) !void {
            var res = Response.init(allocator);
            defer res.deinit();
            try res.text(200, "first");
            const User = struct { id: u32, name: []const u8 };
            res.replaceJson(201, User, .{ .id = 42, .name = "replacement" }) catch |err| {
                try std.testing.expectEqualStrings("first", res.body);
                try std.testing.expectEqual(@as(u16, 200), res.status_code);
                return err;
            };
            try std.testing.expectEqualStrings("{\"id\":42,\"name\":\"replacement\"}", res.body);
            try std.testing.expectEqual(@as(u16, 201), res.status_code);
        }
    }.build;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, build, .{});
}

test "response with repeated Set-Cookie fields remains valid after request destruction" {
    const request = @import("request.zig");
    var req = try request.parseOriginForm(std.testing.allocator, .default, "/users/42?tag=one");

    var res = Response.init(std.testing.allocator);
    defer res.deinit();
    try res.text(200, req.segments[1]);
    try res.setHeader("Set-Cookie", "sid=a");
    try res.setHeader("Set-Cookie", "csrf=b");
    try res.setHeader("X-Path", req.target);

    req.deinit();

    try std.testing.expectEqualStrings("42", res.body);
    var it = res.getAllHeaders("set-cookie");
    try std.testing.expectEqualStrings("sid=a", it.next().?);
    try std.testing.expectEqualStrings("csrf=b", it.next().?);
    try std.testing.expect(it.next() == null);
    try std.testing.expectEqualStrings("/users/42?tag=one", (try res.getHeaderOne("x-path")).?);
}
