//! Static-file middleware with kernel-enforced document-root confinement
//! (ADR-0001 §4 Phase 2e, §5.4).
//!
//! `middleware(App, &config)` returns an entry that serves `GET` and `HEAD`
//! requests for regular files beneath `Config.root`, a caller-owned directory
//! handle. A hit writes the response and returns without calling `next`, so the
//! route never runs. Anything that is not a hit calls `next.call` with the
//! request unchanged: other methods, paths outside `Config.prefix`, missing
//! files, directories, symlinks, special files, and rejected paths.
//!
//! Confinement. Every file is opened with Linux `openat2(2)` relative to the
//! root handle, with `RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS |
//! RESOLVE_NO_MAGICLINKS`. The kernel resolves the whole path in one call and
//! refuses `..` escapes, absolute paths, and any symlink in any component,
//! including the last. There is no separate check before the open, so a
//! concurrent rename or symlink swap cannot redirect it. The opened descriptor
//! is then inspected with `statx` on the descriptor itself, never by path.
//! Before the kernel sees a path, segments are also rejected when they are
//! empty, `.` or `..`, contain `/`, `\`, or NUL, or (by default) start with `.`.
//! The request parser already rejects most of these; the check is repeated so
//! the middleware does not depend on it.
//!
//! Fail closed. `openat2` needs Linux 5.6 or later. Where it is missing or
//! blocked (`ENOSYS`, `EPERM` from a seccomp filter, `EINVAL`/`E2BIG` for an
//! unknown resolve flag or struct size), and on every non-Linux target, the
//! request fails with `error.ConfinementUnavailable` instead of falling back to
//! an unconfined open. `checkSupport` runs the same probe at startup. The
//! pinned std's `Dir.OpenOptions.resolve_beneath` is not used: on Linux it
//! does nothing, because it only sets an `O_RESOLVE_BENEATH` flag that Linux
//! does not have.
//!
//! Directory listing does not exist. A directory is never served, and there
//! is no index-file lookup; requests for directories fall through to `next`.
//!
//! Buffered limits. A hit reads the whole file into one response-owned buffer.
//! A file larger than `Config.max_file_bytes` or the response's
//! `max_body_bytes`, whichever is smaller, fails with `error.BodyTooLarge`
//! (the transport answers with the generic 500). That is a configuration
//! error, not a reason to stream (§4.2.5). The size is taken from the open
//! descriptor and at most that many bytes are read, so memory stays bounded
//! even if the file grows while it is read. A file that shrinks is served at
//! its shorter length. Files are expected not to change while served.
//!
//! Not covered: a hard link inside the root to a file outside it is an
//! ordinary file to the kernel and is served. Creating one needs write access
//! to the root, so keep the document root read-only to the server.
//!
//! Route helper. `sendFile(req, res, root, path, options)` serves one file
//! from a route through the same open, `statx`, and read path as the
//! middleware, so every guarantee above holds for it. `path` is relative,
//! `/`-separated, and checked segment by segment like a request path; a
//! rejected or missing path returns `false` with the response untouched, and
//! the route decides what to send instead.
//!
//! Cache headers. Neither the middleware nor `sendFile` sets `Cache-Control`
//! or `ETag` unless configured. `cache_control` takes an `http_cache.Policy`
//! and applies it with `http_cache.setCacheControl`, including its refusal of
//! `public` on requests with `Authorization` or `Cookie`. `etag = true` adds a
//! strong body `ETag` and answers a matching `If-None-Match` with 304. A
//! policy or validator error propagates after the body is written; the
//! response is then partial, as with any route error.
//!
//! Reads are blocking syscalls on the request's task, like the rest of
//! dispatch.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const router = @import("router.zig");
const response = @import("response.zig");
const http_cache = @import("plugins/http_cache.zig");

/// True where confinement is implemented. Elsewhere every request that would
/// open a file fails with `error.ConfinementUnavailable`.
pub const supported = builtin.os.tag == .linux;

/// Longest relative path, in bytes, that the middleware will try to open.
/// Longer paths are a miss.
pub const max_path_bytes = 4095;

/// Static-file configuration. Caller-owned, immutable, and valid until the
/// app is shut down, like every middleware configuration (§3.6). The
/// middleware never closes `root`.
pub const Config = struct {
    /// Document-root directory handle, for example from
    /// `Io.Dir.cwd().openDir(io, "public", .{})`.
    root: Io.Dir,
    /// Leading path segments that select static files, for example
    /// `&.{"static"}`. Empty serves from the URL root.
    prefix: []const []const u8 = &.{},
    /// Serve files and directories whose name starts with `.`.
    allow_dotfiles: bool = false,
    /// Upper bound on a served file. The response's `max_body_bytes` also
    /// applies; the smaller one wins.
    max_file_bytes: usize = std.math.maxInt(usize),
    /// `Cache-Control` for every hit; null sends none. Misses are untouched.
    cache_control: ?http_cache.Policy = null,
    /// Add a strong body `ETag` to hits and answer a matching
    /// `If-None-Match` with 304.
    etag: bool = false,
};

/// Options for `sendFile`. The defaults match `Config`.
pub const SendOptions = struct {
    allow_dotfiles: bool = false,
    /// Upper bound on the file. The response's `max_body_bytes` also
    /// applies; the smaller one wins.
    max_file_bytes: usize = std.math.maxInt(usize),
    /// Overrides the extension-based content type. Must not contain CR, LF,
    /// or NUL.
    content_type: ?[]const u8 = null,
    cache_control: ?http_cache.Policy = null,
    etag: bool = false,
};

/// Confinement and I/O failures. Misses are not errors; they call `next`.
pub const Error = error{
    /// Kernel-enforced confinement is not available on this system.
    ConfinementUnavailable,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    InputOutput,
    Unexpected,
};

/// Why a path did not open.
pub const Miss = enum {
    /// No such file, or a non-directory used as a directory.
    not_found,
    /// A symlink appeared in some component.
    symlink,
    /// Resolution would leave the root (`..` escape or absolute path).
    escape,
    /// The kernel denied access.
    forbidden,
    /// The path is too long.
    name_too_long,
};

