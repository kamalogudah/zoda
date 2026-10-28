//! Inertia.js todo app. One Zoda server, three interchangeable frontends:
//!
//!     (cd examples/inertia/react && npm install && npm run build)
//!     zig build run-inertia -- react        # or svelte, vue
//!
//! then open http://localhost:8080. Todos live in memory. The server serves
//! the chosen frontend's built `dist/assets` and renders every page through
//! `zoda.Inertia`; mutations redirect back with 303 so the client re-fetches
//! the page as JSON.
const std = @import("std");
const zoda = @import("zoda");

pub const Todo = struct {
    id: u64,
    text: []const u8,
    done: bool = false,
};

pub const Filter = enum { all, active, done };

pub const max_text_bytes = 200;

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(Todo) = .empty,
    next_id: u64 = 1,

    pub fn deinit(self: *Store) void {
        for (self.items.items) |item| self.allocator.free(item.text);
        self.items.deinit(self.allocator);
    }

    fn add(self: *Store, text: []const u8) !u64 {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.items.append(self.allocator, .{ .id = self.next_id, .text = owned });
        self.next_id += 1;
        return self.next_id - 1;
    }

    fn toggle(self: *Store, id: u64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.items.items) |*item| {
            if (item.id == id) {
                item.done = !item.done;
                return true;
            }
        }
        return false;
    }

    fn delete(self: *Store, id: u64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.items.items, 0..) |item, i| {
            if (item.id == id) {
                self.allocator.free(item.text);
                _ = self.items.orderedRemove(i);
                return true;
            }
        }
        return false;
    }
};

/// Counts over every todo, whatever the filter. Sent as a deferred prop.
pub const Stats = struct {
    total: usize,
    done: usize,

    /// Runs inside `render`, which `renderIndex` calls with the store lock
    /// held, so it reads the items without locking again.
    fn compute(store: *Store, _: std.mem.Allocator) Stats {
        var done: usize = 0;
        for (store.items.items) |todo| done += @intFromBool(todo.done);
        return .{ .total = store.items.items.len, .done = done };
    }
};

/// Sent with every page; route props of the same name would win.
pub const Shared = struct { app: []const u8, framework: []const u8 };

pub const Plugins = struct {
    inertia: zoda.Inertia(Shared),
    json: zoda.JsonParser = .{ .max_body_bytes = 4096 },
    store: struct { value: *Store },
};
pub const App = zoda.app.App(Plugins);

/// Each frontend's Vite config writes `assets/app.js` and `assets/app.css`.
pub const layout =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1">
    \\  <title>Zoda + Inertia todos</title>
    \\  <link rel="stylesheet" href="/assets/app.css">
    \\  <script type="module" src="/assets/app.js"></script>
    \\</head>
    \\<body>@inertia</body>
    \\</html>
;

pub fn route(ctx: *App.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    const inertia = &ctx.plugins.inertia;
    if (req.isRoot() and req.isGet()) return inertia.redirect(req, res, "/todos");
    if (!req.onLiteral("todos")) return;

    const store = ctx.plugins.store.value;
    const filter = parseFilter(req);
    if (req.isRoot()) {
        if (req.isGet()) return renderIndex(ctx, req, res, filter, null);
        if (req.method != .post) return;
        var parsed = ctx.plugins.json.parse(res.allocator, req, struct { text: []const u8 }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return res.text(400, "Expected a JSON body with a text field"),
        };
        defer parsed.deinit();
        const text = std.mem.trim(u8, parsed.value.text, " \t\r\n");
        // Re-render with `errors`; Inertia's form helpers read that prop.
        if (text.len == 0) return renderIndex(ctx, req, res, filter, "Write something first.");
        if (text.len > max_text_bytes) return renderIndex(ctx, req, res, filter, "Keep it under 200 bytes.");
        const id = try store.add(text);
        // The fragment scrolls to the new item. Inertia requests get it as
        // 409 + `X-Inertia-Redirect`, because XHR drops followed fragments.
        var buffer: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&buffer, "{s}#todo-{d}", .{ backTo(filter), id });
        return inertia.redirect(req, res, path);
    }

    const id = req.onInt(u64) orelse return;
    if (!req.isRoot()) return;
    const found = switch (req.method) {
        .patch => store.toggle(id),
        .delete => store.delete(id),
        else => return,
    };
    if (!found) return res.text(404, "Todo not found");
    return inertia.redirect(req, res, backTo(filter));
}

