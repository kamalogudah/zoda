//! Bounded HTTP/1.x wire adapter (ADR-0001 §3.4, Phase 2).
//!
//! The adapter deliberately leaves connection acceptance and concurrency to
//! its caller. It owns HTTP framing for one connection: every
//! request is copied into a fresh `RequestArena`, dispatched only after the
//! complete body has been decoded, and released after its buffered response is
//! sent. Protocol rejections and application failures close the connection.
//! HTTP/2 is unsupported: the pinned `std.http` parses only HTTP/1.0 and
//! HTTP/1.1, and h2c upgrades are ignored (ADR-0001 §4.2.6).
//!
//! Zig 0.16.0 APIs used here are `std.http.Server.init/receiveHead`,
//! `Request.iterateHeaders`, `std.http.Reader.bodyReader`, and
//! `Request.respond`. `bodyReader` reads Content-Length bodies. Chunked bodies
//! are decoded here instead: the pinned `std.http.ChunkParser` accepts non-hex
//! size digits (`g`-`z`), empty or signed sizes, bare LF, and unvalidated
//! extensions, each a request-smuggling ambiguity (Phase 2b, issue #16).
//! `respond` supplies exactly one Content-Length and
//! suppresses HEAD bodies; this adapter additionally suppresses bodies for
//! bodyless status codes and removes application framing headers.
const std = @import("std");
const buffering = @import("buffering.zig");
const request = @import("request.zig");
const response = @import("response.zig");
const router = @import("router.zig");

pub const Config = struct {
    request_limits: request.Limits = .default,
    /// Sequential requests accepted before the adapter closes the connection.
    max_requests: usize = 100,
    /// Optional operation-boundary hooks used by the socket runtime.
    deadlines: ?Deadlines = null,
};

/// Hooks mark total header, body-read, and response-write operations. A hook
/// must set one absolute deadline; it must not refresh it for each byte.
pub const Deadlines = struct {
    context: *anyopaque,
    begin_header: *const fn (context: *anyopaque, keep_alive: bool, buffered: bool) void,
    begin_body: *const fn (context: *anyopaque) void,
    begin_write: *const fn (context: *anyopaque) void,

    fn header(self: Deadlines, keep_alive: bool, buffered: bool) void {
        self.begin_header(self.context, keep_alive, buffered);
    }

    fn body(self: Deadlines) void {
        self.begin_body(self.context);
    }

    fn write(self: Deadlines) void {
        self.begin_write(self.context);
    }
};

/// Upper bound needed for a syntactically valid request head at the configured
/// target/header limits. The caller's `std.Io.Reader` buffer can be larger or
/// smaller; the adapter clamps `std.http.Reader.max_head_len` to this value.
pub fn maxWireHeadBytes(limits: request.Limits) usize {
    const framing = std.math.mul(usize, limits.max_headers, 4) catch return std.math.maxInt(usize);
    const fields = std.math.add(usize, limits.target_bytes, limits.header_bytes) catch return std.math.maxInt(usize);
    const overhead = std.math.add(usize, framing, 32) catch return std.math.maxInt(usize);
    return std.math.add(usize, fields, overhead) catch std.math.maxInt(usize);
}

/// Processes one HTTP connection. `AppType` must provide
/// `dispatch(*router.Request) !response.Response`.
pub fn serveConnection(
    comptime AppType: type,
    allocator: std.mem.Allocator,
    server: *std.http.Server,
    app: *const AppType,
    config: Config,
) anyerror!void {
    if (config.max_requests == 0) return;
    server.reader.max_head_len = @min(server.reader.max_head_len, maxWireHeadBytes(config.request_limits));

    var request_index: usize = 0;
    while (request_index < config.max_requests) : (request_index += 1) {
        if (config.deadlines) |deadlines| {
            deadlines.header(request_index != 0, server.reader.in.bufferedLen() != 0);
        }
        var wire_req = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            error.HttpHeadersOversize => {
                if (config.deadlines) |deadlines| deadlines.write();
                try writeRawError(server.out, .request_header_fields_too_large);
                return;
            },
            error.HttpHeadersInvalid,
            error.HttpRequestTruncated,
            => {
                if (config.deadlines) |deadlines| deadlines.write();
                try writeRawError(server.out, .bad_request);
                return;
            },
            error.ReadFailed => return error.ReadFailed,
        };

        const keep_alive = wire_req.head.keep_alive and request_index + 1 < config.max_requests;
        const outcome = try processRequest(AppType, allocator, &wire_req, app, config.request_limits, keep_alive, config.deadlines);
        if (outcome == .close) return;
    }
}

