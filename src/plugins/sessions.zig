//! Authenticated, client-side cookie sessions (ADR-0001 §3.2, §3.4, Phase 5).
//! The payload is authenticated with HMAC-SHA256, not encrypted: do not store
//! confidential information in it. No response is written during cleanup.
//! Optional server-side `Store` adds revocation (v4 cookies); see PLUGINS.md.
const std = @import("std");
const router = @import("../router.zig");
const response = @import("../response.zig");
const flash = @import("flash.zig");

const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const base64 = std.base64.url_safe_no_pad;

pub const cookie_name = "__Host-zoda_session";
pub const max_payload_bytes: usize = 2048;
pub const max_cookie_bytes: usize = 4096;
pub const max_lifetime_seconds: u32 = 30 * 24 * 60 * 60;

comptime {
    // The largest v4 Set-Cookie value (u8 key ID, i64 expiry, u32 Max-Age)
    // must fit the fixed header buffer in `save`.
    const fields = base64.Encoder.calcSize(max_payload_bytes) + base64.Encoder.calcSize(32) +
        base64.Encoder.calcSize(flash.max_bytes) + base64.Encoder.calcSize(Hmac.mac_length) +
        base64.Encoder.calcSize(16);
    const framing = cookie_name.len + "=v4.255.9223372036854775807......".len +
        "; Max-Age=4294967295; Path=/; Secure; HttpOnly; SameSite=Lax".len;
    std.debug.assert(fields + framing <= max_cookie_bytes);
}

/// Required length of keys made by `Key.generate` and `Key.fromBase64`.
pub const key_bytes: usize = 32;

/// An HMAC-SHA256 signing key. The first key in `Sessions.keys` signs new
/// cookies; every key verifies them. IDs must be unique, as must the secrets.
/// Key bytes are caller-owned and must remain valid for the app lifetime.
///
/// `Sessions` only checks that a secret is at least 32 bytes long. Length is
/// not entropy: the framework cannot tell a random key from a predictable one,
/// so never type a key into source code. Create keys with `generate` or
/// `openssl rand -base64 32`, and load them with `fromBase64` from protected
/// runtime configuration (see PLUGINS.md "Session keys").
///
/// A key authenticates cookies; it does not encrypt them. Anyone holding a
/// cookie can read its payload.
pub const Key = struct {
    id: u8,
    secret: []const u8,

    pub const KeyError = error{InvalidSessionKey};

    /// Fills `out` from the OS CSPRNG and returns a key over it. A key made
    /// at startup is lost on restart, which signs every user out; persist
    /// stable keys in protected configuration instead.
    pub fn generate(io: std.Io, id: u8, out: *[key_bytes]u8) std.Io.RandomSecureError!Key {
        try std.Io.randomSecure(io, out);
        return .{ .id = id, .secret = out };
    }

    /// Decodes a standard-alphabet base64 secret (padding optional), as
    /// printed by `openssl rand -base64 32`, into `out`. Surrounding ASCII
    /// whitespace is ignored. The secret must decode to exactly 32 bytes.
    pub fn fromBase64(id: u8, text: []const u8, out: *[key_bytes]u8) KeyError!Key {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        const decoder = std.base64.standard_no_pad.Decoder;
        const unpadded = std.mem.trimEnd(u8, trimmed, "=");
        const size = decoder.calcSizeForSlice(unpadded) catch return error.InvalidSessionKey;
        if (size != key_bytes) return error.InvalidSessionKey;
        decoder.decode(out, unpadded) catch return error.InvalidSessionKey;
        return .{ .id = id, .secret = out };
    }
};

/// Opaque session identifier length in bytes (128 random bits).
pub const sid_bytes: usize = 16;
/// Longest subject (account ID) a revocable session may be bound to.
pub const max_subject_bytes: usize = 64;

/// Storage failures. Every one of them fails closed: a session whose status
/// cannot be confirmed is never authenticated.
pub const StoreError = error{ SessionStoreUnavailable, SessionStoreFull };

pub const Record = struct {
    subject: [max_subject_bytes]u8 = undefined,
    subject_len: usize = 0,
    /// UTC Unix seconds; the record is invalid at and after this instant.
    expires_at: i64 = 0,
};

/// Server-side session registry (an allowlist: unknown IDs are rejected).
/// Implementations must be safe for concurrent calls, bounded in the work
/// each call does, and linearizable: once `revoke` or `revokeSubject` returns,
/// no later `lookup` may report the revoked record. Return
/// `error.SessionStoreUnavailable` when the status cannot be determined;
/// never answer "found" from a cache that may have missed a revocation.
pub const Store = struct {
    ctx: *anyopaque,
    create_fn: *const fn (*anyopaque, *const [sid_bytes]u8, []const u8, i64) StoreError!void,
    lookup_fn: *const fn (*anyopaque, *const [sid_bytes]u8, *Record) StoreError!bool,
    revoke_fn: *const fn (*anyopaque, *const [sid_bytes]u8) StoreError!void,
    revoke_subject_fn: *const fn (*anyopaque, []const u8) StoreError!void,
};