fn renderIndex(
    ctx: *App.Context,
    req: *zoda.router.Request,
    res: *zoda.response.Response,
    filter: Filter,
    text_error: ?[]const u8,
) !void {
    const store = ctx.plugins.store.value;
    store.mutex.lockUncancelable(store.io);
    defer store.mutex.unlock(store.io);

    var shown: std.ArrayList(Todo) = .empty;
    defer shown.deinit(res.allocator);
    var remaining: usize = 0;
    for (store.items.items) |todo| {
        if (!todo.done) remaining += 1;
        const keep = switch (filter) {
            .all => true,
            .active => !todo.done,
            .done => todo.done,
        };
        if (keep) try shown.append(res.allocator, todo);
    }
    // `render` copies everything into the response, so the borrowed todo
    // text only has to live while the lock is held. Without an `errors`
    // prop, the plugin sends `errors: {}`. `stats` is left out of the page
    // and computed when the client asks for it right after.
    const props = .{
        .todos = shown.items,
        .filter = filter,
        .remaining = remaining,
        .stats = zoda.plugins.inertia.deferred(store, Stats.compute),
    };
    const inertia = &ctx.plugins.inertia;
    if (text_error) |message| {
        return inertia.render(req, res, "Todos/Index", .{
            .todos = props.todos,
            .filter = props.filter,
            .remaining = props.remaining,
            .stats = props.stats,
            .errors = .{ .text = message },
        });
    }
    return inertia.render(req, res, "Todos/Index", props);
}

fn parseFilter(req: *const zoda.router.Request) Filter {
    const value = (req.getOne("filter") catch null) orelse return .all;
    return std.meta.stringToEnum(Filter, value) orelse .all;
}

/// Keeps the current filter after a mutation. Built from the enum, never from
/// request bytes, so the redirect target is always one of three local paths.
fn backTo(filter: Filter) []const u8 {
    return switch (filter) {
        .all => "/todos",
        .active => "/todos?filter=active",
        .done => "/todos?filter=done",
    };
}

const frameworks = [_][]const u8{ "react", "svelte", "vue" };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const framework = if (args.len > 1) args[1] else "react";
    for (frameworks) |known| {
        if (std.mem.eql(u8, framework, known)) break;
    } else {
        std.log.err("unknown frontend '{s}'; use react, svelte, or vue", .{framework});
        return error.UnknownFrontend;
    }

    var path_buffer: [64]u8 = undefined;
    const assets_path = try std.fmt.bufPrint(&path_buffer, "examples/inertia/{s}/dist/assets", .{framework});
    var assets = std.Io.Dir.cwd().openDir(io, assets_path, .{}) catch |err| {
        std.log.err("{s} is missing; run `npm install && npm run build` in examples/inertia/{s} first", .{ assets_path, framework });
        return err;
    };
    defer assets.close(io);
    try zoda.static.checkSupport(assets);

    // The asset version is a hash of the built bundle. Rebuild the frontend
    // and restart the server, and open tabs reload instead of mixing builds.
    const bundle = try assets.readFileAlloc(io, "app.js", allocator, .limited(16 << 20));
    defer allocator.free(bundle);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bundle, &digest, .{});
    const version = std.fmt.bytesToHex(digest[0..8], .lower);

    var store = Store{ .allocator = allocator, .io = io };
    defer store.deinit();
    const static_config: zoda.static.Config = .{
        .root = assets,
        .prefix = &.{"assets"},
        // Bundle names are not fingerprinted, so revalidate with an ETag.
        .etag = true,
    };
    var app = try App.init(allocator, .{
        .response_allocator = allocator,
        .config = .{ .name = "inertia-todo" },
        .plugins = .{
            .inertia = .{
                .layout = layout,
                .version = .{ .value = &version },
                .shared = .{ .value = .{ .app = "Zoda", .framework = framework } },
            },
            .store = .{ .value = &store },
        },
        .route_fn = route,
        .middleware = &.{zoda.static.middleware(App, &static_config)},
    });
    defer app.deinit();
    try app.plugins.inertia.validate();

    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(8080) };
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    std.log.info("serving the {s} frontend on http://localhost:8080", .{framework});
    try zoda.server.serve(App, allocator, io, &listener, &app, .{});
}

