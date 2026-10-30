//! Inertia.js todo app. One Zoda server, three interchangeable frontends:
//!
//!     (cd examples/inertia/react && npm install && npm run build)
//!     zig build run-inertia -- react        # or svelte, vue
//!
//! then open http://localhost:8080. Todos live in memory, starting with a few
//! dozen samples, and are shown newest first, a page at a time, through
//! `<InfiniteScroll>`. The server serves the chosen frontend's built
//! `dist/assets` and renders every page through `zoda.Inertia`; mutations
//! redirect back with 303 so the client re-fetches the page as JSON. Adding a
//! todo flashes "Todo added" through `zoda.Flash`, sent as the page's
//! top-level `flash` on the next render; a rejected todo redirects back with
//! its validation errors stored in the session the same way. Every page asks
//! the client to encrypt the copy it keeps in browser history, and "Forget
//! history" redirects to a page that clears it. The add form validates as you
//! type through Inertia's precognition support, which the same route answers
//! without adding anything.
//!
//! With `--ssr` (React only), full visits are rendered on the server first:
//!
//!     (cd examples/inertia/react && npm run ssr)   # SSR server on :13714
//!     zig build run-inertia -- react --ssr
//!
//! If the SSR server is down or slow, pages fall back to client rendering
//! and the failure is logged.
const std = @import("std");
const zoda = @import("zoda");

pub const Todo = struct {
    id: u64,
    text: []const u8,
    done: bool = false,
};

pub const Filter = enum { all, active, done };

pub const max_text_bytes = 200;
pub const per_page = 10;
/// Sample todos `main` adds, enough for a few pages.
pub const sample_count = 25;

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
    sessions: zoda.Sessions,
    flash: zoda.Flash = .{},
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
    \\  @inertiaHead
    \\</head>
    \\<body>@inertia</body>
    \\</html>
;

