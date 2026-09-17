//! Application dispatch and typed handler context (ADR-0001 §3.2, §5.2).
//!
//! An `App(Plugins)` wires a set of plugin instances into a handler context,
//! initializes per-request plugin state, invokes the configured route, and
//! supplies a fallback 404 when the route leaves the response unhandled.
//!
//! `RequestState(Plugins)` is generated from the plugin struct: one field is
//! emitted for every plugin instance that declares a non-`void` `State` type
//! and an `initRequest` hook. Initialization runs in declaration order; cleanup
//! runs in reverse order, including partial initialization failures.
const std = @import("std");
const router = @import("router.zig");
const response = @import("response.zig");
const request = @import("request.zig");
const Json = @import("plugins/json.zig").Json;

/// Re-export the JSON plugin instance type so downstream code can write
/// `const Plugins = struct { json: zoda.Json = .{} };`.
pub const json = Json;

/// Immutable application configuration. Applications may add fields here as
/// long as the values remain valid for the lifetime of the app.
pub const AppConfig = struct {
    name: []const u8 = "zoda",
};

/// Generates a struct containing one field per plugin instance that declares a
/// non-`void` `State` type and an `initRequest` hook. Field names match the
/// plugin instance names.
pub fn RequestState(comptime Plugins: type) type {
    const fields = std.meta.fields(Plugins);
    const count = comptime blk: {
        var c: usize = 0;
        for (fields) |f| {
            const PT = f.type;
            if (@hasDecl(PT, "State") and PT.State != void and @hasDecl(PT, "initRequest")) c += 1;
        }
        break :blk c;
    };
    var names: [count][]const u8 = undefined;
    var types: [count]type = undefined;
    var attrs: [count]std.builtin.Type.StructField.Attributes = undefined;
    var i: usize = 0;
    inline for (fields) |f| {
        const PT = f.type;
        if (@hasDecl(PT, "State") and PT.State != void and @hasDecl(PT, "initRequest")) {
            names[i] = f.name;
            types[i] = PT.State;
            attrs[i] = .{};
            i += 1;
        }
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

/// Initializes the per-request state for `Plugins` in declaration order. If a
/// later hook fails, already-initialized states are deinitialized in reverse
/// order before the error is returned.
pub fn initRequestState(
    comptime Plugins: type,
    plugins: *const Plugins,
    req: *router.Request,
    state: *RequestState(Plugins),
) !void {
    const fields = std.meta.fields(Plugins);
    var initialized = [1]bool{false} ** fields.len;

    errdefer {
        inline for (0..fields.len) |rev_offset| {
            const idx = fields.len - 1 - rev_offset;
            const f = fields[idx];
            const PT = f.type;
            if (initialized[idx] and @hasDecl(PT, "deinitRequest")) {
                @field(plugins, f.name).deinitRequest(&@field(state, f.name));
            }
        }
    }

    inline for (fields, 0..) |f, idx| {
        const PT = f.type;
        if (@hasDecl(PT, "State") and PT.State != void and @hasDecl(PT, "initRequest")) {
            const plugin_ptr = &@field(plugins, f.name);
            @field(state, f.name) = try plugin_ptr.initRequest(req);
            initialized[idx] = true;
        }
    }
}

/// Deinitializes the per-request state for `Plugins` in reverse declaration
/// order. Cleanup is infallible and does not write responses.
pub fn deinitRequestState(
    comptime Plugins: type,
    plugins: *const Plugins,
    state: *RequestState(Plugins),
) void {
    const fields = std.meta.fields(Plugins);
    inline for (0..fields.len) |rev_offset| {
        const idx = fields.len - 1 - rev_offset;
        const f = fields[idx];
        const PT = f.type;
        if (@hasDecl(PT, "State") and PT.State != void and @hasDecl(PT, "deinitRequest")) {
            @field(plugins, f.name).deinitRequest(&@field(state, f.name));
        }
    }
}

/// A typed application: `Plugins` is a struct of plugin instances, and the
/// route receives a typed context exposing those instances, application
/// configuration, and per-request state.
pub fn App(comptime Plugins: type) type {
    return struct {
        const Self = @This();
        pub const State = RequestState(Plugins);
        pub const Context = struct {
            plugins: *const Plugins,
            config: *const AppConfig,
            state: *State,
        };
        pub const RouteFn = *const fn (*Context, *router.Request, *response.Response) anyerror!void;

        response_allocator: std.mem.Allocator,
        config: AppConfig,
        plugins: Plugins,
        route_fn: RouteFn,

        /// Dispatches a request through the route and returns an independently
        /// owned response. The caller owns `req` and must keep it alive until
        /// `dispatch` returns; the returned response must be released with
        /// `res.deinit()`.
        pub fn dispatch(self: *const Self, req: *router.Request) !response.Response {
            var state: State = undefined;
            try initRequestState(Plugins, &self.plugins, req, &state);
            defer deinitRequestState(Plugins, &self.plugins, &state);

            var ctx = Context{
                .plugins = &self.plugins,
                .config = &self.config,
                .state = &state,
            };
            var res = response.Response.init(self.response_allocator);
            errdefer res.deinit();
            try self.route_fn(&ctx, req, &res);
            if (!res.handled) try res.text(404, "Not Found");
            return res;
        }
    };
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

const TrackingPlugin = struct {
    tag: u8,
    init_order: *std.ArrayList(u8),
    deinit_order: *std.ArrayList(u8),
    call_count: *usize,
    fail_after: ?usize,

    pub const State = struct { tag: u8 };

    pub fn initRequest(self: *const @This(), _: *router.Request) !State {
        self.call_count.* += 1;
        if (self.fail_after) |limit| {
            if (self.call_count.* > limit) return error.TestInitFail;
        }
        try self.init_order.append(std.testing.allocator, self.tag);
        return .{ .tag = self.tag };
    }

    pub fn deinitRequest(self: *const @This(), state: *State) void {
        self.deinit_order.append(std.testing.allocator, state.tag) catch unreachable;
    }
};

fn makeTrackingPlugin(
    tag: u8,
    init_order: *std.ArrayList(u8),
    deinit_order: *std.ArrayList(u8),
    call_count: *usize,
    fail_after: ?usize,
) TrackingPlugin {
    return .{
        .tag = tag,
        .init_order = init_order,
        .deinit_order = deinit_order,
        .call_count = call_count,
        .fail_after = fail_after,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "request state initializes in order and cleans up in reverse on failure" {
    var init_order: std.ArrayList(u8) = .empty;
    defer init_order.deinit(std.testing.allocator);
    var deinit_order: std.ArrayList(u8) = .empty;
    defer deinit_order.deinit(std.testing.allocator);

    var alpha_calls: usize = 0;
    var beta_calls: usize = 0;
    var gamma_calls: usize = 0;

    const Plugins = struct {
        alpha: TrackingPlugin,
        beta: TrackingPlugin,
        gamma: TrackingPlugin,
    };
    const plugins = Plugins{
        .alpha = makeTrackingPlugin('A', &init_order, &deinit_order, &alpha_calls, null),
        .beta = makeTrackingPlugin('B', &init_order, &deinit_order, &beta_calls, null),
        .gamma = makeTrackingPlugin('G', &init_order, &deinit_order, &gamma_calls, 0),
    };

    const State = RequestState(Plugins);
    var req_arena = try request.parseOriginForm(std.testing.allocator, .default, "/");
    defer req_arena.deinit();
    var req = req_arena.requestView(.get);

    var state: State = undefined;
    const result = initRequestState(Plugins, &plugins, &req, &state);
    try std.testing.expectError(error.TestInitFail, result);
    try std.testing.expectEqualSlices(u8, "AB", init_order.items);
    try std.testing.expectEqualSlices(u8, "BA", deinit_order.items);
}

test "demo app route outcomes" {
    const User = struct { id: []const u8, name: []const u8 };
    const Plugins = struct { json: Json = .{} };
    const Demo = App(Plugins);

    const route = struct {
        fn run(ctx: *Demo.Context, req: *router.Request, res: *response.Response) !void {
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
    }.run;

    const app = Demo{
        .response_allocator = std.testing.allocator,
        .config = .{ .name = "demo" },
        .plugins = .{},
        .route_fn = route,
    };

    {
        var arena = try request.parseOriginForm(std.testing.allocator, .default, "/");
        defer arena.deinit();
        var req = arena.requestView(.get);
        var res = try app.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 200), res.status_code);
        try std.testing.expectEqualStrings("hello from zoda", res.body);
        try std.testing.expectEqualStrings("text/plain", res.content_type);
    }

    {
        var arena = try request.parseOriginForm(std.testing.allocator, .default, "/users/42");
        defer arena.deinit();
        var req = arena.requestView(.get);
        var res = try app.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 200), res.status_code);
        try std.testing.expectEqualStrings("application/json", res.content_type);
        try std.testing.expectEqualStrings("{\"id\":\"42\",\"name\":\"unknown\"}", res.body);
    }

    {
        var arena = try request.parseOriginForm(std.testing.allocator, .default, "/users");
        defer arena.deinit();
        var req = arena.requestView(.get);
        var res = try app.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 404), res.status_code);
        try std.testing.expectEqualStrings("Not Found", res.body);
    }

    {
        var arena = try request.parseOriginForm(std.testing.allocator, .default, "/users/42/extra");
        defer arena.deinit();
        var req = arena.requestView(.get);
        var res = try app.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 404), res.status_code);
    }

    {
        var arena = try request.parseOriginForm(std.testing.allocator, .default, "/users/42/");
        defer arena.deinit();
        var req = arena.requestView(.get);
        var res = try app.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 404), res.status_code);
    }

    {
        var arena = try request.parseOriginForm(std.testing.allocator, .default, "/users/42");
        defer arena.deinit();
        var req = arena.requestView(.post);
        var res = try app.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 404), res.status_code);
    }
}

