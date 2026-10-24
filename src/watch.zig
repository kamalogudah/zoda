//! Development watcher: rebuild and restart the demo (ADR-0001 §4 Phase 2d).
//!
//! `zig build watch` runs this program. It does not rely on `zig build --watch`
//! or any `watch` step provided by the build system; it polls the watched paths
//! itself, which works the same on every POSIX file system.
//!
//! Loop contract:
//! - Each poll hashes the contents of every watched file. A change is acted on
//!   only after one further poll observes the same fingerprint, so a burst of
//!   saves produces one rebuild.
//! - The build command runs to completion with its output captured. On failure
//!   the diagnostics are displayed and the last working process keeps
//!   running; the next change triggers another attempt.
//! - On success the previous process receives SIGTERM, is given
//!   `Config.stop_grace` to exit, is killed with SIGKILL after that, and is
//!   always reaped before the new build starts. Two generations never run
//!   concurrently, so the new process can bind the same port.
//! - A process that exits on its own is reaped and reported; the next
//!   successful build starts a new one.
//! - SIGINT/SIGTERM delivered to the watcher stop the running process through
//!   the same path before the watcher exits.
//!
//! Hidden files and names ending in `~` are ignored so editor swap and backup
//! files do not trigger rebuilds.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const posix = std.posix;
const process = std.process;

pub const Config = struct {
    /// Working directory for the build and run commands and the base for
    /// relative `watch_paths`.
    root: Io.Dir = .cwd(),
    /// Files or directories (walked recursively) whose contents are hashed.
    watch_paths: []const []const u8,
    build_argv: []const []const u8,
    run_argv: []const []const u8,
    poll_interval: Io.Duration = .fromMilliseconds(200),
    /// Time the previous process is given to exit after SIGTERM.
    stop_grace: Io.Duration = .fromSeconds(5),
    /// Upper bound for one watched file and for captured build output.
    max_file_bytes: usize = 16 * 1024 * 1024,
};

pub const Outcome = enum {
    /// Fingerprint unchanged; nothing was done.
    unchanged,
    /// The build succeeded and a new process is running.
    started,
    /// The build failed; the previous process (if any) is still running.
    build_failed,
};

/// How the previous process ended when it was stopped.
pub const StopResult = enum { terminated, killed, already_exited };