pub fn route(ctx: *App.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    const inertia = &ctx.plugins.inertia;
    if (req.isRoot() and req.isGet()) return inertia.redirect(req, res, "/todos");
    const filter = parseFilter(req);
    if (req.onLiteral("history")) {
        if (!req.isRoot() or req.method != .delete) return;
        return forgetHistory(ctx, req, res, filter);
    }
    if (!req.onLiteral("todos")) return;

    const store = ctx.plugins.store.value;
    if (req.isRoot()) {
        if (req.isGet()) return renderIndex(ctx, req, res, filter);
        if (req.method != .post) return;
        var parsed = ctx.plugins.json.parse(res.allocator, req, struct { text: []const u8 }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return res.text(400, "Expected a JSON body with a text field"),
        };
        defer parsed.deinit();
        const text = std.mem.trim(u8, parsed.value.text, " \t\r\n");
        const problem = textProblem(text);
        // Live validation from `useForm(...).withPrecognition()`: answer 422
        // or 204 now, before the todo is added.
        if (try zoda.plugins.inertia.precognition(req) != null) {
            return inertia.answerPrecognition(req, res, .{ .text = problem });
        }
        if (problem) |message| return rejectTodo(ctx, req, res, filter, message);
        const id = try store.add(text);
        // Shown once, by the render that follows the redirect.
        try ctx.plugins.flash.add(&ctx.state.sessions, "notice", "Todo added");
        try ctx.plugins.sessions.save(&ctx.state.sessions, res);
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

/// Why `text` cannot be a todo, or null when it can.
fn textProblem(text: []const u8) ?[]const u8 {
    if (text.len == 0) return "Write something first.";
    if (text.len > max_text_bytes) return "Keep it under 200 bytes.";
    return null;
}

/// Redirects back to the list with `errors.text` stored in the session, which
/// the next render sends as `props.errors` once. The form posts with
/// `errorBag: 'createTodo'`, so they arrive as `errors.createTodo.text`, and
/// `useForm` reads its own bag. The destination is built from the filter
/// enum, never from `Referer`.
fn rejectTodo(
    ctx: *App.Context,
    req: *zoda.router.Request,
    res: *zoda.response.Response,
    filter: Filter,
    message: []const u8,
) !void {
    const session = &ctx.state.sessions;
    try ctx.plugins.inertia.redirectWithErrors(req, res, .{ .plugin = &ctx.plugins.flash, .session = session }, backTo(filter), .{ .text = message });
    return ctx.plugins.sessions.save(session, res);
}

/// Asks the page the redirect lands on to send `clearHistory: true`. The
/// client then deletes its history key, so Back to a page seen before makes
/// it fetch that page again instead of decrypting the stored copy. A real
/// app does this when logging out.
fn forgetHistory(
    ctx: *App.Context,
    req: *zoda.router.Request,
    res: *zoda.response.Response,
    filter: Filter,
) !void {
    const session = &ctx.state.sessions;
    try ctx.plugins.inertia.clearHistoryOnNextRender(.{ .plugin = &ctx.plugins.flash, .session = session });
    try ctx.plugins.flash.add(session, "notice", "History cleared");
    try ctx.plugins.sessions.save(session, res);
    return ctx.plugins.inertia.redirect(req, res, backTo(filter));
}

fn renderIndex(
    ctx: *App.Context,
    req: *zoda.router.Request,
    res: *zoda.response.Response,
    filter: Filter,
) !void {
    const requested = parsePage(req);
    const store = ctx.plugins.store.value;
    store.mutex.lockUncancelable(store.io);
    defer store.mutex.unlock(store.io);

    var shown: std.ArrayList(Todo) = .empty;
    defer shown.deinit(res.allocator);
    var remaining: usize = 0;
    // Newest first, so a new todo is on the first page.
    var i = store.items.items.len;
    while (i > 0) {
        i -= 1;
        const todo = store.items.items[i];
        if (!todo.done) remaining += 1;
        const keep = switch (filter) {
            .all => true,
            .active => !todo.done,
            .done => todo.done,
        };
        if (keep) try shown.append(res.allocator, todo);
    }
    // Zoda does not paginate: the route picks the page `<InfiniteScroll>`
    // asked for with `?page=` and says which pages exist around it. A page
    // past the end (an old link after deletes) shows the last one.
    const last: u32 = @intCast(@max(1, (shown.items.len + per_page - 1) / per_page));
    const page = @min(requested, last);
    const start = (page - 1) * per_page;
    // `render` copies everything into the response, so the borrowed todo
    // text only has to live while the lock is held. `stats` is left out of
    // the page and computed when the client asks for it right after.
    const props = .{
        // Matching on `id` drops a duplicate when a todo added meanwhile
        // shifts an item onto the next page.
        .todos = zoda.plugins.inertia.scroll(shown.items[start..@min(start + per_page, shown.items.len)], .{
            .previous = if (page > 1) page - 1 else null,
            .next = if (page < last) page + 1 else null,
            .current = page,
        }).matchOn("id"),
        .filter = filter,
        .remaining = remaining,
        .stats = zoda.plugins.inertia.deferred(store, Stats.compute),
    };
    const session = &ctx.state.sessions;
    // Sends pending flash messages as the page's `flash`, stored validation
    // errors as `errors` (`{}` when there are none), and a pending history
    // clear as `clearHistory`, and marks them read; the save below persists
    // that, so they are sent once.
    try ctx.plugins.inertia.renderWith(req, res, "Todos/Index", props, .{
        .flash = .{ .plugin = &ctx.plugins.flash, .session = session },
    });
    return ctx.plugins.sessions.save(session, res);
}

/// The `?page=` that `<InfiniteScroll>` sends; anything but a positive
/// number means the first page.
fn parsePage(req: *const zoda.router.Request) u32 {
    const value = (req.getOne("page") catch null) orelse return 1;
    const page = std.fmt.parseInt(u32, value, 10) catch return 1;
    return @max(page, 1);
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

/// The session clock reads the wall clock through the `Io` that `main` sets.
var clock_io: std.Io = undefined;

fn unixSeconds() i64 {
    return std.Io.Clock.real.now(clock_io).toSeconds();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const framework = if (args.len > 1) args[1] else "react";
    const ssr = args.len > 2 and std.mem.eql(u8, args[2], "--ssr");
    if (args.len > 3 or (args.len > 2 and !ssr)) {
        std.log.err("usage: run-inertia -- [react|svelte|vue] [--ssr]", .{});
        return error.InvalidArguments;
    }
    if (ssr and !std.mem.eql(u8, framework, "react")) {
        std.log.err("--ssr is only set up for the react frontend", .{});
        return error.InvalidArguments;
    }
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

    // Sessions only carry flash messages and validation errors here, so a
    // fresh key per run is enough: a restart just drops pending ones. A real app loads a
    // stable secret from its configuration.
    clock_io = io;
    var secret: [32]u8 = undefined;
    try std.Io.randomSecure(io, &secret);

    var store = Store{ .allocator = allocator, .io = io };
    defer store.deinit();
    for (1..sample_count + 1) |n| {
        var text: [32]u8 = undefined;
        _ = try store.add(try std.fmt.bufPrint(&text, "Sample todo {d}", .{n}));
    }
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
                // The client encrypts with Web Crypto, which needs HTTPS or
                // localhost, where this example runs.
                .encrypt_history = true,
                // `npm run ssr` listens on the default 127.0.0.1:13714.
                .ssr = if (ssr) .{ .timeout_ms = 500 } else null,
                .on_ssr_failure = logSsrFailure,
            },
            .sessions = .{ .keys = &.{.{ .id = 1, .secret = &secret }}, .lifetime_seconds = 60 * 60, .now_seconds = unixSeconds },
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
    std.log.info("serving the {s} frontend on http://localhost:8080{s}", .{ framework, if (ssr) " with SSR" else "" });
    try zoda.server.serve(App, allocator, io, &listener, &app, .{});
}

fn logSsrFailure(req: *const zoda.router.Request, failure: zoda.plugins.inertia.SsrFailure) void {
    std.log.warn("SSR failed for {s}: {s}; sent the client-rendered page", .{ req.target, @errorName(failure) });
}

fn testClock() i64 {
    return 1000;
}

fn testApp(store: *Store) !App {
    return App.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{
            .inertia = .{ .layout = layout, .version = .{ .value = "v1" }, .shared = .{ .value = .{ .app = "Zoda", .framework = "test" } }, .encrypt_history = true },
            .sessions = .{ .keys = &.{.{ .id = 1, .secret = "x" ** 32 }}, .lifetime_seconds = 300, .now_seconds = testClock },
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
        \\<script data-page="app" type="application/json">{"component":"Todos/Index","props":{"app":"Zoda","framework":"test","todos":[],"filter":"all","remaining":0,"errors":{}},"url":"/todos","version":"v1","encryptHistory":true,"mergeProps":["todos"],"matchPropsOn":["todos.id"],"scrollProps":{"todos":{"pageName":"page","previousPage":null,"nextPage":null,"currentPage":1,"reset":false}},"deferredProps":{"default":["stats"]},"sharedProps":["app","framework"]}</script><div id="app"></div>
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
        \\{"component":"Todos/Index","props":{"app":"Zoda","framework":"test","todos":[{"id":2,"text":"Walk <dog>","done":false}],"filter":"active","remaining":1,"errors":{}},"url":"/todos?filter=active","version":"v1","encryptHistory":true,"mergeProps":["todos"],"matchPropsOn":["todos.id"],"scrollProps":{"todos":{"pageName":"page","previousPage":null,"nextPage":null,"currentPage":1,"reset":false}},"deferredProps":{"default":["stats"]},"sharedProps":["app","framework"]}
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

test "validation errors redirect back and show once, and stale clients reload" {
    var store = Store{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer store.deinit();
    var app = try testApp(&store);
    defer app.deinit();

    // What `form.post('/todos?filter=active', { errorBag: 'createTodo' })` sends.
    const form = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "X-Inertia-Error-Bag", .value = "createTodo" },
    };
    var blank = try visit(&app, .post, "/todos?filter=active", &form, "{\"text\":\"   \"}");
    defer blank.deinit();
    try std.testing.expectEqual(@as(u16, 303), blank.status_code);
    try std.testing.expectEqualStrings("/todos?filter=active", (try blank.getHeaderOne("Location")).?);
    try std.testing.expectEqual(@as(usize, 0), store.items.items.len);

    // XHR follows with the same headers; the errors arrive under the bag.
    var followed: [form.len + 1]zoda.request.Header = undefined;
    @memcpy(followed[0..form.len], &form);
    followed[form.len] = .{ .name = "Cookie", .value = (try sessionCookie(&blank)).? };
    var shown = try visit(&app, .get, "/todos?filter=active", &followed, "");
    defer shown.deinit();
    try std.testing.expect(std.mem.indexOf(u8, shown.body, "\"errors\":{\"createTodo\":{\"text\":\"Write something first.\"}}},") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown.body, "\"flash\"") == null);

    // The saved cookie drops them, so the next visit has `errors: {}`.
    const again_headers = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "Cookie", .value = (try sessionCookie(&shown)).? },
    };
    var again = try visit(&app, .get, "/todos?filter=active", &again_headers, "");
    defer again.deinit();
    try std.testing.expect(std.mem.indexOf(u8, again.body, "\"errors\":{}},") != null);
    try std.testing.expect((try sessionCookie(&again)) == null);

    // Without a bag, an overlong todo's error is top-level.
    var long = try visit(&app, .post, "/todos", &inertia_json, "{\"text\":\"" ++ "x" ** (max_text_bytes + 1) ++ "\"}");
    defer long.deinit();
    const long_headers = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "Cookie", .value = (try sessionCookie(&long)).? },
    };
    var long_shown = try visit(&app, .get, "/todos", &long_headers, "");
    defer long_shown.deinit();
    try std.testing.expect(std.mem.indexOf(u8, long_shown.body, "\"errors\":{\"text\":\"Keep it under 200 bytes.\"}}") != null);

    const bad_bag = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "X-Inertia-Error-Bag", .value = "create todo" },
    };
    try std.testing.expectError(error.MalformedErrorBagHeader, visit(&app, .post, "/todos", &bad_bag, "{\"text\":\"\"}"));

    var malformed = try visit(&app, .post, "/todos", &inertia_json, "{\"title\":\"x\"}");
    defer malformed.deinit();
    try std.testing.expectEqual(@as(u16, 400), malformed.status_code);

    const stale_headers = [_]zoda.request.Header{ .{ .name = "X-Inertia", .value = "true" }, .{ .name = "X-Inertia-Version", .value = "old" } };
    var stale = try visit(&app, .get, "/todos?filter=done", &stale_headers, "");
    defer stale.deinit();
    try std.testing.expectEqual(@as(u16, 409), stale.status_code);
    try std.testing.expectEqualStrings("/todos?filter=done", (try stale.getHeaderOne("X-Inertia-Location")).?);
}