const Outcome = enum { keep_alive, close };

fn processRequest(
    comptime AppType: type,
    allocator: std.mem.Allocator,
    wire_req: *std.http.Server.Request,
    app: *const AppType,
    limits: request.Limits,
    keep_alive: bool,
    deadlines: ?Deadlines,
) anyerror!Outcome {
    const version = wire_req.head.version;
    const wire_method = wire_req.head.method;
    const transfer_encoding = wire_req.head.transfer_encoding;
    const content_length = wire_req.head.content_length;

    if (content_length != null and transfer_encoding != .none) {
        try reject(wire_req, .bad_request, version, deadlines);
        return .close;
    }
    if (wire_req.head.transfer_compression != .identity or wire_req.head.expect != null) {
        try reject(wire_req, .bad_request, version, deadlines);
        return .close;
    }
    if (content_length) |len| {
        if (len > limits.max_body_bytes) {
            try reject(wire_req, .payload_too_large, version, deadlines);
            return .close;
        }
    }

    var arena = request.parseOriginForm(allocator, limits, wire_req.head.target) catch |err| {
        try reject(wire_req, statusFromCode(buffering.parseErrorStatus(err)), version, deadlines);
        return .close;
    };
    defer arena.deinit();

    var headers: std.ArrayList(request.Header) = .empty;
    var header_bytes: usize = 0;
    var saw_content_length = false;
    var saw_transfer_encoding = false;
    var header_it = wire_req.iterateHeaders();
    while (header_it.next()) |header| {
        // The pinned head parser treats a line without ':' as a name with an
        // empty value. The name is a slice of the head buffer, and every field
        // line ends in CRLF, so the byte after the name is always readable.
        if (!validHeader(header.name, header.value) or header.name.ptr[header.name.len] != ':') {
            try reject(wire_req, .bad_request, version, deadlines);
            return .close;
        }
        // `std.fmt.parseInt` accepts a sign; RFC 9110 requires `1*DIGIT`.
        if (std.ascii.eqlIgnoreCase(header.name, "content-length") and !allDigits(header.value)) {
            try reject(wire_req, .bad_request, version, deadlines);
            return .close;
        }
        if (headers.items.len >= limits.max_headers) {
            try reject(wire_req, .request_header_fields_too_large, version, deadlines);
            return .close;
        }
        const field_bytes = std.math.add(usize, header.name.len, header.value.len) catch {
            try reject(wire_req, .request_header_fields_too_large, version, deadlines);
            return .close;
        };
        header_bytes = std.math.add(usize, header_bytes, field_bytes) catch {
            try reject(wire_req, .request_header_fields_too_large, version, deadlines);
            return .close;
        };
        if (header_bytes > limits.header_bytes) {
            try reject(wire_req, .request_header_fields_too_large, version, deadlines);
            return .close;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "content-length")) saw_content_length = true;
        if (std.ascii.eqlIgnoreCase(header.name, "transfer-encoding")) saw_transfer_encoding = true;
        const name = arena.allocator().dupe(u8, header.name) catch {
            try reject(wire_req, .internal_server_error, version, deadlines);
            return .close;
        };
        const value = arena.allocator().dupe(u8, header.value) catch {
            try reject(wire_req, .internal_server_error, version, deadlines);
            return .close;
        };
        headers.append(arena.allocator(), .{ .name = name, .value = value }) catch {
            try reject(wire_req, .internal_server_error, version, deadlines);
            return .close;
        };
    }
    // RFC 9112 §6.1: Transfer-Encoding in an HTTP/1.0 request is faulty framing.
    if (saw_transfer_encoding and (transfer_encoding != .chunked or saw_content_length or version == .@"HTTP/1.0")) {
        try reject(wire_req, .bad_request, version, deadlines);
        return .close;
    }
    if (transfer_encoding != .none or content_length != null) {
        if (deadlines) |operation_deadlines| operation_deadlines.body();
        var body = buffering.BoundedAccumulator.init(arena.allocator(), limits.max_body_bytes);
        defer body.deinit();
        var trailer_section: std.ArrayList(u8) = .empty;

        if (transfer_encoding == .chunked) {
            readChunked(wire_req.server.reader.in, &body, &trailer_section, arena.allocator(), limits.header_bytes) catch |err| {
                try reject(wire_req, switch (err) {
                    error.BodyTooLarge => .payload_too_large,
                    error.TrailersTooLarge => .request_header_fields_too_large,
                    error.OutOfMemory => .internal_server_error,
                    error.Malformed, error.ReadFailed => .bad_request,
                }, version, deadlines);
                return .close;
            };
            wire_req.server.reader.state = .ready;
        } else {
            var transfer_buffer: [8192]u8 = undefined;
            var chunk: [8192]u8 = undefined;
            const body_reader = wire_req.server.reader.bodyReader(
                &transfer_buffer,
                transfer_encoding,
                content_length,
            );
            while (true) {
                const n = body_reader.readSliceShort(&chunk) catch {
                    try reject(wire_req, .bad_request, version, deadlines);
                    return .close;
                };
                if (n == 0) break;
                body.append(chunk[0..n]) catch |err| switch (err) {
                    error.BodyTooLarge => {
                        try reject(wire_req, .payload_too_large, version, deadlines);
                        return .close;
                    },
                    error.OutOfMemory => {
                        try reject(wire_req, .internal_server_error, version, deadlines);
                        return .close;
                    },
                };
            }
        }
        arena.body = body.toOwnedSlice() catch {
            try reject(wire_req, .internal_server_error, version, deadlines);
            return .close;
        };

        // Chunk trailers share the request header limits and are exposed to
        // dispatch as additional ordered header fields.
        var trailers: []const u8 = trailer_section.items;
        while (trailers.len != 0) {
            const end = std.mem.indexOf(u8, trailers, "\r\n") orelse {
                try reject(wire_req, .bad_request, version, deadlines);
                return .close;
            };
            const line = trailers[0..end];
            trailers = trailers[end + 2 ..];
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
                try reject(wire_req, .bad_request, version, deadlines);
                return .close;
            };
            const header: std.http.Header = .{
                .name = line[0..colon],
                .value = std.mem.trim(u8, line[colon + 1 ..], " \t"),
            };
            if (!validHeader(header.name, header.value) or
                std.ascii.eqlIgnoreCase(header.name, "content-length") or
                std.ascii.eqlIgnoreCase(header.name, "transfer-encoding"))
            {
                try reject(wire_req, .bad_request, version, deadlines);
                return .close;
            }
            if (headers.items.len >= limits.max_headers) {
                try reject(wire_req, .request_header_fields_too_large, version, deadlines);
                return .close;
            }
            const field_bytes = std.math.add(usize, header.name.len, header.value.len) catch {
                try reject(wire_req, .request_header_fields_too_large, version, deadlines);
                return .close;
            };
            header_bytes = std.math.add(usize, header_bytes, field_bytes) catch {
                try reject(wire_req, .request_header_fields_too_large, version, deadlines);
                return .close;
            };
            if (header_bytes > limits.header_bytes) {
                try reject(wire_req, .request_header_fields_too_large, version, deadlines);
                return .close;
            }
            const name = arena.allocator().dupe(u8, header.name) catch {
                try reject(wire_req, .internal_server_error, version, deadlines);
                return .close;
            };
            const value = arena.allocator().dupe(u8, header.value) catch {
                try reject(wire_req, .internal_server_error, version, deadlines);
                return .close;
            };
            headers.append(arena.allocator(), .{ .name = name, .value = value }) catch {
                try reject(wire_req, .internal_server_error, version, deadlines);
                return .close;
            };
        }
    } else {
        // `std.http.Server.Request.readerExpectNone` treats several methods as
        // intrinsically bodyless. We use explicit framing instead and advance
        // the server state ourselves when no body framing exists.
        wire_req.server.reader.state = .ready;
    }

    arena.headers = headers.toOwnedSlice(arena.allocator()) catch {
        try reject(wire_req, .internal_server_error, version, deadlines);
        return .close;
    };

    var req = arena.requestView(methodFromStd(wire_method));
    var res = app.dispatch(&req) catch {
        try reject(wire_req, .internal_server_error, version, deadlines);
        return .close;
    };
    defer res.deinit();

    if (!validStatus(res.status_code)) {
        try reject(wire_req, .internal_server_error, version, deadlines);
        return .close;
    }

    var extra: std.ArrayList(std.http.Header) = .empty;
    defer extra.deinit(allocator);
    var has_content_type = false;
    for (res.headers[0..res.header_count]) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "content-length") or
            std.ascii.eqlIgnoreCase(header.name, "transfer-encoding")) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "content-type")) has_content_type = true;
        extra.append(allocator, .{ .name = header.name, .value = header.value }) catch {
            try reject(wire_req, .internal_server_error, version, deadlines);
            return .close;
        };
    }
    if (!has_content_type and res.content_type.len != 0) {
        extra.append(allocator, .{ .name = "content-type", .value = res.content_type }) catch {
            try reject(wire_req, .internal_server_error, version, deadlines);
            return .close;
        };
    }

    const status: std.http.Status = @enumFromInt(res.status_code);
    const content = if (statusAllowsBody(res.status_code)) res.body else "";
    if (deadlines) |operation_deadlines| operation_deadlines.write();
    try wire_req.respond(content, .{
        .version = version,
        .status = status,
        .keep_alive = keep_alive,
        .extra_headers = extra.items,
    });
    return if (keep_alive) .keep_alive else .close;
}

