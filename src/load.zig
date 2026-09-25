//! Opt-in 60-second load and above-cap overload measurements.
const std = @import("std");
const hardening = @import("hardening.zig");
const Io = std.Io;
const testing = std.testing;
const Harness = hardening.Harness;
const Client = hardening.Client;
const ms = hardening.ms;
const elapsedMs = hardening.elapsedMs;
const elapsedUs = hardening.elapsedUs;

// The two tests below are selected only by `zig build test-load`. Keep them
// out of the fast suite: the first must run for at least 60 wall-clock seconds.
const Latencies = struct {
    count: u64 = 0,
    sum_us: u64 = 0,
    max_us: u64 = 0,
    // Bucket 0 is 0 us; bucket n has an upper bound of 2^n - 1 us.
    buckets: [64]u64 = @splat(0),

    fn add(self: *Latencies, us: u64) void {
        self.count += 1;
        self.sum_us += us;
        self.max_us = @max(self.max_us, us);
        const bucket: usize = if (us == 0) 0 else 64 - @clz(us);
        self.buckets[bucket] += 1;
    }

    fn merge(self: *Latencies, other: Latencies) void {
        self.count += other.count;
        self.sum_us += other.sum_us;
        self.max_us = @max(self.max_us, other.max_us);
        for (&self.buckets, other.buckets) |*bucket, value| bucket.* += value;
    }

    fn percentileUpper(self: *const Latencies, numerator: u64) u64 {
        const target = @divFloor(self.count * numerator + 99, 100);
        var seen: u64 = 0;
        for (self.buckets, 0..) |count, index| {
            seen += count;
            if (seen >= target) return (@as(u64, 1) << @intCast(index)) - 1;
        }
        return 0;
    }
};

test "load measurement: 64 keep-alive clients for 60 seconds" {
    var h: Harness = undefined;
    // Keep the same 64 sockets throughout the run. The default 100-request
    // limit would churn connections and temporarily lift the measured peak.
    try h.start(.{ .shutdown_grace_period = ms(25), .max_requests_per_connection = std.math.maxInt(usize) }, 0);
    defer h.deinit();

    const clients = 64;
    const duration_ms = 60_000;
    const Gate = struct {
        ready: std.atomic.Value(usize) = .init(0),
        go: std.atomic.Value(bool) = .init(false),
        started: Io.Clock.Timestamp = undefined,
    };
    var gate: Gate = .{};
    const Task = struct {
        fn run(harness: *Harness, start_gate: *Gate, result: *Latencies, failure: *?anyerror) void {
            exchange(harness, start_gate, result) catch |err| {
                failure.* = err;
            };
        }

        fn exchange(harness: *Harness, start_gate: *Gate, result: *Latencies) !void {
            var client = try harness.connect();
            defer client.close();
            _ = start_gate.ready.fetchAdd(1, .acq_rel);
            while (!start_gate.go.load(.acquire)) try Io.sleep(harness.io, .fromMilliseconds(1), .awake);
            while (elapsedMs(harness.io, start_gate.started) < duration_ms) {
                const begun = Io.Clock.Timestamp.now(harness.io, .awake);
                try client.send("GET / HTTP/1.1\r\nHost: load\r\n\r\n");
                const reply = try client.expectResponse(200, "ok");
                defer reply.deinit();
                if (reply.close) return error.UnexpectedConnectionClose;
                result.add(elapsedUs(harness.io, begun));
            }
        }
    };

    var results: [clients]Latencies = @splat(.{});
    var failures: [clients]?anyerror = @splat(null);
    var group: Io.Group = .init;
    for (&results, &failures) |*result, *failure| {
        try group.concurrent(h.io, Task.run, .{ &h, &gate, result, failure });
    }
    const connecting = Io.Clock.Timestamp.now(h.io, .awake);
    while (gate.ready.load(.acquire) != clients or h.stats.active.load(.acquire) != clients) {
        if (elapsedMs(h.io, connecting) > 3000) {
            // Backdate the start so connected clients exit immediately
            // instead of running the full measurement before we fail.
            gate.started = Io.Clock.Timestamp.now(h.io, .awake).subDuration(.{ .raw = .fromMilliseconds(duration_ms), .clock = .awake });
            gate.go.store(true, .release);
            try group.await(h.io);
            return error.LoadClientsDidNotConnect;
        }
        try Io.sleep(h.io, .fromMilliseconds(1), .awake);
    }
    gate.started = Io.Clock.Timestamp.now(h.io, .awake);
    gate.go.store(true, .release);
    try group.await(h.io);
    var total: Latencies = .{};
    var errors: usize = 0;
    for (results, failures) |result, failure| {
        total.merge(result);
        if (failure) |err| {
            errors += 1;
            std.debug.print("load client error: {t}\n", .{err});
        }
    }
    const wall_ms = elapsedMs(h.io, gate.started);
    try h.expectBaseline();
    std.debug.print("load: duration_ms={d} clients={d} requests={d} errors={d} rps={d} latency_us_mean={d} p50_upper={d} p95_upper={d} p99_upper={d} max={d} active={d} peak={d} admitted={d} rejected={d} peak_allocator_bytes={d}\n", .{
        wall_ms,                                                           clients,                     total.count,                     errors,                          @divFloor(total.count * 1000, @as(u64, @intCast(wall_ms))),
        if (total.count == 0) 0 else @divFloor(total.sum_us, total.count), total.percentileUpper(50),   total.percentileUpper(95),       total.percentileUpper(99),       total.max_us,
        h.stats.active.load(.acquire),                                     h.stats.peak.load(.acquire), h.stats.admitted.load(.acquire), h.stats.rejected.load(.acquire), h.counting.peak_bytes.load(.acquire),
    });
    try testing.expect(wall_ms >= duration_ms);
    try testing.expectEqual(@as(usize, 0), errors);
    try testing.expect(total.count > 0);
    try testing.expectEqual(total.count, h.dispatches());
    try testing.expectEqual(@as(usize, clients), h.stats.admitted.load(.acquire));
    try testing.expect(h.stats.peak.load(.acquire) <= clients);
    try testing.expectEqual(@as(usize, 0), h.stats.rejected.load(.acquire));
    try h.stop();
}