pub const Watcher = struct {
    gpa: std.mem.Allocator,
    io: Io,
    config: Config,
    out: *Io.Writer,
    fingerprint: u64,
    child: ?process.Child = null,
    /// Successful builds that started a process.
    generation: usize = 0,

    pub fn init(gpa: std.mem.Allocator, io: Io, config: Config, out: *Io.Writer) !Watcher {
        return .{
            .gpa = gpa,
            .io = io,
            .config = config,
            .out = out,
            .fingerprint = try fingerprintPaths(gpa, io, config.root, config.watch_paths, config.max_file_bytes),
        };
    }

    /// Stops the running process, if any. Infallible.
    pub fn deinit(self: *Watcher) void {
        _ = self.stop();
        self.out.flush() catch {};
    }

    /// The PID of the running process, if any.
    pub fn pid(self: *const Watcher) ?process.Child.Id {
        const child = self.child orelse return null;
        return child.id;
    }

    /// Runs the initial build, then polls until `stop_flag` is set.
    pub fn run(self: *Watcher, stop_flag: *const std.atomic.Value(bool)) !void {
        _ = try self.rebuild();
        while (!stop_flag.load(.acquire)) {
            try Io.sleep(self.io, self.config.poll_interval, .awake);
            _ = try self.poll();
        }
        try self.out.print("[watch] stopping\n", .{});
        try self.out.flush();
    }

    /// One poll cycle: reaps a process that exited on its own, then rebuilds
    /// when the watched contents changed and have settled.
    pub fn poll(self: *Watcher) !Outcome {
        try self.reapExited();
        var current = try self.currentFingerprint();
        if (current == self.fingerprint) return .unchanged;
        while (true) {
            try Io.sleep(self.io, self.config.poll_interval, .awake);
            const settled = try self.currentFingerprint();
            if (settled == current) break;
            current = settled;
        }
        self.fingerprint = current;
        try self.out.print("[watch] change detected\n", .{});
        return self.rebuild();
    }

    /// Builds; on success replaces the running process, on failure displays
    /// diagnostics and keeps it.
    pub fn rebuild(self: *Watcher) !Outcome {
        const started = Io.Clock.Timestamp.now(self.io, .awake);
        try self.out.print("[watch] building\n", .{});
        try self.out.flush();

        const result = try process.run(self.gpa, self.io, .{
            .argv = self.config.build_argv,
            .cwd = .{ .dir = self.config.root },
            .stdout_limit = .limited(self.config.max_file_bytes),
            .stderr_limit = .limited(self.config.max_file_bytes),
        });
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        try self.out.writeAll(result.stdout);
        try self.out.writeAll(result.stderr);

        const ok = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!ok) {
            if (self.pid()) |id| {
                try self.out.print("[watch] build failed; keeping previous process (pid {d})\n", .{id});
            } else {
                try self.out.print("[watch] build failed; no process running\n", .{});
            }
            try self.out.flush();
            return .build_failed;
        }

        _ = self.stop();
        self.child = try process.spawn(self.io, .{
            .argv = self.config.run_argv,
            .cwd = .{ .dir = self.config.root },
            .stdin = .ignore,
        });
        self.generation += 1;
        try self.out.print("[watch] started pid {d} after {d} ms\n", .{
            self.child.?.id.?, -@divFloor(started.durationFromNow(self.io).raw.nanoseconds, std.time.ns_per_ms),
        });
        try self.out.flush();
        return .started;
    }

    /// Sends SIGTERM, waits up to `stop_grace`, then SIGKILL. The process is
    /// always reaped before this returns.
    pub fn stop(self: *Watcher) ?StopResult {
        var child = self.child orelse return null;
        self.child = null;
        const id = child.id.?;
        if (hasExited(id)) {
            _ = child.wait(self.io) catch child.kill(self.io);
            return .already_exited;
        }
        posix.kill(id, .TERM) catch {
            forceKill(&child, self.io);
            return .killed;
        };
        const started = Io.Clock.Timestamp.now(self.io, .awake);
        const grace_ns = self.config.stop_grace.nanoseconds;
        while (-started.durationFromNow(self.io).raw.nanoseconds < grace_ns) {
            if (hasExited(id)) {
                _ = child.wait(self.io) catch child.kill(self.io);
                self.out.print("[watch] stopped pid {d}\n", .{id}) catch {};
                return .terminated;
            }
            Io.sleep(self.io, .fromMilliseconds(10), .awake) catch break;
        }
        forceKill(&child, self.io);
        self.out.print("[watch] pid {d} ignored SIGTERM; killed\n", .{id}) catch {};
        return .killed;
    }

    fn reapExited(self: *Watcher) !void {
        const id = self.pid() orelse return;
        if (!hasExited(id)) return;
        var child = self.child.?;
        self.child = null;
        const term = child.wait(self.io) catch {
            child.kill(self.io);
            return;
        };
        try self.out.print("[watch] pid {d} exited ({any}); waiting for the next change\n", .{ id, term });
        try self.out.flush();
    }

    fn currentFingerprint(self: *const Watcher) !u64 {
        return fingerprintPaths(self.gpa, self.io, self.config.root, self.config.watch_paths, self.config.max_file_bytes);
    }
};

/// SIGKILL, then reap. `Child.kill` in Zig 0.16.0 sends SIGTERM and blocks
/// in `wait4`, which never returns for a process that ignores SIGTERM.
fn forceKill(child: *process.Child, io: Io) void {
    posix.kill(child.id.?, .KILL) catch {};
    child.kill(io);
}

/// True when the child has terminated. Does not reap it (`WNOWAIT`), so the
/// PID stays reserved until `Child.wait` collects the status.
fn hasExited(id: process.Child.Id) bool {
    if (builtin.os.tag != .linux) @compileError("the watcher supports Linux only (PLATFORM.md §2)");
    const linux = std.os.linux;
    var info: linux.siginfo_t = std.mem.zeroes(linux.siginfo_t);
    const rc = linux.waitid(.PID, id, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT, null);
    if (linux.errno(rc) != .SUCCESS) return true;
    return info.fields.common.first.piduid.pid != 0;
}

/// Order-independent hash over the relative path and contents of every watched
/// file. Missing paths contribute a fixed marker so creating them is a change.
pub fn fingerprintPaths(
    gpa: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    paths: []const []const u8,
    max_file_bytes: usize,
) !u64 {
    var sum: u64 = 0;
    for (paths) |path| {
        const stat = root.statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                sum +%= std.hash.Wyhash.hash(1, path);
                continue;
            },
            else => return err,
        };
        if (stat.kind != .directory) {
            sum +%= try hashFile(gpa, io, root, path, path, "", max_file_bytes);
            continue;
        }
        var dir = try root.openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or ignored(entry.basename)) continue;
            sum +%= try hashFile(gpa, io, entry.dir, entry.basename, path, entry.path, max_file_bytes);
        }
    }
    return sum;
}

fn ignored(basename: []const u8) bool {
    return std.mem.startsWith(u8, basename, ".") or std.mem.endsWith(u8, basename, "~");
}