test "precognitive posts validate the todo without adding it" {
    var store = Store{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer store.deinit();
    var app = try testApp(&store);
    defer app.deinit();

    // What `form.validate('text')` sends after `withPrecognition('post', '/todos')`.
    const precognitive = [_]zoda.request.Header{
        .{ .name = "Precognition", .value = "true" },
        .{ .name = "Precognition-Validate-Only", .value = "text" },
        .{ .name = "Content-Type", .value = "application/json" },
    };
    var blank = try visit(&app, .post, "/todos", &precognitive, "{\"text\":\"  \"}");
    defer blank.deinit();
    try std.testing.expectEqual(@as(u16, 422), blank.status_code);
    try std.testing.expectEqualStrings("{\"errors\":{\"text\":\"Write something first.\"}}", blank.body);
    try std.testing.expectEqualStrings("true", (try blank.getHeaderOne("Precognition")).?);
    try std.testing.expectEqualStrings("Precognition", (try blank.getHeaderOne("Vary")).?);
    try std.testing.expect((try sessionCookie(&blank)) == null);

    var valid = try visit(&app, .post, "/todos", &precognitive, "{\"text\":\"Buy milk\"}");
    defer valid.deinit();
    try std.testing.expectEqual(@as(u16, 204), valid.status_code);
    try std.testing.expectEqualStrings("true", (try valid.getHeaderOne("Precognition-Success")).?);

    // A field the client did not ask about is not reported.
    const other_field = [_]zoda.request.Header{
        .{ .name = "Precognition", .value = "true" },
        .{ .name = "Precognition-Validate-Only", .value = "due" },
        .{ .name = "Content-Type", .value = "application/json" },
    };
    var unlisted = try visit(&app, .post, "/todos", &other_field, "{\"text\":\"\"}");
    defer unlisted.deinit();
    try std.testing.expectEqual(@as(u16, 204), unlisted.status_code);
    try std.testing.expectEqual(@as(usize, 0), store.items.items.len);

    const duplicate = [_]zoda.request.Header{
        .{ .name = "Precognition", .value = "true" },
        .{ .name = "Precognition", .value = "true" },
        .{ .name = "Content-Type", .value = "application/json" },
    };
    try std.testing.expectError(error.DuplicatePrecognitionHeader, visit(&app, .post, "/todos", &duplicate, "{\"text\":\"x\"}"));
    try std.testing.expectEqual(@as(usize, 0), store.items.items.len);
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
        \\{"component":"Todos/Index","props":{"todos":[{"id":1,"text":"Buy milk","done":false}],"errors":{}},"url":"/todos","version":"v1","encryptHistory":true,"mergeProps":["todos"],"matchPropsOn":["todos.id"],"scrollProps":{"todos":{"pageName":"page","previousPage":null,"nextPage":null,"currentPage":1,"reset":false}},"sharedProps":["app","framework"]}
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
        \\{"component":"Todos/Index","props":{"stats":{"total":2,"done":1},"errors":{}},"url":"/todos?filter=active","version":"v1","encryptHistory":true,"sharedProps":["app","framework"]}
    , stats.body);
}

