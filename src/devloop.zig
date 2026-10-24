//! End-to-end development-loop checks against the demo (ADR-0001 §4 Phase 2d).
//!
//! The test copies `src/`, `build.zig`, and `build.zig.zon` into a temporary
//! directory and runs `watch.Watcher` there with the real build command
//! (`<zig> build`, the compiler that ran `zig build test-devloop`) and the real
//! demo (`zig-out/bin/zoda serve <port>`). Edits rewrite the `GET /` body in
//! the copied `src/main.zig`; the repository itself is never modified.
//!
//! Edit-to-response latency is measured from the moment the edited file has
//! been written until `GET /` first returns the new body, polling every 10 ms.
//! It includes the watcher's poll-and-settle window, the build, stopping the
//! previous process, and starting the new one. Results are printed; the 2 s
//! target is reported, not asserted, because hosted runners vary.
//!
//! Run with `zig build test-devloop`.
const std = @import("std");
const options = @import("devloop_options");
const watch = @import("watch.zig");
const hardening = @import("hardening.zig");

const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const elapsedMs = hardening.elapsedMs;

/// Valid edits timed after the initial build.
const edits = 5;
const target_ms = 2000;
/// Upper bound for one build-and-restart, including a cold first build.
const step_timeout_ms = 180_000;
const response_poll_ms = 10;

const original_line = "res.text(200, \"hello from zoda\")";

/// Watcher output shared with the test thread. The watcher writes from its
/// own task, so every write and read takes the mutex.
const Log = struct {
    mutex: Io.Mutex = .init,
    bytes: std.ArrayList(u8) = .empty,
    failed: bool = false,
    interface: Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *Log = @alignCast(@fieldParentPtr("interface", w));
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.bytes.appendSlice(testing.allocator, bytes) catch return error.WriteFailed;
            written += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            self.bytes.appendSlice(testing.allocator, last) catch return error.WriteFailed;
            written += last.len;
        }
        return written;
    }

    fn count(self: *Log, needle: []const u8) usize {
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        return std.mem.count(u8, self.bytes.items, needle);
    }

    /// Build-and-start durations reported by the watcher, in order.
    fn startDurations(self: *Log, out: []i64) !usize {
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        var n: usize = 0;
        var lines = std.mem.tokenizeScalar(u8, self.bytes.items, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "[watch] started pid ")) continue;
            const after = std.mem.indexOf(u8, line, " after ") orelse continue;
            const value = std.mem.trimEnd(u8, line[after + " after ".len ..], " ms");
            if (n == out.len) break;
            out[n] = try std.fmt.parseInt(i64, value, 10);
            n += 1;
        }
        return n;
    }

    fn deinit(self: *Log) void {
        self.bytes.deinit(testing.allocator);
    }
};

fn runWatcher(watcher: *watch.Watcher, stop: *const std.atomic.Value(bool), failure: *?anyerror) void {
    watcher.run(stop) catch |err| {
        failure.* = err;
    };
}

/// Copies `src/` (recursively), `build.zig`, and `build.zig.zon`.
fn copyProject(io: Io, from: Io.Dir, to: Io.Dir) !void {
    for ([_][]const u8{ "build.zig", "build.zig.zon" }) |name| {
        try from.copyFile(name, to, name, io, .{});
    }
    var src = try from.openDir(io, "src", .{ .iterate = true });
    defer src.close(io);
    var walker = try src.walk(testing.allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const dest = try std.fs.path.join(testing.allocator, &.{ "src", entry.path });
        defer testing.allocator.free(dest);
        switch (entry.kind) {
            .directory => try to.createDirPath(io, dest),
            .file => try entry.dir.copyFile(entry.basename, to, dest, io, .{ .make_path = true }),
            else => {},
        }
    }
}

/// Rewrites the `GET /` handler so it returns `body`, or so it fails to
/// compile when `broken` is set.
fn writeRoute(io: Io, dir: Io.Dir, original: []const u8, body: []const u8, broken: bool) !void {
    const replacement = try std.fmt.allocPrint(testing.allocator, "res.text(200, \"{s}\"{s})", .{
        body, if (broken) " ++ undefined_devloop_identifier" else "",
    });
    defer testing.allocator.free(replacement);
    const edited = try std.mem.replaceOwned(u8, testing.allocator, original, original_line, replacement);
    defer testing.allocator.free(edited);
    try dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = edited });
}

/// One `GET /`; null while the server is down or restarting.
fn get(io: Io, address: *const net.IpAddress) !?[]u8 {
    var client = hardening.Client.connect(io, address) catch |err| switch (err) {
        error.ConnectionRefused => return null,
        else => return err,
    };
    defer client.close();
    client.send("GET / HTTP/1.1\r\nHost: devloop\r\nConnection: close\r\n\r\n") catch return null;
    const reply = client.readResponse(false) catch return null;
    if (reply.status != 200) {
        reply.deinit();
        return error.UnexpectedStatus;
    }
    return reply.body;
}

/// Polls `GET /` until it returns `body`; returns the elapsed milliseconds.
fn awaitBody(io: Io, address: *const net.IpAddress, body: []const u8, since: Io.Clock.Timestamp, log: *Log) !i64 {
    while (true) {
        if (try get(io, address)) |got| {
            defer testing.allocator.free(got);
            if (std.mem.eql(u8, got, body)) return elapsedMs(io, since);
        }
        if (elapsedMs(io, since) > step_timeout_ms) {
            log.mutex.lockUncancelable(io);
            defer log.mutex.unlock(io);
            std.debug.print("devloop: timed out waiting for \"{s}\"; watcher log:\n{s}\n", .{ body, log.bytes.items });
            return error.ResponseTimedOut;
        }
        try Io.sleep(io, .fromMilliseconds(response_poll_ms), .awake);
    }
}