pub const OpenResult = union(enum) {
    /// An open, read-only descriptor. The caller closes it.
    file: std.posix.fd_t,
    miss: Miss,
};

/// Opens `path` read-only beneath `root` with kernel-enforced confinement.
/// `path` is passed to the kernel as is; the middleware validates segments
/// before it gets here, but confinement does not depend on that.
pub fn openBeneath(root: Io.Dir, path: [:0]const u8) Error!OpenResult {
    return if (supported) openLinux(root.handle, path, file_flags) else error.ConfinementUnavailable;
}

/// Probes `openat2` on `root` without opening a file. Returns
/// `error.ConfinementUnavailable` where requests would fail closed and
/// `error.NotDir` when `root` is not a directory. Run it at startup to fail
/// early instead of on the first static request.
pub fn checkSupport(root: Io.Dir) (Error || error{NotDir})!void {
    if (!supported) return error.ConfinementUnavailable;
    // `openat2` rejects `O_PATH` combined with flags other than these.
    switch (try openLinux(root.handle, ".", .{ .PATH = true, .DIRECTORY = true, .CLOEXEC = true })) {
        .file => |fd| _ = std.os.linux.close(fd),
        .miss => return error.NotDir,
    }
}

/// Returns a static-file entry for `AppT` that reads `config`. `config` must
/// outlive the app.
pub fn middleware(comptime AppT: type, config: *const Config) AppT.Middleware {
    const Impl = struct {
        fn invoke(
            raw: *const anyopaque,
            ctx: *AppT.Context,
            req: *router.Request,
            res: *response.Response,
            next: AppT.Next,
        ) anyerror!void {
            const cfg: *const Config = @ptrCast(@alignCast(raw));
            if (try serve(cfg, req, res)) return;
            return next.call(ctx, req, res);
        }
    };
    return .{ .config = config, .invoke = Impl.invoke };
}

/// Serves `req` from `config.root` when it names a regular file. Returns
/// `true` on a hit (response written) and `false` on a miss (response and
/// request untouched).
pub fn serve(config: *const Config, req: *const router.Request, res: *response.Response) !bool {
    if (req.method != .get and req.method != .head) return false;
    const remaining = req.segments[req.cursor..];
    if (remaining.len < config.prefix.len) return false;
    for (config.prefix, remaining[0..config.prefix.len]) |want, got| {
        if (!std.mem.eql(u8, want, got)) return false;
    }

    var path_buffer: [max_path_bytes + 1]u8 = undefined;
    const path = relativePath(&path_buffer, remaining[config.prefix.len..], config.allow_dotfiles) orelse return false;
    return serveFile(config.root, path, .{
        .allow_dotfiles = config.allow_dotfiles,
        .max_file_bytes = config.max_file_bytes,
        .cache_control = config.cache_control,
        .etag = config.etag,
    }, req, res);
}

/// Writes the regular file at `path` beneath `root` as a 200 response from a
/// route. `path` is relative and `/`-separated (`"reports/q3.pdf"`); each
/// segment is checked like a request segment, so `..`, `.`, empty segments,
/// a leading `/`, `\`, NUL, and (unless allowed) dotfiles are refused before
/// the kernel sees the path. Returns `true` when the file was sent and
/// `false` when it is missing, rejected, a symlink, a directory, or a special
/// file; the response is then untouched. The method is not checked; the
/// route decides which methods send files. A file over the size limit fails
/// with `error.BodyTooLarge`.
pub fn sendFile(
    req: *const router.Request,
    res: *response.Response,
    root: Io.Dir,
    path: []const u8,
    options: SendOptions,
) !bool {
    var path_buffer: [max_path_bytes + 1]u8 = undefined;
    const checked = checkedPath(&path_buffer, path, options.allow_dotfiles) orelse return false;
    return serveFile(root, checked, options, req, res);
}

/// The single open-and-read path shared by `serve` and `sendFile`.
fn serveFile(
    root: Io.Dir,
    path: [:0]const u8,
    options: SendOptions,
    req: *const router.Request,
    res: *response.Response,
) !bool {
    const fd = switch (try openBeneath(root, path)) {
        .file => |fd| fd,
        .miss => return false,
    };
    defer _ = std.os.linux.close(fd);

    const size = (try regularFileSize(fd)) orelse return false;
    const limit = @min(options.max_file_bytes, res.limits.max_body_bytes);
    if (size > limit) return error.BodyTooLarge;

    var body = try res.allocator.alloc(u8, @intCast(size));
    var owned = true;
    defer if (owned) res.allocator.free(body);
    const len = try readAll(fd, body);
    if (len < body.len) body = try res.allocator.realloc(body, len);

    try res.replaceOwnedBody(200, options.content_type orelse contentType(path), body);
    owned = false;
    try res.setHeader("X-Content-Type-Options", "nosniff");
    if (options.cache_control) |policy| try http_cache.setCacheControl(req, res, policy);
    if (options.etag) {
        try http_cache.setBodyETag(res);
        _ = try http_cache.evaluate(req, res);
    }
    return true;
}

/// Copies `path` into `buffer` when every `/`-separated segment is allowed.
fn checkedPath(buffer: *[max_path_bytes + 1]u8, path: []const u8, allow_dotfiles: bool) ?[:0]const u8 {
    if (path.len == 0 or path.len > max_path_bytes) return null;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (!segmentAllowed(segment, allow_dotfiles)) return null;
    }
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    return buffer[0..path.len :0];
}

/// Joins validated segments with `/` into `buffer`. Returns null when there
/// are no segments or any segment is rejected.
pub fn relativePath(
    buffer: *[max_path_bytes + 1]u8,
    segments: []const []const u8,
    allow_dotfiles: bool,
) ?[:0]const u8 {
    if (segments.len == 0) return null;
    var len: usize = 0;
    for (segments, 0..) |segment, i| {
        if (!segmentAllowed(segment, allow_dotfiles)) return null;
        const extra = segment.len + @intFromBool(i != 0);
        if (len + extra > max_path_bytes) return null;
        if (i != 0) {
            buffer[len] = '/';
            len += 1;
        }
        @memcpy(buffer[len..][0..segment.len], segment);
        len += segment.len;
    }
    buffer[len] = 0;
    return buffer[0..len :0];
}

