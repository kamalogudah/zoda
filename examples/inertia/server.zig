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
//! without adding anything. Every page sets an `XSRF-TOKEN` cookie bound to
//! the session, which the Inertia client sends back as `X-XSRF-TOKEN` on
//! each change, and every change is refused without it.
//!
//! The page also shows the rest of the protocol: the input limits are a once
//! prop, the server details a deferred once prop, the activity log an
//! optional deep-merge prop loaded on demand, the remaining count an always
//! prop, and "Refresh counts" an `except` reload. Activity entries link to
//! `/todos/<id>#todo-<id>`, which redirects to the page holding the todo and
//! keeps the fragment through `preserveFragment`, or renders a 404 page for
//! a deleted one. Filter links are prefetched on hover.
//!
//! With `--ssr` (React only), full visits are rendered on the server first:
//!
//!     (cd examples/inertia/react && npm run ssr)   # SSR server on :13714
//!     zig build run-inertia -- react --ssr
//!
//! If the SSR server is down or slow, pages fall back to client rendering
//! and the failure is logged.
const std = @import("std");
const builtin = @import("builtin");
const zoda = @import("zoda");
const inertia_props = zoda.plugins.inertia;
const csrf = zoda.plugins.csrf;

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
/// Activity entries the store keeps; older ones are dropped.
pub const max_events = 50;
/// Entries the activity log shows when it is first opened.
pub const recent_events = 10;