const ChunkedError = error{ Malformed, BodyTooLarge, TrailersTooLarge, OutOfMemory, ReadFailed };

/// Longest accepted chunk-size line, extensions included.
const max_chunk_line = 1024;

/// Strict RFC 9112 §7.1 chunked decoder. Sizes are `1*HEXDIG` without
/// overflow, lines end in CRLF, extensions start with `;` and contain no
/// control bytes, and a declared size larger than the remaining body budget is
/// refused before its data is read. The raw trailer section (field lines with
/// CRLF, final empty line excluded) is copied into `trailers`, bounded by
/// `trailer_limit` bytes.
fn readChunked(
    in: *std.Io.Reader,
    body: *buffering.BoundedAccumulator,
    trailers: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    trailer_limit: usize,
) ChunkedError!void {
    while (true) {
        const size = try parseChunkSize(try takeCrlfLine(in));
        if (size == 0) break;
        if (size > body.max_bytes - body.len()) return error.BodyTooLarge;
        var remaining: usize = @intCast(size);
        while (remaining != 0) {
            const available = in.peekGreedy(1) catch |err| return mapReadError(err);
            const n = @min(available.len, remaining);
            body.append(available[0..n]) catch |err| return err;
            in.toss(n);
            remaining -= n;
        }
        const crlf = in.takeArray(2) catch |err| return mapReadError(err);
        if (!std.mem.eql(u8, crlf, "\r\n")) return error.Malformed;
    }
    while (true) {
        const line = try takeCrlfLine(in);
        if (line.len == 0) return;
        if (trailers.items.len + line.len + 2 > trailer_limit) return error.TrailersTooLarge;
        try trailers.appendSlice(allocator, line);
        try trailers.appendSlice(allocator, "\r\n");
    }
}