fn segmentAllowed(segment: []const u8, allow_dotfiles: bool) bool {
    if (segment.len == 0) return false;
    if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    if (!allow_dotfiles and segment[0] == '.') return false;
    return std.mem.indexOfAny(u8, segment, "/\\\x00") == null;
}

/// Content type by file extension. Unknown extensions are
/// `application/octet-stream`; the middleware also sends `nosniff`.
pub fn contentType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    for (content_types) |entry| {
        if (std.ascii.eqlIgnoreCase(ext, entry[0])) return entry[1];
    }
    return "application/octet-stream";
}

const content_types = [_][2][]const u8{
    .{ ".html", "text/html; charset=utf-8" },
    .{ ".htm", "text/html; charset=utf-8" },
    .{ ".css", "text/css; charset=utf-8" },
    .{ ".js", "text/javascript; charset=utf-8" },
    .{ ".mjs", "text/javascript; charset=utf-8" },
    .{ ".json", "application/json" },
    .{ ".map", "application/json" },
    .{ ".txt", "text/plain; charset=utf-8" },
    .{ ".xml", "application/xml" },
    .{ ".svg", "image/svg+xml" },
    .{ ".png", "image/png" },
    .{ ".jpg", "image/jpeg" },
    .{ ".jpeg", "image/jpeg" },
    .{ ".gif", "image/gif" },
    .{ ".webp", "image/webp" },
    .{ ".ico", "image/x-icon" },
    .{ ".wasm", "application/wasm" },
    .{ ".woff", "font/woff" },
    .{ ".woff2", "font/woff2" },
    .{ ".pdf", "application/pdf" },
};

// ---------------------------------------------------------------------------
// Linux implementation
// ---------------------------------------------------------------------------

const linux = std.os.linux;

/// `struct open_how` from `<linux/openat2.h>`.
const OpenHow = extern struct {
    flags: u64,
    mode: u64,
    resolve: u64,
};

const RESOLVE_NO_MAGICLINKS: u64 = 0x02;
const RESOLVE_NO_SYMLINKS: u64 = 0x04;
const RESOLVE_BENEATH: u64 = 0x08;
const resolve_flags = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS;

/// `NONBLOCK` keeps a FIFO from blocking the open; `NOCTTY` keeps a terminal
/// from becoming the controlling one. Neither is ever served.
const file_flags: linux.O = .{
    .ACCMODE = .RDONLY,
    .CLOEXEC = true,
    .NOFOLLOW = true,
    .NONBLOCK = true,
    .NOCTTY = true,
};

fn openLinux(root: std.posix.fd_t, path: [*:0]const u8, flags: linux.O) Error!OpenResult {
    const how: OpenHow = .{
        .flags = @as(u32, @bitCast(flags)),
        .mode = 0,
        .resolve = resolve_flags,
    };
    while (true) {
        const rc = linux.syscall4(
            .openat2,
            @as(usize, @bitCast(@as(isize, root))),
            @intFromPtr(path),
            @intFromPtr(&how),
            @sizeOf(OpenHow),
        );
        switch (linux.errno(rc)) {
            .SUCCESS => return .{ .file = @intCast(rc) },
            .INTR => continue,
            else => |e| return .{ .miss = try classifyOpenErrno(e) },
        }
    }
}

/// Maps an `openat2` failure to a miss or an error. Anything that means the
/// kernel could not enforce the requested resolution fails closed.
pub fn classifyOpenErrno(e: linux.E) Error!Miss {
    return switch (e) {
        .NOENT, .NOTDIR => .not_found,
        .LOOP => .symlink,
        .XDEV => .escape,
        .ACCES => .forbidden,
        .NAMETOOLONG => .name_too_long,
        .NOSYS, .PERM, .INVAL, .@"2BIG", .OPNOTSUPP => error.ConfinementUnavailable,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        .IO => error.InputOutput,
        else => error.Unexpected,
    };
}

/// Size of the open file, or null when it is not a regular file.
fn regularFileSize(fd: std.posix.fd_t) Error!?u64 {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .SIZE = true }, &stx);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .NOMEM => return error.SystemResources,
        .IO => return error.InputOutput,
        else => return error.Unexpected,
    }
    if (!stx.mask.TYPE or !stx.mask.SIZE) return error.Unexpected;
    if (!linux.S.ISREG(stx.mode)) return null;
    return stx.size;
}

/// Reads from offset 0 until `buffer` is full or end of file.
fn readAll(fd: std.posix.fd_t, buffer: []u8) Error!usize {
    var len: usize = 0;
    while (len < buffer.len) {
        const rc = linux.pread(fd, buffer[len..].ptr, buffer.len - len, @intCast(len));
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) break;
                len += rc;
            },
            .INTR => continue,
            .IO => return error.InputOutput,
            .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
    return len;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const app_mod = @import("app.zig");
const request = @import("request.zig");
const timing = @import("timing.zig");

const TestApp = app_mod.App(struct {});
const testing = std.testing;
const secret = "TOP-SECRET";

/// Records whether routing ran and what it saw.
const probe_route = struct {
    var runs: usize = 0;
    var cursor: usize = 0;
    var segments: usize = 0;

    fn run(_: *TestApp.Context, req: *router.Request, res: *response.Response) !void {
        runs += 1;
        cursor = req.cursor;
        segments = req.segments.len;
        if (req.isLiteral("routed") and req.isGet()) return res.text(200, "routed");
    }

    fn reset() void {
        runs = 0;
        cursor = 0;
        segments = 0;
    }
};