test "<InfiniteScroll> pages through todos newest first and resets after a change" {
    var store = Store{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer store.deinit();
    var app = try testApp(&store);
    defer app.deinit();
    for (0..per_page + 2) |_| _ = try store.add("x");

    var first = try visit(&app, .get, "/todos", &inertia_get, "");
    defer first.deinit();
    try std.testing.expect(std.mem.indexOf(u8, first.body, "\"todos\":[{\"id\":12,") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.body,
        \\"mergeProps":["todos"],"matchPropsOn":["todos.id"],"scrollProps":{"todos":{"pageName":"page","previousPage":null,"nextPage":2,"currentPage":1,"reset":false}}
    ) != null);

    // What the "Show more" button sends.
    const more = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "X-Inertia-Partial-Component", .value = "Todos/Index" },
        .{ .name = "X-Inertia-Partial-Data", .value = "todos" },
        .{ .name = "X-Inertia-Infinite-Scroll-Merge-Intent", .value = "append" },
    };
    var second = try visit(&app, .get, "/todos?page=2", &more, "");
    defer second.deinit();
    try std.testing.expectEqualStrings(
        \\{"component":"Todos/Index","props":{"todos":[{"id":2,"text":"x","done":false},{"id":1,"text":"x","done":false}],"errors":{}},"url":"/todos?page=2","version":"v1","encryptHistory":true,"mergeProps":["todos"],"matchPropsOn":["todos.id"],"scrollProps":{"todos":{"pageName":"page","previousPage":1,"nextPage":null,"currentPage":2,"reset":false}},"sharedProps":["app","framework"]}
    , second.body);

    // Opening `?page=2` directly, then "Show earlier", prepends page 1. A
    // page past the end shows the last one.
    const earlier = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "X-Inertia-Partial-Component", .value = "Todos/Index" },
        .{ .name = "X-Inertia-Partial-Data", .value = "todos" },
        .{ .name = "X-Inertia-Infinite-Scroll-Merge-Intent", .value = "prepend" },
    };
    var before = try visit(&app, .get, "/todos", &earlier, "");
    defer before.deinit();
    try std.testing.expect(std.mem.indexOf(u8, before.body, "\"prependProps\":[\"todos\"]") != null);
    var past = try visit(&app, .get, "/todos?page=9", &inertia_get, "");
    defer past.deinit();
    try std.testing.expect(std.mem.indexOf(u8, past.body, "\"previousPage\":1,\"nextPage\":null,\"currentPage\":2") != null);

    // A toggle sent with `only` and `reset: ['todos']`: XHR repeats the
    // headers on the 303's GET, which replaces the list and resets paging.
    const reset = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "X-Inertia-Partial-Component", .value = "Todos/Index" },
        .{ .name = "X-Inertia-Partial-Data", .value = "todos,remaining,stats,todos" },
        .{ .name = "X-Inertia-Reset", .value = "todos" },
    };
    var toggled = try visit(&app, .patch, "/todos/12", &reset, "");
    defer toggled.deinit();
    try std.testing.expectEqualStrings("/todos", (try toggled.getHeaderOne("Location")).?);
    var back = try visit(&app, .get, "/todos", &reset, "");
    defer back.deinit();
    try std.testing.expect(std.mem.indexOf(u8, back.body, "\"remaining\":11,\"stats\":{\"total\":12,\"done\":1},\"errors\":{}},") != null);
    try std.testing.expect(std.mem.indexOf(u8, back.body, "\"mergeProps\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, back.body, "\"nextPage\":2,\"currentPage\":1,\"reset\":true") != null);
}

