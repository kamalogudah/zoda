const std = @import("std");
const Io = std.Io;

const zoda = @import("zoda");

const router = zoda.router;
const request = zoda.request;
const response = zoda.response;
const app = zoda.app;
const Json = zoda.Json;

const User = struct {
    id: []const u8,
    name: []const u8,
};

const Plugins = struct { json: Json = .{} };
const Demo = app.App(Plugins);

fn route(ctx: *Demo.Context, req: *router.Request, res: *response.Response) !void {
    if (req.isRoot() and req.isGet()) return res.text(200, "hello from zoda");
    if (req.onLiteral("users")) {
        if (req.onSegment()) |id| {
            if (req.isRoot() and req.isGet()) {
                return ctx.plugins.json.render(res, User, .{ .id = id, .name = "unknown" });
            }
        }
        return;
    }
}

/// `zoda` dispatches the route matrix in memory and exits.
/// `zoda serve [port]` serves the same routes on 127.0.0.1 (default 8080);
/// `zig build watch` uses this mode.
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len > 1 and std.mem.eql(u8, args[1], "serve")) {
        const port = if (args.len > 2) try std.fmt.parseInt(u16, args[2], 10) else 8080;
        return serve(io, stdout_writer, port);
    }

    const demo_app = Demo{
        .response_allocator = arena,
        .config = .{ .name = "demo" },
        .plugins = .{},
        .route_fn = route,
    };

    const cases = .{
        .{ .method = router.Method.get, .path = "/" },
        .{ .method = router.Method.get, .path = "/users/42" },
        .{ .method = router.Method.get, .path = "/users" },
        .{ .method = router.Method.get, .path = "/users/42/extra" },
        .{ .method = router.Method.get, .path = "/users/42/" },
        .{ .method = router.Method.post, .path = "/users/42" },
    };

    inline for (cases) |case| {
        var req_arena = try request.parseOriginForm(arena, .default, case.path);
        defer req_arena.deinit();
        var req = req_arena.requestView(case.method);
        var res = try demo_app.dispatch(&req);
        defer res.deinit();
        try stdout_writer.print("{s} {s} -> {d} {s}\n", .{
            @tagName(case.method), case.path, res.status_code, res.content_type,
        });
    }

    try stdout_writer.flush();
}

fn serve(io: Io, stdout_writer: *Io.Writer, port: u16) !void {
    // Connection tasks share this allocator concurrently (PLATFORM.md §5).
    const gpa = std.heap.smp_allocator;
    // Timing is registered first so it is outermost and times the whole chain.
    var demo_app = try Demo.init(gpa, .{
        .response_allocator = gpa,
        .config = .{ .name = "demo", .clock = .monotonic(io) },
        .plugins = .{},
        .route_fn = route,
        .middleware = &.{zoda.timing.middleware(Demo)},
    });
    defer demo_app.deinit();

    const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    try stdout_writer.print("listening on http://127.0.0.1:{d}\n", .{port});
    try stdout_writer.flush();
    try zoda.server.serve(Demo, gpa, io, &listener, &demo_app, .{});
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "route demo outcomes" {
    const demo_app = Demo{
        .response_allocator = std.testing.allocator,
        .config = .{ .name = "demo" },
        .plugins = .{},
        .route_fn = route,
    };

    {
        var req_arena = try request.parseOriginForm(std.testing.allocator, .default, "/");
        defer req_arena.deinit();
        var req = req_arena.requestView(.get);
        var res = try demo_app.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 200), res.status_code);
        try std.testing.expectEqualStrings("text/plain", res.content_type);
        try std.testing.expectEqualStrings("hello from zoda", res.body);
    }

    {
        var req_arena = try request.parseOriginForm(std.testing.allocator, .default, "/users/42");
        defer req_arena.deinit();
        var req = req_arena.requestView(.get);
        var res = try demo_app.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 200), res.status_code);
        try std.testing.expectEqualStrings("application/json", res.content_type);
        try std.testing.expectEqualStrings("{\"id\":\"42\",\"name\":\"unknown\"}", res.body);
    }

    const not_found_paths = .{ "/users", "/users/42/extra", "/users/42/" };
    inline for (not_found_paths) |path| {
        var req_arena = try request.parseOriginForm(std.testing.allocator, .default, path);
        defer req_arena.deinit();
        var req = req_arena.requestView(.get);
        var res = try demo_app.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 404), res.status_code);
        try std.testing.expectEqualStrings("text/plain", res.content_type);
        try std.testing.expectEqualStrings("Not Found", res.body);
    }

    {
        var req_arena = try request.parseOriginForm(std.testing.allocator, .default, "/users/42");
        defer req_arena.deinit();
        var req = req_arena.requestView(.post);
        var res = try demo_app.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 404), res.status_code);
        try std.testing.expectEqualStrings("text/plain", res.content_type);
        try std.testing.expectEqualStrings("Not Found", res.body);
    }
}

test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!

    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
        .add_data => {
            const slice = try list.addManyAsSlice(gpa, smith.value(u4));
            smith.bytes(slice);
        },
        .dup_data => {
            if (list.items.len == 0) continue;
            if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
            const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
            const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
            try list.appendSlice(gpa, list.items[off..][0..len]);
            try std.testing.expectEqualSlices(
                u8,
                list.items[off..][0..len],
                list.items[list.items.len - len ..],
            );
        },
    };
}
