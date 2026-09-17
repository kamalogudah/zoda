//! Bounded buffering and protocol error mappings (ADR-0001 §3.4).
//!
//! This module defines the HTTP status code mappings the transport uses when
//! request construction fails, and a bounded byte accumulator that lets the
//! transport enforce limits while reading — including decoded chunked body
//! chunks — before the request arena owns the bytes.
//!
//! Status mapping contract:
//!
//! - 400 Bad Request: invalid syntax, malformed percent encoding, forbidden
//!   path characters, dot segments, and segment/query-count violations.
//! - 414 URI Too Long: raw target exceeds `Limits.target_bytes`.
//! - 431 Request Header Fields Too Large: header count or byte limit exceeded.
//! - 413 Content Too Large: body exceeds `Limits.max_body_bytes`.
//! - 500 Internal Server Error: allocation failures while building a response
//!   or a generic error response.
//!
//! Connection policy: the transport should close the connection after sending
//! one of the above status responses unless it can safely establish the start
//! of the next request (e.g. it has not yet read any body bytes for a keep-alive
//! HTTP/1.1 connection). This module documents the mapping; the wire adapter
//! owns the close decision.
//!
//! The default limits are owned by `request.Limits` and `response.Limits` so
//! they live next to the code that enforces them. This module re-exports those
//! defaults for transport configuration.
const std = @import("std");
const request = @import("request.zig");
const response = @import("response.zig");

/// HTTP status codes used for protocol-level rejections.
pub const ProtocolStatus = struct {
    pub const bad_request: u16 = 400;
    pub const uri_too_long: u16 = 414;
    pub const headers_too_large: u16 = 431;
    pub const content_too_large: u16 = 413;
    pub const internal_server_error: u16 = 500;
};

/// Default request buffering limits (§3.4: 8 KiB target, 100 headers / 32 KiB
/// header bytes, 128 path segments, 256 query pairs, 1 MiB body).
pub const default_request_limits: request.Limits = .{};

/// Default response buffering limits (§3.4: 100 headers / 32 KiB header bytes,
/// 1 MiB body).
pub const default_response_limits: response.Limits = .{};

/// Maps a request target/path/query parsing error to the status the transport
/// should send before closing the connection (unless the next boundary is
/// safely established).
pub fn parseErrorStatus(err: request.ParseError) u16 {
    return switch (err) {
        error.InvalidTarget,
        error.MalformedPercentEncoding,
        error.ForbiddenPathCharacter,
        error.DotSegment,
        error.TooManyPathSegments,
        error.TooManyQueryPairs,
        => ProtocolStatus.bad_request,
        error.TargetTooLong => ProtocolStatus.uri_too_long,
        error.OutOfMemory => ProtocolStatus.internal_server_error,
    };
}

/// Maps a request header-storage error to the status the transport should send.
pub fn requestHeaderStatus(err: request.HeaderStoreError) u16 {
    return switch (err) {
        error.TooManyHeaders,
        error.HeaderBytesExceeded,
        => ProtocolStatus.headers_too_large,
        error.OutOfMemory => ProtocolStatus.internal_server_error,
    };
}

/// Maps a request body-storage error to the status the transport should send.
pub fn requestBodyStatus(err: request.BodyStoreError) u16 {
    return switch (err) {
        error.BodyTooLarge => ProtocolStatus.content_too_large,
        error.OutOfMemory => ProtocolStatus.internal_server_error,
    };
}

/// Maps a response header error to the status used when the transport falls
/// back to a generic response. A handler-produced invalid or oversized header
/// is treated as an internal error because it is a server-side failure.
pub fn responseHeaderStatus(err: response.HeaderError) u16 {
    return switch (err) {
        error.InvalidHeaderName,
        error.InvalidHeaderValue,
        error.TooManyHeaders,
        error.HeaderBytesExceeded,
        error.OutOfMemory,
        => ProtocolStatus.internal_server_error,
    };
}

/// Maps a response body error to the status used when the transport falls back
/// to a generic response.
pub fn responseBodyStatus(err: response.BodyError) u16 {
    return switch (err) {
        error.BodyTooLarge,
        error.OutOfMemory,
        => ProtocolStatus.internal_server_error,
    };
}

/// Errors from bounded incremental accumulation.
pub const AccumulateError = error{
    OutOfMemory,
    BodyTooLarge,
};

/// Accumulates bytes incrementally up to a configured limit. The transport can
/// use this while reading a request body, including after decoding each chunked
/// transfer chunk, before handing an owned slice to `RequestArena.copyBody`.
///
/// The accumulator itself does not parse chunked framing; callers decode each
/// chunk and append the decoded bytes. This keeps the bound on decoded body
/// bytes independent of framing details and prevents unbounded intermediate
/// allocations.
pub const BoundedAccumulator = struct {
    allocator: std.mem.Allocator,
    max_bytes: usize,
    buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, max_bytes: usize) BoundedAccumulator {
        return .{
            .allocator = allocator,
            .max_bytes = max_bytes,
            .buffer = .empty,
        };
    }

    pub fn deinit(self: *BoundedAccumulator) void {
        self.buffer.deinit(self.allocator);
    }

    /// Number of bytes currently accumulated.
    pub fn len(self: *const BoundedAccumulator) usize {
        return self.buffer.items.len;
    }

    /// Appends `chunk` to the accumulator. Returns `error.BodyTooLarge` without
    /// altering state if the new total would exceed `max_bytes`.
    pub fn append(self: *BoundedAccumulator, chunk: []const u8) AccumulateError!void {
        const new_len = std.math.add(usize, self.buffer.items.len, chunk.len) catch return error.BodyTooLarge;
        if (new_len > self.max_bytes) return error.BodyTooLarge;
        try self.buffer.appendSlice(self.allocator, chunk);
    }

    /// Finalizes the accumulator into an owned slice. The caller owns the
    /// returned memory and must free it with the same allocator passed to
    /// `init`.
    pub fn toOwnedSlice(self: *BoundedAccumulator) ![]u8 {
        return try self.buffer.toOwnedSlice(self.allocator);
    }
};