/// The session cookie a response sets, without its attributes.
fn sessionCookie(res: *const zoda.response.Response) !?[]const u8 {
    const set_cookie = (try res.getHeaderOne("Set-Cookie")) orelse return null;
    return set_cookie[0..std.mem.indexOfScalar(u8, set_cookie, ';').?];
}

test "adding a todo flashes a notice that the next render shows once" {
    var store = Store{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer store.deinit();
    var app = try testApp(&store);
    defer app.deinit();

    // The form posts with `only` and `reset`, which XHR repeats on the GET
    // that follows the redirect, so that partial reload carries the flash.
    const form = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "X-Inertia-Partial-Component", .value = "Todos/Index" },
        .{ .name = "X-Inertia-Partial-Data", .value = "todos,remaining,stats" },
        .{ .name = "X-Inertia-Reset", .value = "todos" },
    };
    var created = try visit(&app, .post, "/todos", &form, "{\"text\":\"Buy milk\"}");
    defer created.deinit();
    try std.testing.expectEqualStrings("/todos#todo-1", (try created.getHeaderOne("X-Inertia-Redirect")).?);
    const pending = (try sessionCookie(&created)).?;

    var with_cookie: [form.len + 1]zoda.request.Header = undefined;
    @memcpy(with_cookie[0..form.len], &form);
    with_cookie[form.len] = .{ .name = "Cookie", .value = pending };
    var shown = try visit(&app, .get, "/todos", &with_cookie, "");
    defer shown.deinit();
    try std.testing.expect(std.mem.endsWith(u8, shown.body, ",\"flash\":{\"notice\":\"Todo added\"}}"));
    const read = (try sessionCookie(&shown)).?;

    // The saved cookie no longer holds the message.
    const again_headers = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "Cookie", .value = read },
    };
    var again = try visit(&app, .get, "/todos", &again_headers, "");
    defer again.deinit();
    try std.testing.expect(std.mem.indexOf(u8, again.body, "\"flash\"") == null);
    try std.testing.expect((try sessionCookie(&again)) == null);

    // A rejected todo stores only its errors, so the page that follows has
    // no `flash`.
    var blank = try visit(&app, .post, "/todos", &inertia_json, "{\"text\":\" \"}");
    defer blank.deinit();
    const rejected = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "Cookie", .value = (try sessionCookie(&blank)).? },
    };
    var back = try visit(&app, .get, "/todos", &rejected, "");
    defer back.deinit();
    try std.testing.expect(std.mem.indexOf(u8, back.body, "\"flash\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, back.body, "\"errors\":{\"text\":\"Write something first.\"}") != null);
}