test "load measurement: 160 simultaneous connections respect the 128 cap" {
    var h: Harness = undefined;
    const cap = 128;
    const excess = 32;
    try h.start(.{ .shutdown_grace_period = ms(25) }, 0);
    defer h.deinit();

    const held = try testing.allocator.alloc(Client, cap);
    defer testing.allocator.free(held);
    var opened: usize = 0;
    defer for (held[0..opened]) |*client| client.close();
    while (opened < cap) : (opened += 1) {
        held[opened] = try h.connect();
        try held[opened].send("GET / HTTP/1.1\r\n");
    }
    try h.waitActive(cap);

    var rejection_latency: Latencies = .{};
    for (0..excess) |_| {
        const begun = Io.Clock.Timestamp.now(h.io, .awake);
        var client = try h.connect();
        try client.expectClosed();
        rejection_latency.add(elapsedUs(h.io, begun));
        client.close();
    }
    const peak = h.stats.peak.load(.acquire);
    const rejected = h.stats.rejected.load(.acquire);
    // Close from the end so the deferred cleanup never sees a closed client.
    while (opened > 0) {
        const client = &held[opened - 1];
        try client.send("Host: load\r\nConnection: close\r\n\r\n");
        const reply = try client.expectResponse(200, "ok");
        reply.deinit();
        client.close();
        opened -= 1;
    }
    try h.expectBaseline();
    std.debug.print("overload: held={d} excess={d} admitted={d} rejected={d} peak={d} rejection_latency_us_mean={d} p50_upper={d} p95_upper={d} max={d} active_after={d} live_allocations_after={d} live_bytes_after={d}\n", .{
        cap,                                                          excess,                                h.stats.admitted.load(.acquire),       rejected,                 peak,
        @divFloor(rejection_latency.sum_us, rejection_latency.count), rejection_latency.percentileUpper(50), rejection_latency.percentileUpper(95), rejection_latency.max_us, h.stats.active.load(.acquire),
        h.counting.live_allocations.load(.acquire),                   h.counting.live_bytes.load(.acquire),
    });
    try testing.expectEqual(@as(usize, cap), peak);
    try testing.expectEqual(@as(usize, excess), rejected);
    try testing.expectEqual(@as(usize, cap), h.dispatches());
    try h.stop();
}
