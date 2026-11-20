//! Optional S3-compatible object storage: an AWS Signature Version 4 signer
//! and a minimal path-style put/get/delete client (S3, R2, MinIO, SeaweedFS).
//!
//! `sign` is pure (no I/O, injected time) and checked against the published
//! AWS S3 SigV4 examples. `Store` is a thin client over `std.http.Client`.
//! Objects are buffered in memory; there is no streaming, multipart upload,
//! listing, or presigned URLs. Requests send `Connection: close` because
//! `std.http.Client` can block forever on a keep-alive `204` (S3 DELETE).
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Credentials = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
    /// Temporary-credential token (STS); sent as `x-amz-security-token`.
    session_token: ?[]const u8 = null,
};

/// SHA-256 of the empty payload, as lowercase hex.
pub const empty_payload_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

pub const Signed = struct {
    /// `YYYYMMDDTHHMMSSZ`; send as `x-amz-date`.
    amz_date: [16]u8,
    /// Allocated `Authorization` header value; free with the same allocator.
    authorization: []u8,

    pub fn deinit(self: Signed, allocator: Allocator) void {
        allocator.free(self.authorization);
    }
};

pub const SignParams = struct {
    credentials: Credentials,
    region: []const u8,
    service: []const u8 = "s3",
    method: []const u8,
    /// Value of the Host header (including `:port` when not the default).
    host: []const u8,
    /// Raw, unencoded absolute path (e.g. `/bucket/some key.txt`). Each
    /// segment is percent-encoded once, as S3 requires.
    path: []const u8,
    /// Already-canonical query string (sorted, encoded); empty for none.
    query: []const u8 = "",
    /// Lowercase hex SHA-256 of the body.
    payload_hash: []const u8,
    /// Additional headers to sign (lowercase names, trimmed values), e.g.
    /// `range`. `host`, `x-amz-date`, `x-amz-content-sha256` and the session
    /// token are added automatically and must not be listed.
    extra_headers: []const std.http.Header = &.{},
    unix_seconds: i64,
};

pub const SignError = error{ OutOfMemory, InvalidTimestamp };

/// Formats unix seconds as `YYYYMMDDTHHMMSSZ`.
pub fn formatAmzDate(unix_seconds: i64) error{InvalidTimestamp}![16]u8 {
    if (unix_seconds < 0) return error.InvalidTimestamp;
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(unix_seconds) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    if (yd.year > 9999) return error.InvalidTimestamp;
    var out: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch unreachable;
    return out;
}

pub fn sha256Hex(data: []const u8) [64]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

