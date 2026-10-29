//! One-time flash messages carried in the authenticated cookie session.
//! Messages queued with `add` reach the next request that loads the saved
//! session; `read` returns what this request received and consumes it on the
//! next explicit `Sessions.save`. Like the rest of the session, messages are
//! signed but **not encrypted**, and nothing is persisted without `save`.
const std = @import("std");
const sessions = @import("sessions.zig");

/// Persisted messages per session: unread incoming plus queued.
pub const max_messages: usize = 8;
/// Persisted encoded bytes per session, counting 3 bytes of framing per message.
pub const max_bytes: usize = 512;
/// Kinds are 1 to 32 bytes of ASCII letters, digits, `_`, or `-`.
pub const max_kind_bytes: usize = 32;

pub const Error = error{ InvalidFlashKind, FlashTooLarge, TooManyFlashMessages };

/// A message borrowed from request state. The slices remain valid until the
/// request ends; copy them into the response (for example with `res.text` or
/// a template, which escapes HTML) rather than retaining them.
pub const Message = struct {
    kind: []const u8,
    text: []const u8,
};

/// Messages in the order they were added.
pub const Messages = struct {
    bytes: []const u8,
    count: usize,
    index: usize = 0,

    pub fn next(self: *Messages) ?Message {
        if (self.index >= self.bytes.len) return null;
        const entry = parseEntry(self.bytes[self.index..]).?;
        self.index += entry.size;
        return entry.message;
    }
};

/// Flash storage embedded in `Sessions.State`. Use `Flash` methods; the
/// fields are encoded by `Sessions.save` and decoded by `initRequest`.
pub const Store = struct {
    incoming: [max_bytes]u8 = undefined,
    incoming_len: usize = 0,
    incoming_count: usize = 0,
    consumed: bool = false,
    queued: [max_bytes]u8 = undefined,
    queued_len: usize = 0,
    queued_count: usize = 0,

    fn keptLen(self: *const Store) usize {
        return if (self.consumed) 0 else self.incoming_len;
    }

    fn keptCount(self: *const Store) usize {
        return if (self.consumed) 0 else self.incoming_count;
    }

    /// Unread incoming entries followed by queued entries; may be empty.
    pub fn persisted(self: *const Store, out: *[max_bytes]u8) []const u8 {
        const kept = self.keptLen();
        @memcpy(out[0..kept], self.incoming[0..kept]);
        @memcpy(out[kept..][0..self.queued_len], self.queued[0..self.queued_len]);
        return out[0 .. kept + self.queued_len];
    }

    /// Accepts decoded cookie bytes only when every entry is well formed.
    pub fn load(self: *Store, bytes: []const u8) bool {
        if (bytes.len == 0 or bytes.len > max_bytes) return false;
        var count: usize = 0;
        var index: usize = 0;
        while (index < bytes.len) {
            const entry = parseEntry(bytes[index..]) orelse return false;
            index += entry.size;
            count += 1;
            if (count > max_messages) return false;
        }
        @memcpy(self.incoming[0..bytes.len], bytes);
        self.incoming_len = bytes.len;
        self.incoming_count = count;
        return true;
    }
};

