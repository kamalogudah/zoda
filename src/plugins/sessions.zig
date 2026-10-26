//! Authenticated, client-side cookie sessions (ADR-0001 §3.2, §3.4, Phase 5).
//! The payload is authenticated with HMAC-SHA256, not encrypted: do not store
//! confidential information in it. No response is written during cleanup.
const std = @import("std");
const router = @import("../router.zig");
const response = @import("../response.zig");

const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const base64 = std.base64.url_safe_no_pad;

pub const cookie_name = "__Host-zoda_session";
pub const max_payload_bytes: usize = 2048;
pub const max_cookie_bytes: usize = 4096;
pub const max_lifetime_seconds: u32 = 30 * 24 * 60 * 60;

/// The first key signs new cookies; all keys verify them. IDs must be unique.
/// Key bytes are caller-owned and must remain valid for the app lifetime.
pub const Key = struct {
    id: u8,
    secret: []const u8,
};

pub const Sessions = struct {
    keys: []const Key = &.{},
    lifetime_seconds: u32 = 0,
    /// UTC Unix seconds. Supply a trusted wall clock; tests can inject one.
    now_seconds: ?*const fn () i64 = null,

    pub const State = struct {
        bytes: [max_payload_bytes]u8 = undefined,
        len: usize = 0,
        dirty: bool = false,
        clearing: bool = false,
        csrf_secret: [32]u8 = undefined,
        csrf_present: bool = false,
        csrf_token: [base64.Encoder.calcSize(32)]u8 = undefined,

        pub fn value(self: *const State) []const u8 {
            return self.bytes[0..self.len];
        }

        /// Copies opaque session bytes. Call `Sessions.save` before returning.
        pub fn set(self: *State, value_bytes: []const u8) error{SessionTooLarge}!void {
            if (value_bytes.len > max_payload_bytes) return error.SessionTooLarge;
            @memcpy(self.bytes[0..value_bytes.len], value_bytes);
            self.len = value_bytes.len;
            self.dirty = true;
            self.clearing = false;
        }

        /// Requests a deletion cookie on the next explicit save.
        pub fn clear(self: *State) void {
            self.len = 0;
            self.dirty = true;
            self.clearing = true;
            self.csrf_present = false;
        }
    };

    pub fn initRequest(self: *const Sessions, req: *router.Request) error{InvalidSessionConfig}!State {
        try self.validate();
        var state: State = .{};
        const value_bytes = findCookie(req) orelse return state;
        self.verify(value_bytes, &state);
        return state;
    }

    pub fn deinitRequest(_: *const Sessions, _: *State) void {}

    /// Explicitly appends one Set-Cookie field. A failed append leaves `state`
    /// dirty so the caller may retry; response header bounds remain enforced.
    pub fn save(self: *const Sessions, state: *State, res: *response.Response) (error{ InvalidSessionConfig, InvalidSessionTime } || response.HeaderError)!void {
        try self.validate();
        if (!state.dirty) return;
        if (state.clearing) {
            try res.setHeader("Set-Cookie", cookie_name ++ "=; Max-Age=0; Path=/; Secure; HttpOnly; SameSite=Lax");
        } else {
            const now = self.now_seconds.?();
            if (now < 0) return error.InvalidSessionTime;
            const expiry = std.math.add(i64, now, self.lifetime_seconds) catch return error.InvalidSessionTime;
            var encoded: [base64.Encoder.calcSize(max_payload_bytes)]u8 = undefined;
            const payload = base64.Encoder.encode(&encoded, state.value());
            var header: [max_cookie_bytes]u8 = undefined;
            const prefix = if (state.csrf_present) blk: {
                var encoded_csrf: [base64.Encoder.calcSize(32)]u8 = undefined;
                const csrf = base64.Encoder.encode(&encoded_csrf, &state.csrf_secret);
                break :blk std.fmt.bufPrint(&header, "{s}=v2.{d}.{d}.{s}.{s}", .{ cookie_name, self.keys[0].id, expiry, payload, csrf }) catch unreachable;
            } else std.fmt.bufPrint(&header, "{s}=v1.{d}.{d}.{s}", .{ cookie_name, self.keys[0].id, expiry, payload }) catch unreachable;
            const signed = prefix[cookie_name.len + 1 ..];
            var mac: [Hmac.mac_length]u8 = undefined;
            Hmac.create(&mac, signed, self.keys[0].secret);
            var encoded_mac: [base64.Encoder.calcSize(Hmac.mac_length)]u8 = undefined;
            const tag = base64.Encoder.encode(&encoded_mac, &mac);
            const suffix = std.fmt.bufPrint(header[prefix.len..], ".{s}; Max-Age={d}; Path=/; Secure; HttpOnly; SameSite=Lax", .{ tag, self.lifetime_seconds }) catch unreachable;
            const total = prefix.len + suffix.len;
            if (total > max_cookie_bytes) unreachable;
            try res.setHeader("Set-Cookie", header[0..total]);
        }
        state.dirty = false;
    }

    fn validate(self: *const Sessions) error{InvalidSessionConfig}!void {
        if (self.keys.len == 0 or self.keys.len > 8 or self.now_seconds == null or
            self.lifetime_seconds == 0 or self.lifetime_seconds > max_lifetime_seconds) return error.InvalidSessionConfig;
        for (self.keys, 0..) |key, i| {
            if (key.secret.len < 32) return error.InvalidSessionConfig;
            for (self.keys[0..i]) |earlier| {
                if (earlier.id == key.id) return error.InvalidSessionConfig;
            }
        }
    }

    fn verify(self: *const Sessions, value_bytes: []const u8, state: *State) void {
        if (value_bytes.len > max_cookie_bytes) return;
        var parts = std.mem.splitScalar(u8, value_bytes, '.');
        const version = parts.next() orelse return;
        const has_csrf = std.mem.eql(u8, version, "v2");
        if (!has_csrf and !std.mem.eql(u8, version, "v1")) return;
        const id_text = parts.next() orelse return;
        const expiry_text = parts.next() orelse return;
        const payload_text = parts.next() orelse return;
        const csrf_text = if (has_csrf) parts.next() orelse return else "";
        const mac_text = parts.next() orelse return;
        if (parts.next() != null) return;
        const id = std.fmt.parseInt(u8, id_text, 10) catch return;
        const expiry = std.fmt.parseInt(i64, expiry_text, 10) catch return;
        const now = self.now_seconds.?();
        if (now < 0 or expiry <= now or expiry -| now > self.lifetime_seconds) return;
        const key = for (self.keys) |candidate| {
            if (candidate.id == id) break candidate;
        } else return;
        if (mac_text.len != base64.Encoder.calcSize(Hmac.mac_length)) return;
        var received: [Hmac.mac_length]u8 = undefined;
        base64.Decoder.decode(&received, mac_text) catch return;
        const signed = value_bytes[0 .. value_bytes.len - mac_text.len - 1];
        var expected: [Hmac.mac_length]u8 = undefined;
        Hmac.create(&expected, signed, key.secret);
        if (!std.crypto.timing_safe.eql([Hmac.mac_length]u8, received, expected)) return;
        const payload_size = base64.Decoder.calcSizeForSlice(payload_text) catch return;
        if (payload_size > max_payload_bytes) return;
        base64.Decoder.decode(state.bytes[0..payload_size], payload_text) catch return;
        if (has_csrf) {
            if (csrf_text.len != base64.Encoder.calcSize(32)) return;
            base64.Decoder.decode(&state.csrf_secret, csrf_text) catch return;
            state.csrf_present = true;
        }
        state.len = payload_size;
    }
};