/// Percent-encodes `raw` for a canonical URI, leaving `/` intact.
pub fn writeEncodedPath(w: *Io.Writer, raw: []const u8) Io.Writer.Error!void {
    for (raw) |c| {
        if (isUnreserved(c) or c == '/') {
            try w.writeByte(c);
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
}

fn lessHeader(_: void, a: std.http.Header, b: std.http.Header) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Computes the SigV4 `Authorization` header value.
pub fn sign(allocator: Allocator, p: SignParams) SignError!Signed {
    const amz_date = try formatAmzDate(p.unix_seconds);
    const date = amz_date[0..8];

    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "host", .value = p.host });
    try headers.append(allocator, .{ .name = "x-amz-content-sha256", .value = p.payload_hash });
    try headers.append(allocator, .{ .name = "x-amz-date", .value = &amz_date });
    if (p.credentials.session_token) |t| {
        try headers.append(allocator, .{ .name = "x-amz-security-token", .value = t });
    }
    try headers.appendSlice(allocator, p.extra_headers);
    std.mem.sort(std.http.Header, headers.items, {}, lessHeader);

    var canon: Io.Writer.Allocating = .init(allocator);
    defer canon.deinit();
    const w = &canon.writer;
    w.print("{s}\n", .{p.method}) catch return error.OutOfMemory;
    writeEncodedPath(w, p.path) catch return error.OutOfMemory;
    w.print("\n{s}\n", .{p.query}) catch return error.OutOfMemory;
    for (headers.items) |h| w.print("{s}:{s}\n", .{ h.name, h.value }) catch return error.OutOfMemory;
    w.writeByte('\n') catch return error.OutOfMemory;
    for (headers.items, 0..) |h, i| {
        if (i != 0) w.writeByte(';') catch return error.OutOfMemory;
        w.writeAll(h.name) catch return error.OutOfMemory;
    }
    const signed_headers_end = canon.written().len;
    w.print("\n{s}", .{p.payload_hash}) catch return error.OutOfMemory;

    const canonical = canon.written();
    const hashed_canonical = sha256Hex(canonical);

    var scope_buf: [128]u8 = undefined;
    const scope = std.fmt.bufPrint(&scope_buf, "{s}/{s}/{s}/aws4_request", .{ date, p.region, p.service }) catch return error.OutOfMemory;

    var sts_buf: [320]u8 = undefined;
    const string_to_sign = std.fmt.bufPrint(&sts_buf, "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{ amz_date, scope, hashed_canonical }) catch return error.OutOfMemory;

    var key_seed_buf: [256]u8 = undefined;
    const key_seed = std.fmt.bufPrint(&key_seed_buf, "AWS4{s}", .{p.credentials.secret_access_key}) catch return error.OutOfMemory;
    var k_date: [32]u8 = undefined;
    var k_region: [32]u8 = undefined;
    var k_service: [32]u8 = undefined;
    var k_signing: [32]u8 = undefined;
    HmacSha256.create(&k_date, date, key_seed);
    HmacSha256.create(&k_region, p.region, &k_date);
    HmacSha256.create(&k_service, p.service, &k_region);
    HmacSha256.create(&k_signing, "aws4_request", &k_service);
    var sig: [32]u8 = undefined;
    HmacSha256.create(&sig, string_to_sign, &k_signing);
    const sig_hex = std.fmt.bytesToHex(sig, .lower);

    // Signed-header names are the last line before the payload hash.
    const names_start = std.mem.lastIndexOfScalar(u8, canonical[0..signed_headers_end], '\n').? + 1;
    const authorization = std.fmt.allocPrint(
        allocator,
        "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}",
        .{ p.credentials.access_key_id, scope, canonical[names_start..signed_headers_end], sig_hex },
    ) catch return error.OutOfMemory;
    return .{ .amz_date = amz_date, .authorization = authorization };
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

pub const Config = struct {
    /// Scheme and authority, e.g. `https://s3.us-east-1.amazonaws.com` or
    /// `http://127.0.0.1:8333`. No path, query, or userinfo.
    endpoint: []const u8,
    region: []const u8 = "us-east-1",
    bucket: []const u8,
    credentials: Credentials,
    /// Largest object `get` will buffer.
    max_object_bytes: usize = 16 * 1024 * 1024,
};

pub const StoreError = error{
    InvalidEndpoint,
    InvalidKey,
    /// 404 from the server (`get` and `delete`).
    NotFound,
    /// Any other non-2xx status.
    RequestFailed,
    ObjectTooLarge,
    OutOfMemory,
    InvalidTimestamp,
    Transport,
};

pub const Store = struct {
    allocator: Allocator,
    io: Io,
    config: Config,
    http: std.http.Client,

    pub fn init(allocator: Allocator, io: Io, config: Config) Store {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .http = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(self: *Store) void {
        self.http.deinit();
    }

    /// Uploads `body` under `key`, replacing any existing object.
    pub fn put(self: *Store, key: []const u8, body: []const u8, content_type: ?[]const u8) StoreError!void {
        const r = try self.perform(.PUT, key, body, content_type);
        self.allocator.free(r);
    }

    /// Returns the object's bytes (caller frees), or `error.NotFound`.
    pub fn get(self: *Store, key: []const u8) StoreError![]u8 {
        return self.perform(.GET, key, null, null);
    }

    /// Deletes `key`. S3 reports success for missing keys; some compatible
    /// servers answer 404, which is mapped to `error.NotFound`.
    pub fn delete(self: *Store, key: []const u8) StoreError!void {
        const r = try self.perform(.DELETE, key, null, null);
        self.allocator.free(r);
    }

    fn perform(self: *Store, method: std.http.Method, key: []const u8, body: ?[]const u8, content_type: ?[]const u8) StoreError![]u8 {
        try validateKey(key);
        const a = self.allocator;
        const base = std.Uri.parse(self.config.endpoint) catch return error.InvalidEndpoint;
        if (!std.ascii.eqlIgnoreCase(base.scheme, "http") and !std.ascii.eqlIgnoreCase(base.scheme, "https")) return error.InvalidEndpoint;
        if (base.user != null or base.password != null or base.query != null or base.fragment != null) return error.InvalidEndpoint;
        const host_raw = base.host orelse return error.InvalidEndpoint;
        var host_buf: [256]u8 = undefined;
        const host_name = host_raw.toRaw(&host_buf) catch return error.InvalidEndpoint;
        const host_header = if (base.port) |port|
            std.fmt.allocPrint(a, "{s}:{d}", .{ host_name, port }) catch return error.OutOfMemory
        else
            a.dupe(u8, host_name) catch return error.OutOfMemory;
        defer a.free(host_header);

        const raw_path = std.fmt.allocPrint(a, "/{s}/{s}", .{ self.config.bucket, key }) catch return error.OutOfMemory;
        defer a.free(raw_path);

        const payload_hash: [64]u8 = if (body) |b| sha256Hex(b) else empty_payload_hash.*;
        const now_ns = Io.Clock.real.now(self.io).nanoseconds;
        const signed = try sign(a, .{
            .credentials = self.config.credentials,
            .region = self.config.region,
            .method = @tagName(method),
            .host = host_header,
            .path = raw_path,
            .payload_hash = &payload_hash,
            .unix_seconds = @intCast(@divFloor(now_ns, std.time.ns_per_s)),
        });
        defer signed.deinit(a);

        var url: Io.Writer.Allocating = .init(a);
        defer url.deinit();
        url.writer.print("{s}://{s}", .{ base.scheme, host_header }) catch return error.OutOfMemory;
        writeEncodedPath(&url.writer, raw_path) catch return error.OutOfMemory;

        var extra: [3]std.http.Header = undefined;
        var n: usize = 0;
        extra[n] = .{ .name = "x-amz-date", .value = &signed.amz_date };
        n += 1;
        extra[n] = .{ .name = "x-amz-content-sha256", .value = &payload_hash };
        n += 1;
        if (self.config.credentials.session_token) |t| {
            extra[n] = .{ .name = "x-amz-security-token", .value = t };
            n += 1;
        }

        var out: Io.Writer.Allocating = .init(a);
        defer out.deinit();
        const result = self.http.fetch(.{
            .location = .{ .url = url.written() },
            .method = method,
            .payload = body,
            .keep_alive = false,
            .headers = .{
                .authorization = .{ .override = signed.authorization },
                .content_type = if (content_type) |ct| .{ .override = ct } else .default,
            },
            .extra_headers = extra[0..n],
            .response_writer = if (method == .GET) &out.writer else null,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Transport,
        };

        switch (@backingInt(result.status)) {
            200...299 => {},
            404 => return error.NotFound,
            else => return error.RequestFailed,
        }
        if (out.written().len > self.config.max_object_bytes) return error.ObjectTooLarge;
        return out.toOwnedSlice() catch error.OutOfMemory;
    }
};

fn validateKey(key: []const u8) StoreError!void {
    if (key.len == 0 or key.len > 1024) return error.InvalidKey;
    for (key) |c| if (c < 0x20 or c == 0x7f) return error.InvalidKey;
}

// ---------------------------------------------------------------------------
// Tests (vectors from "Signature Calculations for the Authorization Header",
// AWS S3 API reference: GET Object with Range, PUT Object).
// ---------------------------------------------------------------------------

const example_creds: Credentials = .{
    .access_key_id = "AKIAIOSFODNN7EXAMPLE",
    .secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
};

test "formatAmzDate" {
    try std.testing.expectEqualStrings("20130524T000000Z", &try formatAmzDate(1369353600));
    try std.testing.expectEqualStrings("20240229T235959Z", &try formatAmzDate(1709251199));
    try std.testing.expectError(error.InvalidTimestamp, formatAmzDate(-1));
}

test "AWS example: GET object with Range" {
    const s = try sign(std.testing.allocator, .{
        .credentials = example_creds,
        .region = "us-east-1",
        .method = "GET",
        .host = "examplebucket.s3.amazonaws.com",
        .path = "/test.txt",
        .payload_hash = empty_payload_hash,
        .extra_headers = &.{.{ .name = "range", .value = "bytes=0-9" }},
        .unix_seconds = 1369353600,
    });
    defer s.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " ++
            "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, " ++
            "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
        s.authorization,
    );
}

test "AWS example: PUT object with encoded key and signed extra headers" {
    const payload = sha256Hex("Welcome to Amazon S3.");
    try std.testing.expectEqualStrings("44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072", &payload);
    const s = try sign(std.testing.allocator, .{
        .credentials = example_creds,
        .region = "us-east-1",
        .method = "PUT",
        .host = "examplebucket.s3.amazonaws.com",
        .path = "/test$file.text",
        .payload_hash = &payload,
        .extra_headers = &.{
            .{ .name = "date", .value = "Fri, 24 May 2013 00:00:00 GMT" },
            .{ .name = "x-amz-storage-class", .value = "REDUCED_REDUNDANCY" },
        },
        .unix_seconds = 1369353600,
    });
    defer s.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " ++
            "SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class, " ++
            "Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd",
        s.authorization,
    );
}

test "session token is signed" {
    var creds = example_creds;
    creds.session_token = "token";
    const s = try sign(std.testing.allocator, .{
        .credentials = creds,
        .region = "auto",
        .method = "GET",
        .host = "h",
        .path = "/b/k",
        .payload_hash = empty_payload_hash,
        .unix_seconds = 1369353600,
    });
    defer s.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, s.authorization, "SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token,") != null);
}

test "key validation" {
    try validateKey("a/b c.txt");
    try std.testing.expectError(error.InvalidKey, validateKey(""));
    try std.testing.expectError(error.InvalidKey, validateKey("a\nb"));
}

test "Store rejects bad endpoint and key before any I/O" {
    var store = Store.init(std.testing.allocator, std.testing.io, .{
        .endpoint = "ftp://example.com",
        .bucket = "b",
        .credentials = example_creds,
    });
    defer store.deinit();
    try std.testing.expectError(error.InvalidEndpoint, store.get("k"));
    try std.testing.expectError(error.InvalidKey, store.get(""));
}
