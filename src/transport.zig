//! Bounded HTTP/1.x wire adapter (ADR-0001 §3.4, Phase 2).
//!
//! The adapter deliberately leaves connection acceptance and concurrency to
//! its caller. It owns HTTP framing for one connection: every
//! request is copied into a fresh `RequestArena`, dispatched only after the
//! complete body has been decoded, and released after its buffered response is
//! sent. Protocol rejections and application failures close the connection.
//!
//! Zig 0.16.0 APIs used here are `std.http.Server.init/receiveHead`,
//! `Request.iterateHeaders`, `std.http.Reader.bodyReader`, and
//! `Request.respond`. `bodyReader` removes chunk framing before bytes reach the
//! bounded accumulator. `respond` supplies exactly one Content-Length and
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
        if (!validHeader(header.name, header.value)) {
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
    if (saw_transfer_encoding and (transfer_encoding != .chunked or saw_content_length)) {
        try reject(wire_req, .bad_request, version, deadlines);
        return .close;
    }
    if (transfer_encoding != .none or content_length != null) {
        if (deadlines) |operation_deadlines| operation_deadlines.body();
        var transfer_buffer: [8192]u8 = undefined;
        var chunk: [8192]u8 = undefined;
        var body = buffering.BoundedAccumulator.init(arena.allocator(), limits.max_body_bytes);
        defer body.deinit();

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
        arena.body = body.toOwnedSlice() catch {
            try reject(wire_req, .internal_server_error, version, deadlines);
            return .close;
        };

        // Chunk trailers share the request header limits and are exposed to
        // dispatch as additional ordered header fields.
        var trailers = wire_req.server.reader.trailers;
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