/// Duplicate session names, including across Cookie fields, are rejected.
fn findCookie(req: *const router.Request) ?[]const u8 {
    var found: ?[]const u8 = null;
    var it = req.getAllHeaders("Cookie");
    while (it.next()) |header| {
        var pairs = std.mem.splitScalar(u8, header, ';');
        while (pairs.next()) |pair| {
            const trimmed = std.mem.trim(u8, pair, " \t");
            const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            if (!std.mem.eql(u8, trimmed[0..equals], cookie_name)) continue;
            if (found != null) return null;
            found = trimmed[equals + 1 ..];
        }
    }
    return found;
}

const test_key_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const test_key_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

fn time1000() i64 {
    return 1000;
}

fn time1200() i64 {
    return 1200;
}

fn time2000() i64 {
    return 2000;
}

fn time1300() i64 {
    return 1300;
}

fn testPlugin() Sessions {
    return .{ .keys = &.{.{ .id = 1, .secret = test_key_a }}, .lifetime_seconds = 300, .now_seconds = time1000 };
}

fn cookieValue(set_cookie: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, set_cookie, ';').?;
    return set_cookie[0..end];
}

test "session round trip requires explicit save and preserves other Set-Cookie fields" {
    const plugin = testPlugin();
    var first_req: router.Request = .{ .method = .get, .segments = &.{} };
    var state = try plugin.initRequest(&first_req);
    defer plugin.deinitRequest(&state);
    try std.testing.expectEqual(@as(usize, 0), state.value().len);
    try state.set("user=42");
    var res = response.Response.init(std.testing.allocator);
    defer res.deinit();
    try res.setHeader("Set-Cookie", "other=1; Path=/");
    try std.testing.expectEqual(@as(usize, 1), res.header_count);
    try plugin.save(&state, &res);
    try std.testing.expectEqual(@as(usize, 2), res.header_count);
    const session_header = res.headers[1].value;
    try std.testing.expect(std.mem.startsWith(u8, session_header, cookie_name ++ "=v1.1.1300."));
    try std.testing.expect(std.mem.endsWith(u8, session_header, "; Max-Age=300; Path=/; Secure; HttpOnly; SameSite=Lax"));
    try plugin.save(&state, &res);
    try std.testing.expectEqual(@as(usize, 2), res.header_count);

    const incoming = [_]router.Header{.{ .name = "Cookie", .value = cookieValue(session_header) }};
    var next_req: router.Request = .{ .method = .get, .segments = &.{}, .headers = &incoming };
    var loaded = try plugin.initRequest(&next_req);
    try std.testing.expectEqualStrings("user=42", loaded.value());
    try std.testing.expect(!loaded.dirty);
    plugin.deinitRequest(&loaded);
}