fn testApp(store: *Store) !App {
    return App.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{
            .inertia = .{ .layout = layout, .version = .{ .value = "v1" }, .shared = .{ .value = .{ .app = "Zoda", .framework = "test" } } },
            .store = .{ .value = store },
        },
        .route_fn = route,
    });
}

const inertia_get = [_]zoda.request.Header{
    .{ .name = "X-Inertia", .value = "true" },
    .{ .name = "X-Inertia-Version", .value = "v1" },
};
const inertia_json = [_]zoda.request.Header{
    .{ .name = "X-Inertia", .value = "true" },
    .{ .name = "Content-Type", .value = "application/json" },
};

fn visit(app: *const App, method: zoda.router.Method, target: []const u8, headers: []const zoda.request.Header, body: []const u8) !zoda.response.Response {
    var arena = try zoda.request.parseOriginForm(std.testing.allocator, .default, target);
    defer arena.deinit();
    try arena.copyHeaders(headers);
    try arena.copyBody(body);
    var req = arena.requestView(method);
    return app.dispatch(&req);
}

test "first visit renders the HTML shell with the page object" {
    var store = Store{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer store.deinit();
    var app = try testApp(&store);
    defer app.deinit();

    var root = try visit(&app, .get, "/", &.{}, "");
    defer root.deinit();
    try std.testing.expectEqual(@as(u16, 302), root.status_code);
    try std.testing.expectEqualStrings("/todos", (try root.getHeaderOne("Location")).?);

    var page = try visit(&app, .get, "/todos", &.{}, "");
    defer page.deinit();
    try std.testing.expectEqual(@as(u16, 200), page.status_code);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "<script type=\"module\" src=\"/assets/app.js\"></script>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body,
        \\<script data-page="app" type="application/json">{"component":"Todos/Index","props":{"app":"Zoda","framework":"test","todos":[],"filter":"all","remaining":0,"errors":{}},"url":"/todos","version":"v1","deferredProps":{"default":["stats"]},"sharedProps":["app","framework"]}</script><div id="app"></div>
    ) != null);
}