/// One change to the list, for the activity log. `todo` is the id of the
/// todo it changed, which may since have been deleted.
pub const Event = struct {
    id: u64,
    todo: u64,
    text: []const u8,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(Todo) = .empty,
    next_id: u64 = 1,
    events: std.ArrayList(Event) = .empty,
    next_event: u64 = 1,
    /// When the server started, in Unix milliseconds, for the `about` prop.
    started_ms: i64 = 0,

    pub fn deinit(self: *Store) void {
        for (self.items.items) |item| self.allocator.free(item.text);
        self.items.deinit(self.allocator);
        for (self.events.items) |event| self.allocator.free(event.text);
        self.events.deinit(self.allocator);
    }

    fn add(self: *Store, text: []const u8) !u64 {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.items.ensureUnusedCapacity(self.allocator, 1);
        try self.record(self.next_id, "Added", text);
        self.items.appendAssumeCapacity(.{ .id = self.next_id, .text = owned });
        self.next_id += 1;
        return self.next_id - 1;
    }

    fn toggle(self: *Store, id: u64) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.items.items) |*item| {
            if (item.id == id) {
                try self.record(id, if (item.done) "Reopened" else "Completed", item.text);
                item.done = !item.done;
                return true;
            }
        }
        return false;
    }

    fn delete(self: *Store, id: u64) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.items.items, 0..) |item, i| {
            if (item.id == id) {
                try self.record(id, "Deleted", item.text);
                self.allocator.free(item.text);
                _ = self.items.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Appends an activity entry, dropping the oldest past `max_events`.
    /// Called with the lock held.
    fn record(self: *Store, todo: u64, verb: []const u8, text: []const u8) !void {
        const line = try std.fmt.allocPrint(self.allocator, "{s} \"{s}\"", .{ verb, text });
        errdefer self.allocator.free(line);
        try self.events.append(self.allocator, .{ .id = self.next_event, .todo = todo, .text = line });
        self.next_event += 1;
        if (self.events.items.len > max_events) self.allocator.free(self.events.orderedRemove(0).text);
    }

    /// The page of the unfiltered, newest-first list that holds `id`.
    fn pageOf(self: *Store, id: u64) ?u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.items.items, 0..) |item, i| {
            if (item.id == id) return @intCast((self.items.items.len - 1 - i) / per_page + 1);
        }
        return null;
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

/// Limits the add form shows. A once prop: they never change while the
/// server runs, so the client keeps them after the first page.
pub const Limits = struct {
    max_text_bytes: usize = max_text_bytes,
    per_page: usize = per_page,

    fn get(_: void, _: std.mem.Allocator) Limits {
        return .{};
    }
};

/// Server details for the footer. A deferred once prop: it stands in for
/// something slow to compute that rarely changes, so the client loads it
/// after the page renders and then keeps it for a few minutes.
pub const About = struct {
    zig: []const u8,
    started_ms: i64,

    fn get(store: *Store, _: std.mem.Allocator) About {
        return .{ .zig = builtin.zig_version_string, .started_ms = store.started_ms };
    }
};

/// The activity log: the entries after `after`, or the latest
/// `recent_events` when `after` is 0, and how many changes there have been.
/// An optional prop deep-merged on the client, so each check appends only
/// the new entries to `events`, matched on `id`, and replaces `total`.
pub const Activity = struct {
    events: []const Event,
    total: u64,

    const Query = struct { store: *Store, after: u64 };

    /// Runs inside `render`, which `renderIndex` calls with the store lock
    /// held; the entries are borrowed until the page is serialized.
    fn get(query: Query, _: std.mem.Allocator) Activity {
        const events = query.store.events.items;
        const start = if (query.after == 0)
            events.len -| recent_events
        else for (events, 0..) |event, i| {
            if (event.id > query.after) break i;
        } else events.len;
        return .{ .events = events[start..], .total = query.store.next_event - 1 };
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
    // Every change, precognitive validation included, must carry the token
    // from the `XSRF-TOKEN` cookie, which only script on this origin can
    // read. The check comes before the body is parsed.
    if (req.method != .get and req.method != .head and !csrf.validHeader(req, &ctx.state.sessions, csrf.xsrf_header_name)) {
        return res.text(403, "Missing or stale CSRF token; reload the page.");
    }
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
        .get => return showTodo(ctx, req, res, id),
        .patch => try store.toggle(id),
        .delete => try store.delete(id),
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

/// A link to one todo, `/todos/<id>#todo-<id>` from the activity log:
/// redirects to the unfiltered page that holds it, or renders a 404 page
/// when it has been deleted. XHR drops the requested fragment when it follows
/// the redirect; the page it lands on sends `preserveFragment`, so the client
/// puts it back and scrolls to the todo.
fn showTodo(
    ctx: *App.Context,
    req: *zoda.router.Request,
    res: *zoda.response.Response,
    id: u64,
) !void {
    const inertia = &ctx.plugins.inertia;
    const page = ctx.plugins.store.value.pageOf(id) orelse {
        // An Inertia page with status 404: the v3 client fires its
        // `httpException` event and then shows it instead of a dialog.
        return inertia.renderWith(req, res, "Errors/NotFound", .{ .id = id }, .{ .status = 404 });
    };
    if (page == 1) return inertia.redirect(req, res, "/todos");
    var buffer: [32]u8 = undefined;
    return inertia.redirect(req, res, try std.fmt.bufPrint(&buffer, "/todos?page={d}", .{page}));
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
        // Sent on every reload, even one that asks only for other props, so
        // the count never goes stale.
        .remaining = inertia_props.always(remaining),
        .stats = inertia_props.deferred(store, Stats.compute),
        // Resolved on the first visit; later visits say the client holds it.
        .limits = inertia_props.once({}, Limits.get),
        // Loaded right after the first page, then kept for five minutes
        // under the key "server".
        .about = inertia_props.deferred(store, About.get).once().as("server").expiresIn(5 * 60 * 1000),
        // Only sent when "Show activity" asks for it.
        .activity = inertia_props.deepMerge(inertia_props.optional(
            Activity.Query{ .store = store, .after = activityAfter(req) },
            Activity.get,
        )).matchOn("events.id"),
    };
    const session = &ctx.state.sessions;
    // The first page of a session creates its token, which the save below
    // persists. The cookie is set on every page, so a browser that lost it
    // gets it back with the next visit.
    try csrf.setXsrfCookie(res, try csrf.token(store.io, session));
    // Sends pending flash messages as the page's `flash`, stored validation
    // errors as `errors` (`{}` when there are none), and a pending history
    // clear as `clearHistory`, and marks them read; the save below persists
    // that, so they are sent once.
    try ctx.plugins.inertia.renderWith(req, res, "Todos/Index", props, .{
        .flash = .{ .plugin = &ctx.plugins.flash, .session = session },
        // Keeps the `#todo-<id>` of a link that `showTodo` redirected here.
        .preserve_fragment = true,
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

/// `X-Activity-After`, the id of the last activity entry the client has, which
/// "Check for new" sends; 0 when absent or malformed.
fn activityAfter(req: *const zoda.router.Request) u64 {
    const value = (req.getHeaderOne("X-Activity-After") catch null) orelse return 0;
    return std.fmt.parseInt(u64, value, 10) catch 0;
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

/// The once-prop clock, for `expiresAt`.
fn unixMilliseconds() i64 {
    return std.Io.Clock.real.now(clock_io).toMilliseconds();
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

    // Sessions only carry flash messages, validation errors, and the CSRF
    // secret here, so a fresh key per run is enough: a restart drops pending
    // messages, and an open tab's next change is refused until it reloads.
    // A real app loads a stable secret from its configuration.
    clock_io = io;
    var secret: [32]u8 = undefined;
    try std.Io.randomSecure(io, &secret);

    var store = Store{ .allocator = allocator, .io = io, .started_ms = unixMilliseconds() };
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
                .now_milliseconds = unixMilliseconds,
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

fn testMilliseconds() i64 {
    return 1_000_000;
}

fn testApp(store: *Store) !App {
    return App.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{
            .inertia = .{ .layout = layout, .version = .{ .value = "v1" }, .shared = .{ .value = .{ .app = "Zoda", .framework = "test" } }, .encrypt_history = true, .now_milliseconds = testMilliseconds },
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

/// What a browser holds after its first page: the session cookie and the
/// `XSRF-TOKEN` value the Inertia client copies into `X-XSRF-TOKEN`.
const Browser = struct {
    cookie_buffer: [4096]u8 = undefined,
    cookie_len: usize = 0,
    token: [csrf.token_bytes]u8 = undefined,

    fn open(app: *const App) !Browser {
        var page = try visit(app, .get, "/todos", &.{}, "");
        defer page.deinit();
        var browser: Browser = .{};
        const session = sessionCookie(&page).?;
        @memcpy(browser.cookie_buffer[0..session.len], session);
        browser.cookie_len = session.len;
        const xsrf = setCookie(&page, csrf.xsrf_cookie_name).?;
        @memcpy(&browser.token, xsrf[csrf.xsrf_cookie_name.len + 1 ..]);
        return browser;
    }

    fn cookie(self: *const Browser) []const u8 {
        return self.cookie_buffer[0..self.cookie_len];
    }

    /// `headers` plus the session cookie and the CSRF header.
    fn with(self: *const Browser, headers: anytype) [headers.len + 2]zoda.request.Header {
        var out: [headers.len + 2]zoda.request.Header = undefined;
        @memcpy(out[0..headers.len], &headers);
        out[headers.len] = .{ .name = "Cookie", .value = self.cookie() };
        out[headers.len + 1] = .{ .name = csrf.xsrf_header_name, .value = &self.token };
        return out;
    }
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
        \\<script data-page="app" type="application/json">{"component":"Todos/Index","props":{"app":"Zoda","framework":"test","todos":[],"filter":"all","remaining":0,"limits":{"max_text_bytes":200,"per_page":10},"errors":{}},"url":"/todos","version":"v1","encryptHistory":true,"preserveFragment":true,"mergeProps":["todos"],"matchPropsOn":["todos.id"],"scrollProps":{"todos":{"pageName":"page","previousPage":null,"nextPage":null,"currentPage":1,"reset":false}},"deferredProps":{"default":["stats","about"]},"onceProps":{"limits":{"prop":"limits","expiresAt":null},"server":{"prop":"about","expiresAt":1300000}},"sharedProps":["app","framework"]}</script><div id="app"></div>
    ) != null);
}

test "Inertia visits add, toggle, filter, and delete todos" {
    var store = Store{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer store.deinit();
    var app = try testApp(&store);
    defer app.deinit();
    var browser = try Browser.open(&app);

    var created = try visit(&app, .post, "/todos", &browser.with(inertia_json), "{\"text\":\"  Buy milk  \"}");
    defer created.deinit();
    try std.testing.expectEqual(@as(u16, 409), created.status_code);
    try std.testing.expectEqualStrings("/todos#todo-1", (try created.getHeaderOne("X-Inertia-Redirect")).?);
    var second = try visit(&app, .post, "/todos?filter=active", &browser.with(inertia_json), "{\"text\":\"Walk <dog>\"}");
    defer second.deinit();
    try std.testing.expectEqualStrings("/todos?filter=active#todo-2", (try second.getHeaderOne("X-Inertia-Redirect")).?);

    var toggled = try visit(&app, .patch, "/todos/1?filter=done", &browser.with(inertia_json), "{}");
    defer toggled.deinit();
    try std.testing.expectEqual(@as(u16, 303), toggled.status_code);
    try std.testing.expectEqualStrings("/todos?filter=done", (try toggled.getHeaderOne("Location")).?);

    var active = try visit(&app, .get, "/todos?filter=active", &inertia_get, "");
    defer active.deinit();
    try std.testing.expectEqualStrings("true", (try active.getHeaderOne("X-Inertia")).?);
    try std.testing.expectEqualStrings(
        \\{"component":"Todos/Index","props":{"app":"Zoda","framework":"test","todos":[{"id":2,"text":"Walk <dog>","done":false}],"filter":"active","remaining":1,"limits":{"max_text_bytes":200,"per_page":10},"errors":{}},"url":"/todos?filter=active","version":"v1","encryptHistory":true,"preserveFragment":true,"mergeProps":["todos"],"matchPropsOn":["todos.id"],"scrollProps":{"todos":{"pageName":"page","previousPage":null,"nextPage":null,"currentPage":1,"reset":false}},"deferredProps":{"default":["stats","about"]},"onceProps":{"limits":{"prop":"limits","expiresAt":null},"server":{"prop":"about","expiresAt":1300000}},"sharedProps":["app","framework"]}
    , active.body);

    var deleted = try visit(&app, .delete, "/todos/2", &browser.with(inertia_json), "");
    defer deleted.deinit();
    try std.testing.expectEqual(@as(u16, 303), deleted.status_code);
    var missing = try visit(&app, .delete, "/todos/2", &browser.with(inertia_json), "");
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
    var browser = try Browser.open(&app);

    // What `form.post('/todos?filter=active', { errorBag: 'createTodo' })` sends.
    const form = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "X-Inertia-Error-Bag", .value = "createTodo" },
    };
    var blank = try visit(&app, .post, "/todos?filter=active", &browser.with(form), "{\"text\":\"   \"}");
    defer blank.deinit();
    try std.testing.expectEqual(@as(u16, 303), blank.status_code);
    try std.testing.expectEqualStrings("/todos?filter=active", (try blank.getHeaderOne("Location")).?);
    try std.testing.expectEqual(@as(usize, 0), store.items.items.len);

    // XHR follows with the same headers; the errors arrive under the bag.
    var followed: [form.len + 1]zoda.request.Header = undefined;
    @memcpy(followed[0..form.len], &form);
    followed[form.len] = .{ .name = "Cookie", .value = sessionCookie(&blank).? };
    var shown = try visit(&app, .get, "/todos?filter=active", &followed, "");
    defer shown.deinit();
    try std.testing.expect(std.mem.indexOf(u8, shown.body, "\"errors\":{\"createTodo\":{\"text\":\"Write something first.\"}}},") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown.body, "\"flash\"") == null);

    // The saved cookie drops them, so the next visit has `errors: {}`.
    const again_headers = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "Cookie", .value = sessionCookie(&shown).? },
    };
    var again = try visit(&app, .get, "/todos?filter=active", &again_headers, "");
    defer again.deinit();
    try std.testing.expect(std.mem.indexOf(u8, again.body, "\"errors\":{}},") != null);
    try std.testing.expect(sessionCookie(&again) == null);

    // Without a bag, an overlong todo's error is top-level.
    var long = try visit(&app, .post, "/todos", &browser.with(inertia_json), "{\"text\":\"" ++ "x" ** (max_text_bytes + 1) ++ "\"}");
    defer long.deinit();
    const long_headers = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "Cookie", .value = sessionCookie(&long).? },
    };
    var long_shown = try visit(&app, .get, "/todos", &long_headers, "");
    defer long_shown.deinit();
    try std.testing.expect(std.mem.indexOf(u8, long_shown.body, "\"errors\":{\"text\":\"Keep it under 200 bytes.\"}}") != null);

    const bad_bag = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "X-Inertia-Error-Bag", .value = "create todo" },
    };
    try std.testing.expectError(error.MalformedErrorBagHeader, visit(&app, .post, "/todos", &browser.with(bad_bag), "{\"text\":\"\"}"));

    var malformed = try visit(&app, .post, "/todos", &browser.with(inertia_json), "{\"title\":\"x\"}");
    defer malformed.deinit();
    try std.testing.expectEqual(@as(u16, 400), malformed.status_code);

    const stale_headers = [_]zoda.request.Header{ .{ .name = "X-Inertia", .value = "true" }, .{ .name = "X-Inertia-Version", .value = "old" } };
    var stale = try visit(&app, .get, "/todos?filter=done", &stale_headers, "");
    defer stale.deinit();
    try std.testing.expectEqual(@as(u16, 409), stale.status_code);
    try std.testing.expectEqualStrings("/todos?filter=done", (try stale.getHeaderOne("X-Inertia-Location")).?);
}