/// Stateless registered instance; flash state lives in the session state.
pub const Flash = struct {
    /// Queues a message for the next request. The session becomes dirty and
    /// needs `Sessions.save` before returning, or the message is discarded.
    /// After `State.clear`, a queued message keeps the session cookie alive
    /// with an empty payload, so a logout page can still show a notice.
    pub fn add(_: *const Flash, state: *sessions.Sessions.State, kind: []const u8, text: []const u8) Error!void {
        if (!validKind(kind)) return error.InvalidFlashKind;
        const store = &state.flash;
        if (store.keptCount() + store.queued_count >= max_messages) return error.TooManyFlashMessages;
        if (text.len > max_bytes) return error.FlashTooLarge;
        const size = 3 + kind.len + text.len;
        if (store.keptLen() + store.queued_len + size > max_bytes) return error.FlashTooLarge;
        const entry = store.queued[store.queued_len..][0..size];
        entry[0] = @intCast(kind.len);
        @memcpy(entry[1..][0..kind.len], kind);
        std.mem.writeInt(u16, entry[1 + kind.len ..][0..2], @intCast(text.len), .big);
        @memcpy(entry[3 + kind.len ..], text);
        store.queued_len += size;
        store.queued_count += 1;
        state.dirty = true;
        state.clearing = false;
    }

    /// Returns the messages this request received and marks them consumed.
    /// Repeated calls return the same messages. Consumption, like any other
    /// change, persists only through `Sessions.save`; without it the browser
    /// keeps the old cookie and shows the messages again. Reading an empty
    /// flash does not dirty the session.
    pub fn read(_: *const Flash, state: *sessions.Sessions.State) Messages {
        const store = &state.flash;
        if (store.incoming_count > 0 and !store.consumed) {
            store.consumed = true;
            state.dirty = true;
        }
        return .{ .bytes = store.incoming[0..store.incoming_len], .count = store.incoming_count };
    }

    /// Returns the messages this request received without consuming them.
    /// For integrations, such as `Inertia.renderWith`, that call `read` only
    /// once the messages are sent.
    pub fn peek(_: *const Flash, state: *const sessions.Sessions.State) Messages {
        return .{ .bytes = state.flash.incoming[0..state.flash.incoming_len], .count = state.flash.incoming_count };
    }

    /// Restores what this request received: un-consumes incoming messages and
    /// drops queued ones. Recovery middleware calls this before replacing a
    /// failed response and saving. The session stays dirty if it already was.
    pub fn reset(_: *const Flash, state: *sessions.Sessions.State) void {
        state.flash.consumed = false;
        state.flash.queued_len = 0;
        state.flash.queued_count = 0;
    }
};

fn validKind(kind: []const u8) bool {
    if (kind.len == 0 or kind.len > max_kind_bytes) return false;
    for (kind) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }
    return true;
}

const Entry = struct { message: Message, size: usize };

fn parseEntry(bytes: []const u8) ?Entry {
    if (bytes.len < 1) return null;
    const kind_len = bytes[0];
    if (bytes.len < 3 + @as(usize, kind_len)) return null;
    const kind = bytes[1..][0..kind_len];
    if (!validKind(kind)) return null;
    const text_len = std.mem.readInt(u16, bytes[1 + kind_len ..][0..2], .big);
    const size = 3 + @as(usize, kind_len) + text_len;
    if (bytes.len < size) return null;
    return .{ .message = .{ .kind = kind, .text = bytes[3 + kind_len .. size] }, .size = size };
}

const router = @import("../router.zig");
const response = @import("../response.zig");
const app_mod = @import("../app.zig");
const csrf = @import("csrf.zig");

const test_secret = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn time1000() i64 {
    return 1000;
}

fn time2000() i64 {
    return 2000;
}

fn testSessions() sessions.Sessions {
    return .{ .keys = &.{.{ .id = 1, .secret = test_secret }}, .lifetime_seconds = 300, .now_seconds = time1000 };
}

fn cookieValue(set_cookie: []const u8) []const u8 {
    return set_cookie[0..std.mem.indexOfScalar(u8, set_cookie, ';').?];
}

const TestApp = app_mod.App(struct { sessions: sessions.Sessions, flash: Flash = .{} });