/// Process-local reference store with fixed capacity and O(capacity) calls.
/// Records vanish on restart (every user is logged out) and are not shared
/// between processes, so use it for tests, development, and single-process
/// deployments only. Expired slots are reclaimed on `create`.
pub fn MemoryStore(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const Slot = struct { used: bool = false, sid: [sid_bytes]u8 = undefined, record: Record = .{} };
        slots: [capacity]Slot = @splat(.{}),
        locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        now_seconds: *const fn () i64,

        pub fn init(now_seconds: *const fn () i64) Self {
            return .{ .now_seconds = now_seconds };
        }

        pub fn store(self: *Self) Store {
            return .{ .ctx = self, .create_fn = create, .lookup_fn = lookup, .revoke_fn = revoke, .revoke_subject_fn = revokeSubject };
        }

        fn lock(self: *Self) void {
            while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
        }

        fn unlock(self: *Self) void {
            self.locked.store(false, .release);
        }

        fn create(ctx: *anyopaque, sid: *const [sid_bytes]u8, subject: []const u8, expires_at: i64) StoreError!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (subject.len > max_subject_bytes) return error.SessionStoreUnavailable;
            self.lock();
            defer self.unlock();
            const now = self.now_seconds();
            for (&self.slots) |*slot| {
                if (slot.used and slot.record.expires_at > now) continue;
                slot.* = .{ .used = true, .sid = sid.*, .record = .{ .subject_len = subject.len, .expires_at = expires_at } };
                @memcpy(slot.record.subject[0..subject.len], subject);
                return;
            }
            return error.SessionStoreFull;
        }

        fn lookup(ctx: *anyopaque, sid: *const [sid_bytes]u8, out: *Record) StoreError!bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.lock();
            defer self.unlock();
            const now = self.now_seconds();
            for (&self.slots) |*slot| {
                if (!slot.used or !std.crypto.timing_safe.eql([sid_bytes]u8, slot.sid, sid.*)) continue;
                if (slot.record.expires_at <= now) return false;
                out.* = slot.record;
                return true;
            }
            return false;
        }

        fn revoke(ctx: *anyopaque, sid: *const [sid_bytes]u8) StoreError!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.lock();
            defer self.unlock();
            for (&self.slots) |*slot| {
                if (slot.used and std.crypto.timing_safe.eql([sid_bytes]u8, slot.sid, sid.*)) slot.used = false;
            }
        }

        fn revokeSubject(ctx: *anyopaque, subject: []const u8) StoreError!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.lock();
            defer self.unlock();
            for (&self.slots) |*slot| {
                if (slot.used and std.mem.eql(u8, slot.record.subject[0..slot.record.subject_len], subject)) slot.used = false;
            }
        }
    };
}

