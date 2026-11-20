//! Production composition reference: authentication, host authorization, CSRF
//! on unsafe methods, static serving, and default security headers, in an
//! order where every responder is covered. Run it with `zig build run-secure-notes`
//! (http://localhost:8080; sign in as alice / correct horse battery staple).
//!
//! The route map (`routes`) is the single source of truth. Each row says
//! whether it is public or protected, and unsafe methods require a CSRF
//! token unless a row says `.csrf = .exempt`. The contract tests at the end
//! enumerate that same table, so adding a route without a decision, or with a
//! weaker one, fails to compile or fails a test.
//!
//! Middleware order (outermost first), and why:
//!   1. security_policy        - adds CSP/Permissions-Policy to every response below it
//!   2. default_headers        - fills nosniff etc. on every response below it
//!   3. host_authorization     - rejects foreign Host before anything else runs
//!   4. gate(/private)         - authenticates before the static responder answers
//!   5. static (/private)      - protected files
//!   6. static (/assets)       - public files
//!   route_fn (route table)    - auth -> CSRF -> handler
//! A middleware registered after a responder cannot protect that responder:
//! put every check ahead of the thing it guards.
const std = @import("std");
const zoda = @import("zoda");

const csrf = zoda.plugins.csrf;
const sessions = zoda.plugins.sessions;
const rt = zoda.route_table;

const max_note_bytes = 200;
pub const demo_user = "alice";
pub const demo_password = "correct horse battery staple";
pub const host = "notes.example";

const Note = struct { id: u64, owner: []const u8, text: []const u8 };

/// Process-local notes. `reached` counts handler entries so tests can prove a
/// rejected request never got that far.
pub const Notes = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(Note) = .empty,
    next_id: u64 = 1,
    reached: usize = 0,

    pub fn deinit(self: *Notes) void {
        for (self.items.items) |n| {
            self.allocator.free(n.owner);
            self.allocator.free(n.text);
        }
        self.items.deinit(self.allocator);
    }

    fn add(self: *Notes, owner: []const u8, text: []const u8) !void {
        const o = try self.allocator.dupe(u8, owner);
        errdefer self.allocator.free(o);
        const t = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(t);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.items.append(self.allocator, .{ .id = self.next_id, .owner = o, .text = t });
        self.next_id += 1;
    }

    fn remove(self: *Notes, owner: []const u8, id: u64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.items.items, 0..) |n, i| {
            if (n.id == id and std.mem.eql(u8, n.owner, owner)) {
                self.allocator.free(n.owner);
                self.allocator.free(n.text);
                _ = self.items.orderedRemove(i);
                return true;
            }
        }
        return false;
    }
};

pub const Plugins = struct {
    sessions: zoda.Sessions,
    json: zoda.JsonParser = .{ .max_body_bytes = 1024 },
    notes: struct { value: *Notes },
};
pub const App = zoda.app.App(Plugins);

/// Authentication is a server-verified, unrevoked session bound to a subject.
/// Missing, malformed, duplicated, expired, and revoked cookies all yield an
/// empty subject.
const authenticate = rt.sessionAuth(App, "sessions");
pub const Routes = rt.Table(App, .{
    .authenticate = authenticate,
    .csrf_sessions = "sessions",
    .csrf_header = csrf.header_name,
});

fn enter(ctx: *App.Context) *Notes {
    const notes = ctx.plugins.notes.value;
    notes.reached += 1;
    return notes;
}

fn health(ctx: *App.Context, _: *zoda.router.Request, res: *zoda.response.Response, _: rt.Params) !void {
    _ = enter(ctx);
    try res.text(200, "ok");
}

/// Public: hands out a session-bound token. The session must be saved so the
/// browser can send the matching cookie back.
fn issueToken(ctx: *App.Context, _: *zoda.router.Request, res: *zoda.response.Response, _: rt.Params) !void {
    const notes = enter(ctx);
    const state = &ctx.state.sessions;
    const issued = try csrf.token(notes.io, state);
    try ctx.plugins.sessions.save(state, res);
    try res.text(200, issued);
}