test "changes need the XSRF-TOKEN cookie's value in X-XSRF-TOKEN" {
    var store = Store{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer store.deinit();
    var app = try testApp(&store);
    defer app.deinit();

    // The first page sets the cookie for script: no `HttpOnly`.
    var page = try visit(&app, .get, "/todos", &.{}, "");
    defer page.deinit();
    var it = page.getAllHeaders("Set-Cookie");
    var xsrf_field: ?[]const u8 = null;
    while (it.next()) |field| {
        if (std.mem.startsWith(u8, field, csrf.xsrf_cookie_name ++ "=")) xsrf_field = field;
    }
    try std.testing.expect(std.mem.endsWith(u8, xsrf_field.?, "; Path=/; Secure; SameSite=Lax"));

    var browser = try Browser.open(&app);
    // No token, the token in the old `X-CSRF-Token` header, a token from
    // another session, and a repeated header are all refused before parsing.
    const no_token = [_]zoda.request.Header{ inertia_json[0], inertia_json[1], .{ .name = "Cookie", .value = browser.cookie() } };
    const old_header = [_]zoda.request.Header{ inertia_json[0], inertia_json[1], .{ .name = "Cookie", .value = browser.cookie() }, .{ .name = csrf.header_name, .value = &browser.token } };
    var other = try Browser.open(&app);
    const foreign = [_]zoda.request.Header{ inertia_json[0], inertia_json[1], .{ .name = "Cookie", .value = browser.cookie() }, .{ .name = csrf.xsrf_header_name, .value = &other.token } };
    const repeated = browser.with([_]zoda.request.Header{ inertia_json[0], inertia_json[1], .{ .name = csrf.xsrf_header_name, .value = &browser.token } });
    inline for (.{ &no_token, &old_header, &foreign, &repeated }) |headers| {
        var refused = try visit(&app, .post, "/todos", headers, "{\"text\":\"Buy milk\"}");
        defer refused.deinit();
        try std.testing.expectEqual(@as(u16, 403), refused.status_code);
    }
    var deleted = try visit(&app, .delete, "/history", &no_token, "");
    defer deleted.deinit();
    try std.testing.expectEqual(@as(u16, 403), deleted.status_code);
    try std.testing.expectEqual(@as(usize, 0), store.items.items.len);

    var accepted = try visit(&app, .post, "/todos", &browser.with(inertia_json), "{\"text\":\"Buy milk\"}");
    defer accepted.deinit();
    try std.testing.expectEqual(@as(u16, 409), accepted.status_code);
    try std.testing.expectEqual(@as(usize, 1), store.items.items.len);
}

test "precognitive posts validate the todo without adding it" {
    var store = Store{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer store.deinit();
    var app = try testApp(&store);
    defer app.deinit();
    var browser = try Browser.open(&app);

    // What `form.validate('text')` sends after `withPrecognition('post', '/todos')`.
    const precognitive = [_]zoda.request.Header{
        .{ .name = "Precognition", .value = "true" },
        .{ .name = "Precognition-Validate-Only", .value = "text" },
        .{ .name = "Content-Type", .value = "application/json" },
    };
    var blank = try visit(&app, .post, "/todos", &browser.with(precognitive), "{\"text\":\"  \"}");
    defer blank.deinit();
    try std.testing.expectEqual(@as(u16, 422), blank.status_code);
    try std.testing.expectEqualStrings("{\"errors\":{\"text\":\"Write something first.\"}}", blank.body);
    try std.testing.expectEqualStrings("true", (try blank.getHeaderOne("Precognition")).?);
    try std.testing.expectEqualStrings("Precognition", (try blank.getHeaderOne("Vary")).?);
    try std.testing.expect(sessionCookie(&blank) == null);

    var valid = try visit(&app, .post, "/todos", &browser.with(precognitive), "{\"text\":\"Buy milk\"}");
    defer valid.deinit();
    try std.testing.expectEqual(@as(u16, 204), valid.status_code);
    try std.testing.expectEqualStrings("true", (try valid.getHeaderOne("Precognition-Success")).?);

    // A field the client did not ask about is not reported.
    const other_field = [_]zoda.request.Header{
        .{ .name = "Precognition", .value = "true" },
        .{ .name = "Precognition-Validate-Only", .value = "due" },
        .{ .name = "Content-Type", .value = "application/json" },
    };
    var unlisted = try visit(&app, .post, "/todos", &browser.with(other_field), "{\"text\":\"\"}");
    defer unlisted.deinit();
    try std.testing.expectEqual(@as(u16, 204), unlisted.status_code);
    try std.testing.expectEqual(@as(usize, 0), store.items.items.len);

    const duplicate = [_]zoda.request.Header{
        .{ .name = "Precognition", .value = "true" },
        .{ .name = "Precognition", .value = "true" },
        .{ .name = "Content-Type", .value = "application/json" },
    };
    try std.testing.expectError(error.DuplicatePrecognitionHeader, visit(&app, .post, "/todos", &browser.with(duplicate), "{\"text\":\"x\"}"));
    try std.testing.expectEqual(@as(usize, 0), store.items.items.len);
}

test "router.reload({ only: ['todos'] }) returns todos and the always props" {
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
        \\{"component":"Todos/Index","props":{"todos":[{"id":1,"text":"Buy milk","done":false}],"remaining":1,"errors":{}},"url":"/todos","version":"v1","encryptHistory":true,"preserveFragment":true,"mergeProps":["todos"],"matchPropsOn":["todos.id"],"scrollProps":{"todos":{"pageName":"page","previousPage":null,"nextPage":null,"currentPage":1,"reset":false}},"sharedProps":["app","framework"]}
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
    _ = try store.toggle(1);

    // The first response lists `stats` instead of sending it.
    var page = try visit(&app, .get, "/todos?filter=active", &inertia_get, "");
    defer page.deinit();
    try std.testing.expect(std.mem.indexOf(u8, page.body, "\"stats\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "\"deferredProps\":{\"default\":[\"stats\",\"about\"]}") != null);

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
        \\{"component":"Todos/Index","props":{"remaining":1,"stats":{"total":2,"done":1},"errors":{}},"url":"/todos?filter=active","version":"v1","encryptHistory":true,"preserveFragment":true,"sharedProps":["app","framework"]}
    , stats.body);
}

test "<InfiniteScroll> pages through todos newest first and resets after a change" {
    var store = Store{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer store.deinit();
    var app = try testApp(&store);
    defer app.deinit();
    var browser = try Browser.open(&app);
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
        \\{"component":"Todos/Index","props":{"todos":[{"id":2,"text":"x","done":false},{"id":1,"text":"x","done":false}],"remaining":12,"errors":{}},"url":"/todos?page=2","version":"v1","encryptHistory":true,"preserveFragment":true,"mergeProps":["todos"],"matchPropsOn":["todos.id"],"scrollProps":{"todos":{"pageName":"page","previousPage":1,"nextPage":null,"currentPage":2,"reset":false}},"sharedProps":["app","framework"]}
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
    var toggled = try visit(&app, .patch, "/todos/12", &browser.with(reset), "");
    defer toggled.deinit();
    try std.testing.expectEqualStrings("/todos", (try toggled.getHeaderOne("Location")).?);
    var back = try visit(&app, .get, "/todos", &reset, "");
    defer back.deinit();
    try std.testing.expect(std.mem.indexOf(u8, back.body, "\"remaining\":11,\"stats\":{\"total\":12,\"done\":1},\"errors\":{}},") != null);
    try std.testing.expect(std.mem.indexOf(u8, back.body, "\"mergeProps\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, back.body, "\"nextPage\":2,\"currentPage\":1,\"reset\":true") != null);
}

test "once and deferred once props are sent until the client holds them" {
    var store = Store{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer store.deinit();
    var app = try testApp(&store);
    defer app.deinit();

    const entries = "\"onceProps\":{\"limits\":{\"prop\":\"limits\",\"expiresAt\":null},\"server\":{\"prop\":\"about\",\"expiresAt\":1300000}}";
    var first = try visit(&app, .get, "/todos", &inertia_get, "");
    defer first.deinit();
    try std.testing.expect(std.mem.indexOf(u8, first.body, "\"limits\":{\"max_text_bytes\":200,\"per_page\":10}") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.body, "\"deferredProps\":{\"default\":[\"stats\",\"about\"]}," ++ entries) != null);

    // The deferred reload `<Deferred data="about">` makes, both props in
    // the "default" group.
    const deferred = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "X-Inertia-Partial-Component", .value = "Todos/Index" },
        .{ .name = "X-Inertia-Partial-Data", .value = "stats,about" },
        .{ .name = "X-Inertia-Except-Once-Props", .value = "limits" },
    };
    var loaded = try visit(&app, .get, "/todos", &deferred, "");
    defer loaded.deinit();
    try std.testing.expect(std.mem.indexOf(u8, loaded.body, "\"about\":{\"zig\":\"" ++ builtin.zig_version_string ++ "\",\"started_ms\":0}") != null);
    try std.testing.expect(std.mem.indexOf(u8, loaded.body, "\"onceProps\":{\"server\":{\"prop\":\"about\",\"expiresAt\":1300000}}") != null);

    // Later visits, while the client holds both: neither is sent, `about`
    // is not deferred again, and the entries stay.
    const later = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "X-Inertia-Except-Once-Props", .value = "limits,server" },
    };
    var held = try visit(&app, .get, "/todos?filter=done", &later, "");
    defer held.deinit();
    try std.testing.expect(std.mem.indexOf(u8, held.body, "\"limits\":{\"max") == null);
    try std.testing.expect(std.mem.indexOf(u8, held.body, "\"deferredProps\":{\"default\":[\"stats\"]}," ++ entries) != null);
}