test "two differently configured apps are independent" {
    const Plugins = struct { json: Json = .{} };
    const Demo = App(Plugins);

    const route = struct {
        fn run(ctx: *Demo.Context, req: *router.Request, res: *response.Response) !void {
            if (req.isRoot() and req.isGet()) return res.text(200, ctx.config.name);
        }
    }.run;

    const app_a = Demo{
        .response_allocator = std.testing.allocator,
        .config = .{ .name = "alpha" },
        .plugins = .{},
        .route_fn = route,
    };
    const app_b = Demo{
        .response_allocator = std.testing.allocator,
        .config = .{ .name = "beta" },
        .plugins = .{},
        .route_fn = route,
    };

    {
        var arena = try request.parseOriginForm(std.testing.allocator, .default, "/");
        defer arena.deinit();
        var req = arena.requestView(.get);
        var res = try app_a.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqualStrings("alpha", res.body);
    }

    {
        var arena = try request.parseOriginForm(std.testing.allocator, .default, "/");
        defer arena.deinit();
        var req = arena.requestView(.get);
        var res = try app_b.dispatch(&req);
        defer res.deinit();
        try std.testing.expectEqualStrings("beta", res.body);
    }
}

test "state cleanup runs after handler failure" {
    var init_dummy: std.ArrayList(u8) = .empty;
    defer init_dummy.deinit(std.testing.allocator);
    var deinit_order: std.ArrayList(u8) = .empty;
    defer deinit_order.deinit(std.testing.allocator);
    var calls: usize = 0;

    const Plugins = struct { track: TrackingPlugin };
    const FailApp = App(Plugins);

    const route = struct {
        fn run(_: *FailApp.Context, _: *router.Request, _: *response.Response) !void {
            return error.Boom;
        }
    }.run;

    const plugins = Plugins{
        .track = makeTrackingPlugin('X', &init_dummy, &deinit_order, &calls, null),
    };
    const app = FailApp{
        .response_allocator = std.testing.allocator,
        .config = .{},
        .plugins = plugins,
        .route_fn = route,
    };

    var arena = try request.parseOriginForm(std.testing.allocator, .default, "/");
    defer arena.deinit();
    var req = arena.requestView(.get);
    try std.testing.expectError(error.Boom, app.dispatch(&req));
    try std.testing.expectEqualSlices(u8, "X", deinit_order.items);
}

test "response remains valid after the request arena is destroyed" {
    const User = struct { id: []const u8, name: []const u8 };
    const Plugins = struct { json: Json = .{} };
    const Demo = App(Plugins);

    const route = struct {
        fn run(ctx: *Demo.Context, req: *router.Request, res: *response.Response) !void {
            if (req.onLiteral("users")) {
                if (req.onSegment()) |id| {
                    if (req.isRoot() and req.isGet()) {
                        return ctx.plugins.json.render(res, User, .{ .id = id, .name = "unknown" });
                    }
                }
            }
        }
    }.run;

    const app = Demo{
        .response_allocator = std.testing.allocator,
        .config = .{},
        .plugins = .{},
        .route_fn = route,
    };

    var res: response.Response = undefined;
    {
        var arena = try request.parseOriginForm(std.testing.allocator, .default, "/users/42");
        defer arena.deinit();
        var req = arena.requestView(.get);
        res = try app.dispatch(&req);
    }
    defer res.deinit();
    try std.testing.expectEqualStrings("{\"id\":\"42\",\"name\":\"unknown\"}", res.body);
}

test "stateless json plugin leaves request state empty" {
    const Plugins = struct { json: Json = .{} };
    const State = RequestState(Plugins);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(State));
}