test "Inertia visits add, toggle, filter, and delete todos" {
    var store = Store{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer store.deinit();
    var app = try testApp(&store);
    defer app.deinit();

    var created = try visit(&app, .post, "/todos", &inertia_json, "{\"text\":\"  Buy milk  \"}");
    defer created.deinit();
    try std.testing.expectEqual(@as(u16, 409), created.status_code);
    try std.testing.expectEqualStrings("/todos#todo-1", (try created.getHeaderOne("X-Inertia-Redirect")).?);
    var second = try visit(&app, .post, "/todos?filter=active", &inertia_json, "{\"text\":\"Walk <dog>\"}");
    defer second.deinit();
    try std.testing.expectEqualStrings("/todos?filter=active#todo-2", (try second.getHeaderOne("X-Inertia-Redirect")).?);

    var toggled = try visit(&app, .patch, "/todos/1?filter=done", &inertia_json, "{}");
    defer toggled.deinit();
    try std.testing.expectEqual(@as(u16, 303), toggled.status_code);
    try std.testing.expectEqualStrings("/todos?filter=done", (try toggled.getHeaderOne("Location")).?);

    var active = try visit(&app, .get, "/todos?filter=active", &inertia_get, "");
    defer active.deinit();
    try std.testing.expectEqualStrings("true", (try active.getHeaderOne("X-Inertia")).?);
    try std.testing.expectEqualStrings(
        \\{"component":"Todos/Index","props":{"app":"Zoda","framework":"test","todos":[{"id":2,"text":"Walk <dog>","done":false}],"filter":"active","remaining":1,"errors":{}},"url":"/todos?filter=active","version":"v1","deferredProps":{"default":["stats"]},"sharedProps":["app","framework"]}
    , active.body);

    var deleted = try visit(&app, .delete, "/todos/2", &inertia_json, "");
    defer deleted.deinit();
    try std.testing.expectEqual(@as(u16, 303), deleted.status_code);
    var missing = try visit(&app, .delete, "/todos/2", &inertia_json, "");
    defer missing.deinit();
    try std.testing.expectEqual(@as(u16, 404), missing.status_code);

    var all = try visit(&app, .get, "/todos?filter=bogus", &inertia_get, "");
    defer all.deinit();
    try std.testing.expect(std.mem.indexOf(u8, all.body, "\"todos\":[{\"id\":1,\"text\":\"Buy milk\",\"done\":true}],\"filter\":\"all\",\"remaining\":0") != null);
}

test "validation errors re-render the page and stale clients reload" {
    var store = Store{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer store.deinit();
    var app = try testApp(&store);
    defer app.deinit();

    var blank = try visit(&app, .post, "/todos", &inertia_json, "{\"text\":\"   \"}");
    defer blank.deinit();
    try std.testing.expectEqual(@as(u16, 200), blank.status_code);
    try std.testing.expect(std.mem.indexOf(u8, blank.body, "\"errors\":{\"text\":\"Write something first.\"}") != null);
    try std.testing.expectEqual(@as(usize, 0), store.items.items.len);

    var malformed = try visit(&app, .post, "/todos", &inertia_json, "{\"title\":\"x\"}");
    defer malformed.deinit();
    try std.testing.expectEqual(@as(u16, 400), malformed.status_code);

    const stale_headers = [_]zoda.request.Header{ .{ .name = "X-Inertia", .value = "true" }, .{ .name = "X-Inertia-Version", .value = "old" } };
    var stale = try visit(&app, .get, "/todos?filter=done", &stale_headers, "");
    defer stale.deinit();
    try std.testing.expectEqual(@as(u16, 409), stale.status_code);
    try std.testing.expectEqualStrings("/todos?filter=done", (try stale.getHeaderOne("X-Inertia-Location")).?);
}

test "router.reload({ only: ['todos'] }) returns only todos and errors" {
    var store = Store{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer store.deinit();
    var app = try testApp(&store);
    defer app.deinit();
    _ = try store.add("Buy milk");

    // The headers the v3 client sends for this reload.
    const reload = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "X-Inertia-Partial-Component", .value = "Todos/Index" },
        .{ .name = "X-Inertia-Partial-Data", .value = "todos" },
    };
    var partial = try visit(&app, .get, "/todos", &reload, "");
    defer partial.deinit();
    try std.testing.expectEqualStrings(
        \\{"component":"Todos/Index","props":{"todos":[{"id":1,"text":"Buy milk","done":false}],"errors":{}},"url":"/todos","version":"v1","sharedProps":["app","framework"]}
    , partial.body);

    const bad = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Partial-Component", .value = "Todos/Index" },
        .{ .name = "X-Inertia-Partial-Data", .value = "todos,,filter" },
    };
    try std.testing.expectError(error.MalformedPartialHeader, visit(&app, .get, "/todos", &bad, ""));
}

test "the client loads deferred stats with a partial reload" {
    var store = Store{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer store.deinit();
    var app = try testApp(&store);
    defer app.deinit();
    _ = try store.add("Buy milk");
    _ = try store.add("Walk dog");
    _ = store.toggle(1);

    // The first response lists `stats` instead of sending it.
    var page = try visit(&app, .get, "/todos?filter=active", &inertia_get, "");
    defer page.deinit();
    try std.testing.expect(std.mem.indexOf(u8, page.body, "\"stats\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "\"deferredProps\":{\"default\":[\"stats\"]}") != null);

    // What `<Deferred data="stats">` makes the client send next.
    const reload = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "X-Inertia-Partial-Component", .value = "Todos/Index" },
        .{ .name = "X-Inertia-Partial-Data", .value = "stats" },
    };
    var stats = try visit(&app, .get, "/todos?filter=active", &reload, "");
    defer stats.deinit();
    try std.testing.expectEqualStrings(
        \\{"component":"Todos/Index","props":{"stats":{"total":2,"done":1},"errors":{}},"url":"/todos?filter=active","version":"v1","sharedProps":["app","framework"]}
    , stats.body);
}