/// Temporary tree:
///
///     secret.txt                 outside the root
///     outside/file.txt           outside the root
///     root/hello.txt, page.html, style.css, blob.bin, empty.txt
///     root/sub/nested.json
///     root/.env, root/.hidden/a.txt
///     root/link_inside  -> hello.txt          (symlink within the root)
///     root/link_outside -> ../secret.txt
///     root/link_abs     -> /etc/passwd
///     root/dir_outside  -> ../outside         (directory symlink)
///     root/dir_inside   -> sub                (directory symlink within the root)
///     root/fifo                               (named pipe)
const Tree = struct {
    tmp: testing.TmpDir,
    root: Io.Dir,

    fn init() !Tree {
        const io = testing.io;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const d = tmp.dir;
        try d.writeFile(io, .{ .sub_path = "secret.txt", .data = secret });
        try d.createDirPath(io, "outside");
        try d.writeFile(io, .{ .sub_path = "outside/file.txt", .data = secret });
        try d.createDirPath(io, "root/sub");
        try d.createDirPath(io, "root/.hidden");
        try d.writeFile(io, .{ .sub_path = "root/hello.txt", .data = "hello" });
        try d.writeFile(io, .{ .sub_path = "root/page.html", .data = "<p>hi</p>" });
        try d.writeFile(io, .{ .sub_path = "root/style.css", .data = "p{}" });
        try d.writeFile(io, .{ .sub_path = "root/blob.bin", .data = "\x00\x01" });
        try d.writeFile(io, .{ .sub_path = "root/empty.txt", .data = "" });
        try d.writeFile(io, .{ .sub_path = "root/sub/nested.json", .data = "{}" });
        try d.writeFile(io, .{ .sub_path = "root/.env", .data = secret });
        try d.writeFile(io, .{ .sub_path = "root/.hidden/a.txt", .data = "dot" });
        try d.symLink(io, "hello.txt", "root/link_inside", .{});
        try d.symLink(io, "../secret.txt", "root/link_outside", .{});
        try d.symLink(io, "/etc/passwd", "root/link_abs", .{});
        try d.symLink(io, "../outside", "root/dir_outside", .{ .is_directory = true });
        try d.symLink(io, "sub", "root/dir_inside", .{ .is_directory = true });
        const root = try d.openDir(io, "root", .{});
        errdefer root.close(io);
        const rc = linux.mknodat(root.handle, "fifo", linux.S.IFIFO | 0o600, 0);
        if (linux.errno(rc) != .SUCCESS) return error.Unexpected;
        return .{ .tmp = tmp, .root = root };
    }

    fn deinit(self: *Tree) void {
        self.root.close(testing.io);
        self.tmp.cleanup();
    }
};

fn initApp(entries: []const TestApp.Middleware, config: app_mod.AppConfig) !TestApp {
    return TestApp.init(testing.allocator, .{
        .response_allocator = testing.allocator,
        .config = config,
        .plugins = .{},
        .route_fn = probe_route.run,
        .middleware = entries,
    });
}

/// Parses `target` like the transport does, then dispatches it.
fn dispatchTarget(app: *const TestApp, method: router.Method, target: []const u8) !response.Response {
    var arena = try request.parseOriginForm(testing.allocator, .default, target);
    defer arena.deinit();
    var req = arena.requestView(method);
    return app.dispatch(&req);
}

/// Dispatches hand-built segments, bypassing the request parser.
fn dispatchSegments(app: *const TestApp, segments: []const []const u8) !response.Response {
    var req: router.Request = .{ .method = .get, .segments = segments };
    return app.dispatch(&req);
}

fn expectHit(app: *const TestApp, target: []const u8, body: []const u8, content_type: []const u8) !void {
    probe_route.reset();
    var res = try dispatchTarget(app, .get, target);
    defer res.deinit();
    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expectEqualStrings(body, res.body);
    try testing.expectEqualStrings(content_type, res.content_type);
    try testing.expectEqualStrings("nosniff", (try res.getHeaderOne("x-content-type-options")).?);
    // A hit skips routing.
    try testing.expectEqual(@as(usize, 0), probe_route.runs);
}

/// A miss reaches the route with the request untouched and ends in a 404.
fn expectMiss(res_or_err: anyerror!response.Response) !void {
    var res = try res_or_err;
    defer res.deinit();
    try testing.expectEqual(@as(u16, 404), res.status_code);
    try testing.expectEqualStrings("Not Found", res.body);
    try testing.expect(std.mem.indexOf(u8, res.body, secret) == null);
    try testing.expectEqual(@as(usize, 1), probe_route.runs);
    try testing.expectEqual(@as(usize, 0), probe_route.cursor);
}

test "confinement is available on the CI platform" {
    if (!supported) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    try checkSupport(tree.root);
    const file = try tree.tmp.dir.openFile(testing.io, "secret.txt", .{});
    defer file.close(testing.io);
    try testing.expectError(error.NotDir, checkSupport(.{ .handle = file.handle }));
}

test "ordinary hits are served with content types and skip routing" {
    if (!supported) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    const config: Config = .{ .root = tree.root };
    var app = try initApp(&.{middleware(TestApp, &config)}, .{});
    defer app.deinit();

    try expectHit(&app, "/hello.txt", "hello", "text/plain; charset=utf-8");
    try expectHit(&app, "/page.html", "<p>hi</p>", "text/html; charset=utf-8");
    try expectHit(&app, "/style.css", "p{}", "text/css; charset=utf-8");
    try expectHit(&app, "/blob.bin", "\x00\x01", "application/octet-stream");
    try expectHit(&app, "/empty.txt", "", "text/plain; charset=utf-8");
    try expectHit(&app, "/sub/nested.json", "{}", "application/json");
    // Percent-decoded once by the parser, like any segment.
    try expectHit(&app, "/hell%6F.txt", "hello", "text/plain; charset=utf-8");

    // HEAD gets the representation; the transport drops the body (§4.2.5).
    probe_route.reset();
    var res = try dispatchTarget(&app, .head, "/hello.txt");
    defer res.deinit();
    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expectEqualStrings("hello", res.body);
    try testing.expectEqual(@as(usize, 0), probe_route.runs);
}