test "Forget history redirects to a page that clears it once" {
    var store = Store{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer store.deinit();
    var app = try testApp(&store);
    defer app.deinit();

    // What `router.delete('/history?filter=active')` sends.
    var forgot = try visit(&app, .delete, "/history?filter=active", &inertia_json, "");
    defer forgot.deinit();
    try std.testing.expectEqual(@as(u16, 303), forgot.status_code);
    try std.testing.expectEqualStrings("/todos?filter=active", (try forgot.getHeaderOne("Location")).?);

    const followed = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "Cookie", .value = (try sessionCookie(&forgot)).? },
    };
    var cleared = try visit(&app, .get, "/todos?filter=active", &followed, "");
    defer cleared.deinit();
    try std.testing.expect(std.mem.indexOf(u8, cleared.body, "\"version\":\"v1\",\"encryptHistory\":true,\"clearHistory\":true,") != null);
    try std.testing.expect(std.mem.endsWith(u8, cleared.body, ",\"flash\":{\"notice\":\"History cleared\"}}"));

    // The saved cookie drops the request, so later pages stay encrypted
    // without clearing again.
    const again_headers = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "Cookie", .value = (try sessionCookie(&cleared)).? },
    };
    var again = try visit(&app, .get, "/todos?filter=active", &again_headers, "");
    defer again.deinit();
    try std.testing.expect(std.mem.indexOf(u8, again.body, "\"encryptHistory\":true,") != null);
    try std.testing.expect(std.mem.indexOf(u8, again.body, "clearHistory") == null);

    var get = try visit(&app, .get, "/history", &inertia_get, "");
    defer get.deinit();
    try std.testing.expectEqual(@as(u16, 404), get.status_code);
}