/// Public, but still CSRF-checked: the token comes from `issueToken`. Login
/// rotates the session ID and CSRF secret, so fetch a new token afterwards.
fn login(ctx: *App.Context, req: *zoda.router.Request, res: *zoda.response.Response, _: rt.Params) !void {
    const notes = enter(ctx);
    var parsed = ctx.plugins.json.parse(res.allocator, req, struct { user: []const u8, password: []const u8 }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return res.text(400, "Expected a JSON body with user and password"),
    };
    defer parsed.deinit();
    // A real app verifies a password hash with a constant-time comparison.
    if (!std.mem.eql(u8, parsed.value.user, demo_user) or !std.mem.eql(u8, parsed.value.password, demo_password)) {
        return res.text(401, "Unauthorized");
    }
    _ = notes;
    try ctx.plugins.sessions.login(ctx.plugins.notes.value.io, &ctx.state.sessions, demo_user);
    try ctx.plugins.sessions.save(&ctx.state.sessions, res);
    try res.text(204, "");
}

fn logout(ctx: *App.Context, _: *zoda.router.Request, res: *zoda.response.Response, _: rt.Params) !void {
    _ = enter(ctx);
    try ctx.plugins.sessions.logout(&ctx.state.sessions);
    try ctx.plugins.sessions.save(&ctx.state.sessions, res);
    try res.text(200, "Signed out");
}

fn listNotes(ctx: *App.Context, _: *zoda.router.Request, res: *zoda.response.Response, _: rt.Params) !void {
    const notes = enter(ctx);
    const owner = ctx.state.sessions.subject();
    var mine: std.ArrayList(Note) = .empty;
    defer mine.deinit(res.allocator);
    notes.mutex.lockUncancelable(notes.io);
    defer notes.mutex.unlock(notes.io);
    for (notes.items.items) |n| {
        if (std.mem.eql(u8, n.owner, owner)) try mine.append(res.allocator, n);
    }
    try res.replaceJson(200, []const Note, mine.items);
}

fn createNote(ctx: *App.Context, req: *zoda.router.Request, res: *zoda.response.Response, _: rt.Params) !void {
    const notes = enter(ctx);
    // The table already ran authentication and CSRF; only now is the body read.
    var parsed = ctx.plugins.json.parse(res.allocator, req, struct { text: []const u8 }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return res.text(400, "Expected a JSON body with a text field"),
    };
    defer parsed.deinit();
    const text = std.mem.trim(u8, parsed.value.text, " \t\r\n");
    if (text.len == 0 or text.len > max_note_bytes) return res.text(400, "Text must be 1-200 bytes");
    try notes.add(ctx.state.sessions.subject(), text);
    try res.text(201, "Created");
}

fn deleteNote(ctx: *App.Context, _: *zoda.router.Request, res: *zoda.response.Response, params: rt.Params) !void {
    const notes = enter(ctx);
    const id = params.int(u64, 0) orelse return res.text(404, "Note not found");
    if (!notes.remove(ctx.state.sessions.subject(), id)) return res.text(404, "Note not found");
    try res.text(200, "Deleted");
}

/// Route map. `access` has no default; unsafe methods require CSRF unless a
/// row says otherwise. Keep this table next to your handlers and review it
/// like an access-control list.
pub const routes = [_]Routes.Route{
    // Public.
    .{ .method = .get, .path = "/health", .access = .public, .handler = health },
    .{ .method = .get, .path = "/csrf", .access = .public, .handler = issueToken },
    .{ .method = .post, .path = "/login", .access = .public, .handler = login }, // CSRF required (default)
    // Protected.
    .{ .method = .post, .path = "/logout", .access = .protected, .handler = logout },
    .{ .method = .get, .path = "/notes", .access = .protected, .handler = listNotes },
    .{ .method = .post, .path = "/notes", .access = .protected, .handler = createNote },
    .{ .method = .delete, .path = "/notes/:id", .access = .protected, .handler = deleteNote },
};

