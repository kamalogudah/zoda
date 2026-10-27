//! Exact HTTP Host authorization for the whole middleware chain.
//!
//! The transport preserves ordered header fields but exposes no normalized
//! authority. Both socket and direct dispatch therefore use the same Host
//! lookup. HTTP/1.0 follows the same fail-closed rule as HTTP/1.1. Forwarded
//! host fields are deliberately ignored.
const std = @import("std");
const router = @import("router.zig");
const response = @import("response.zig");

pub const Config = struct {
    /// Exact authorities. Borrowed until app shutdown. An entry with a port
    /// matches only that port; an entry without one matches only no port.
    allowed_hosts: []const []const u8,
};

pub const ConfigError = error{ EmptyAllowlist, InvalidAllowedHost, DuplicateAllowedHost };

const Authority = struct { host: []const u8, port: ?[]const u8 };

/// Host is one ASCII DNS-style name (including IPv4-style names), optionally followed by a
/// decimal port. No whitespace, trailing dot, empty labels, or leading-zero
/// ports are accepted. Bracketed IP literals, userinfo, and forwarded host
/// fields are outside this contract.
fn parseAuthority(raw: []const u8) ?Authority {
    if (raw.len == 0) return null;
    const colon = std.mem.indexOfScalar(u8, raw, ':');
    const host = if (colon) |i| raw[0..i] else raw;
    const port: ?[]const u8 = if (colon) |i| raw[i + 1 ..] else null;
    if (host.len == 0 or host.len > 253 or host[0] == '.' or host[host.len - 1] == '.') return null;
    var label_len: usize = 0;
    for (host) |c| {
        if (c == '.') {
            if (label_len == 0) return null;
            label_len = 0;
        } else if (std.ascii.isAlphanumeric(c) or c == '-') {
            if (label_len == 0 and c == '-') return null;
            label_len += 1;
            if (label_len > 63) return null;
        } else return null;
    }
    if (label_len == 0 or host[host.len - 1] == '-') return null;
    // Reject a hyphen at either end of every label.
    var labels = std.mem.splitScalar(u8, host, '.');
    while (labels.next()) |label| {
        if (label[label.len - 1] == '-') return null;
    }
    if (port) |p| {
        if (p.len == 0 or p.len > 5 or (p.len > 1 and p[0] == '0')) return null;
        var number: u32 = 0;
        for (p) |c| {
            if (!std.ascii.isDigit(c)) return null;
            number = number * 10 + c - '0';
        }
        if (number == 0 or number > 65535) return null;
    }
    return .{ .host = host, .port = port };
}

fn same(a: Authority, b: Authority) bool {
    if (!std.ascii.eqlIgnoreCase(a.host, b.host)) return false;
    if (a.port) |port| return b.port != null and std.mem.eql(u8, port, b.port.?);
    return b.port == null;
}

pub fn validate(config: *const Config) ConfigError!void {
    if (config.allowed_hosts.len == 0) return error.EmptyAllowlist;
    for (config.allowed_hosts, 0..) |raw, i| {
        const authority = parseAuthority(raw) orelse return error.InvalidAllowedHost;
        for (config.allowed_hosts[0..i]) |prior| {
            if (same(authority, parseAuthority(prior).?)) return error.DuplicateAllowedHost;
        }
    }
}

/// Fail closed on missing, repeated, or malformed Host fields. A direct
/// dispatch has the same rule as a socket request, including HTTP/1.0.
pub fn authorized(config: *const Config, req: *const router.Request) bool {
    const raw = (req.getHeaderOne("Host") catch return false) orelse return false;
    const authority = parseAuthority(std.mem.trim(u8, raw, " \t")) orelse return false;
    for (config.allowed_hosts) |allowed| {
        if (same(authority, parseAuthority(allowed).?)) return true;
    }
    return false;
}

/// Register before static and routing middleware so every response source is
/// guarded. Invalid configuration fails during setup.
pub fn middleware(comptime AppT: type, config: *const Config) ConfigError!AppT.Middleware {
    try validate(config);
    const Impl = struct {
        fn invoke(raw: *const anyopaque, ctx: *AppT.Context, req: *router.Request, res: *response.Response, next: AppT.Next) anyerror!void {
            const cfg: *const Config = @ptrCast(@alignCast(raw));
            if (!authorized(cfg, req)) return res.text(403, "Forbidden");
            return next.call(ctx, req, res);
        }
    };
    return .{ .config = config, .invoke = Impl.invoke };
}