test "tampered, malformed, expired, oversized, and duplicated cookies load empty" {
    const plugin = testPlugin();
    var req: router.Request = .{ .method = .get, .segments = &.{} };
    var state = try plugin.initRequest(&req);
    try state.set("safe");
    var res = response.Response.init(std.testing.allocator);
    defer res.deinit();
    try plugin.save(&state, &res);
    const original = cookieValue(res.headers[0].value);

    const tampered = try std.testing.allocator.dupe(u8, original);
    defer std.testing.allocator.free(tampered);
    tampered[cookie_name.len + 1 + "v1.1.1300.".len] = 'X';
    const bad_tag = try std.testing.allocator.dupe(u8, original);
    defer std.testing.allocator.free(bad_tag);
    bad_tag[bad_tag.len - 1] = if (bad_tag[bad_tag.len - 1] == 'A') 'B' else 'A';
    const invalid_values = [_][]const u8{
        tampered,
        bad_tag,
        cookie_name ++ "=v1.1.nope.c2FmZQ.x",
        cookie_name ++ "=garbage",
        cookie_name ++ "=v1.9.1300.c2FmZQ.x",
    };
    for (invalid_values) |value_bytes| {
        const headers = [_]router.Header{.{ .name = "Cookie", .value = value_bytes }};
        var bad_req: router.Request = .{ .method = .get, .segments = &.{}, .headers = &headers };
        const empty = try plugin.initRequest(&bad_req);
        try std.testing.expectEqual(@as(usize, 0), empty.value().len);
    }

    const expired_plugin = Sessions{ .keys = plugin.keys, .lifetime_seconds = 300, .now_seconds = time2000 };
    const old_headers = [_]router.Header{.{ .name = "Cookie", .value = original }};
    var old_req: router.Request = .{ .method = .get, .segments = &.{}, .headers = &old_headers };
    const expired = try expired_plugin.initRequest(&old_req);
    try std.testing.expectEqual(@as(usize, 0), expired.value().len);
    const boundary_plugin = Sessions{ .keys = plugin.keys, .lifetime_seconds = 300, .now_seconds = time1300 };
    const at_expiry = try boundary_plugin.initRequest(&old_req);
    try std.testing.expectEqual(@as(usize, 0), at_expiry.value().len);

    const duplicate = [_]router.Header{
        .{ .name = "Cookie", .value = original },
        .{ .name = "Cookie", .value = original },
    };
    var dup_req: router.Request = .{ .method = .get, .segments = &.{}, .headers = &duplicate };
    const rejected = try plugin.initRequest(&dup_req);
    try std.testing.expectEqual(@as(usize, 0), rejected.value().len);

    var huge: [max_cookie_bytes + 1]u8 = undefined;
    @memset(&huge, 'x');
    const oversized = [_]router.Header{.{ .name = "Cookie", .value = cookie_name ++ "=" ++ huge }};
    var huge_req: router.Request = .{ .method = .get, .segments = &.{}, .headers = &oversized };
    const rejected_huge = try plugin.initRequest(&huge_req);
    try std.testing.expectEqual(@as(usize, 0), rejected_huge.value().len);
}