fn freePort(io: Io) !u16 {
    const any: net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try any.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    return listener.socket.address.getPort();
}

fn lessThan(_: void, a: i64, b: i64) bool {
    return a < b;
}

test "devloop: demo rebuilds, restarts, and recovers from a compile failure" {
    const io = testing.io;
    var repo = try Io.Dir.cwd().openDir(io, options.repo_root, .{});
    defer repo.close(io);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try copyProject(io, repo, tmp.dir);
    const original = try tmp.dir.readFileAlloc(io, "src/main.zig", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(original);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, original, original_line));

    const port = try freePort(io);
    var port_buf: [5]u8 = undefined;
    const port_arg = try std.fmt.bufPrint(&port_buf, "{d}", .{port});
    const address: net.IpAddress = .{ .ip4 = .loopback(port) };

    var log: Log = .{};
    defer log.deinit();
    var watcher = try watch.Watcher.init(testing.allocator, io, .{
        .root = tmp.dir,
        .watch_paths = &.{ "src", "build.zig", "build.zig.zon" },
        .build_argv = &.{ options.zig_exe, "build" },
        .run_argv = &.{ "zig-out/bin/zoda", "serve", port_arg },
        // The test runner's stdout carries the build-system protocol.
        .run_stdout = .ignore,
    }, &log.interface);
    var stop: std.atomic.Value(bool) = .init(false);
    var failure: ?anyerror = null;
    var task = try io.concurrent(runWatcher, .{ &watcher, &stop, &failure });
    var stopped = false;
    defer if (!stopped) {
        stop.store(true, .release);
        task.await(io);
        watcher.deinit();
    };

    // Cold start: first build of the copy, then the original body.
    const cold = Io.Clock.Timestamp.now(io, .awake);
    const cold_ms = try awaitBody(io, &address, "hello from zoda", cold, &log);

    // Successful rebuild and restart, timed.
    var samples: [edits]i64 = undefined;
    var body_buf: [64]u8 = undefined;
    for (&samples, 1..) |*sample, n| {
        const body = try std.fmt.bufPrint(&body_buf, "hello from zoda edit {d}", .{n});
        try writeRoute(io, tmp.dir, original, body, false);
        sample.* = try awaitBody(io, &address, body, Io.Clock.Timestamp.now(io, .awake), &log);
    }
    try testing.expectEqual(@as(usize, edits + 1), log.count("[watch] started pid "));
    try testing.expectEqual(@as(usize, edits), log.count("[watch] stopped pid "));
    const last_body = try testing.allocator.dupe(u8, try std.fmt.bufPrint(&body_buf, "hello from zoda edit {d}", .{edits}));
    defer testing.allocator.free(last_body);

    // Compile failure: diagnostics shown, the last working process keeps
    // serving, and nothing is restarted.
    try writeRoute(io, tmp.dir, original, "hello from zoda broken", true);
    const broken = Io.Clock.Timestamp.now(io, .awake);
    while (log.count("[watch] build failed; keeping previous process") == 0) {
        if (elapsedMs(io, broken) > step_timeout_ms) return error.BuildFailureNotReported;
        try Io.sleep(io, .fromMilliseconds(response_poll_ms), .awake);
    }
    const failed_ms = elapsedMs(io, broken);
    try testing.expect(log.count("undefined_devloop_identifier") > 0);
    try testing.expect(log.count("error:") > 0);
    for (0..3) |_| {
        const got = (try get(io, &address)) orelse return error.ServerDownAfterFailedBuild;
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(last_body, got);
    }
    try testing.expectEqual(@as(usize, edits + 1), log.count("[watch] started pid "));

    // Recovery on the next valid edit, timed like the others.
    try writeRoute(io, tmp.dir, original, "hello from zoda recovered", false);
    const recovered_ms = try awaitBody(io, &address, "hello from zoda recovered", Io.Clock.Timestamp.now(io, .awake), &log);
    try testing.expectEqual(@as(usize, edits + 2), log.count("[watch] started pid "));
    try testing.expectEqual(@as(usize, edits + 1), log.count("[watch] stopped pid "));

    // Stopping the watcher stops and reaps the demo; the port is released.
    stop.store(true, .release);
    task.await(io);
    stopped = true;
    if (failure) |err| return err;
    const last_pid = watcher.pid().?;
    watcher.deinit();
    try testing.expectEqual(@as(?std.process.Child.Id, null), watcher.pid());
    try testing.expectError(error.ProcessNotFound, std.posix.kill(last_pid, @enumFromInt(0)));
    try testing.expectEqual(@as(?[]u8, null), try get(io, &address));

    var builds: [edits + 2]i64 = undefined;
    try testing.expectEqual(builds.len, try log.startDurations(&builds));
    var sorted = samples;
    std.mem.sort(i64, &sorted, {}, lessThan);
    var over: usize = 0;
    for (samples) |sample| over += @intFromBool(sample > target_ms);
    over += @intFromBool(recovered_ms > target_ms);
    std.debug.print("devloop: zig={s} builtin_zig={s} cold_start_ms={d} edit_to_response_ms={any} min={d} median={d} max={d} build_and_start_ms={any} failed_build_reported_ms={d} recovery_ms={d} target_ms={d} over_target={d}/{d}\n", .{
        options.zig_exe, @import("builtin").zig_version_string, cold_ms, samples, sorted[0], sorted[edits / 2], sorted[edits - 1], builds, failed_ms, recovered_ms, target_ms, over, edits + 1,
    });
}