/// Everything the app borrows must outlive it, so it lives beside it.
pub const Server = struct {
    allowed_hosts: [1][]const u8 = .{host},
    host_config: zoda.host_authorization.Config = undefined,
    policies: zoda.plugins.security_policy.Config(App) = .{
        .content_security_policy = .{ .value = "default-src 'self'; frame-ancestors 'none'" },
        .permissions_policy = .{ .value = "camera=(), geolocation=(), microphone=()" },
    },
    defaults: zoda.default_headers.Config = .{ .headers = &.{
        .{ .name = "X-Content-Type-Options", .value = "nosniff" },
        .{ .name = "Referrer-Policy", .value = "no-referrer" },
    } },
    private_gate: rt.Gate = .{ .prefix = &.{"private"} },
    private_files: zoda.static.Config = undefined,
    public_files: zoda.static.Config = undefined,
    app: App = undefined,

    /// `self` must not move after `init`: the app borrows its fields.
    pub fn init(
        self: *Server,
        allocator: std.mem.Allocator,
        plugins: Plugins,
        public_root: std.Io.Dir,
        private_root: std.Io.Dir,
    ) !void {
        self.* = .{};
        self.host_config = .{ .allowed_hosts = &self.allowed_hosts };
        self.public_files = .{ .root = public_root, .prefix = &.{"assets"}, .etag = true };
        self.private_files = .{ .root = private_root, .prefix = &.{"private"}, .cache_control = .{ .private = .{ .no_cache = true } } };
        self.app = try App.init(allocator, .{
            .response_allocator = allocator,
            .config = .{ .name = "secure-notes" },
            .plugins = plugins,
            .route_fn = App.composeRoute(Routes.route(&routes)),
            .middleware = &.{
                try zoda.plugins.security_policy.middleware(App, &self.policies),
                try zoda.default_headers.middleware(App, &self.defaults),
                try zoda.host_authorization.middleware(App, &self.host_config),
                rt.gate(App, authenticate, &self.private_gate),
                zoda.static.middleware(App, &self.private_files),
                zoda.static.middleware(App, &self.public_files),
            },
        });
    }

    pub fn deinit(self: *Server) void {
        self.app.deinit();
    }
};

var clock_io: std.Io = undefined;

fn unixSeconds() i64 {
    return std.Io.Clock.real.now(clock_io).toSeconds();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    clock_io = io;
    const allocator = std.heap.smp_allocator;
    var public_root = try std.Io.Dir.cwd().openDir(io, "examples/secure_notes/assets", .{});
    defer public_root.close(io);
    var private_root = try std.Io.Dir.cwd().openDir(io, "examples/secure_notes/private", .{});
    defer private_root.close(io);
    try zoda.static.checkSupport(public_root);
    try zoda.static.checkSupport(private_root);

    // DEV ONLY: a fresh key per run logs everyone out on restart and breaks
    // multi-instance deployments. A real deployment loads a stable key from
    // protected runtime configuration with `sessions.Key.fromBase64`
    // (PLUGINS.md "Session keys"). Cookie payloads are signed, not encrypted.
    var secret: [32]u8 = undefined;
    try std.Io.randomSecure(io, &secret);
    var session_store = sessions.MemoryStore(256).init(unixSeconds);
    var notes = Notes{ .allocator = allocator, .io = io };
    defer notes.deinit();
    var server: Server = undefined;
    try server.init(allocator, .{
        .sessions = .{ .keys = &.{.{ .id = 1, .secret = &secret }}, .lifetime_seconds = 60 * 60, .now_seconds = unixSeconds, .store = session_store.store() },
        .notes = .{ .value = &notes },
    }, public_root, private_root);
    defer server.deinit();

    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(8080) };
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    std.log.info("secure-notes on http://localhost:8080 (send Host: {s})", .{host});
    try zoda.server.serve(App, allocator, io, &listener, &server.app, .{});
}

// ---------------------------------------------------------------------------
// Contract tests. They iterate `routes`, so a new row is covered automatically.
// ---------------------------------------------------------------------------

const testing = std.testing;
var test_now: std.atomic.Value(i64) = .init(1000);