test "the activity log loads on demand and deep-merges only new entries" {
    var store = Store{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer store.deinit();
    var app = try testApp(&store);
    defer app.deinit();
    _ = try store.add("Buy milk");
    _ = try store.add("Walk dog");
    _ = try store.toggle(1);

    var page = try visit(&app, .get, "/todos", &inertia_get, "");
    defer page.deinit();
    try std.testing.expect(std.mem.indexOf(u8, page.body, "activity") == null);

    // "Show activity": `router.reload({ only: ['activity'] })`. The
    // always prop `remaining` comes along.
    const show = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "X-Inertia-Partial-Component", .value = "Todos/Index" },
        .{ .name = "X-Inertia-Partial-Data", .value = "activity" },
    };
    var shown = try visit(&app, .get, "/todos", &show, "");
    defer shown.deinit();
    try std.testing.expect(std.mem.startsWith(u8, shown.body,
        \\{"component":"Todos/Index","props":{"remaining":1,"activity":{"events":[{"id":1,"todo":1,"text":"Added \"Buy milk\""},{"id":2,"todo":2,"text":"Added \"Walk dog\""},{"id":3,"todo":1,"text":"Completed \"Buy milk\""}],"total":3},"errors":{}}
    ));
    try std.testing.expect(std.mem.indexOf(u8, shown.body, "\"deepMergeProps\":[\"activity\"],\"matchPropsOn\":[\"activity.events.id\"]") != null);

    // "Check for new" sends the last id it has and gets only what follows.
    _ = try store.delete(2);
    const check = show ++ [_]zoda.request.Header{.{ .name = "X-Activity-After", .value = "3" }};
    var newer = try visit(&app, .get, "/todos", &check, "");
    defer newer.deinit();
    try std.testing.expect(std.mem.indexOf(u8, newer.body,
        \\"activity":{"events":[{"id":4,"todo":2,"text":"Deleted \"Walk dog\""}],"total":4}
    ) != null);

    // Opened fresh, the log starts at the latest `recent_events`.
    for (0..recent_events) |_| _ = try store.add("x");
    var recent = try visit(&app, .get, "/todos", &show, "");
    defer recent.deinit();
    try std.testing.expect(std.mem.indexOf(u8, recent.body, "\"events\":[{\"id\":5,") != null);

    // "Refresh counts": `router.reload({ except: ['todos', 'activity'] })`
    // while the client holds the once props.
    const refresh = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "X-Inertia-Partial-Component", .value = "Todos/Index" },
        .{ .name = "X-Inertia-Partial-Except", .value = "todos,activity" },
        .{ .name = "X-Inertia-Except-Once-Props", .value = "limits,server" },
    };
    var counts = try visit(&app, .get, "/todos", &refresh, "");
    defer counts.deinit();
    try std.testing.expect(std.mem.indexOf(u8, counts.body,
        \\"props":{"app":"Zoda","framework":"test","filter":"all","remaining":10,"stats":{"total":11,"done":1},"errors":{}}
    ) != null);
}