const TestRoutes = struct {
    fn render(ctx: *TestApp.Context, res: *response.Response) !void {
        var body: [max_bytes * 2]u8 = undefined;
        var len: usize = 0;
        var messages = ctx.plugins.flash.read(&ctx.state.sessions);
        while (messages.next()) |message| {
            const line = try std.fmt.bufPrint(body[len..], "{s}:{s};", .{ message.kind, message.text });
            len += line.len;
        }
        return res.text(200, body[0..len]);
    }

    fn route(ctx: *TestApp.Context, req: *router.Request, res: *response.Response) !void {
        const flash = &ctx.plugins.flash;
        const state = &ctx.state.sessions;
        if (req.isLiteral("add")) {
            try flash.add(state, "notice", "Saved");
            try flash.add(state, "alert", "Check the form");
            try ctx.plugins.sessions.save(state, res);
            return res.redirectPath(.see_other, "/show");
        }
        if (req.isLiteral("add-unsaved")) {
            try flash.add(state, "notice", "lost");
            return res.text(200, "unsaved");
        }
        if (req.isLiteral("show")) {
            // Reading twice in one request yields the same messages.
            _ = flash.read(state);
            try render(ctx, res);
            return ctx.plugins.sessions.save(state, res);
        }
        if (req.isLiteral("peek")) return render(ctx, res);
        if (req.isLiteral("ignore")) {
            try state.set("touched");
            return ctx.plugins.sessions.save(state, res);
        }
        if (req.isLiteral("show-and-add")) {
            try render(ctx, res);
            try flash.add(state, "notice", "next");
            return ctx.plugins.sessions.save(state, res);
        }
        if (req.isLiteral("logout")) {
            state.clear();
            try flash.add(state, "notice", "Signed out");
            return ctx.plugins.sessions.save(state, res);
        }
        if (req.isLiteral("fail") or req.isLiteral("recover")) {
            _ = flash.read(state);
            try flash.add(state, "notice", "never");
            try ctx.plugins.sessions.save(state, res);
            return error.RouteFailed;
        }
    }

    fn middleware(_: *const anyopaque, ctx: *TestApp.Context, req: *router.Request, res: *response.Response, next: TestApp.Next) !void {
        const flash = &ctx.plugins.flash;
        const state = &ctx.state.sessions;
        if (req.isLiteral("short")) {
            try flash.add(state, "alert", "denied");
            try ctx.plugins.sessions.save(state, res);
            return res.text(403, "short");
        }
        if (req.isLiteral("short-unsaved")) {
            _ = flash.read(state);
            try flash.add(state, "alert", "lost");
            return res.text(403, "short");
        }
        const recovering = req.segments.len == 1 and std.mem.eql(u8, req.segments[0], "recover");
        next.call(ctx, req, res) catch |err| {
            if (!recovering) return err;
            res.clear();
            flash.reset(state);
            try flash.add(state, "alert", "Something went wrong");
            try ctx.plugins.sessions.save(state, res);
            return res.text(503, "recovered");
        };
    }
};

fn testApp() !TestApp {
    const mw = TestApp.Middleware{ .config = &.{}, .invoke = TestRoutes.middleware };
    return TestApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{ .sessions = testSessions() },
        .route_fn = TestRoutes.route,
        .middleware = &.{mw},
    });
}

/// Dispatches `/segment` with an optional session cookie. Returns the body and
/// the new cookie, if any, copied into `out`.
const Outcome = struct {
    status: u16,
    body: []const u8,
    cookie: ?[]const u8,
};

fn visit(app: *const TestApp, segment: []const u8, cookie: ?[]const u8, out: *[2][sessions.max_cookie_bytes]u8) !Outcome {
    const headers = [_]router.Header{.{ .name = "Cookie", .value = cookie orelse "" }};
    const segments = [_][]const u8{segment};
    var req: router.Request = .{ .method = .get, .segments = &segments, .headers = if (cookie != null) &headers else &.{} };
    var res = try app.dispatch(&req);
    defer res.deinit();
    @memcpy(out[0][0..res.body.len], res.body);
    var outcome: Outcome = .{ .status = res.status_code, .body = out[0][0..res.body.len], .cookie = null };
    var cookies = res.getAllHeaders("Set-Cookie");
    if (cookies.next()) |set_cookie| {
        const value = cookieValue(set_cookie);
        @memcpy(out[1][0..value.len], value);
        outcome.cookie = out[1][0..value.len];
        try std.testing.expect(cookies.next() == null);
    }
    return outcome;
}