fn testClock() i64 {
    return test_now.load(.monotonic);
}

const Fixture = struct {
    tmp: testing.TmpDir,
    public_root: std.Io.Dir,
    private_root: std.Io.Dir,
    session_store: sessions.MemoryStore(8),
    notes: Notes,
    server: Server,

    /// Heap-allocate so the app's borrowed pointers stay valid.
    fn create() !*Fixture {
        const io = testing.io;
        const self = try testing.allocator.create(Fixture);
        errdefer testing.allocator.destroy(self);
        test_now.store(1000, .monotonic);
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        try self.tmp.dir.createDirPath(io, "assets");
        try self.tmp.dir.createDirPath(io, "private");
        try self.tmp.dir.writeFile(io, .{ .sub_path = "assets/app.css", .data = "p{}" });
        try self.tmp.dir.writeFile(io, .{ .sub_path = "private/report.txt", .data = "secret numbers" });
        self.public_root = try self.tmp.dir.openDir(io, "assets", .{});
        self.private_root = try self.tmp.dir.openDir(io, "private", .{});
        self.session_store = .init(testClock);
        self.notes = .{ .allocator = testing.allocator, .io = io };
        try self.server.init(testing.allocator, .{
            .sessions = .{
                .keys = &.{.{ .id = 1, .secret = "TEST-ONLY-do-not-deploy-this-key!" }},
                .lifetime_seconds = 300,
                .now_seconds = testClock,
                .store = self.session_store.store(),
            },
            .notes = .{ .value = &self.notes },
        }, self.public_root, self.private_root);
        return self;
    }

    fn destroy(self: *Fixture) void {
        self.server.deinit();
        self.notes.deinit();
        self.private_root.close(testing.io);
        self.public_root.close(testing.io);
        self.tmp.cleanup();
        testing.allocator.destroy(self);
    }

    const Opts = struct {
        host: ?[]const u8 = host,
        cookie: ?[]const u8 = null,
        extra: []const zoda.request.Header = &.{},
        body: []const u8 = "",
    };

    fn send(self: *Fixture, method: zoda.router.Method, target: []const u8, opts: Opts) !zoda.response.Response {
        var headers: [8]zoda.request.Header = undefined;
        var n: usize = 0;
        if (opts.host) |h| {
            headers[n] = .{ .name = "Host", .value = h };
            n += 1;
        }
        if (opts.cookie) |c| {
            headers[n] = .{ .name = "Cookie", .value = c };
            n += 1;
        }
        if (opts.body.len > 0) {
            headers[n] = .{ .name = "Content-Type", .value = "application/json" };
            n += 1;
        }
        for (opts.extra) |h| {
            headers[n] = h;
            n += 1;
        }
        var arena = try zoda.request.parseOriginForm(testing.allocator, .default, target);
        defer arena.deinit();
        try arena.copyHeaders(headers[0..n]);
        try arena.copyBody(opts.body);
        var req = arena.requestView(method);
        return self.server.app.dispatch(&req);
    }
};

/// A signed-in browser: its session cookie and current CSRF token.
const Session = struct {
    cookie_buf: [sessions.max_cookie_bytes + 64]u8 = undefined,
    cookie_len: usize = 0,
    token: [csrf.token_bytes]u8 = undefined,

    fn cookie(self: *const Session) []const u8 {
        return self.cookie_buf[0..self.cookie_len];
    }

    fn absorb(self: *Session, res: *const zoda.response.Response) void {
        var it = res.getAllHeaders("Set-Cookie");
        while (it.next()) |field| {
            if (!std.mem.startsWith(u8, field, sessions.cookie_name ++ "=")) continue;
            const pair = field[0..std.mem.indexOfScalar(u8, field, ';').?];
            @memcpy(self.cookie_buf[0..pair.len], pair);
            self.cookie_len = pair.len;
        }
    }

    fn open(fx: *Fixture, user: []const u8) !Session {
        var s: Session = .{};
        try s.refreshToken(fx);
        const body = try std.fmt.allocPrint(testing.allocator, "{{\"user\":\"{s}\",\"password\":\"{s}\"}}", .{ user, demo_password });
        defer testing.allocator.free(body);
        var res = try fx.send(.post, "/login", .{ .cookie = s.cookie(), .extra = &.{.{ .name = csrf.header_name, .value = &s.token }}, .body = body });
        defer res.deinit();
        try testing.expectEqual(@as(u16, 204), res.status_code);
        s.absorb(&res);
        try s.refreshToken(fx); // login rotated the CSRF secret
        return s;
    }

    fn refreshToken(self: *Session, fx: *Fixture) !void {
        var res = try fx.send(.get, "/csrf", .{ .cookie = if (self.cookie_len > 0) self.cookie() else null });
        defer res.deinit();
        try testing.expectEqual(@as(u16, 200), res.status_code);
        @memcpy(&self.token, res.body);
        self.absorb(&res);
    }

    fn proof(self: *const Session) [1]zoda.request.Header {
        return .{.{ .name = csrf.header_name, .value = &self.token }};
    }
};