/// Client-side session cookies. **Payloads are signed, not encrypted**: the
/// cookie holder can decode every byte, so never store passwords, tokens,
/// secrets, or sensitive personal data in them. A stateless cookie also cannot
/// be revoked before it expires; set `store` for revocation. Key rotation
/// invalidates sessions as described in PLUGINS.md "Session keys".
pub const Sessions = struct {
    keys: []const Key = &.{},
    /// Optional server-side registry. When set, only revocable v4 cookies are
    /// accepted (stateless v1-v3 cookies are rejected so they cannot bypass
    /// revocation) and identity comes from `State.subject`, never the payload.
    store: ?Store = null,
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
        sid: [sid_bytes]u8 = undefined,
        sid_present: bool = false,
        subject_buf: [max_subject_bytes]u8 = undefined,
        subject_len: usize = 0,
        /// Managed by `zoda.plugins.flash.Flash`.
        flash: flash.Store = .{},

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

        /// The server-verified account this session is bound to, or empty when
        /// unauthenticated. Only meaningful with a configured `Sessions.store`.
        pub fn subject(self: *const State) []const u8 {
            return self.subject_buf[0..self.subject_len];
        }

        /// Requests a deletion cookie on the next explicit save. This only
        /// affects the browser: a copied cookie stays valid unless the session
        /// is revoked server-side. Use `Sessions.logout` for that.
        pub fn clear(self: *State) void {
            self.sid_present = false;
            self.subject_len = 0;
            self.len = 0;
            self.dirty = true;
            self.clearing = true;
            self.csrf_present = false;
            self.flash = .{};
        }
    };

    /// With a store, a store failure while checking a presented session
    /// returns `error.SessionStoreUnavailable` rather than loading it.
    pub fn initRequest(self: *const Sessions, req: *router.Request) (error{InvalidSessionConfig} || StoreError)!State {
        try self.validate();
        var state: State = .{};
        const value_bytes = findCookie(req) orelse return state;
        try self.verify(value_bytes, &state);
        return state;
    }

    /// Binds the session to `subject` under a fresh random identifier
    /// (rotating any previous one, which is revoked) and a fresh CSRF secret.
    /// Call after verifying credentials, then `save`. Requires a store.
    pub fn login(self: *const Sessions, io: std.Io, state: *State, subject: []const u8) (error{ InvalidSessionConfig, InvalidSessionTime, SubjectTooLong } || StoreError || std.Io.RandomSecureError)!void {
        try self.validate();
        const store = self.store orelse return error.InvalidSessionConfig;
        if (subject.len == 0 or subject.len > max_subject_bytes) return error.SubjectTooLong;
        const now = self.now_seconds.?();
        if (now < 0) return error.InvalidSessionTime;
        const expiry = std.math.add(i64, now, self.lifetime_seconds) catch return error.InvalidSessionTime;
        var sid: [sid_bytes]u8 = undefined;
        try std.Io.randomSecure(io, &sid);
        try store.create_fn(store.ctx, &sid, subject, expiry);
        if (state.sid_present) store.revoke_fn(store.ctx, &state.sid) catch {};
        state.sid = sid;
        state.sid_present = true;
        @memcpy(state.subject_buf[0..subject.len], subject);
        state.subject_len = subject.len;
        state.csrf_present = false;
        state.dirty = true;
        state.clearing = false;
    }

    /// Revokes this session server-side, then clears local state. The local
    /// state is cleared even on error, but an error means the server-side
    /// record may still be live: do not report a successful logout.
    pub fn logout(self: *const Sessions, state: *State) StoreError!void {
        const sid = state.sid;
        const present = state.sid_present;
        state.clear();
        const store = self.store orelse return;
        if (present) try store.revoke_fn(store.ctx, &sid);
    }

    /// Revokes every session bound to `subject`. Call after password reset,
    /// account suspension, or privilege changes. Takes effect on the next
    /// request in every process that shares the store.
    pub fn revokeSubject(self: *const Sessions, subject: []const u8) StoreError!void {
        const store = self.store orelse return;
        try store.revoke_subject_fn(store.ctx, subject);
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
            var encoded_csrf: [base64.Encoder.calcSize(32)]u8 = undefined;
            const csrf = if (state.csrf_present) base64.Encoder.encode(&encoded_csrf, &state.csrf_secret) else "";
            var flash_bytes: [flash.max_bytes]u8 = undefined;
            const flash_raw = state.flash.persisted(&flash_bytes);
            var header: [max_cookie_bytes]u8 = undefined;
            const prefix = if (self.store != null) blk: {
                var encoded_sid: [base64.Encoder.calcSize(sid_bytes)]u8 = undefined;
                const sid_text = if (state.sid_present) base64.Encoder.encode(&encoded_sid, &state.sid) else "";
                var encoded_flash: [base64.Encoder.calcSize(flash.max_bytes)]u8 = undefined;
                const flash_text = base64.Encoder.encode(&encoded_flash, flash_raw);
                break :blk std.fmt.bufPrint(&header, "{s}=v4.{d}.{d}.{s}.{s}.{s}.{s}", .{ cookie_name, self.keys[0].id, expiry, sid_text, payload, csrf, flash_text }) catch unreachable;
            } else if (flash_raw.len > 0) blk: {
                var encoded_flash: [base64.Encoder.calcSize(flash.max_bytes)]u8 = undefined;
                const flash_text = base64.Encoder.encode(&encoded_flash, flash_raw);
                break :blk std.fmt.bufPrint(&header, "{s}=v3.{d}.{d}.{s}.{s}.{s}", .{ cookie_name, self.keys[0].id, expiry, payload, csrf, flash_text }) catch unreachable;
            } else if (state.csrf_present)
                std.fmt.bufPrint(&header, "{s}=v2.{d}.{d}.{s}.{s}", .{ cookie_name, self.keys[0].id, expiry, payload, csrf }) catch unreachable
            else
                std.fmt.bufPrint(&header, "{s}=v1.{d}.{d}.{s}", .{ cookie_name, self.keys[0].id, expiry, payload }) catch unreachable;
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
                if (std.mem.eql(u8, earlier.secret, key.secret)) return error.InvalidSessionConfig;
            }
        }
    }

    fn verify(self: *const Sessions, value_bytes: []const u8, state: *State) StoreError!void {
        if (value_bytes.len > max_cookie_bytes) return;
        var parts = std.mem.splitScalar(u8, value_bytes, '.');
        const version = parts.next() orelse return;
        // v2 adds a CSRF secret; v3 adds an optional CSRF secret and flash;
        // v4 (store-backed) adds an opaque session ID and always carries both.
        const revocable = std.mem.eql(u8, version, "v4");
        // A store makes v4 the only acceptable format and vice versa.
        if (revocable != (self.store != null)) return;
        const has_flash = revocable or std.mem.eql(u8, version, "v3");
        const has_csrf = has_flash or std.mem.eql(u8, version, "v2");
        if (!has_csrf and !std.mem.eql(u8, version, "v1")) return;
        const id_text = parts.next() orelse return;
        const expiry_text = parts.next() orelse return;
        const sid_text = if (revocable) parts.next() orelse return else "";
        const payload_text = parts.next() orelse return;
        const csrf_text = if (has_csrf) parts.next() orelse return else "";
        const flash_text = if (has_flash) parts.next() orelse return else "";
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
        // Commit nothing until every field decodes, so a rejected cookie
        // leaves an empty session.
        var sid: [sid_bytes]u8 = undefined;
        var record: Record = .{};
        if (revocable and sid_text.len > 0) {
            if (sid_text.len != base64.Encoder.calcSize(sid_bytes)) return;
            base64.Decoder.decode(&sid, sid_text) catch return;
            // Unknown, revoked, and expired IDs are all "not found"; an
            // outage propagates instead of authenticating.
            const store = self.store.?;
            if (!try store.lookup_fn(store.ctx, &sid, &record)) return;
            if (record.expires_at <= now or record.subject_len > max_subject_bytes) return;
        }
        const csrf_present = has_csrf and !(has_flash and csrf_text.len == 0);
        if (csrf_present) {
            if (csrf_text.len != base64.Encoder.calcSize(32)) return;
            base64.Decoder.decode(&state.csrf_secret, csrf_text) catch return;
        }
        // v3 always carries flash; only v4 may leave the field empty.
        if (has_flash and !(revocable and flash_text.len == 0)) {
            const flash_size = base64.Decoder.calcSizeForSlice(flash_text) catch return;
            if (flash_size > flash.max_bytes) return;
            var flash_bytes: [flash.max_bytes]u8 = undefined;
            base64.Decoder.decode(flash_bytes[0..flash_size], flash_text) catch return;
            if (!state.flash.load(flash_bytes[0..flash_size])) return;
        }
        state.csrf_present = csrf_present;
        state.len = payload_size;
        if (revocable and sid_text.len > 0) {
            state.sid = sid;
            state.sid_present = true;
            state.subject_buf = record.subject;
            state.subject_len = record.subject_len;
        }
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

// TEST ONLY: predictable, public values. Never use them outside tests.
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
    missing = .{ .keys = &.{ .{ .id = 1, .secret = test_key_a }, .{ .id = 2, .secret = test_key_a } }, .lifetime_seconds = 300, .now_seconds = time1000 };
    try std.testing.expectError(error.InvalidSessionConfig, missing.initRequest(&req));
    missing = .{ .keys = &.{ .{ .id = 1, .secret = test_key_a }, .{ .id = 2, .secret = "short" } }, .lifetime_seconds = 300, .now_seconds = time1000 };
    try std.testing.expectError(error.InvalidSessionConfig, missing.initRequest(&req));
    const nine = comptime blk: {
        var keys: [9]Key = undefined;
        for (&keys, 0..) |*k, i| k.* = .{ .id = @intCast(i), .secret = test_key_a ++ &[_]u8{@intCast('a' + i)} };
        break :blk keys;
    };
    missing = .{ .keys = &nine, .lifetime_seconds = 300, .now_seconds = time1000 };
    try std.testing.expectError(error.InvalidSessionConfig, missing.initRequest(&req));
    missing = .{ .keys = &.{.{ .id = 1, .secret = test_key_a }}, .lifetime_seconds = 0, .now_seconds = time1000 };
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

test "key helpers decode exact 32-byte secrets and reject everything else" {
    var buf: [key_bytes]u8 = undefined;
    const b64 = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=";
    const key = try Key.fromBase64(7, b64 ++ "\n", &buf);
    try std.testing.expectEqual(@as(u8, 7), key.id);
    try std.testing.expectEqual(@as(usize, 32), key.secret.len);
    try std.testing.expectEqual(@as(u8, 31), key.secret[31]);
    const unpadded = try Key.fromBase64(7, b64[0 .. b64.len - 1], &buf);
    try std.testing.expectEqualSlices(u8, key.secret, unpadded.secret);
    try std.testing.expectError(error.InvalidSessionKey, Key.fromBase64(1, "", &buf));
    try std.testing.expectError(error.InvalidSessionKey, Key.fromBase64(1, "c2hvcnQ=", &buf));
    try std.testing.expectError(error.InvalidSessionKey, Key.fromBase64(1, "!!!" ++ b64[3..], &buf));
    try std.testing.expectError(error.InvalidSessionKey, Key.fromBase64(1, b64 ++ "AAAA", &buf));

    const io = std.testing.io;
    var a: [key_bytes]u8 = undefined;
    var b: [key_bytes]u8 = undefined;
    const ka = try Key.generate(io, 1, &a);
    const kb = try Key.generate(io, 2, &b);
    try std.testing.expect(!std.mem.eql(u8, ka.secret, kb.secret));
    const plugin = Sessions{ .keys = &.{ ka, kb }, .lifetime_seconds = 300, .now_seconds = time1000 };
    try plugin.validate();
}

test "rotation: retired keys verify until removed, then their cookies are dropped" {
    var req: router.Request = .{ .method = .get, .segments = &.{} };
    const k1 = Key{ .id = 1, .secret = test_key_a };
    const k2 = Key{ .id = 2, .secret = test_key_b };
    const phase1 = Sessions{ .keys = &.{k1}, .lifetime_seconds = 300, .now_seconds = time1000 };
    var state = try phase1.initRequest(&req);
    try state.set("payload");
    var res = response.Response.init(std.testing.allocator);
    defer res.deinit();
    try phase1.save(&state, &res);
    const headers = [_]router.Header{.{ .name = "Cookie", .value = cookieValue(res.headers[0].value) }};
    var cookie_req: router.Request = .{ .method = .get, .segments = &.{}, .headers = &headers };

    // Overlap: new key signs, old key still verifies.
    const overlap = Sessions{ .keys = &.{ k2, k1 }, .lifetime_seconds = 300, .now_seconds = time1000 };
    try std.testing.expectEqualStrings("payload", (try overlap.initRequest(&cookie_req)).value());
    // Verify-only order: the first key signs, so listing k1 first keeps v1.1 cookies.
    // Retired: k1 removed, existing cookies silently become anonymous.
    const retired = Sessions{ .keys = &.{k2}, .lifetime_seconds = 300, .now_seconds = time1000 };
    try std.testing.expectEqual(@as(usize, 0), (try retired.initRequest(&cookie_req)).value().len);
    // Same ID with a different secret (a replaced key) also fails verification.
    const replaced = Sessions{ .keys = &.{.{ .id = 1, .secret = test_key_b }}, .lifetime_seconds = 300, .now_seconds = time1000 };
    try std.testing.expectEqual(@as(usize, 0), (try replaced.initRequest(&cookie_req)).value().len);
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

test "session cookie policy follows success, recovery, failure, and short circuits" {
    const app_mod = @import("../app.zig");
    const A = app_mod.App(struct { sessions: Sessions });
    const Handler = struct {
        fn route(ctx: *A.Context, req: *router.Request, res: *response.Response) !void {
            if (req.isLiteral("saved")) {
                try ctx.state.sessions.set("saved");
                try ctx.plugins.sessions.save(&ctx.state.sessions, res);
                return res.text(200, "ok");
            }
            if (req.isLiteral("fail-saved") or req.isLiteral("recover")) {
                try ctx.state.sessions.set("discarded");
                try ctx.plugins.sessions.save(&ctx.state.sessions, res);
                return error.RouteFailed;
            }
            if (req.isLiteral("fail")) {
                try ctx.state.sessions.set("discarded");
                return error.RouteFailed;
            }
            if (req.isLiteral("read")) return res.text(200, ctx.state.sessions.value());
        }

        fn middleware(_: *const anyopaque, ctx: *A.Context, req: *router.Request, res: *response.Response, next: A.Next) !void {
            if (req.isLiteral("short")) {
                try ctx.state.sessions.set("short");
                try ctx.plugins.sessions.save(&ctx.state.sessions, res);
                return res.text(200, "short");
            }
            if (req.isLiteral("short-unsaved")) {
                try ctx.state.sessions.set("discarded");
                return res.text(403, "denied");
            }
            const recovering = req.segments.len == 1 and std.mem.eql(u8, req.segments[0], "recover");
            next.call(ctx, req, res) catch |err| {
                if (!recovering) return err;
                res.clear();
                // Recovery chooses a fresh cookie policy after clearing the
                // partial response. A dirty session alone writes nothing.
                try ctx.state.sessions.set("recovered");
                try ctx.plugins.sessions.save(&ctx.state.sessions, res);
                return res.text(503, "recovered");
            };
        }
    };
    const mw = A.Middleware{ .config = &.{}, .invoke = Handler.middleware };
    var app = try A.init(std.testing.allocator, .{
        .response_allocator = std.testing.allocator,
        .plugins = .{ .sessions = testPlugin() },
        .route_fn = Handler.route,
        .middleware = &.{mw},
    });
    defer app.deinit();

    var saved_req: router.Request = .{ .method = .get, .segments = &.{"saved"} };
    var saved = try app.dispatch(&saved_req);
    defer saved.deinit();
    try std.testing.expectEqual(@as(usize, 1), saved.header_count);
    const saved_cookie = cookieValue(saved.headers[0].value);

    var fail_req: router.Request = .{ .method = .get, .segments = &.{"fail"} };
    try std.testing.expectError(error.RouteFailed, app.dispatch(&fail_req));
    var fail_saved_req: router.Request = .{ .method = .get, .segments = &.{"fail-saved"} };
    try std.testing.expectError(error.RouteFailed, app.dispatch(&fail_saved_req));
    var read_req: router.Request = .{ .method = .get, .segments = &.{"read"} };
    var read = try app.dispatch(&read_req);
    defer read.deinit();
    try std.testing.expectEqual(@as(usize, 0), read.header_count);
    try std.testing.expectEqual(@as(usize, 0), read.body.len);

    var recover_req: router.Request = .{ .method = .get, .segments = &.{"recover"} };
    var recovered = try app.dispatch(&recover_req);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(u16, 503), recovered.status_code);
    try std.testing.expectEqual(@as(usize, 1), recovered.header_count);
    const recovered_cookie = cookieValue(recovered.headers[0].value);

    var short_req: router.Request = .{ .method = .get, .segments = &.{"short"} };
    var short = try app.dispatch(&short_req);
    defer short.deinit();
    try std.testing.expectEqual(@as(usize, 1), short.header_count);
    var short_unsaved_req: router.Request = .{ .method = .get, .segments = &.{"short-unsaved"} };
    var short_unsaved = try app.dispatch(&short_unsaved_req);
    defer short_unsaved.deinit();
    try std.testing.expectEqual(@as(usize, 0), short_unsaved.header_count);

    // Returned cookie bytes remain valid through later dispatches and after
    // their request state has been destroyed.
    const saved_headers = [_]router.Header{.{ .name = "Cookie", .value = saved_cookie }};
    read_req.headers = &saved_headers;
    read_req.cursor = 0;
    var saved_read = try app.dispatch(&read_req);
    defer saved_read.deinit();
    try std.testing.expectEqualStrings("saved", saved_read.body);
    const recovered_headers = [_]router.Header{.{ .name = "Cookie", .value = recovered_cookie }};
    read_req.headers = &recovered_headers;
    read_req.cursor = 0;
    var recovered_read = try app.dispatch(&read_req);
    defer recovered_read.deinit();
    try std.testing.expectEqualStrings("recovered", recovered_read.body);
}

test "session app instances use independent keys, clocks, and request state concurrently" {
    const app_mod = @import("../app.zig");
    const A = app_mod.App(struct { sessions: Sessions });
    const Handler = struct {
        fn route(ctx: *A.Context, req: *router.Request, res: *response.Response) !void {
            if (req.segments.len == 2 and std.mem.eql(u8, req.segments[0], "set")) {
                try ctx.state.sessions.set(req.segments[1]);
                try ctx.plugins.sessions.save(&ctx.state.sessions, res);
                return res.text(200, "ok");
            }
            return res.text(200, ctx.state.sessions.value());
        }
    };
    const alloc = std.heap.smp_allocator;
    var first = try A.init(alloc, .{ .response_allocator = alloc, .plugins = .{ .sessions = testPlugin() }, .route_fn = Handler.route });
    defer first.deinit();
    var second = try A.init(alloc, .{ .response_allocator = alloc, .plugins = .{ .sessions = .{
        .keys = &.{.{ .id = 2, .secret = test_key_b }},
        .lifetime_seconds = 600,
        .now_seconds = time1200,
    } }, .route_fn = Handler.route });
    defer second.deinit();

    const Worker = struct {
        fn run(a: *const A, other: *const A, value: []const u8, expiry: []const u8, failures: *std.atomic.Value(usize)) void {
            for (0..100) |_| {
                check(a, other, value, expiry) catch {
                    _ = failures.fetchAdd(1, .monotonic);
                };
            }
        }

        fn check(a: *const A, other: *const A, value: []const u8, expiry: []const u8) !void {
            const segments = [_][]const u8{ "set", value };
            var set_req: router.Request = .{ .method = .get, .segments = &segments };
            var res = try a.dispatch(&set_req);
            defer res.deinit();
            try std.testing.expectEqual(@as(usize, 1), res.header_count);
            try std.testing.expect(std.mem.indexOf(u8, res.headers[0].value, expiry) != null);
            const cookie = cookieValue(res.headers[0].value);
            const headers = [_]router.Header{.{ .name = "Cookie", .value = cookie }};
            var read_req: router.Request = .{ .method = .get, .segments = &.{"read"}, .headers = &headers };
            var own = try a.dispatch(&read_req);
            defer own.deinit();
            try std.testing.expectEqualStrings(value, own.body);
            var foreign = try other.dispatch(&read_req);
            defer foreign.deinit();
            try std.testing.expectEqual(@as(usize, 0), foreign.body.len);
            var fresh_req: router.Request = .{ .method = .get, .segments = &.{"read"} };
            var fresh = try a.dispatch(&fresh_req);
            defer fresh.deinit();
            try std.testing.expectEqual(@as(usize, 0), fresh.body.len);
        }
    };
    var failures = std.atomic.Value(usize).init(0);
    const t1 = try std.Thread.spawn(.{}, Worker.run, .{ &first, &second, "first-a", "=v1.1.1300.", &failures });
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{ &first, &second, "first-b", "=v1.1.1300.", &failures });
    const t3 = try std.Thread.spawn(.{}, Worker.run, .{ &second, &first, "second-a", "=v1.2.1800.", &failures });
    const t4 = try std.Thread.spawn(.{}, Worker.run, .{ &second, &first, "second-b", "=v1.2.1800.", &failures });
    t1.join();
    t2.join();
    t3.join();
    t4.join();
    try std.testing.expectEqual(@as(usize, 0), failures.load(.monotonic));
}