test "configuration, payload size, deletion, and key rotation" {
    var req: router.Request = .{ .method = .get, .segments = &.{} };
    var missing = Sessions{};
    try std.testing.expectError(error.InvalidSessionConfig, missing.initRequest(&req));
    missing = .{ .keys = &.{.{ .id = 1, .secret = "short" }}, .lifetime_seconds = 300, .now_seconds = time1000 };
    try std.testing.expectError(error.InvalidSessionConfig, missing.initRequest(&req));
    missing = .{ .keys = &.{.{ .id = 1, .secret = test_key_a }}, .lifetime_seconds = 300 };
    try std.testing.expectError(error.InvalidSessionConfig, missing.initRequest(&req));
    missing = .{ .keys = &.{ .{ .id = 1, .secret = test_key_a }, .{ .id = 1, .secret = test_key_b } }, .lifetime_seconds = 300, .now_seconds = time1000 };
    try std.testing.expectError(error.InvalidSessionConfig, missing.initRequest(&req));
    missing = .{ .keys = &.{.{ .id = 1, .secret = test_key_a }}, .lifetime_seconds = max_lifetime_seconds + 1, .now_seconds = time1000 };
    try std.testing.expectError(error.InvalidSessionConfig, missing.initRequest(&req));

    const old_plugin = testPlugin();
    var state = try old_plugin.initRequest(&req);
    var too_big: [max_payload_bytes + 1]u8 = undefined;
    @memset(&too_big, 'q');
    try std.testing.expectError(error.SessionTooLarge, state.set(&too_big));
    try std.testing.expectEqual(@as(usize, 0), state.value().len);
    try state.set("old-key");
    var res = response.Response.init(std.testing.allocator);
    defer res.deinit();
    try old_plugin.save(&state, &res);
    const old_cookie = cookieValue(res.headers[0].value);

    const rotated = Sessions{ .keys = &.{ .{ .id = 2, .secret = test_key_b }, .{ .id = 1, .secret = test_key_a } }, .lifetime_seconds = 300, .now_seconds = time1200 };
    const headers = [_]router.Header{.{ .name = "Cookie", .value = old_cookie }};
    var next_req: router.Request = .{ .method = .get, .segments = &.{}, .headers = &headers };
    var loaded = try rotated.initRequest(&next_req);
    try std.testing.expectEqualStrings("old-key", loaded.value());
    try loaded.set("new-key");
    try rotated.save(&loaded, &res);
    try std.testing.expect(std.mem.startsWith(u8, res.headers[1].value, cookie_name ++ "=v1.2."));
    const new_cookie = cookieValue(res.headers[1].value);
    const new_headers = [_]router.Header{.{ .name = "Cookie", .value = new_cookie }};
    var new_req: router.Request = .{ .method = .get, .segments = &.{}, .headers = &new_headers };
    const no_old_key = try old_plugin.initRequest(&new_req);
    try std.testing.expectEqual(@as(usize, 0), no_old_key.value().len);

    loaded.clear();
    try rotated.save(&loaded, &res);
    try std.testing.expectEqualStrings(cookie_name ++ "=; Max-Age=0; Path=/; Secure; HttpOnly; SameSite=Lax", res.headers[2].value);
}