/// Concrete request target for a route pattern, e.g. `/notes/:id` -> `/notes/1`.
fn concretePath(buf: []u8, comptime pattern: []const u8) []const u8 {
    var out: usize = 0;
    var it = std.mem.splitScalar(u8, pattern, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        buf[out] = '/';
        out += 1;
        const text = if (seg[0] == ':') "1" else seg;
        @memcpy(buf[out..][0..text.len], text);
        out += text.len;
    }
    return if (out == 0) "/" else buf[0..out];
}

const route_map = Routes.entries(&routes);

test "route map lists every protected route and no CSRF exemptions" {
    // Reviewable inventory: changing it forces a conscious edit here.
    const expected_protected = [_][]const u8{ "/logout", "/notes", "/notes", "/notes/:id" };
    var seen: usize = 0;
    inline for (route_map) |entry| {
        if (entry.access == .protected) {
            try testing.expectEqualStrings(expected_protected[seen], entry.path);
            seen += 1;
        }
        // Every unsafe method needs proof; no row opts out.
        if (!rt.isSafe(entry.method)) try testing.expect(entry.csrf_required);
    }
    try testing.expectEqual(expected_protected.len, seen);
    inline for (routes) |r| try testing.expect(r.csrf != .exempt);
}

test "protected routes reject missing, malformed, duplicate, stale, and expired sessions before any handler" {
    if (!zoda.static.supported) return error.SkipZigTest;
    const fx = try Fixture.create();
    defer fx.destroy();
    var alice = try Session.open(fx, demo_user);
    const reached = fx.notes.reached;

    var dup_buf: [2 * sessions.max_cookie_bytes + 8]u8 = undefined;
    const duplicate = try std.fmt.bufPrint(&dup_buf, "{s}; {s}", .{ alice.cookie(), alice.cookie() });
    const malformed = [_][]const u8{
        sessions.cookie_name ++ "=garbage",
        sessions.cookie_name ++ "=v4.1.AAAA.AAAA.AAAA.AAAA.AAAA",
        sessions.cookie_name ++ "=",
        "other=1",
        duplicate,
    };

    inline for (route_map) |entry| {
        if (comptime entry.access != .protected) continue;
        var path_buf: [64]u8 = undefined;
        const path = concretePath(&path_buf, entry.path);
        // Present valid CSRF proof so the only missing check is authentication.
        const extra = alice.proof();
        var res = try fx.send(entry.method, path, .{ .extra = &extra });
        defer res.deinit();
        try testing.expectEqual(@as(u16, 401), res.status_code);
        for (malformed) |bad| {
            var r = try fx.send(entry.method, path, .{ .cookie = bad, .extra = &extra });
            defer r.deinit();
            try testing.expectEqual(@as(u16, 401), r.status_code);
        }
    }
    try testing.expectEqual(reached, fx.notes.reached);

    // Stale: a logged-out cookie copy is refused everywhere.
    const copied = try testing.allocator.dupe(u8, alice.cookie());
    defer testing.allocator.free(copied);
    const copied_token = alice.token;
    var out = try fx.send(.post, "/logout", .{ .cookie = alice.cookie(), .extra = &alice.proof() });
    defer out.deinit();
    try testing.expectEqual(@as(u16, 200), out.status_code);
    const after_logout = fx.notes.reached;
    inline for (route_map) |entry| {
        if (comptime entry.access != .protected) continue;
        var path_buf: [64]u8 = undefined;
        var r = try fx.send(entry.method, concretePath(&path_buf, entry.path), .{
            .cookie = copied,
            .extra = &.{.{ .name = csrf.header_name, .value = &copied_token }},
            .body = "{\"text\":\"x\"}",
        });
        defer r.deinit();
        try testing.expectEqual(@as(u16, 401), r.status_code);
    }
    try testing.expectEqual(after_logout, fx.notes.reached);

    // Expired: a fresh session past its lifetime.
    var bob = try Session.open(fx, demo_user);
    test_now.store(1000 + 301, .monotonic);
    var expired = try fx.send(.get, "/notes", .{ .cookie = bob.cookie() });
    defer expired.deinit();
    try testing.expectEqual(@as(u16, 401), expired.status_code);
    try testing.expectEqual(@as(usize, 0), fx.notes.items.items.len);
}