test "flash messages are read once, in order, after an explicit save" {
    var app = try testApp();
    defer app.deinit();
    var a: [2][sessions.max_cookie_bytes]u8 = undefined;
    var b: [2][sessions.max_cookie_bytes]u8 = undefined;
    var c: [2][sessions.max_cookie_bytes]u8 = undefined;

    const added = try visit(&app, "add", null, &a);
    try std.testing.expectEqual(@as(u16, 303), added.status);
    try std.testing.expect(std.mem.startsWith(u8, added.cookie.?, sessions.cookie_name ++ "=v3.1.1300.."));

    // A response that reads nothing can save the session without dropping
    // pending messages.
    const ignored = try visit(&app, "ignore", added.cookie, &b);
    const shown = try visit(&app, "show", ignored.cookie, &c);
    try std.testing.expectEqualStrings("notice:Saved;alert:Check the form;", shown.body);
    try std.testing.expect(std.mem.startsWith(u8, shown.cookie.?, sessions.cookie_name ++ "=v1."));

    const again = try visit(&app, "show", shown.cookie, &a);
    try std.testing.expectEqualStrings("", again.body);
    // Reading an empty flash leaves the session clean: no cookie is written.
    try std.testing.expect(again.cookie == null);

    // Received messages come first; queued messages wait for the next request.
    const rolled = try visit(&app, "show-and-add", ignored.cookie, &b);
    try std.testing.expectEqualStrings("notice:Saved;alert:Check the form;", rolled.body);
    const next = try visit(&app, "peek", rolled.cookie, &c);
    try std.testing.expectEqualStrings("notice:next;", next.body);
}

test "flash changes without save are discarded and never written by cleanup" {
    var app = try testApp();
    defer app.deinit();
    var a: [2][sessions.max_cookie_bytes]u8 = undefined;
    var b: [2][sessions.max_cookie_bytes]u8 = undefined;

    const unsaved = try visit(&app, "add-unsaved", null, &a);
    try std.testing.expect(unsaved.cookie == null);

    const added = try visit(&app, "add", null, &a);
    // Reading without saving leaves the browser's cookie in place, so the
    // messages are shown again.
    const peeked = try visit(&app, "peek", added.cookie, &b);
    try std.testing.expect(peeked.cookie == null);
    try std.testing.expectEqualStrings("notice:Saved;alert:Check the form;", peeked.body);
    const peeked_again = try visit(&app, "peek", added.cookie, &b);
    try std.testing.expectEqualStrings("notice:Saved;alert:Check the form;", peeked_again.body);
}

test "flash follows short circuits, errors, and recovery" {
    var app = try testApp();
    defer app.deinit();
    var a: [2][sessions.max_cookie_bytes]u8 = undefined;
    var b: [2][sessions.max_cookie_bytes]u8 = undefined;
    var c: [2][sessions.max_cookie_bytes]u8 = undefined;

    const short = try visit(&app, "short", null, &a);
    try std.testing.expectEqual(@as(u16, 403), short.status);
    try std.testing.expectEqualStrings("alert:denied;", (try visit(&app, "peek", short.cookie, &b)).body);

    // An unsaved short circuit neither consumes nor queues.
    const added = try visit(&app, "add", null, &a);
    const denied = try visit(&app, "short-unsaved", added.cookie, &b);
    try std.testing.expect(denied.cookie == null);
    try std.testing.expectEqualStrings("notice:Saved;alert:Check the form;", (try visit(&app, "peek", added.cookie, &b)).body);

    // A propagated error discards the response, including its saved cookie.
    const fail_headers = [_]router.Header{.{ .name = "Cookie", .value = added.cookie.? }};
    var fail_req: router.Request = .{ .method = .get, .segments = &.{"fail"}, .headers = &fail_headers };
    try std.testing.expectError(error.RouteFailed, app.dispatch(&fail_req));

    // Recovery resets the failed route's flash changes before its own save:
    // received messages stay unread and only the recovery message is queued.
    const recovered = try visit(&app, "recover", added.cookie, &b);
    try std.testing.expectEqual(@as(u16, 503), recovered.status);
    const after = try visit(&app, "peek", recovered.cookie, &c);
    try std.testing.expectEqualStrings("notice:Saved;alert:Check the form;alert:Something went wrong;", after.body);
}