test "session cookie save and dispatch release partial allocations" {
    const app_mod = @import("../app.zig");
    const A = app_mod.App(struct { sessions: Sessions });
    const Harness = struct {
        fn route(ctx: *A.Context, _: *router.Request, res: *response.Response) !void {
            try ctx.state.sessions.set("allocated");
            try ctx.plugins.sessions.save(&ctx.state.sessions, res);
            return res.text(200, "ok");
        }

        fn check(allocator: std.mem.Allocator) !void {
            var app = try A.init(std.testing.allocator, .{
                .response_allocator = allocator,
                .plugins = .{ .sessions = testPlugin() },
                .route_fn = route,
            });
            defer app.deinit();
            var req: router.Request = .{ .method = .get, .segments = &.{} };
            var res = try app.dispatch(&req);
            defer res.deinit();
            try std.testing.expectEqual(@as(usize, 1), res.header_count);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.check, .{});
}

var test_now: std.atomic.Value(i64) = std.atomic.Value(i64).init(1000);

fn testNow() i64 {
    return test_now.load(.monotonic);
}

fn revocableFixture(store: *MemoryStore(4)) Sessions {
    test_now.store(1000, .monotonic);
    return .{ .keys = &.{.{ .id = 1, .secret = test_key_a }}, .lifetime_seconds = 300, .now_seconds = testNow, .store = store.store() };
}

fn issue(plugin: *const Sessions, subject: []const u8, res: *response.Response) ![]const u8 {
    var req: router.Request = .{ .method = .get, .segments = &.{} };
    var state = try plugin.initRequest(&req);
    try plugin.login(std.testing.io, &state, subject);
    try state.set("app-data");
    try plugin.save(&state, res);
    return cookieValue(res.headers[res.header_count - 1].value);
}

fn loadWith(plugin: *const Sessions, cookie: []const u8) !Sessions.State {
    const headers = [_]router.Header{.{ .name = "Cookie", .value = cookie }};
    var req: router.Request = .{ .method = .get, .segments = &.{}, .headers = &headers };
    return plugin.initRequest(&req);
}

test "logout revokes a copied cookie so replay fails immediately" {
    var store = MemoryStore(4).init(testNow);
    const plugin = revocableFixture(&store);
    var res = response.Response.init(std.testing.allocator);
    defer res.deinit();
    const copied = try std.testing.allocator.dupe(u8, try issue(&plugin, "user-42", &res));
    defer std.testing.allocator.free(copied);
    try std.testing.expect(std.mem.startsWith(u8, copied, cookie_name ++ "=v4.1."));

    var live = try loadWith(&plugin, copied);
    try std.testing.expectEqualStrings("user-42", live.subject());
    try std.testing.expectEqualStrings("app-data", live.value());
    try plugin.logout(&live);
    try res.setHeader("Set-Cookie", "x=1");
    try plugin.save(&live, &res);

    const replay = try loadWith(&plugin, copied);
    try std.testing.expectEqual(@as(usize, 0), replay.subject().len);
    try std.testing.expectEqual(@as(usize, 0), replay.value().len);
}

test "revokeSubject invalidates every session of one account only" {
    var store = MemoryStore(4).init(testNow);
    const plugin = revocableFixture(&store);
    var res = response.Response.init(std.testing.allocator);
    defer res.deinit();
    const a1 = try std.testing.allocator.dupe(u8, try issue(&plugin, "alice", &res));
    defer std.testing.allocator.free(a1);
    const a2 = try std.testing.allocator.dupe(u8, try issue(&plugin, "alice", &res));
    defer std.testing.allocator.free(a2);
    const b1 = try std.testing.allocator.dupe(u8, try issue(&plugin, "bob", &res));
    defer std.testing.allocator.free(b1);

    try plugin.revokeSubject("alice");
    try std.testing.expectEqual(@as(usize, 0), (try loadWith(&plugin, a1)).subject().len);
    try std.testing.expectEqual(@as(usize, 0), (try loadWith(&plugin, a2)).subject().len);
    try std.testing.expectEqualStrings("bob", (try loadWith(&plugin, b1)).subject());
    // A login after the reset is a new session and works.
    const fresh = try std.testing.allocator.dupe(u8, try issue(&plugin, "alice", &res));
    defer std.testing.allocator.free(fresh);
    try std.testing.expectEqualStrings("alice", (try loadWith(&plugin, fresh)).subject());
}

test "expired, unknown, forged, and stateless cookies fail closed" {
    var store = MemoryStore(4).init(testNow);
    const plugin = revocableFixture(&store);
    var res = response.Response.init(std.testing.allocator);
    defer res.deinit();
    const good = try std.testing.allocator.dupe(u8, try issue(&plugin, "carol", &res));
    defer std.testing.allocator.free(good);

    // Same signing key, valid MAC, but the ID was never issued by this store.
    var other_store = MemoryStore(4).init(testNow);
    const other = revocableFixture(&other_store);
    try std.testing.expectEqual(@as(usize, 0), (try loadWith(&other, good)).subject().len);

    // A stateless cookie signed with the same key is refused in store mode.
    const stateless: Sessions = .{ .keys = plugin.keys, .lifetime_seconds = 300, .now_seconds = testNow };
    var sreq: router.Request = .{ .method = .get, .segments = &.{} };
    var sstate = try stateless.initRequest(&sreq);
    try sstate.set("user=1");
    try stateless.save(&sstate, &res);
    const v1 = cookieValue(res.headers[res.header_count - 1].value);
    try std.testing.expectEqual(@as(usize, 0), (try loadWith(&plugin, v1)).value().len);
    // ...and a v4 cookie is refused without a store.
    try std.testing.expectEqual(@as(usize, 0), (try loadWith(&stateless, good)).value().len);

    // Tampering fails the MAC before any store lookup.
    const bad = try std.testing.allocator.dupe(u8, good);
    defer std.testing.allocator.free(bad);
    bad[cookie_name.len + 1 + "v4.1.1300.".len] ^= 1;
    try std.testing.expectEqual(@as(usize, 0), (try loadWith(&plugin, bad)).subject().len);

    // Expiry wins even though the server record is still present.
    test_now.store(1300, .monotonic);
    try std.testing.expectEqual(@as(usize, 0), (try loadWith(&plugin, good)).subject().len);
    test_now.store(1000, .monotonic);
}

test "store outage fails closed and logout reports it" {
    const Failing = struct {
        down: bool = false,
        inner: *MemoryStore(4),
        fn create(c: *anyopaque, sid: *const [sid_bytes]u8, sub: []const u8, exp: i64) StoreError!void {
            const self: *@This() = @ptrCast(@alignCast(c));
            return self.inner.store().create_fn(self.inner.store().ctx, sid, sub, exp);
        }
        fn lookup(c: *anyopaque, sid: *const [sid_bytes]u8, out: *Record) StoreError!bool {
            const self: *@This() = @ptrCast(@alignCast(c));
            if (self.down) return error.SessionStoreUnavailable;
            return self.inner.store().lookup_fn(self.inner.store().ctx, sid, out);
        }
        fn revoke(c: *anyopaque, sid: *const [sid_bytes]u8) StoreError!void {
            const self: *@This() = @ptrCast(@alignCast(c));
            if (self.down) return error.SessionStoreUnavailable;
            return self.inner.store().revoke_fn(self.inner.store().ctx, sid);
        }
        fn revokeSubject(c: *anyopaque, sub: []const u8) StoreError!void {
            const self: *@This() = @ptrCast(@alignCast(c));
            if (self.down) return error.SessionStoreUnavailable;
            return self.inner.store().revoke_subject_fn(self.inner.store().ctx, sub);
        }
    };
    var mem = MemoryStore(4).init(testNow);
    var failing: Failing = .{ .inner = &mem };
    test_now.store(1000, .monotonic);
    const plugin: Sessions = .{ .keys = &.{.{ .id = 1, .secret = test_key_a }}, .lifetime_seconds = 300, .now_seconds = testNow, .store = .{
        .ctx = &failing,
        .create_fn = Failing.create,
        .lookup_fn = Failing.lookup,
        .revoke_fn = Failing.revoke,
        .revoke_subject_fn = Failing.revokeSubject,
    } };
    var res = response.Response.init(std.testing.allocator);
    defer res.deinit();
    const cookie = try std.testing.allocator.dupe(u8, try issue(&plugin, "dave", &res));
    defer std.testing.allocator.free(cookie);

    failing.down = true;
    try std.testing.expectError(error.SessionStoreUnavailable, loadWith(&plugin, cookie));
    try std.testing.expectError(error.SessionStoreUnavailable, plugin.revokeSubject("dave"));
    var state: Sessions.State = .{};
    state.sid_present = true;
    try std.testing.expectError(error.SessionStoreUnavailable, plugin.logout(&state));
    try std.testing.expect(!state.sid_present);
    failing.down = false;
    try std.testing.expectEqualStrings("dave", (try loadWith(&plugin, cookie)).subject());
}

test "store capacity is bounded and expired slots are reclaimed" {
    var store = MemoryStore(2).init(testNow);
    test_now.store(1000, .monotonic);
    const plugin: Sessions = .{ .keys = &.{.{ .id = 1, .secret = test_key_a }}, .lifetime_seconds = 300, .now_seconds = testNow, .store = store.store() };
    var state: Sessions.State = .{};
    var second: Sessions.State = .{};
    try plugin.login(std.testing.io, &state, "a");
    try plugin.login(std.testing.io, &second, "a");
    var other: Sessions.State = .{};
    try std.testing.expectError(error.SessionStoreFull, plugin.login(std.testing.io, &other, "b"));
    test_now.store(1301, .monotonic);
    try plugin.login(std.testing.io, &other, "b");
    test_now.store(1000, .monotonic);
}

test "concurrent requests race logout and never authenticate after it returns" {
    var store = MemoryStore(4).init(testNow);
    const plugin = revocableFixture(&store);
    var res = response.Response.init(std.testing.allocator);
    defer res.deinit();
    const cookie = try std.testing.allocator.dupe(u8, try issue(&plugin, "erin", &res));
    defer std.testing.allocator.free(cookie);

    const Worker = struct {
        fn run(p: *const Sessions, c: []const u8, revoked: *const std.atomic.Value(bool), violations: *std.atomic.Value(usize)) void {
            for (0..2000) |_| {
                const done = revoked.load(.acquire);
                const st = loadWith(p, c) catch {
                    _ = violations.fetchAdd(1, .monotonic);
                    return;
                };
                if (done and st.subject().len != 0) _ = violations.fetchAdd(1, .monotonic);
            }
        }
    };
    var revoked = std.atomic.Value(bool).init(false);
    var violations = std.atomic.Value(usize).init(0);
    var threads: [3]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &plugin, cookie, &revoked, &violations });
    try plugin.revokeSubject("erin");
    revoked.store(true, .release);
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(usize, 0), violations.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), (try loadWith(&plugin, cookie)).subject().len);
}