test "every state-changing route rejects missing, malformed, duplicate, header-swapped, and cross-session CSRF proof" {
    if (!zoda.static.supported) return error.SkipZigTest;
    const fx = try Fixture.create();
    defer fx.destroy();
    var alice = try Session.open(fx, demo_user);
    var other = try Session.open(fx, demo_user);

    var anon: Session = .{};
    try anon.refreshToken(fx); // public routes still need CSRF for login
    const reached = fx.notes.reached;

    inline for (route_map) |entry| {
        if (comptime rt.isSafe(entry.method)) continue;
        var path_buf: [64]u8 = undefined;
        const path = concretePath(&path_buf, entry.path);
        const session = if (entry.access == .protected) &alice else &anon;
        const dup = [_]zoda.request.Header{ .{ .name = csrf.header_name, .value = &session.token }, .{ .name = csrf.header_name, .value = &session.token } };
        const cases = [_][]const zoda.request.Header{
            &.{}, // missing
            &.{.{ .name = csrf.header_name, .value = "not-a-token" }}, // malformed
            &dup, // duplicate
            &.{.{ .name = csrf.xsrf_header_name, .value = &session.token }}, // wrong header
            &.{.{ .name = csrf.header_name, .value = &other.token }}, // another session's token
        };
        for (cases) |extra| {
            var r = try fx.send(entry.method, path, .{ .cookie = session.cookie(), .extra = extra, .body = "{\"text\":\"x\",\"user\":\"alice\",\"password\":\"x\"}" });
            defer r.deinit();
            try testing.expectEqual(@as(u16, 403), r.status_code);
        }
    }
    try testing.expectEqual(reached, fx.notes.reached);
    try testing.expectEqual(@as(usize, 0), fx.notes.items.items.len);
}

test "valid session plus proof reaches handlers; sessions are isolated" {
    if (!zoda.static.supported) return error.SkipZigTest;
    const fx = try Fixture.create();
    defer fx.destroy();
    var alice = try Session.open(fx, demo_user);

    var created = try fx.send(.post, "/notes", .{ .cookie = alice.cookie(), .extra = &alice.proof(), .body = "{\"text\":\"hello\"}" });
    defer created.deinit();
    try testing.expectEqual(@as(u16, 201), created.status_code);
    var listed = try fx.send(.get, "/notes", .{ .cookie = alice.cookie() });
    defer listed.deinit();
    try testing.expectEqual(@as(u16, 200), listed.status_code);
    try testing.expect(std.mem.indexOf(u8, listed.body, "hello") != null);

    var deleted = try fx.send(.delete, "/notes/1", .{ .cookie = alice.cookie(), .extra = &alice.proof() });
    defer deleted.deinit();
    try testing.expectEqual(@as(u16, 200), deleted.status_code);
    try testing.expectEqual(@as(usize, 0), fx.notes.items.items.len);
}