test "flash survives logout and coexists with CSRF and the payload" {
    var app = try testApp();
    defer app.deinit();
    var a: [2][sessions.max_cookie_bytes]u8 = undefined;
    var b: [2][sessions.max_cookie_bytes]u8 = undefined;

    const out = try visit(&app, "logout", null, &a);
    try std.testing.expect(std.mem.startsWith(u8, out.cookie.?, sessions.cookie_name ++ "=v3.1.1300.."));
    try std.testing.expectEqualStrings("notice:Signed out;", (try visit(&app, "peek", out.cookie, &b)).body);

    const plugin = testSessions();
    const flash: Flash = .{};
    var empty_req: router.Request = .{ .method = .get, .segments = &.{} };
    var state = try plugin.initRequest(&empty_req);
    try state.set("user=42");
    const issued = try csrf.token(std.testing.io, &state);
    try flash.add(&state, "notice", "hi");
    var res = response.Response.init(std.testing.allocator);
    defer res.deinit();
    try plugin.save(&state, &res);
    const headers = [_]router.Header{.{ .name = "Cookie", .value = cookieValue(res.headers[0].value) }};
    var req: router.Request = .{ .method = .get, .segments = &.{}, .headers = &headers };
    var loaded = try plugin.initRequest(&req);
    try std.testing.expectEqualStrings("user=42", loaded.value());
    try std.testing.expect(csrf.validToken(&loaded, issued));
    var messages = flash.read(&loaded);
    try std.testing.expectEqual(@as(usize, 1), messages.count);
    try std.testing.expectEqualStrings("hi", messages.next().?.text);
    try std.testing.expect(messages.next() == null);

    // Clearing the session drops received and queued messages.
    loaded.clear();
    try std.testing.expectEqual(@as(usize, 0), flash.read(&loaded).count);
}

test "flash limits count received messages until they are read" {
    const plugin = testSessions();
    const flash: Flash = .{};
    var req: router.Request = .{ .method = .get, .segments = &.{} };
    var state = try plugin.initRequest(&req);
    try std.testing.expectError(error.InvalidFlashKind, flash.add(&state, "", "x"));
    try std.testing.expectError(error.InvalidFlashKind, flash.add(&state, "has space", "x"));
    try std.testing.expectError(error.InvalidFlashKind, flash.add(&state, "k" ** (max_kind_bytes + 1), "x"));
    try std.testing.expectError(error.FlashTooLarge, flash.add(&state, "n", "x" ** (max_bytes - 3)));
    try std.testing.expect(!state.dirty);
    try flash.add(&state, "n", "x" ** (max_bytes - 4));
    try std.testing.expectError(error.FlashTooLarge, flash.add(&state, "n", ""));
    flash.reset(&state);
    for (0..max_messages) |_| try flash.add(&state, "n", "");
    try std.testing.expectError(error.TooManyFlashMessages, flash.add(&state, "n", ""));

    var res = response.Response.init(std.testing.allocator);
    defer res.deinit();
    try plugin.save(&state, &res);
    const headers = [_]router.Header{.{ .name = "Cookie", .value = cookieValue(res.headers[0].value) }};
    var next_req: router.Request = .{ .method = .get, .segments = &.{}, .headers = &headers };
    var loaded = try plugin.initRequest(&next_req);
    // Unread messages would be persisted again, so they still fill the budget.
    try std.testing.expectError(error.TooManyFlashMessages, flash.add(&loaded, "n", ""));
    try std.testing.expectEqual(@as(usize, max_messages), flash.read(&loaded).count);
    try flash.add(&loaded, "n", "x" ** (max_bytes - 4));

    // The largest session, CSRF secret, and flash still fit one cookie.
    try loaded.set("p" ** sessions.max_payload_bytes);
    _ = try csrf.token(std.testing.io, &loaded);
    try plugin.save(&loaded, &res);
    try std.testing.expect(res.headers[1].value.len <= sessions.max_cookie_bytes);
}