test "misses call next with the request unchanged" {
    if (!supported) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    const config: Config = .{ .root = tree.root, .prefix = &.{"static"} };
    var app = try initApp(&.{middleware(TestApp, &config)}, .{});
    defer app.deinit();

    try expectHit(&app, "/static/hello.txt", "hello", "text/plain; charset=utf-8");

    inline for (.{
        "/static/missing.txt", // no such file
        "/static/hello.txt/x", // a file used as a directory
        "/hello.txt", // outside the prefix
        "/statics/hello.txt",
        "/static", // the prefix itself
        "/static/", // empty segment
        "/static//hello.txt",
        "/static/sub/", // trailing slash
    }) |target| {
        probe_route.reset();
        try expectMiss(dispatchTarget(&app, .get, target));
    }

    // Other methods are not served.
    inline for (.{ router.Method.post, .put, .delete, .options }) |method| {
        probe_route.reset();
        try expectMiss(dispatchTarget(&app, method, "/static/hello.txt"));
    }

    // The route still answers its own paths.
    probe_route.reset();
    var res = try dispatchTarget(&app, .get, "/routed");
    defer res.deinit();
    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expectEqual(@as(usize, 1), probe_route.runs);
}

test "directories are never listed or served" {
    if (!supported) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    const config: Config = .{ .root = tree.root };
    var app = try initApp(&.{middleware(TestApp, &config)}, .{});
    defer app.deinit();

    inline for (.{ "/", "/sub", "/sub/" }) |target| {
        probe_route.reset();
        try expectMiss(dispatchTarget(&app, .get, target));
    }
    // The root handle itself is a directory, not a file.
    try testing.expect(relativePath(undefined, &.{}, false) == null);
}

test "symlinks are rejected in every component, inside or outside the root" {
    if (!supported) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    const config: Config = .{ .root = tree.root };
    var app = try initApp(&.{middleware(TestApp, &config)}, .{});
    defer app.deinit();

    inline for (.{
        "/link_inside", // final component, target inside the root
        "/link_outside", // final component, target outside
        "/link_abs", // absolute target
        "/dir_outside/file.txt", // directory component, target outside
        "/dir_inside/nested.json", // directory component, target inside
    }) |target| {
        probe_route.reset();
        try expectMiss(dispatchTarget(&app, .get, target));
    }

    // The kernel, not a pre-check, refuses them: the open reports a symlink.
    inline for (.{ "link_inside", "link_outside", "link_abs", "dir_outside/file.txt", "dir_inside/nested.json" }) |path| {
        try testing.expectEqual(OpenResult{ .miss = .symlink }, try openBeneath(tree.root, path));
    }
}

test "encoded traversal never reaches the file system" {
    if (!supported) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    const config: Config = .{ .root = tree.root };
    var app = try initApp(&.{middleware(TestApp, &config)}, .{});
    defer app.deinit();

    // The parser rejects these before dispatch (the transport answers 400).
    const rejected = .{
        .{ "/../secret.txt", error.DotSegment },
        .{ "/%2e%2e/secret.txt", error.DotSegment },
        .{ "/%2E%2E/secret.txt", error.DotSegment },
        .{ "/.%2e/secret.txt", error.DotSegment },
        .{ "/sub/%2e%2e/%2e%2e/secret.txt", error.DotSegment },
        .{ "/..%2Fsecret.txt", error.ForbiddenPathCharacter },
        .{ "/%2e%2e%2fsecret.txt", error.ForbiddenPathCharacter },
        .{ "/..%5Csecret.txt", error.ForbiddenPathCharacter },
        .{ "/..\\secret.txt", error.ForbiddenPathCharacter },
        .{ "/hello.txt%00.html", error.ForbiddenPathCharacter },
        .{ "/%2Fetc%2Fpasswd", error.ForbiddenPathCharacter },
    };
    inline for (rejected) |case| {
        try testing.expectError(case[1], dispatchTarget(&app, .get, case[0]));
    }
    // Decoded exactly once: a literal "%2e%2e" directory, which does not exist.
    probe_route.reset();
    try expectMiss(dispatchTarget(&app, .get, "/%252e%252e/secret.txt"));

    // The middleware rejects the same shapes itself when handed segments that
    // bypass the parser.
    inline for (.{
        &.{ "..", "secret.txt" },
        &.{ "sub", "..", "..", "secret.txt" },
        &.{"../secret.txt"},
        &.{"sub/../../secret.txt"},
        &.{"/etc/passwd"},
        &.{"..\\secret.txt"},
        &.{"hello.txt\x00"},
        &.{ ".", "hello.txt" },
        &.{ "", "hello.txt" },
    }) |segments| {
        probe_route.reset();
        try expectMiss(dispatchSegments(&app, segments));
    }
}

test "paths outside the root are refused by the kernel" {
    if (!supported) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();

    // Raw paths straight to the confinement primitive, no segment checks.
    inline for (.{ "../secret.txt", "sub/../../secret.txt", "../outside/file.txt", "/etc/passwd", "../root/../secret.txt" }) |path| {
        try testing.expectEqual(OpenResult{ .miss = .escape }, try openBeneath(tree.root, path));
    }
    // `..` that stays beneath the root is permitted by the kernel.
    const inside = try openBeneath(tree.root, "sub/../hello.txt");
    try testing.expect(inside == .file);
    _ = linux.close(inside.file);
    try testing.expectEqual(OpenResult{ .miss = .not_found }, try openBeneath(tree.root, "missing"));
}

test "dotfiles are hidden by default and opt-in" {
    if (!supported) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();

    const hidden: Config = .{ .root = tree.root };
    var app = try initApp(&.{middleware(TestApp, &hidden)}, .{});
    defer app.deinit();
    inline for (.{ "/.env", "/.hidden/a.txt" }) |target| {
        probe_route.reset();
        try expectMiss(dispatchTarget(&app, .get, target));
    }

    const shown: Config = .{ .root = tree.root, .allow_dotfiles = true };
    var open_app = try initApp(&.{middleware(TestApp, &shown)}, .{});
    defer open_app.deinit();
    try expectHit(&open_app, "/.hidden/a.txt", "dot", "text/plain; charset=utf-8");
}