test "public routes stay reachable without credentials" {
    if (!zoda.static.supported) return error.SkipZigTest;
    const fx = try Fixture.create();
    defer fx.destroy();
    inline for (route_map) |entry| {
        if (comptime entry.access != .public or entry.method != .get) continue;
        var path_buf: [64]u8 = undefined;
        var r = try fx.send(.get, concretePath(&path_buf, entry.path), .{});
        defer r.deinit();
        try testing.expectEqual(@as(u16, 200), r.status_code);
    }
    var css = try fx.send(.get, "/assets/app.css", .{});
    defer css.deinit();
    try testing.expectEqual(@as(u16, 200), css.status_code);
    try testing.expectEqualStrings("p{}", css.body);
}

test "protected static files need a session; public ones do not" {
    if (!zoda.static.supported) return error.SkipZigTest;
    const fx = try Fixture.create();
    defer fx.destroy();
    var alice = try Session.open(fx, demo_user);

    var anon = try fx.send(.get, "/private/report.txt", .{});
    defer anon.deinit();
    try testing.expectEqual(@as(u16, 401), anon.status_code);
    try testing.expect(std.mem.indexOf(u8, anon.body, "secret") == null);
    // Missing files are also refused, so existence is not revealed.
    var anon_missing = try fx.send(.get, "/private/nope.txt", .{});
    defer anon_missing.deinit();
    try testing.expectEqual(@as(u16, 401), anon_missing.status_code);
    var forged = try fx.send(.get, "/private/report.txt", .{ .cookie = sessions.cookie_name ++ "=garbage" });
    defer forged.deinit();
    try testing.expectEqual(@as(u16, 401), forged.status_code);

    var ok = try fx.send(.get, "/private/report.txt", .{ .cookie = alice.cookie() });
    defer ok.deinit();
    try testing.expectEqual(@as(u16, 200), ok.status_code);
    try testing.expectEqualStrings("secret numbers", ok.body);
}

test "host authorization and security headers cover routes, static files, and short circuits" {
    if (!zoda.static.supported) return error.SkipZigTest;
    const fx = try Fixture.create();
    defer fx.destroy();
    var alice = try Session.open(fx, demo_user);
    const reached = fx.notes.reached;

    // A foreign or absent Host is refused before routes, gate, or static files,
    // even with perfectly valid credentials.
    for ([_]?[]const u8{ "evil.example", null }) |h| {
        for ([_][]const u8{ "/health", "/notes", "/private/report.txt", "/assets/app.css" }) |path| {
            var r = try fx.send(.get, path, .{ .host = h, .cookie = alice.cookie() });
            defer r.deinit();
            try testing.expectEqual(@as(u16, 403), r.status_code);
        }
    }
    try testing.expectEqual(reached, fx.notes.reached);

    // The outer policies reach every response class: handler, gate 401, CSRF
    // 403, static hit, default 404, and the host 403.
    var handler = try fx.send(.get, "/health", .{});
    defer handler.deinit();
    var gated = try fx.send(.get, "/private/report.txt", .{});
    defer gated.deinit();
    var csrf_403 = try fx.send(.post, "/notes", .{ .cookie = alice.cookie() });
    defer csrf_403.deinit();
    var file = try fx.send(.get, "/assets/app.css", .{});
    defer file.deinit();
    var missing = try fx.send(.get, "/nowhere", .{});
    defer missing.deinit();
    var wrong_host = try fx.send(.get, "/health", .{ .host = "evil.example" });
    defer wrong_host.deinit();
    try testing.expectEqual(@as(u16, 401), gated.status_code);
    try testing.expectEqual(@as(u16, 403), csrf_403.status_code);
    try testing.expectEqual(@as(u16, 404), missing.status_code);
    for ([_]*const zoda.response.Response{ &handler, &gated, &csrf_403, &file, &missing, &wrong_host }) |r| {
        try testing.expect((try r.getHeaderOne("Content-Security-Policy")) != null);
        try testing.expectEqualStrings("nosniff", (try r.getHeaderOne("X-Content-Type-Options")).?);
    }
}