test "failed response header append keeps the session dirty" {
    const plugin = testPlugin();
    var req: router.Request = .{ .method = .get, .segments = &.{} };
    var state = try plugin.initRequest(&req);
    try state.set("retry");
    var limited = response.Response.initWithLimits(std.testing.allocator, .{ .max_headers = 0 });
    defer limited.deinit();
    try std.testing.expectError(error.TooManyHeaders, plugin.save(&state, &limited));
    try std.testing.expect(state.dirty);
    try std.testing.expectEqual(@as(usize, 0), limited.header_count);
    var regular = response.Response.init(std.testing.allocator);
    defer regular.deinit();
    try plugin.save(&state, &regular);
    try std.testing.expect(!state.dirty);
}

test "app generated session state is isolated and short circuits persist explicitly" {
    const app_mod = @import("../app.zig");
    const Plugins = struct { sessions: Sessions };
    const A = app_mod.App(Plugins);
    const Handler = struct {
        fn route(ctx: *A.Context, req: *router.Request, res: *response.Response) !void {
            if (req.isLiteral("set")) {
                try ctx.state.sessions.set("route");
                try ctx.plugins.sessions.save(&ctx.state.sessions, res);
                return res.text(200, "saved");
            }
            if (req.isLiteral("unsaved")) {
                try ctx.state.sessions.set("discarded");
                return res.text(200, "unsaved");
            }
            if (req.isLiteral("read")) return res.text(200, ctx.state.sessions.value());
        }

        fn middleware(_: *const anyopaque, ctx: *A.Context, req: *router.Request, res: *response.Response, next: A.Next) !void {
            if (req.isLiteral("short")) {
                try ctx.state.sessions.set("short-circuit");
                try ctx.plugins.sessions.save(&ctx.state.sessions, res);
                return res.text(200, "short");
            }
            return next.call(ctx, req, res);
        }
    };
    const entry = A.Middleware{ .config = &.{}, .invoke = Handler.middleware };
    var app = try A.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{ .sessions = testPlugin() },
        .route_fn = Handler.route,
        .middleware = &.{entry},
    });
    defer app.deinit();

    var set_req: router.Request = .{ .method = .get, .segments = &.{"set"} };
    var set_res = try app.dispatch(&set_req);
    defer set_res.deinit();
    try std.testing.expectEqual(@as(usize, 1), set_res.header_count);

    var unsaved_req: router.Request = .{ .method = .get, .segments = &.{"unsaved"} };
    var unsaved_res = try app.dispatch(&unsaved_req);
    defer unsaved_res.deinit();
    try std.testing.expectEqual(@as(usize, 0), unsaved_res.header_count);

    var read_req: router.Request = .{ .method = .get, .segments = &.{"read"} };
    var read_res = try app.dispatch(&read_req);
    defer read_res.deinit();
    try std.testing.expectEqual(@as(usize, 0), read_res.body.len);

    var short_req: router.Request = .{ .method = .get, .segments = &.{"short"} };
    var short_res = try app.dispatch(&short_req);
    defer short_res.deinit();
    try std.testing.expectEqualStrings("short", short_res.body);
    try std.testing.expectEqual(@as(usize, 1), short_res.header_count);
}