fn hashFile(
    gpa: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    prefix: []const u8,
    relative: []const u8,
    max_file_bytes: usize,
) !u64 {
    // A file removed between listing and reading is picked up by the next poll.
    const bytes = dir.readFileAlloc(io, sub_path, gpa, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer gpa.free(bytes);
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(prefix);
    hasher.update("/");
    hasher.update(relative);
    hasher.update(&.{0});
    hasher.update(bytes);
    return hasher.final();
}

// ---------------------------------------------------------------------------
// Executable entry point
// ---------------------------------------------------------------------------

var stop_requested: std.atomic.Value(bool) = .init(false);

fn requestStop(_: posix.SIG) callconv(.c) void {
    stop_requested.store(true, .release);
}

const usage =
    \\usage: zoda-watch [--zig <path>] [-- <demo args>...]
    \\
    \\Rebuilds with `<zig> build` when src/, build.zig, or build.zig.zon change,
    \\then restarts `zig-out/bin/zoda <demo args>` (default: serve).
    \\Run from the repository root, or use `zig build watch`.
    \\
;

pub fn main(init: process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var zig: []const u8 = "zig";
    var demo_args: []const []const u8 = &.{"serve"};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--zig") and i + 1 < args.len) {
            i += 1;
            zig = args[i];
        } else if (std.mem.eql(u8, arg, "--")) {
            if (i + 1 < args.len) demo_args = args[i + 1 ..];
            break;
        } else {
            std.debug.print("{s}", .{usage});
            std.process.exit(2);
        }
    }

    var run_argv: std.ArrayList([]const u8) = .empty;
    try run_argv.append(arena, "zig-out/bin/zoda");
    try run_argv.appendSlice(arena, demo_args);

    const action: posix.Sigaction = .{
        .handler = .{ .handler = requestStop },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.INT, &action, null);
    posix.sigaction(.TERM, &action, null);

    // Streaming, not positional: the demo inherits this descriptor, and
    // positional writes to a redirected file would overwrite its output.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    var watcher = try Watcher.init(init.gpa, io, .{
        .watch_paths = &.{ "src", "build.zig", "build.zig.zon" },
        .build_argv = &.{ zig, "build" },
        .run_argv = run_argv.items,
    }, out);
    defer watcher.deinit();
    try watcher.run(&stop_requested);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// The build copies `src/version` to `out/version` and fails with a
/// diagnostic when it contains `broken`. The process records its version and
/// writes `out/stopped` when it handles SIGTERM.
const test_build =
    \\mkdir -p out
    \\if grep -q broken src/version; then echo "src/version:1: error: broken" >&2; exit 1; fi
    \\cp src/version out/version
;
const test_run =
    \\v=$(cat out/version)
    \\trap 'echo "$v" > out/stopped; exit 0' TERM
    \\echo "$v" > out/running
    \\while :; do sleep 0.02; done
;
const test_run_ignoring_term =
    \\trap '' TERM
    \\cat out/version > out/running
    \\while :; do sleep 0.02; done
;

const Fixture = struct {
    tmp: testing.TmpDir,
    out: Io.Writer.Allocating,
    run_argv: [3][]const u8,
    watcher: Watcher,

    fn init(self: *Fixture, run_script: []const u8, stop_grace: Io.Duration) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        try self.tmp.dir.createDirPath(testing.io, "src");
        try self.write("src/version", "v1");
        self.out = .init(testing.allocator);
        errdefer self.out.deinit();
        self.run_argv = .{ "sh", "-c", run_script };
        self.watcher = try Watcher.init(testing.allocator, testing.io, .{
            .root = self.tmp.dir,
            .watch_paths = &.{"src"},
            .build_argv = &.{ "sh", "-c", test_build },
            .run_argv = &self.run_argv,
            .poll_interval = .fromMilliseconds(20),
            .stop_grace = stop_grace,
        }, &self.out.writer);
    }

    fn deinit(self: *Fixture) void {
        self.watcher.deinit();
        self.out.deinit();
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, path: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = data });
    }

    /// Waits until `path` holds exactly `expected`.
    fn expectFile(self: *Fixture, path: []const u8, expected: []const u8) !void {
        const started = Io.Clock.Timestamp.now(testing.io, .awake);
        while (true) {
            const bytes = self.tmp.dir.readFileAlloc(testing.io, path, testing.allocator, .limited(64)) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (bytes) |b| {
                defer testing.allocator.free(b);
                if (std.mem.eql(u8, std.mem.trimEnd(u8, b, "\n"), expected)) return;
            }
            if (-started.durationFromNow(testing.io).raw.nanoseconds > 5 * std.time.ns_per_s) {
                return error.FileDidNotMatch;
            }
            try Io.sleep(testing.io, .fromMilliseconds(5), .awake);
        }
    }
};

fn expectGone(id: process.Child.Id) !void {
    try testing.expectError(error.ProcessNotFound, posix.kill(id, @enumFromInt(0)));
}