test "configuration and direct dispatch authorize exact authority before routing" {
    const testing = std.testing;
    const app_mod = @import("app.zig");
    const App = app_mod.App(struct {});
    const Handler = struct {
        var calls: usize = 0;
        fn route(_: *App.Context, _: *router.Request, res: *response.Response) !void {
            calls += 1;
            try res.text(200, "ok");
        }
    };
    const empty = Config{ .allowed_hosts = &.{} };
    try testing.expectError(error.EmptyAllowlist, middleware(App, &empty));
    for ([_][]const u8{ "", "example.com.", "a..b", "-bad.test", "bad-.test", "example.com:", "example.com:0", "example.com:080", "example.com:65536", "[::1]", "example.com.evil:1:2" }) |bad| {
        const invalid = Config{ .allowed_hosts = &.{bad} };
        try testing.expectError(error.InvalidAllowedHost, middleware(App, &invalid));
    }
    const duplicate = Config{ .allowed_hosts = &.{ "example.com", "EXAMPLE.COM" } };
    try testing.expectError(error.DuplicateAllowedHost, middleware(App, &duplicate));

    const config = Config{ .allowed_hosts = &.{ "example.com", "example.com:8080" } };
    Handler.calls = 0;
    var app = try App.init(testing.allocator, .{
        .response_allocator = testing.allocator,
        .plugins = .{},
        .route_fn = Handler.route,
        .middleware = &.{try middleware(App, &config)},
    });
    defer app.deinit();
    const cases = .{
        .{ "EXAMPLE.COM", @as(u16, 200) },
        .{ "example.com:8080", @as(u16, 200) },
        .{ "example.com.evil.test", @as(u16, 403) },
        .{ "example.com:80", @as(u16, 403) },
        .{ "example.com:08080", @as(u16, 403) },
        .{ "evil.test", @as(u16, 403) },
        .{ "example.com,evil.test", @as(u16, 403) },
        .{ " example.com", @as(u16, 200) },
        .{ "exa mple.com", @as(u16, 403) },
    };
    inline for (cases) |case| {
        const headers = [_]router.Header{.{ .name = "hOsT", .value = case[0] }};
        var req: router.Request = .{ .method = .get, .segments = &.{}, .headers = &headers };
        var res = try app.dispatch(&req);
        defer res.deinit();
        try testing.expectEqual(case[1], res.status_code);
    }
    const duplicate_headers = [_]router.Header{ .{ .name = "Host", .value = "example.com" }, .{ .name = "host", .value = "example.com" } };
    var repeated: router.Request = .{ .method = .get, .segments = &.{}, .headers = &duplicate_headers };
    var repeated_res = try app.dispatch(&repeated);
    defer repeated_res.deinit();
    try testing.expectEqual(@as(u16, 403), repeated_res.status_code);
    var missing: router.Request = .{ .method = .get, .segments = &.{} };
    var missing_res = try app.dispatch(&missing);
    defer missing_res.deinit();
    try testing.expectEqual(@as(u16, 403), missing_res.status_code);
    try testing.expectEqual(@as(usize, 3), Handler.calls);
}