test "default limits match ADR-0001 §3.4" {
    try std.testing.expectEqual(@as(usize, 8 * 1024), default_request_limits.target_bytes);
    try std.testing.expectEqual(@as(usize, 100), default_request_limits.max_headers);
    try std.testing.expectEqual(@as(usize, 32 * 1024), default_request_limits.header_bytes);
    try std.testing.expectEqual(@as(usize, 128), default_request_limits.max_path_segments);
    try std.testing.expectEqual(@as(usize, 256), default_request_limits.max_query_pairs);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), default_request_limits.max_body_bytes);

    try std.testing.expectEqual(@as(usize, 100), default_response_limits.max_headers);
    try std.testing.expectEqual(@as(usize, 32 * 1024), default_response_limits.header_bytes);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), default_response_limits.max_body_bytes);
}

test "parse errors map to expected protocol statuses" {
    try std.testing.expectEqual(@as(u16, 400), parseErrorStatus(error.InvalidTarget));
    try std.testing.expectEqual(@as(u16, 400), parseErrorStatus(error.MalformedPercentEncoding));
    try std.testing.expectEqual(@as(u16, 400), parseErrorStatus(error.ForbiddenPathCharacter));
    try std.testing.expectEqual(@as(u16, 400), parseErrorStatus(error.DotSegment));
    try std.testing.expectEqual(@as(u16, 400), parseErrorStatus(error.TooManyPathSegments));
    try std.testing.expectEqual(@as(u16, 400), parseErrorStatus(error.TooManyQueryPairs));
    try std.testing.expectEqual(@as(u16, 414), parseErrorStatus(error.TargetTooLong));
    try std.testing.expectEqual(@as(u16, 500), parseErrorStatus(error.OutOfMemory));
}

test "request header and body errors map to expected statuses" {
    try std.testing.expectEqual(@as(u16, 431), requestHeaderStatus(error.TooManyHeaders));
    try std.testing.expectEqual(@as(u16, 431), requestHeaderStatus(error.HeaderBytesExceeded));
    try std.testing.expectEqual(@as(u16, 500), requestHeaderStatus(error.OutOfMemory));

    try std.testing.expectEqual(@as(u16, 413), requestBodyStatus(error.BodyTooLarge));
    try std.testing.expectEqual(@as(u16, 500), requestBodyStatus(error.OutOfMemory));
}

test "response errors map to internal server error" {
    try std.testing.expectEqual(@as(u16, 500), responseHeaderStatus(error.InvalidHeaderName));
    try std.testing.expectEqual(@as(u16, 500), responseHeaderStatus(error.InvalidHeaderValue));
    try std.testing.expectEqual(@as(u16, 500), responseHeaderStatus(error.TooManyHeaders));
    try std.testing.expectEqual(@as(u16, 500), responseHeaderStatus(error.HeaderBytesExceeded));
    try std.testing.expectEqual(@as(u16, 500), responseHeaderStatus(error.OutOfMemory));

    try std.testing.expectEqual(@as(u16, 500), responseBodyStatus(error.BodyTooLarge));
    try std.testing.expectEqual(@as(u16, 500), responseBodyStatus(error.OutOfMemory));
}

test "bounded accumulator accepts chunks up to the limit" {
    var acc = BoundedAccumulator.init(std.testing.allocator, 10);
    defer acc.deinit();

    try acc.append("hello");
    try std.testing.expectEqual(@as(usize, 5), acc.len());
    try acc.append("world");
    try std.testing.expectEqual(@as(usize, 10), acc.len());

    const owned = try acc.toOwnedSlice();
    defer std.testing.allocator.free(owned);
    try std.testing.expectEqualStrings("helloworld", owned);
}

test "bounded accumulator rejects chunks that would exceed the limit" {
    var acc = BoundedAccumulator.init(std.testing.allocator, 4);
    defer acc.deinit();

    try acc.append("hi");
    try std.testing.expectError(error.BodyTooLarge, acc.append("world"));
    try std.testing.expectEqual(@as(usize, 2), acc.len());

    // A second small append should still succeed.
    try acc.append("ya");
    try std.testing.expectEqual(@as(usize, 4), acc.len());
}

test "bounded accumulator simulates decoded chunked body reads" {
    // Transport decodes each chunk and appends decoded bytes; the accumulator
    // enforces the bound on the decoded body, not on framing bytes.
    var acc = BoundedAccumulator.init(std.testing.allocator, 8);
    defer acc.deinit();

    const decoded_chunks = [_][]const u8{ "abc", "def", "gh" };
    for (decoded_chunks) |chunk| try acc.append(chunk);

    const owned = try acc.toOwnedSlice();
    defer std.testing.allocator.free(owned);
    try std.testing.expectEqualStrings("abcdefgh", owned);
}

test "bounded accumulator reports allocation failures without leaking" {
    const build = struct {
        fn build(allocator: std.mem.Allocator) !void {
            var acc = BoundedAccumulator.init(allocator, 8);
            defer acc.deinit();
            try acc.append("abc");
            try acc.append("def");
            const owned = try acc.toOwnedSlice();
            defer allocator.free(owned);
        }
    }.build;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, build, .{});
}