fn signed(comptime body: []const u8) [body.len + 1 + std.base64.url_safe_no_pad.Encoder.calcSize(32)]u8 {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    var out: [body.len + 1 + std.base64.url_safe_no_pad.Encoder.calcSize(32)]u8 = undefined;
    @memcpy(out[0..body.len], body);
    out[body.len] = '.';
    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, body, test_secret);
    _ = std.base64.url_safe_no_pad.Encoder.encode(out[body.len + 1 ..], &mac);
    return out;
}

test "tampered, expired, and malformed flash cookies load an empty session" {
    var app = try testApp();
    defer app.deinit();
    var a: [2][sessions.max_cookie_bytes]u8 = undefined;
    var b: [2][sessions.max_cookie_bytes]u8 = undefined;
    const added = try visit(&app, "add", null, &a);
    const original = added.cookie.?;

    var tampered: [sessions.max_cookie_bytes]u8 = undefined;
    @memcpy(tampered[0..original.len], original);
    // Flip one character of the flash segment, just before the MAC.
    const flash_end = std.mem.lastIndexOfScalar(u8, original, '.').? - 1;
    tampered[flash_end] = if (tampered[flash_end] == 'A') 'B' else 'A';
    try std.testing.expectEqualStrings("", (try visit(&app, "peek", tampered[0..original.len], &b)).body);

    var expired_app = try TestApp.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{ .sessions = .{ .keys = &.{.{ .id = 1, .secret = test_secret }}, .lifetime_seconds = 300, .now_seconds = time2000 } },
        .route_fn = TestRoutes.route,
    });
    defer expired_app.deinit();
    try std.testing.expectEqualStrings("", (try visit(&expired_app, "peek", original, &b)).body);

    // Correctly signed but malformed contents are rejected as a whole, so the
    // payload is not loaded either.
    const prefix = sessions.cookie_name ++ "=";
    const bad = [_][]const u8{
        prefix ++ &signed("v3.1.1300.dXNlcg.."), // empty flash segment
        prefix ++ &signed("v3.1.1300.dXNlcg..AQ"), // truncated entry
        prefix ++ &signed("v3.1.1300.dXNlcg..ASAAAA"), // kind " " is invalid
        prefix ++ &signed("v3.1.1300.dXNlcg..AW4AAQ"), // text longer than entry
        prefix ++ &signed("v3.1.1300.dXNlcg.short.AW4AAA"), // malformed CSRF secret
        prefix ++ &signed("v3.1.1300.dXNlcg..AW4AAAFuAAABbgAAAW4AAAFuAAABbgAAAW4AAAFuAAABbgAA"), // nine messages
    };
    for (bad) |cookie| {
        const headers = [_]router.Header{.{ .name = "Cookie", .value = cookie }};
        var req: router.Request = .{ .method = .get, .segments = &.{}, .headers = &headers };
        const state = try testSessions().initRequest(&req);
        try std.testing.expectEqual(@as(usize, 0), state.value().len);
        try std.testing.expectEqual(@as(usize, 0), state.flash.incoming_count);
        try std.testing.expect(!state.csrf_present);
    }
    // The same framing with one valid message loads both payload and flash.
    const good = prefix ++ &signed("v3.1.1300.dXNlcg..AW4AAA");
    const headers = [_]router.Header{.{ .name = "Cookie", .value = good }};
    var req: router.Request = .{ .method = .get, .segments = &.{}, .headers = &headers };
    const state = try testSessions().initRequest(&req);
    try std.testing.expectEqualStrings("user", state.value());
    try std.testing.expectEqual(@as(usize, 1), state.flash.incoming_count);
}