test "todo links redirect to the page holding the todo, or show a 404 page" {
    var store = Store{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer store.deinit();
    var app = try testApp(&store);
    defer app.deinit();
    var browser = try Browser.open(&app);
    for (0..per_page + 2) |_| _ = try store.add("x");

    // `<Link href="/todos/1#todo-1">`: the client keeps the fragment
    // through the page's `preserveFragment`.
    var oldest = try visit(&app, .get, "/todos/1", &inertia_get, "");
    defer oldest.deinit();
    try std.testing.expectEqual(@as(u16, 302), oldest.status_code);
    try std.testing.expectEqualStrings("/todos?page=2", (try oldest.getHeaderOne("Location")).?);
    var newest = try visit(&app, .get, "/todos/12", &inertia_get, "");
    defer newest.deinit();
    try std.testing.expectEqualStrings("/todos", (try newest.getHeaderOne("Location")).?);

    var deleted = try visit(&app, .delete, "/todos/1", &browser.with(inertia_json), "");
    defer deleted.deinit();
    var gone = try visit(&app, .get, "/todos/1", &inertia_get, "");
    defer gone.deinit();
    try std.testing.expectEqual(@as(u16, 404), gone.status_code);
    try std.testing.expectEqualStrings("true", (try gone.getHeaderOne("X-Inertia")).?);
    try std.testing.expectEqualStrings(
        \\{"component":"Errors/NotFound","props":{"app":"Zoda","framework":"test","id":1,"errors":{}},"url":"/todos/1","version":"v1","encryptHistory":true,"sharedProps":["app","framework"]}
    , gone.body);
    var html = try visit(&app, .get, "/todos/1", &.{}, "");
    defer html.deinit();
    try std.testing.expectEqual(@as(u16, 404), html.status_code);
    try std.testing.expect(std.mem.indexOf(u8, html.body, "\"component\":\"Errors/NotFound\"") != null);
}

/// The session cookie a response sets, without its attributes.
fn sessionCookie(res: *const zoda.response.Response) ?[]const u8 {
    return setCookie(res, zoda.plugins.sessions.cookie_name);
}

/// The `name=value` of the cookie `name` that `res` sets.
fn setCookie(res: *const zoda.response.Response, name: []const u8) ?[]const u8 {
    var it = res.getAllHeaders("Set-Cookie");
    while (it.next()) |field| {
        const pair = field[0..std.mem.indexOfScalar(u8, field, ';').?];
        if (pair.len > name.len and std.mem.startsWith(u8, pair, name) and pair[name.len] == '=') return pair;
    }
    return null;
}

test "adding a todo flashes a notice that the next render shows once" {
    var store = Store{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer store.deinit();
    var app = try testApp(&store);
    defer app.deinit();
    var browser = try Browser.open(&app);

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
    var created = try visit(&app, .post, "/todos", &browser.with(form), "{\"text\":\"Buy milk\"}");
    defer created.deinit();
    try std.testing.expectEqualStrings("/todos#todo-1", (try created.getHeaderOne("X-Inertia-Redirect")).?);
    const pending = sessionCookie(&created).?;

    var with_cookie: [form.len + 1]zoda.request.Header = undefined;
    @memcpy(with_cookie[0..form.len], &form);
    with_cookie[form.len] = .{ .name = "Cookie", .value = pending };
    var shown = try visit(&app, .get, "/todos", &with_cookie, "");
    defer shown.deinit();
    try std.testing.expect(std.mem.endsWith(u8, shown.body, ",\"flash\":{\"notice\":\"Todo added\"}}"));
    const read = sessionCookie(&shown).?;

    // The saved cookie no longer holds the message.
    const again_headers = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "Cookie", .value = read },
    };
    var again = try visit(&app, .get, "/todos", &again_headers, "");
    defer again.deinit();
    try std.testing.expect(std.mem.indexOf(u8, again.body, "\"flash\"") == null);
    try std.testing.expect(sessionCookie(&again) == null);

    // A rejected todo stores only its errors, so the page that follows has
    // no `flash`.
    var blank = try visit(&app, .post, "/todos", &browser.with(inertia_json), "{\"text\":\" \"}");
    defer blank.deinit();
    const rejected = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "Cookie", .value = sessionCookie(&blank).? },
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
    var browser = try Browser.open(&app);

    // What `router.delete('/history?filter=active')` sends.
    var forgot = try visit(&app, .delete, "/history?filter=active", &browser.with(inertia_json), "");
    defer forgot.deinit();
    try std.testing.expectEqual(@as(u16, 303), forgot.status_code);
    try std.testing.expectEqualStrings("/todos?filter=active", (try forgot.getHeaderOne("Location")).?);

    const followed = [_]zoda.request.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "Cookie", .value = sessionCookie(&forgot).? },
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
        .{ .name = "Cookie", .value = sessionCookie(&cleared).? },
    };
    var again = try visit(&app, .get, "/todos?filter=active", &again_headers, "");
    defer again.deinit();
    try std.testing.expect(std.mem.indexOf(u8, again.body, "\"encryptHistory\":true,") != null);
    try std.testing.expect(std.mem.indexOf(u8, again.body, "clearHistory") == null);

    var get = try visit(&app, .get, "/history", &inertia_get, "");
    defer get.deinit();
    try std.testing.expectEqual(@as(u16, 404), get.status_code);
}