test "watch: repeated edits rebuild and restart, stopping each previous process" {
    var f: Fixture = undefined;
    try f.init(test_run, .fromSeconds(5));
    defer f.deinit();

    try testing.expectEqual(Outcome.started, try f.watcher.rebuild());
    try f.expectFile("out/running", "v1");
    try testing.expectEqual(Outcome.unchanged, try f.watcher.poll());

    var previous = f.watcher.pid().?;
    for ([_][]const u8{ "v2", "v3", "v4" }) |version| {
        try f.write("src/version", version);
        try testing.expectEqual(Outcome.started, try f.watcher.poll());
        try f.expectFile("out/running", version);
        // The previous generation handled SIGTERM and was reaped first.
        try expectGone(previous);
        const current = f.watcher.pid().?;
        try testing.expect(current != previous);
        previous = current;
    }
    try testing.expectEqual(@as(usize, 4), f.watcher.generation);
    try f.expectFile("out/stopped", "v3");
}

test "watch: failed build keeps the last working process and recovers on the next valid edit" {
    var f: Fixture = undefined;
    try f.init(test_run, .fromSeconds(5));
    defer f.deinit();

    try testing.expectEqual(Outcome.started, try f.watcher.rebuild());
    try f.expectFile("out/running", "v1");
    const working = f.watcher.pid().?;

    try f.write("src/version", "broken");
    try testing.expectEqual(Outcome.build_failed, try f.watcher.poll());
    try testing.expect(std.mem.indexOf(u8, f.out.written(), "src/version:1: error: broken") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.written(), "keeping previous process") != null);
    // Still the same live process.
    try testing.expectEqual(working, f.watcher.pid().?);
    try posix.kill(working, @enumFromInt(0));
    try testing.expectEqual(Outcome.unchanged, try f.watcher.poll());

    try f.write("src/version", "v2");
    try testing.expectEqual(Outcome.started, try f.watcher.poll());
    try f.expectFile("out/running", "v2");
    try f.expectFile("out/stopped", "v1");
    try expectGone(working);
}

test "watch: initial build failure starts nothing until a valid edit" {
    var f: Fixture = undefined;
    try f.init(test_run, .fromSeconds(5));
    defer f.deinit();

    try f.write("src/version", "broken");
    try testing.expectEqual(Outcome.build_failed, try f.watcher.rebuild());
    try testing.expectEqual(@as(?process.Child.Id, null), f.watcher.pid());
    try testing.expect(std.mem.indexOf(u8, f.out.written(), "no process running") != null);

    try f.write("src/version", "v2");
    try testing.expectEqual(Outcome.started, try f.watcher.poll());
    try f.expectFile("out/running", "v2");
}

test "watch: deinit stops the process, killing one that ignores SIGTERM" {
    var f: Fixture = undefined;
    try f.init(test_run_ignoring_term, .fromMilliseconds(100));
    defer f.deinit();

    try testing.expectEqual(Outcome.started, try f.watcher.rebuild());
    try f.expectFile("out/running", "v1");
    const id = f.watcher.pid().?;
    try testing.expectEqual(StopResult.killed, f.watcher.stop().?);
    try expectGone(id);
    try testing.expectEqual(@as(?StopResult, null), f.watcher.stop());
}

test "watch: a process that exits on its own is reaped and restarted by the next build" {
    var f: Fixture = undefined;
    try f.init("cat out/version > out/running", .fromSeconds(5));
    defer f.deinit();

    try testing.expectEqual(Outcome.started, try f.watcher.rebuild());
    try f.expectFile("out/running", "v1");
    const id = f.watcher.pid().?;
    const started = Io.Clock.Timestamp.now(testing.io, .awake);
    while (f.watcher.pid() != null) {
        try testing.expectEqual(Outcome.unchanged, try f.watcher.poll());
        if (-started.durationFromNow(testing.io).raw.nanoseconds > 5 * std.time.ns_per_s) return error.NotReaped;
        try Io.sleep(testing.io, .fromMilliseconds(5), .awake);
    }
    try expectGone(id);
    try testing.expect(std.mem.indexOf(u8, f.out.written(), "exited") != null);

    try f.write("src/version", "v2");
    try testing.expectEqual(Outcome.started, try f.watcher.poll());
    try f.expectFile("out/running", "v2");
}

test "watch: ignored names do not change the fingerprint" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/a.zig", .data = "a" });
    const paths: []const []const u8 = &.{ "src", "missing.zon" };
    const before = try fingerprintPaths(testing.allocator, testing.io, tmp.dir, paths, 1024);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/.a.zig.swp", .data = "x" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/a.zig~", .data = "x" });
    try testing.expectEqual(before, try fingerprintPaths(testing.allocator, testing.io, tmp.dir, paths, 1024));

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "missing.zon", .data = "" });
    try testing.expect(before != try fingerprintPaths(testing.allocator, testing.io, tmp.dir, paths, 1024));
}