fn takeCrlfLine(in: *std.Io.Reader) ChunkedError![]const u8 {
    const line = in.takeDelimiterInclusive('\n') catch |err| return switch (err) {
        error.ReadFailed => error.ReadFailed,
        error.EndOfStream, error.StreamTooLong => error.Malformed,
    };
    if (line.len < 2 or line.len > max_chunk_line or line[line.len - 2] != '\r') return error.Malformed;
    return line[0 .. line.len - 2];
}

fn mapReadError(err: std.Io.Reader.Error) ChunkedError {
    return switch (err) {
        error.ReadFailed => error.ReadFailed,
        error.EndOfStream => error.Malformed,
    };
}

fn parseChunkSize(line: []const u8) error{Malformed}!u64 {
    var size: u64 = 0;
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        const digit = std.fmt.charToDigit(line[index], 16) catch break;
        size = std.math.mul(u64, size, 16) catch return error.Malformed;
        size = std.math.add(u64, size, digit) catch return error.Malformed;
    }
    if (index == 0) return error.Malformed;
    const extensions = std.mem.trimStart(u8, line[index..], " \t");
    if (extensions.len != 0 and extensions[0] != ';') return error.Malformed;
    for (extensions) |c| if ((c < 0x20 and c != '\t') or c == 0x7f) return error.Malformed;
    return size;
}