test "direct dispatch and real sockets agree on Host authorization" {
    const testing = std.testing;
    const app_mod = @import("app.zig");
    const server = @import("server.zig");
    const App = app_mod.App(struct {});
    const Route = struct {
        fn route(_: *App.Context, _: *router.Request, res: *response.Response) !void {
            try res.text(200, "ok");
        }
    };
    const Runner = struct {
        fn run(allocator: std.mem.Allocator, io: std.Io, listener: *std.Io.net.Server, instance: *const App, options: server.Config) !void {
            return server.serve(App, allocator, io, listener, instance, options);
        }
    };

    const config = Config{ .allowed_hosts = &.{ "example.com", "example.com:8080" } };
    var app = try App.init(testing.allocator, .{
        .response_allocator = testing.allocator,
        .plugins = .{},
        .route_fn = Route.route,
        .middleware = &.{try middleware(App, &config)},
    });
    defer app.deinit();

    const io = testing.io;
    const loopback: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try loopback.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var future = try io.concurrent(Runner.run, .{
        testing.allocator,
        io,
        &listener,
        &app,
        server.Config{ .shutdown_grace_period = .{ .raw = .fromMilliseconds(25), .clock = .awake } },
    });
    defer _ = future.cancel(io) catch {};

    const Case = struct {
        version: []const u8,
        fields: []const router.Header,
        raw_fields: []const u8,
        status: u16,
    };
    const cases = [_]Case{
        .{ .version = "HTTP/1.1", .fields = &.{.{ .name = "Host", .value = "example.com" }}, .raw_fields = "Host: example.com\r\n", .status = 200 },
        .{ .version = "HTTP/1.1", .fields = &.{.{ .name = "hOsT", .value = "EXAMPLE.COM" }}, .raw_fields = "hOsT: EXAMPLE.COM\r\n", .status = 200 },
        .{ .version = "HTTP/1.1", .fields = &.{.{ .name = "Host", .value = "example.com:8080" }}, .raw_fields = "Host: example.com:8080\r\n", .status = 200 },
        .{ .version = "HTTP/1.1", .fields = &.{.{ .name = "Host", .value = " \texample.com \t" }}, .raw_fields = "Host: \texample.com \t\r\n", .status = 200 },
        .{ .version = "HTTP/1.0", .fields = &.{.{ .name = "Host", .value = "example.com" }}, .raw_fields = "Host: example.com\r\n", .status = 200 },
        .{ .version = "HTTP/1.1", .fields = &.{.{ .name = "Host", .value = "example.com.evil.test" }}, .raw_fields = "Host: example.com.evil.test\r\n", .status = 403 },
        .{ .version = "HTTP/1.1", .fields = &.{.{ .name = "Host", .value = "example.com:80" }}, .raw_fields = "Host: example.com:80\r\n", .status = 403 },
        .{ .version = "HTTP/1.1", .fields = &.{.{ .name = "Host", .value = "example.com:08080" }}, .raw_fields = "Host: example.com:08080\r\n", .status = 403 },
        .{ .version = "HTTP/1.1", .fields = &.{.{ .name = "Host", .value = "a..b" }}, .raw_fields = "Host: a..b\r\n", .status = 403 },
        .{ .version = "HTTP/1.1", .fields = &.{.{ .name = "Host", .value = "exa mple.com" }}, .raw_fields = "Host: exa mple.com\r\n", .status = 403 },
        .{ .version = "HTTP/1.1", .fields = &.{.{ .name = "Host", .value = "example.com," }}, .raw_fields = "Host: example.com,\r\n", .status = 403 },
        .{ .version = "HTTP/1.1", .fields = &.{ .{ .name = "Host", .value = "example.com" }, .{ .name = "host", .value = "example.com" } }, .raw_fields = "Host: example.com\r\nhost: example.com\r\n", .status = 403 },
        .{ .version = "HTTP/1.0", .fields = &.{}, .raw_fields = "", .status = 403 },
        .{ .version = "HTTP/1.1", .fields = &.{.{ .name = "X-Forwarded-Host", .value = "example.com" }}, .raw_fields = "X-Forwarded-Host: example.com\r\n", .status = 403 },
    };
    for (cases) |case| {
        var req: router.Request = .{ .method = .get, .segments = &.{}, .headers = case.fields };
        var direct = try app.dispatch(&req);
        defer direct.deinit();
        try testing.expectEqual(case.status, direct.status_code);

        const client = try listener.socket.address.connect(io, .{ .mode = .stream, .protocol = .tcp });
        defer client.close(io);
        var write_buffer: [512]u8 = undefined;
        var writer = client.writer(io, &write_buffer);
        try writer.interface.print("GET / {s}\r\n{s}Connection: close\r\n\r\n", .{ case.version, case.raw_fields });
        try writer.interface.flush();
        var read_buffer: [512]u8 = undefined;
        var reader = client.reader(io, &read_buffer);
        const status_line = try reader.interface.takeDelimiterInclusive('\n');
        var expected: [16]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&expected, "{s} {d}", .{ case.version, case.status });
        try testing.expect(std.mem.startsWith(u8, status_line, prefix));
    }
}

test "Host authorization guards static files" {
    const testing = std.testing;
    const app_mod = @import("app.zig");
    const static = @import("static.zig");
    if (!static.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "asset.txt", .data = "asset" });
    try static.checkSupport(tmp.dir);

    const App = app_mod.App(struct {});
    const Route = struct {
        fn route(_: *App.Context, _: *router.Request, res: *response.Response) !void {
            try res.text(200, "route");
        }
    };
    const config = Config{ .allowed_hosts = &.{"example.com"} };
    const static_config = static.Config{ .root = tmp.dir };
    var app = try App.init(testing.allocator, .{
        .response_allocator = testing.allocator,
        .plugins = .{},
        .route_fn = Route.route,
        .middleware = &.{ try middleware(App, &config), static.middleware(App, &static_config) },
    });
    defer app.deinit();

    for ([_]struct { host: []const u8, status: u16, body: []const u8 }{
        .{ .host = "example.com", .status = 200, .body = "asset" },
        .{ .host = "example.com.evil.test", .status = 403, .body = "Forbidden" },
    }) |case| {
        const headers = [_]router.Header{.{ .name = "Host", .value = case.host }};
        var req: router.Request = .{ .method = .get, .segments = &.{"asset.txt"}, .headers = &headers };
        var res = try app.dispatch(&req);
        defer res.deinit();
        try testing.expectEqual(case.status, res.status_code);
        try testing.expectEqualStrings(case.body, res.body);
    }
}