test "special files are not opened or served" {
    if (!supported) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    const config: Config = .{ .root = tree.root };
    var app = try initApp(&.{middleware(TestApp, &config)}, .{});
    defer app.deinit();
    // A FIFO with no writer would block a plain open; NONBLOCK and the
    // regular-file check make it a miss.
    probe_route.reset();
    try expectMiss(dispatchTarget(&app, .get, "/fifo"));
}

test "buffered limits: at-limit files are served and larger files fail" {
    if (!supported) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    const io = testing.io;

    const small: Config = .{ .root = tree.root, .max_file_bytes = 5 };
    var app = try initApp(&.{middleware(TestApp, &small)}, .{});
    defer app.deinit();
    try expectHit(&app, "/hello.txt", "hello", "text/plain; charset=utf-8");
    try testing.expectError(error.BodyTooLarge, dispatchTarget(&app, .get, "/page.html"));

    // The response's own 1 MiB limit applies without configuration.
    const big = try testing.allocator.alloc(u8, response.Limits.default.max_body_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    try tree.root.writeFile(io, .{ .sub_path = "big.bin", .data = big });
    try tree.root.writeFile(io, .{ .sub_path = "limit.bin", .data = big[1..] });

    const default: Config = .{ .root = tree.root };
    var default_app = try initApp(&.{middleware(TestApp, &default)}, .{});
    defer default_app.deinit();
    try testing.expectError(error.BodyTooLarge, dispatchTarget(&default_app, .get, "/big.bin"));
    var res = try dispatchTarget(&default_app, .get, "/limit.bin");
    defer res.deinit();
    try testing.expectEqual(big.len - 1, res.body.len);
}

test "descriptors and buffers are released on hits, misses, and errors" {
    if (!supported) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    const config: Config = .{ .root = tree.root, .max_file_bytes = 5 };
    var app = try initApp(&.{middleware(TestApp, &config)}, .{});
    defer app.deinit();

    // The kernel hands out the lowest free descriptor, so a leak shows up
    // as a higher number afterwards.
    const before = try lowestFreeFd();
    for (0..200) |_| {
        inline for (.{ "/hello.txt", "/missing", "/sub", "/link_inside", "/fifo", "/dir_outside/file.txt" }) |target| {
            var res = try dispatchTarget(&app, .get, target);
            res.deinit();
        }
        try testing.expectError(error.BodyTooLarge, dispatchTarget(&app, .get, "/page.html"));
        const req: router.Request = .{ .method = .get, .segments = &.{} };
        inline for (.{ "hello.txt", "missing", "sub", "link_inside", "fifo" }) |path| {
            var res = response.Response.init(testing.allocator);
            defer res.deinit();
            _ = try sendFile(&req, &res, tree.root, path, .{ .max_file_bytes = 5 });
        }
        var res = response.Response.init(testing.allocator);
        defer res.deinit();
        try testing.expectError(error.BodyTooLarge, sendFile(&req, &res, tree.root, "page.html", .{ .max_file_bytes = 5 }));
    }
    try testing.expectEqual(before, try lowestFreeFd());
    // `testing.allocator` checks the response buffers at the end of the test.
}

fn lowestFreeFd() !i32 {
    const rc = linux.openat(linux.AT.FDCWD, "/dev/null", .{ .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.Unexpected;
    const fd: i32 = @intCast(rc);
    _ = linux.close(fd);
    return fd;
}

test "a concurrent symlink swap never redirects an open outside the root" {
    if (!supported) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    const io = testing.io;
    // `swap` and `alt` trade places atomically: one is a real directory, the
    // other a symlink to a directory outside the root holding a same-named
    // file. A check-then-open implementation could validate the directory and
    // then open through the symlink.
    try tree.root.createDirPath(io, "swap");
    try tree.root.writeFile(io, .{ .sub_path = "swap/file.txt", .data = "inside" });
    try tree.root.symLink(io, "../outside", "alt", .{ .is_directory = true });

    const Swapper = struct {
        root: std.posix.fd_t,
        stop: std.atomic.Value(bool) = .init(false),
        swaps: std.atomic.Value(usize) = .init(0),

        fn run(self: *@This()) void {
            while (!self.stop.load(.acquire)) {
                const rc = linux.renameat2(self.root, "swap", self.root, "alt", .{ .EXCHANGE = true });
                if (linux.errno(rc) == .SUCCESS) _ = self.swaps.fetchAdd(1, .release);
            }
        }
    };
    var swapper: Swapper = .{ .root = tree.root.handle };
    const thread = try std.Thread.spawn(.{}, Swapper.run, .{&swapper});

    const config: Config = .{ .root = tree.root };
    var app = try initApp(&.{middleware(TestApp, &config)}, .{});
    defer app.deinit();

    var served: usize = 0;
    var requests: usize = 0;
    while (requests < 20_000 and (requests < 2_000 or swapper.swaps.load(.acquire) < 2_000)) : (requests += 1) {
        const target = if (requests % 2 == 0) "/swap/file.txt" else "/alt/file.txt";
        var res = try dispatchTarget(&app, .get, target);
        defer res.deinit();
        try testing.expect(std.mem.indexOf(u8, res.body, secret) == null);
        if (res.status_code == 200) {
            try testing.expectEqualStrings("inside", res.body);
            served += 1;
        }
        // The route helper goes through the same confined open.
        const req: router.Request = .{ .method = .get, .segments = &.{} };
        var sent = response.Response.init(testing.allocator);
        defer sent.deinit();
        if (try sendFile(&req, &sent, tree.root, target[1..], .{})) {
            try testing.expectEqualStrings("inside", sent.body);
            served += 1;
        }
    }
    swapper.stop.store(true, .release);
    thread.join();
    // The race was exercised, and the real directory was served in between.
    try testing.expect(swapper.swaps.load(.acquire) > 0);
    try testing.expect(served > 0);
}

test "unavailable or unenforceable confinement fails closed" {
    inline for (.{ linux.E.NOSYS, .PERM, .INVAL, .@"2BIG", .OPNOTSUPP }) |e| {
        try testing.expectError(error.ConfinementUnavailable, classifyOpenErrno(e));
    }
    try testing.expectEqual(Miss.escape, try classifyOpenErrno(.XDEV));
    try testing.expectEqual(Miss.symlink, try classifyOpenErrno(.LOOP));
    try testing.expectEqual(Miss.not_found, try classifyOpenErrno(.NOENT));
    try testing.expectError(error.ProcessFdQuotaExceeded, classifyOpenErrno(.MFILE));
    try testing.expectError(error.Unexpected, classifyOpenErrno(.FAULT));
}

test "content types fall back to octet-stream" {
    try testing.expectEqualStrings("text/html; charset=utf-8", contentType("a/B.HTML"));
    try testing.expectEqualStrings("application/octet-stream", contentType("README"));
    try testing.expectEqualStrings("application/octet-stream", contentType("x.exe"));
}

/// A route that sends `/files/<name>` with `sendFile` and answers 404 itself
/// when the file is not sent.
const send_route = struct {
    var root: Io.Dir = undefined;
    var options: SendOptions = .{};
    var sent: ?bool = null;

    fn run(_: *TestApp.Context, req: *router.Request, res: *response.Response) !void {
        if (!req.isGet() or !req.onLiteral("files")) return;
        var buffer: [max_path_bytes + 1]u8 = undefined;
        const rest = req.segments[req.cursor..];
        const path = relativePath(&buffer, rest, true) orelse "";
        sent = try sendFile(req, res, root, path, options);
        if (!sent.?) try res.text(404, "no such file");
    }
};

fn initSendApp(tree: *const Tree, options: SendOptions) !TestApp {
    send_route.root = tree.root;
    send_route.options = options;
    send_route.sent = null;
    return TestApp.init(testing.allocator, .{
        .response_allocator = testing.allocator,
        .config = .{},
        .plugins = .{},
        .route_fn = send_route.run,
        .middleware = &.{},
    });
}

test "sendFile serves files from a route with content types" {
    if (!supported) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    var app = try initSendApp(&tree, .{});
    defer app.deinit();

    inline for (.{
        .{ "/files/hello.txt", "hello", "text/plain; charset=utf-8" },
        .{ "/files/page.html", "<p>hi</p>", "text/html; charset=utf-8" },
        .{ "/files/blob.bin", "\x00\x01", "application/octet-stream" },
        .{ "/files/empty.txt", "", "text/plain; charset=utf-8" },
        .{ "/files/sub/nested.json", "{}", "application/json" },
    }) |case| {
        var res = try dispatchTarget(&app, .get, case[0]);
        defer res.deinit();
        try testing.expect(send_route.sent.?);
        try testing.expectEqual(@as(u16, 200), res.status_code);
        try testing.expectEqualStrings(case[1], res.body);
        try testing.expectEqualStrings(case[2], res.content_type);
        try testing.expectEqualStrings("nosniff", (try res.getHeaderOne("x-content-type-options")).?);
        try testing.expect((try res.getHeaderOne("cache-control")) == null);
        try testing.expect((try res.getHeaderOne("etag")) == null);
    }

    // The content type can be overridden, but not with header-breaking bytes.
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    const req: router.Request = .{ .method = .get, .segments = &.{} };
    try testing.expect(try sendFile(&req, &res, tree.root, "blob.bin", .{ .content_type = "application/x-demo" }));
    try testing.expectEqualStrings("application/x-demo", res.content_type);
    var bad = response.Response.init(testing.allocator);
    defer bad.deinit();
    try testing.expectError(error.InvalidContentType, sendFile(&req, &bad, tree.root, "blob.bin", .{ .content_type = "a\r\nb" }));
    try testing.expect(!bad.handled);
}

test "sendFile misses leave the response to the route" {
    if (!supported) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    var app = try initSendApp(&tree, .{});
    defer app.deinit();

    inline for (.{
        "/files/missing.txt",
        "/files/sub", // directory
        "/files/hello.txt/x",
        "/files/link_inside",
        "/files/link_outside",
        "/files/dir_outside/file.txt",
        "/files/fifo",
        "/files/.env", // dotfile, hidden by default
    }) |target| {
        var res = try dispatchTarget(&app, .get, target);
        defer res.deinit();
        try testing.expect(!send_route.sent.?);
        try testing.expectEqual(@as(u16, 404), res.status_code);
        try testing.expectEqualStrings("no such file", res.body);
    }

    // Paths are checked segment by segment before the kernel sees them, and
    // a miss leaves an earlier response untouched.
    const req: router.Request = .{ .method = .get, .segments = &.{} };
    inline for (.{
        "",
        "/etc/passwd",
        "../secret.txt",
        "sub/../../secret.txt",
        "sub/../hello.txt",
        "./hello.txt",
        "sub//nested.json",
        "sub/",
        "..\\secret.txt",
        "hello.txt\x00",
        ".hidden/a.txt",
    }) |path| {
        var res = response.Response.init(testing.allocator);
        defer res.deinit();
        try res.text(418, "kept");
        try testing.expect(!try sendFile(&req, &res, tree.root, path, .{}));
        try testing.expectEqual(@as(u16, 418), res.status_code);
        try testing.expectEqualStrings("kept", res.body);
    }
    var long: [max_path_bytes + 1]u8 = undefined;
    @memset(&long, 'a');
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try testing.expect(!try sendFile(&req, &res, tree.root, &long, .{}));
    try testing.expect(try sendFile(&req, &res, tree.root, ".hidden/a.txt", .{ .allow_dotfiles = true }));
    try testing.expectEqualStrings("dot", res.body);
}

test "sendFile enforces the file and response size limits" {
    if (!supported) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    const req: router.Request = .{ .method = .get, .segments = &.{} };

    var at_limit = response.Response.init(testing.allocator);
    defer at_limit.deinit();
    try testing.expect(try sendFile(&req, &at_limit, tree.root, "hello.txt", .{ .max_file_bytes = 5 }));
    try testing.expectEqualStrings("hello", at_limit.body);

    var over = response.Response.init(testing.allocator);
    defer over.deinit();
    try testing.expectError(error.BodyTooLarge, sendFile(&req, &over, tree.root, "page.html", .{ .max_file_bytes = 5 }));
    try testing.expect(!over.handled);

    // The response limit wins when it is smaller.
    var small = response.Response.initWithLimits(testing.allocator, .{ .max_body_bytes = 4 });
    defer small.deinit();
    try testing.expectError(error.BodyTooLarge, sendFile(&req, &small, tree.root, "hello.txt", .{}));
    try testing.expect(!small.handled);

    // From a route, the error propagates out of dispatch.
    var app = try initSendApp(&tree, .{ .max_file_bytes = 5 });
    defer app.deinit();
    try testing.expectError(error.BodyTooLarge, dispatchTarget(&app, .get, "/files/page.html"));
}

test "configured cache headers apply to hits only" {
    if (!supported) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    const config: Config = .{
        .root = tree.root,
        .cache_control = .{ .public = .{ .max_age = 31536000, .immutable = true } },
        .etag = true,
    };
    var app = try initApp(&.{middleware(TestApp, &config)}, .{});
    defer app.deinit();

    probe_route.reset();
    var hit = try dispatchTarget(&app, .get, "/hello.txt");
    defer hit.deinit();
    try testing.expectEqual(@as(u16, 200), hit.status_code);
    try testing.expectEqualStrings("public, max-age=31536000, immutable", (try hit.getHeaderOne("cache-control")).?);
    const etag = (try hit.getHeaderOne("etag")).?;
    try testing.expect(etag.len == 34 and etag[0] == '"');

    // A miss reaches the route without cache headers.
    probe_route.reset();
    var miss = try dispatchTarget(&app, .get, "/missing.txt");
    defer miss.deinit();
    try testing.expectEqual(@as(u16, 404), miss.status_code);
    try testing.expect((try miss.getHeaderOne("cache-control")) == null);
    try testing.expect((try miss.getHeaderOne("etag")) == null);

    // A matching validator becomes 304 with the headers kept; HEAD too.
    inline for (.{ router.Method.get, .head }) |method| {
        const headers = [_]router.Header{.{ .name = "If-None-Match", .value = etag }};
        var req: router.Request = .{ .method = method, .segments = &.{"hello.txt"}, .headers = &headers };
        var res = try app.dispatch(&req);
        defer res.deinit();
        try testing.expectEqual(@as(u16, 304), res.status_code);
        try testing.expectEqualStrings("", res.body);
        try testing.expectEqualStrings(etag, (try res.getHeaderOne("etag")).?);
        try testing.expect((try res.getHeaderOne("cache-control")) != null);
    }
    // A stale validator gets the full file.
    {
        const headers = [_]router.Header{.{ .name = "If-None-Match", .value = "\"stale\"" }};
        var req: router.Request = .{ .method = .get, .segments = &.{"hello.txt"}, .headers = &headers };
        var res = try app.dispatch(&req);
        defer res.deinit();
        try testing.expectEqual(@as(u16, 200), res.status_code);
        try testing.expectEqualStrings("hello", res.body);
    }
    // `public` keeps http_cache's credential rule.
    {
        const headers = [_]router.Header{.{ .name = "Cookie", .value = "sid=1" }};
        var req: router.Request = .{ .method = .get, .segments = &.{"hello.txt"}, .headers = &headers };
        try testing.expectError(error.SharedCacheWithCredentials, app.dispatch(&req));
    }

    // sendFile takes the same options.
    const req: router.Request = .{ .method = .get, .segments = &.{} };
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try testing.expect(try sendFile(&req, &res, tree.root, "hello.txt", .{ .cache_control = .no_store, .etag = true }));
    try testing.expectEqualStrings("no-store", (try res.getHeaderOne("cache-control")).?);
    try testing.expectEqualStrings(etag, (try res.getHeaderOne("etag")).?);
}

/// Advances 3 ms on every read.
const StepClock = struct {
    now: Io.Timestamp = .zero,

    fn read(context: *anyopaque) Io.Timestamp {
        const self: *StepClock = @ptrCast(@alignCast(context));
        self.now = self.now.addDuration(.fromMilliseconds(3));
        return self.now;
    }
};

test "configured ordering decides which responses are timed" {
    if (!supported) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    var clock: StepClock = .{};
    const app_config: app_mod.AppConfig = .{ .clock = .{ .source = .{ .context = &clock, .now = StepClock.read } } };
    const config: Config = .{ .root = tree.root };
    const static_entry = middleware(TestApp, &config);
    const timing_entry = timing.middleware(TestApp);

    // Static first: hits return before timing runs; routes and 404s are timed.
    {
        var app = try initApp(&.{ static_entry, timing_entry }, app_config);
        defer app.deinit();
        probe_route.reset();
        var hit = try dispatchTarget(&app, .get, "/hello.txt");
        defer hit.deinit();
        try testing.expectEqualStrings("hello", hit.body);
        try testing.expect((try hit.getHeaderOne(timing.header_name)) == null);
        try testing.expectEqual(@as(usize, 0), probe_route.runs);

        inline for (.{ .{ "/routed", 200 }, .{ "/missing", 404 } }) |case| {
            var res = try dispatchTarget(&app, .get, case[0]);
            defer res.deinit();
            try testing.expectEqual(@as(u16, case[1]), res.status_code);
            try testing.expectEqualStrings("3", (try res.getHeaderOne(timing.header_name)).?);
        }
        try testing.expectEqual(@as(usize, 2), probe_route.runs);
    }
    // Timing first: static hits are timed too.
    {
        var app = try initApp(&.{ timing_entry, static_entry }, app_config);
        defer app.deinit();
        probe_route.reset();
        var hit = try dispatchTarget(&app, .get, "/hello.txt");
        defer hit.deinit();
        try testing.expectEqualStrings("hello", hit.body);
        try testing.expectEqualStrings("3", (try hit.getHeaderOne(timing.header_name)).?);
        try testing.expectEqual(@as(usize, 0), probe_route.runs);
    }
}