fn allDigits(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn validStatus(code: u16) bool {
    return code >= 100 and code <= 599 and code != 100;
}

fn statusAllowsBody(code: u16) bool {
    return !(code >= 100 and code < 200) and code != 204 and code != 205 and code != 304;
}

fn statusFromCode(code: u16) std.http.Status {
    return @enumFromInt(code);
}

fn methodFromStd(method: std.http.Method) router.Method {
    return switch (method) {
        .GET => .get,
        .POST => .post,
        .PUT => .put,
        .DELETE => .delete,
        .PATCH => .patch,
        .HEAD => .head,
        .OPTIONS => .options,
        .TRACE => .trace,
        .CONNECT => .connect,
    };
}

fn validHeader(name: []const u8, value: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| switch (c) {
        'a'...'z',
        'A'...'Z',
        '0'...'9',
        '!',
        '#',
        '$',
        '%',
        '&',
        '\'',
        '*',
        '+',
        '-',
        '.',
        '^',
        '_',
        '`',
        '|',
        '~',
        => {},
        else => return false,
    };
    for (value) |c| if (c == 0 or c == '\r' or c == '\n' or (c < 0x20 and c != '\t') or c == 0x7f) return false;
    return true;
}

fn reject(req: *std.http.Server.Request, status: std.http.Status, version: std.http.Version, deadlines: ?Deadlines) !void {
    // `respond` would otherwise emit an interim `100 Continue` first, inviting
    // the body of a request that is being refused.
    req.head.expect = null;
    if (deadlines) |operation_deadlines| operation_deadlines.write();
    try req.respond(status.phrase() orelse "Error", .{
        .version = version,
        .status = status,
        .keep_alive = false,
    });
}

fn writeRawError(out: *std.Io.Writer, status: std.http.Status) !void {
    const phrase = status.phrase() orelse "Error";
    try out.print(
        "HTTP/1.1 {d} {s}\r\nconnection: close\r\ncontent-length: {d}\r\ncontent-type: text/plain\r\n\r\n{s}",
        .{ @intFromEnum(status), phrase, phrase.len, phrase },
    );
    try out.flush();
}

const TestApp = struct {
    allocator: std.mem.Allocator,
    calls: *usize,
    fail: bool = false,
    bodyless: bool = false,

    fn dispatch(self: *const TestApp, req: *router.Request) !response.Response {
        self.calls.* += 1;
        if (self.fail) return error.DispatchFailed;
        var res = response.Response.init(self.allocator);
        errdefer res.deinit();
        if (self.bodyless) {
            try res.text(204, "must not be sent");
            try res.setHeader("Content-Length", "999");
            try res.setHeader("Transfer-Encoding", "chunked");
        } else {
            try res.text(200, req.body);
            try res.setHeader("x-target", req.target);
        }
        return res;
    }
};

fn runTest(input: []const u8, app: *const TestApp, config: Config) ![]u8 {
    var in = std.Io.Reader.fixed(input);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer out.deinit();
    var server = std.http.Server.init(&in, &out.writer);
    try serveConnection(TestApp, std.testing.allocator, &server, app, config);
    return out.toOwnedSlice();
}

test "chunked body is decoded within the limit and sequential requests are isolated" {
    var calls: usize = 0;
    const app: TestApp = .{ .allocator = std.testing.allocator, .calls = &calls };
    const output = try runTest(
        "POST /one HTTP/1.1\r\nHost: example\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n" ++
            "POST /two HTTP/1.1\r\nHost: example\r\nContent-Length: 2\r\nConnection: close\r\n\r\nfg",
        &app,
        .{},
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqual(@as(usize, 2), calls);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output, "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, output, "\r\n\r\nabcdeHTTP/1.1") != null);
    try std.testing.expect(std.mem.endsWith(u8, output, "\r\n\r\nfg"));
}

test "request framing and decoded body limits reject and close" {
    var calls: usize = 0;
    const app: TestApp = .{ .allocator = std.testing.allocator, .calls = &calls };

    const conflict = try runTest(
        "POST / HTTP/1.1\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
        &app,
        .{},
    );
    defer std.testing.allocator.free(conflict);
    try std.testing.expect(std.mem.startsWith(u8, conflict, "HTTP/1.1 400"));

    const oversized = try runTest(
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n",
        &app,
        .{ .request_limits = .{ .max_body_bytes = 2 } },
    );
    defer std.testing.allocator.free(oversized);
    try std.testing.expect(std.mem.startsWith(u8, oversized, "HTTP/1.1 413"));
    try std.testing.expectEqual(@as(usize, 0), calls);
}

test "target, header count, and malformed syntax map to bounded errors" {
    var calls: usize = 0;
    const app: TestApp = .{ .allocator = std.testing.allocator, .calls = &calls };

    const target = try runTest("GET /toolong HTTP/1.1\r\n\r\n", &app, .{ .request_limits = .{ .target_bytes = 4 } });
    defer std.testing.allocator.free(target);
    try std.testing.expect(std.mem.startsWith(u8, target, "HTTP/1.1 414"));

    const headers = try runTest(
        "GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\n\r\n",
        &app,
        .{ .request_limits = .{ .max_headers = 1 } },
    );
    defer std.testing.allocator.free(headers);
    try std.testing.expect(std.mem.startsWith(u8, headers, "HTTP/1.1 431"));

    const malformed = try runTest(
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nZ\r\n",
        &app,
        .{},
    );
    defer std.testing.allocator.free(malformed);
    try std.testing.expect(std.mem.startsWith(u8, malformed, "HTTP/1.1 400"));
    try std.testing.expectEqual(@as(usize, 0), calls);
}

test "dispatch failures are generic and response framing is transport owned" {
    var calls: usize = 0;
    const failing: TestApp = .{ .allocator = std.testing.allocator, .calls = &calls, .fail = true };
    const failed = try runTest("GET / HTTP/1.1\r\nHost: example\r\n\r\n", &failing, .{});
    defer std.testing.allocator.free(failed);
    try std.testing.expect(std.mem.startsWith(u8, failed, "HTTP/1.1 500 Internal Server Error"));
    try std.testing.expect(std.mem.indexOf(u8, failed, "DispatchFailed") == null);

    const bodyless: TestApp = .{ .allocator = std.testing.allocator, .calls = &calls, .bodyless = true };
    const framed = try runTest("GET / HTTP/1.1\r\nHost: example\r\n\r\n", &bodyless, .{});
    defer std.testing.allocator.free(framed);
    try std.testing.expect(std.mem.indexOf(u8, framed, "content-length: 0\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, framed, "content-length: 999") == null);
    try std.testing.expect(std.mem.indexOf(u8, framed, "transfer-encoding") == null);
    try std.testing.expect(!std.mem.endsWith(u8, framed, "must not be sent"));
}

test "HEAD retains representation length and emits no body" {
    var calls: usize = 0;
    const app: TestApp = .{ .allocator = std.testing.allocator, .calls = &calls };
    const output = try runTest("HEAD / HTTP/1.1\r\nHost: example\r\nContent-Length: 4\r\n\r\ndata", &app, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "content-length: 4\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, output, "\r\n\r\n"));
}

test "chunk sizes are strict hexadecimal with optional extensions" {
    try std.testing.expectEqual(@as(u64, 0x1f), try parseChunkSize("1F"));
    try std.testing.expectEqual(@as(u64, 3), try parseChunkSize("3;name=value"));
    try std.testing.expectEqual(@as(u64, 3), try parseChunkSize("3 ; name"));
    try std.testing.expectEqual(@as(u64, 0), try parseChunkSize("000"));
    for ([_][]const u8{ "", "g", "zz", "-1", "+1", "3 x", ";ext", "3;\x00", "1ffffffffffffffff" }) |line| {
        try std.testing.expectError(error.Malformed, parseChunkSize(line));
    }
}

test "chunked framing ambiguities are rejected before dispatch" {
    var calls: usize = 0;
    const app: TestApp = .{ .allocator = std.testing.allocator, .calls = &calls };
    const head = "POST / HTTP/1.1\r\nHost: example\r\nTransfer-Encoding: chunked\r\n\r\n";
    inline for (.{
        head ++ "zz\r\nab\r\n0\r\n\r\n",
        head ++ "\r\n",
        head ++ "3\nabc\r\n0\r\n\r\n",
        head ++ "3\r\nabcX\r\n0\r\n\r\n",
        head ++ "1\r\na\r\n0\r\nNoColon\r\n\r\n",
    }) |input| {
        const output = try runTest(input, &app, .{});
        defer std.testing.allocator.free(output);
        try std.testing.expect(std.mem.startsWith(u8, output, "HTTP/1.1 400"));
    }

    // A declared chunk beyond the body limit is refused before its data.
    const huge = try runTest(head ++ "40000000\r\n", &app, .{ .request_limits = .{ .max_body_bytes = 16 } });
    defer std.testing.allocator.free(huge);
    try std.testing.expect(std.mem.startsWith(u8, huge, "HTTP/1.1 413"));
    try std.testing.expectEqual(@as(usize, 0), calls);

    // Valid extensions and trailers are accepted.
    const valid = try runTest(head ++ "3;ext=1\r\nabc\r\n0\r\nX-Sum: 1\r\n\r\n", &app, .{});
    defer std.testing.allocator.free(valid);
    try std.testing.expect(std.mem.startsWith(u8, valid, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.endsWith(u8, valid, "\r\n\r\nabc"));
}

test "signed lengths, colonless fields, and rejected expectations" {
    var calls: usize = 0;
    const app: TestApp = .{ .allocator = std.testing.allocator, .calls = &calls };
    inline for (.{
        "POST / HTTP/1.1\r\nContent-Length: +1\r\n\r\na",
        "GET / HTTP/1.1\r\nNoColon\r\n\r\n",
        "POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
    }) |input| {
        const output = try runTest(input, &app, .{});
        defer std.testing.allocator.free(output);
        try std.testing.expect(std.mem.startsWith(u8, output, "HTTP/1."));
        try std.testing.expect(std.mem.indexOf(u8, output, " 400 ") != null);
    }
    // No interim `100 Continue` precedes the rejection.
    const expect = try runTest("POST / HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 1\r\n\r\na", &app, .{});
    defer std.testing.allocator.free(expect);
    try std.testing.expect(std.mem.startsWith(u8, expect, "HTTP/1.1 400"));
    try std.testing.expect(std.mem.indexOf(u8, expect, "100 Continue") == null);
    try std.testing.expectEqual(@as(usize, 0), calls);
}

test "HTTP/2 prior knowledge and h2c upgrade stay HTTP/1.1 only" {
    var calls: usize = 0;
    const app: TestApp = .{ .allocator = std.testing.allocator, .calls = &calls };
    // The RFC 9113 client preface has an unsupported version and is refused.
    const preface = try runTest("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", &app, .{});
    defer std.testing.allocator.free(preface);
    try std.testing.expect(std.mem.startsWith(u8, preface, "HTTP/1.1 400"));
    try std.testing.expectEqual(@as(usize, 0), calls);

    // An h2c upgrade request is served over HTTP/1.1 without switching.
    const upgrade = try runTest(
        "GET / HTTP/1.1\r\nHost: example\r\nConnection: Upgrade, HTTP2-Settings\r\n" ++
            "Upgrade: h2c\r\nHTTP2-Settings: AAMAAABkAARAAAAAAAIAAAAA\r\n\r\n",
        &app,
        .{},
    );
    defer std.testing.allocator.free(upgrade);
    try std.testing.expect(std.mem.startsWith(u8, upgrade, "HTTP/1.1 200"));
    try std.testing.expect(std.ascii.indexOfIgnoreCase(upgrade, "upgrade") == null);
    try std.testing.expectEqual(@as(usize, 1), calls);
}
