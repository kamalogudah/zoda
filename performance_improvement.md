# Performance improvement log

This document tracks Zoda's measured throughput, what limits it, and the
proposals for raising it. It is a living record: every change that can affect
the request path adds a row to the [benchmark log](#benchmark-log) and updates
the [proposal status](#proposals). [Agent.md](Agent.md) describes the procedure.

Numbers here are local loopback measurements, not throughput guarantees.

## Current state

| | |
|---|---|
| Last measured | 2026-11-04, `a59d0ff` + Zig 0.17.1 upgrade, A/B against Zig 0.16.0, cores pinned (environments C and D) |
| Todo app, `GET /api/todos`, 128 connections | ~72–95k req/s on 0.17.1 (median 83k; 0.16.0 median 90k) |
| Todo app, `GET /`, 128 connections | ~33–49k req/s on 0.17.1 (median 42k; 0.16.0 median 43k) |
| Todo app, `GET /api/todos`, 400 connections | ~21–40k req/s on 0.17.1 (median 26k; 0.16.0 median 27k), 190k–370k socket read errors on both |
| Demo server, `GET /`, 128 connections | ~92–120k req/s on 0.17.1 (median 117k; 0.16.0 median 104k) |
| Zig 0.17.1 vs 0.16.0 | No measurable runtime change. Paired per-round differences ranged from −25% to +27% and flipped sign with run order; throughput fell ~30% from round 1 to round 4 on both versions (thermal). Differences under ~10% cannot be resolved on this laptop. Cold ReleaseFast compile of the todo app is slower on 0.17.1 (3 of 4 runs; median ~35 s vs ~28 s) and binaries are ~7% larger |

Earlier rows were not pinned (environment A), so they are not directly
comparable with the 2026-11-04 rows.

## How the server handles concurrency

- `src/server.zig` runs one accept loop. Each admitted connection becomes a
  task through `std.Io.Group.concurrent`.
- Under the default `std.Io.Threaded` (Zig 0.16 and 0.17), each task runs on
  a pooled OS thread, so the server is **thread-per-connection**. With 128 wrk
  connections the process had 137 threads and used about 3.75 of 8 cores. On
  2026-11-04 the todo app had 135 threads on 0.16.0 and 136 on 0.17.1.
- Socket reads and writes call `read` and `sendmsg` directly, with
  `SO_RCVTIMEO`/`SO_SNDTIMEO` set before each call to enforce absolute
  deadlines. Because they bypass `std.Io`, switching to an evented `Io`
  implementation is not a drop-in change.
- HTTP/1.x heads are parsed by `std.http.Server`. Zoda adds its own framing
  checks and chunked decoder in `src/transport.zig`.
- `listen(.{ .reuse_address = true })` also sets `SO_REUSEPORT` (Zig 0.16 and
  0.17; four servers were seen sharing port 8080 on 0.17.1). A
  second process on the same port silently receives half the connections. Make
  sure only one server is running before you benchmark.

## Where the time goes (2026-10-28)

Per-request CPU of the server process, measured from `/proc/<pid>/stat` over an
8 s wrk run with 4 threads and 128 connections, using the P1 config below:

| Route | User CPU / request | Kernel CPU / request | Context switches / request |
|---|---|---|---|
| `GET /api/todos` | ~18 µs | ~52 µs | ~0.8 |
| `GET /` | ~69 µs | ~35 µs | ~0.5 |

During those runs the whole machine was 0% idle (32% user, 48% system, 20%
softirq), and changing wrk's thread count from 2 to 8 did not change the
result. Two conclusions follow:

1. The JSON route is dominated by kernel work: loopback TCP, syscalls, and
   waking many connection threads.
2. The `/` route spends most of its user CPU re-rendering the same 3 KB
   template on every request.

`perf` and `strace` were not available on the measuring machine
(`perf_event_paranoid=4`, ptrace restricted). Function-level profiles are
still to be captured.

## Proposals

Status values: `proposed`, `in progress`, `done`, `rejected`. When a proposal
changes status, link the benchmark log row that measured it.

| ID | Proposal | Expected effect | Effort | Status |
|---|---|---|---|---|
| P1 | Raise `max_connections` (e.g. 1024) and `max_requests_per_connection` (e.g. 1,000,000 or unlimited) | Removes reconnect churn and admission rejections | One-line config; defaults also documented in README | proposed (measured in experiment E1) |
| P2 | Render the todo `/` page once at startup and serve the stored bytes | Removes ~69 µs user CPU per `/` request | Small | proposed |
| P3 | Cache the serialized todo list JSON, rebuilt on add/toggle/delete, or use a reader-writer lock | Shorter critical section under load; grows with list size | Small | proposed |
| P4 | Set socket timeouts only when the phase deadline changes, not before every read/write | Removes 1 syscall per read and per write | Small, but weakens slow-client protection | proposed, low priority (E2 within noise) |
| P5 | Replace thread-per-connection with an epoll/io_uring loop, about one worker per core | Cuts kernel scheduling and context-switch cost, the main limit today | Large | proposed |
| P6 | Add http.zig as an alternative transport behind `App.dispatch` (see [below](#http-zig-evaluation)) | Gets P5's model from an existing library | ~3–6 days | proposed |
| P7 | Benchmark with wrk and the server pinned to separate cores, with other heavy apps closed | Results measure Zoda, not the machine | Procedure only | in progress: pinning used for the 2026-11-04 Zig 0.17.1 A/B rows (environments C, D) with Chrome still open; thermal drift remained the largest error source |

### Experiments

These ran in a throwaway worktree on commit `09cfa3c`. They were not merged.

| ID | Change | `/api/todos` c128 | `/` c128 | `/api/todos` c400 |
|---|---|---|---|---|
| base | none | 37,855 req/s, 44 read errors | 24,221 req/s, 12 read errors | 21,362 req/s, 61,002 read errors |
| E1 | todo config `.max_connections = 1024, .max_requests_per_connection = 1_000_000` | 34,764 req/s, 0 errors | 20,789 req/s, 0 errors | 30,623 req/s, 0 errors |
| E2 | E1 plus `setSocketTimeout` disabled (unsafe; measurement only) | 35,124 req/s | 26,079 req/s | 32,487 req/s |

Run-to-run variation on this machine was about ±15%, so the 128-connection
differences are within noise. E1's 400-connection gain (+43%, errors from
61k to 0) is well outside it.

### http.zig evaluation

[karlseguin/http.zig](https://github.com/karlseguin/http.zig) uses epoll or
kqueue worker threads that parse requests and hand them to a handler thread
pool. Its master branch targets Zig 0.17, and a `zig-0.16.0` branch matches
Zoda's pinned toolchain.

- **Integration point.** Everything above the transport goes through
  `App.dispatch(*router.Request) !response.Response`. An adapter handler copies
  method, target, headers and body into a `request.RequestArena`, calls
  `dispatch`, and writes the status, headers and body back. That is roughly
  150–300 lines.
- **What it replaces.** `src/server.zig` and `src/transport.zig` (about 1,400
  lines), plus the `zoda.server.serve` call sites in `src/main.zig`,
  `examples/todo.zig` and the `src/host_authorization.zig` tests.
- **Main cost.** `src/hardening.zig` (787 lines of real-socket tests) targets
  `server.serve`. Each guarantee needs re-checking under http.zig: strict
  chunked parsing, rejecting Content-Length together with Transfer-Encoding,
  absolute header/body/write deadlines, the admission cap, and graceful
  shutdown.
- **Recommendation.** Do P1–P3 first. Then add http.zig as an optional second
  backend and compare both with the standard procedure before removing
  anything.

## Standard benchmark procedure

Use the same commands each time so rows in the log stay comparable. Build with
ReleaseFast and seed the todo store with 10 items first.

```sh
zig build -Doptimize=ReleaseFast run-todo &
# Wait for http://127.0.0.1:8080 to answer, then:
for i in $(seq 1 10); do
  curl -s -o /dev/null -X POST -d "{\"text\":\"todo item $i\"}" http://127.0.0.1:8080/api/todos
done
wrk -t8 -c128 -d10s http://127.0.0.1:8080/api/todos
wrk -t8 -c128 -d10s http://127.0.0.1:8080/
wrk -t8 -c400 -d10s http://127.0.0.1:8080/api/todos
pkill -x todo
```

For the demo server:

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/zoda serve 18080 &
wrk -t12 -c128 -d30s http://127.0.0.1:18080
```

Record `Requests/sec`, average latency, and the `Socket errors` line. If you
pin cores (P7), note the `taskset` masks in the log row.

## Benchmark log

Newest first. Never edit or delete old rows; add a new row for every
measurement.

| Date | Commit | Change | Target | Command | Req/s | Avg latency | Socket errors | Environment |
|---|---|---|---|---|---|---|---|---|
| 2026-11-04 | `a59d0ff` | Zig 0.17.1 upgrade A/B, round 4/4, ran second: baseline on Zig 0.16.0. Paired rounds within noise; see Current state | demo `zoda serve` `/` | `wrk -t12 -c128 -d30s` | 97,929 | 1.73 ms | none | C |
| 2026-11-04 | `a59d0ff` + working tree | Zig 0.17.1 upgrade A/B, round 4/4, ran first: `update-zig` branch on Zig 0.17.1. Paired rounds within noise; see Current state | demo `zoda serve` `/` | `wrk -t12 -c128 -d30s` | 115,091 | 1.35 ms | none | D |
| 2026-11-04 | `a59d0ff` | Zig 0.17.1 upgrade A/B, round 4/4, ran second: baseline on Zig 0.16.0. Paired rounds within noise; see Current state | todo `/api/todos` | `wrk -t8 -c400 -d10s` | 21,423 | 3.36 ms | read 283,415 | C |
| 2026-11-04 | `a59d0ff` | Zig 0.17.1 upgrade A/B, round 4/4, ran second: baseline on Zig 0.16.0. Paired rounds within noise; see Current state | todo `/` | `wrk -t8 -c128 -d10s` | 33,212 | 4.50 ms | read 39 | C |
| 2026-11-04 | `a59d0ff` | Zig 0.17.1 upgrade A/B, round 4/4, ran second: baseline on Zig 0.16.0. Paired rounds within noise; see Current state | todo `/api/todos` | `wrk -t8 -c128 -d10s` | 73,459 | 2.20 ms | read 76 | C |
| 2026-11-04 | `a59d0ff` + working tree | Zig 0.17.1 upgrade A/B, round 4/4, ran first: `update-zig` branch on Zig 0.17.1. Paired rounds within noise; see Current state | todo `/api/todos` | `wrk -t8 -c400 -d10s` | 20,564 | 3.36 ms | read 286,402 | D |
| 2026-11-04 | `a59d0ff` + working tree | Zig 0.17.1 upgrade A/B, round 4/4, ran first: `update-zig` branch on Zig 0.17.1. Paired rounds within noise; see Current state | todo `/` | `wrk -t8 -c128 -d10s` | 32,658 | 4.68 ms | read 61 | D |
| 2026-11-04 | `a59d0ff` + working tree | Zig 0.17.1 upgrade A/B, round 4/4, ran first: `update-zig` branch on Zig 0.17.1. Paired rounds within noise; see Current state | todo `/api/todos` | `wrk -t8 -c128 -d10s` | 71,890 | 1.88 ms | read 110 | D |
| 2026-11-04 | `a59d0ff` + working tree | Zig 0.17.1 upgrade A/B, round 3/4, ran second: `update-zig` branch on Zig 0.17.1. Paired rounds within noise; see Current state | demo `zoda serve` `/` | `wrk -t12 -c128 -d30s` | 92,347 | 1.44 ms | none | D |
| 2026-11-04 | `a59d0ff` | Zig 0.17.1 upgrade A/B, round 3/4, ran first: baseline on Zig 0.16.0. Paired rounds within noise; see Current state | demo `zoda serve` `/` | `wrk -t12 -c128 -d30s` | 97,852 | 1.55 ms | none | C |
| 2026-11-04 | `a59d0ff` + working tree | Zig 0.17.1 upgrade A/B, round 3/4, ran second: `update-zig` branch on Zig 0.17.1. Paired rounds within noise; see Current state | todo `/api/todos` | `wrk -t8 -c400 -d10s` | 28,284 | 3.12 ms | read 190,814 | D |
| 2026-11-04 | `a59d0ff` + working tree | Zig 0.17.1 upgrade A/B, round 3/4, ran second: `update-zig` branch on Zig 0.17.1. Paired rounds within noise; see Current state | todo `/` | `wrk -t8 -c128 -d10s` | 38,610 | 4.35 ms | read 39 | D |
| 2026-11-04 | `a59d0ff` + working tree | Zig 0.17.1 upgrade A/B, round 3/4, ran second: `update-zig` branch on Zig 0.17.1. Paired rounds within noise; see Current state | todo `/api/todos` | `wrk -t8 -c128 -d10s` | 73,889 | 1.90 ms | read 85 | D |
| 2026-11-04 | `a59d0ff` | Zig 0.17.1 upgrade A/B, round 3/4, ran first: baseline on Zig 0.16.0. Paired rounds within noise; see Current state | todo `/api/todos` | `wrk -t8 -c400 -d10s` | 23,721 | 3.10 ms | read 258,501 | C |
| 2026-11-04 | `a59d0ff` | Zig 0.17.1 upgrade A/B, round 3/4, ran first: baseline on Zig 0.16.0. Paired rounds within noise; see Current state | todo `/` | `wrk -t8 -c128 -d10s` | 42,926 | 5.82 ms | read 47 | C |
| 2026-11-04 | `a59d0ff` | Zig 0.17.1 upgrade A/B, round 3/4, ran first: baseline on Zig 0.16.0. Paired rounds within noise; see Current state | todo `/api/todos` | `wrk -t8 -c128 -d10s` | 90,201 | 1.79 ms | read 97 | C |
| 2026-11-04 | `a59d0ff` | Zig 0.17.1 upgrade A/B, round 2/4, ran second: baseline on Zig 0.16.0. Paired rounds within noise; see Current state | demo `zoda serve` `/` | `wrk -t12 -c128 -d30s` | 111,036 | 1.21 ms | none | C |
| 2026-11-04 | `a59d0ff` + working tree | Zig 0.17.1 upgrade A/B, round 2/4, ran first: `update-zig` branch on Zig 0.17.1. Paired rounds within noise; see Current state | demo `zoda serve` `/` | `wrk -t12 -c128 -d30s` | 120,120 | 1.13 ms | none | D |
| 2026-11-04 | `a59d0ff` | Zig 0.17.1 upgrade A/B, round 2/4, ran second: baseline on Zig 0.16.0. Paired rounds within noise; see Current state | todo `/api/todos` | `wrk -t8 -c400 -d10s` | 30,500 | 2.34 ms | read 328,966 | C |
| 2026-11-04 | `a59d0ff` | Zig 0.17.1 upgrade A/B, round 2/4, ran second: baseline on Zig 0.16.0. Paired rounds within noise; see Current state | todo `/` | `wrk -t8 -c128 -d10s` | 42,729 | 4.12 ms | read 48 | C |
| 2026-11-04 | `a59d0ff` | Zig 0.17.1 upgrade A/B, round 2/4, ran second: baseline on Zig 0.16.0. Paired rounds within noise; see Current state | todo `/api/todos` | `wrk -t8 -c128 -d10s` | 89,813 | 1.77 ms | read 75 | C |
| 2026-11-04 | `a59d0ff` + working tree | Zig 0.17.1 upgrade A/B, round 2/4, ran first: `update-zig` branch on Zig 0.17.1. Paired rounds within noise; see Current state | todo `/api/todos` | `wrk -t8 -c400 -d10s` | 22,846 | 2.99 ms | read 370,346 | D |
| 2026-11-04 | `a59d0ff` + working tree | Zig 0.17.1 upgrade A/B, round 2/4, ran first: `update-zig` branch on Zig 0.17.1. Paired rounds within noise; see Current state | todo `/` | `wrk -t8 -c128 -d10s` | 49,180 | 2.61 ms | read 76 | D |
| 2026-11-04 | `a59d0ff` + working tree | Zig 0.17.1 upgrade A/B, round 2/4, ran first: `update-zig` branch on Zig 0.17.1. Paired rounds within noise; see Current state | todo `/api/todos` | `wrk -t8 -c128 -d10s` | 92,137 | 1.59 ms | read 107 | D |
| 2026-11-04 | `a59d0ff` + working tree | Zig 0.17.1 upgrade A/B, round 1/4, ran second: `update-zig` branch on Zig 0.17.1. Paired rounds within noise; see Current state | demo `zoda serve` `/` | `wrk -t12 -c128 -d30s` | 119,159 | 1.17 ms | none | D |
| 2026-11-04 | `a59d0ff` | Zig 0.17.1 upgrade A/B, round 1/4, ran first: baseline on Zig 0.16.0. Paired rounds within noise; see Current state | demo `zoda serve` `/` | `wrk -t12 -c128 -d30s` | 113,489 | 1.35 ms | none | C |
| 2026-11-04 | `a59d0ff` + working tree | Zig 0.17.1 upgrade A/B, round 1/4, ran second: `update-zig` branch on Zig 0.17.1. Paired rounds within noise; see Current state | todo `/api/todos` | `wrk -t8 -c400 -d10s` | 40,096 | 2.31 ms | read 230,524 | D |
| 2026-11-04 | `a59d0ff` + working tree | Zig 0.17.1 upgrade A/B, round 1/4, ran second: `update-zig` branch on Zig 0.17.1. Paired rounds within noise; see Current state | todo `/` | `wrk -t8 -c128 -d10s` | 46,339 | 4.71 ms | read 97 | D |
| 2026-11-04 | `a59d0ff` + working tree | Zig 0.17.1 upgrade A/B, round 1/4, ran second: `update-zig` branch on Zig 0.17.1. Paired rounds within noise; see Current state | todo `/api/todos` | `wrk -t8 -c128 -d10s` | 95,281 | 1.61 ms | read 119 | D |
| 2026-11-04 | `a59d0ff` | Zig 0.17.1 upgrade A/B, round 1/4, ran first: baseline on Zig 0.16.0. Paired rounds within noise; see Current state | todo `/api/todos` | `wrk -t8 -c400 -d10s` | 31,615 | 2.60 ms | read 281,078 | C |
| 2026-11-04 | `a59d0ff` | Zig 0.17.1 upgrade A/B, round 1/4, ran first: baseline on Zig 0.16.0. Paired rounds within noise; see Current state | todo `/` | `wrk -t8 -c128 -d10s` | 50,155 | 4.47 ms | read 52 | C |
| 2026-11-04 | `a59d0ff` | Zig 0.17.1 upgrade A/B, round 1/4, ran first: baseline on Zig 0.16.0. Paired rounds within noise; see Current state | todo `/api/todos` | `wrk -t8 -c128 -d10s` | 107,199 | 1.36 ms | read 109 | C |
| 2026-10-30 | `04b8fd0` + working tree | CSRF `X-XSRF-TOKEN`/`XSRF-TOKEN` helpers and Inertia context shared props (opt-in, not in todo app; request path unchanged). Differences from earlier rows are machine variation | todo `/api/todos` | `wrk -t8 -c128 -d10s` | 83,362 | 1.63 ms | read 230 | A |
| 2026-10-30 | `04b8fd0` + working tree | CSRF `X-XSRF-TOKEN`/`XSRF-TOKEN` helpers and Inertia context shared props (opt-in, not in todo app; request path unchanged). Differences from earlier rows are machine variation | todo `/` | `wrk -t8 -c128 -d10s` | 49,084 | 3.16 ms | read 21 | A |
| 2026-10-30 | `04b8fd0` + working tree | CSRF `X-XSRF-TOKEN`/`XSRF-TOKEN` helpers and Inertia context shared props (opt-in, not in todo app; request path unchanged). Differences from earlier rows are machine variation | todo `/api/todos` | `wrk -t8 -c400 -d10s` | 55,824 | 1.54 ms | read 149571 | A |
| 2026-10-28 | `1b8b3ee` + working tree | Inertia.js plugin (opt-in, not in todo app; request path unchanged). About 2x the previous rows with no request-path change: machine load differed, not an improvement | todo `/api/todos` | `wrk -t8 -c128 -d10s` | 65,867 | 2.03 ms | read 196 | A |
| 2026-10-28 | `1b8b3ee` + working tree | Inertia.js plugin (opt-in, not in todo app; request path unchanged). About 2x the previous rows with no request-path change: machine load differed, not an improvement | todo `/` | `wrk -t8 -c128 -d10s` | 41,911 | 2.87 ms | read 63 | A |
| 2026-10-28 | `1b8b3ee` + working tree | Inertia.js plugin (opt-in, not in todo app; request path unchanged). About 2x the previous rows with no request-path change: machine load differed, not an improvement | todo `/api/todos` | `wrk -t8 -c400 -d10s` | 29,565 | 2.35 ms | read 211,631 | A |
| 2026-10-28 | `1d0023e` + working tree | security response policy middleware (opt-in, not in todo app; request path unchanged) | todo `/api/todos` | `wrk -t8 -c128 -d10s` | 33,684 | 4.08 ms | read 69 | A |
| 2026-10-28 | `1d0023e` + working tree | security response policy middleware (opt-in, not in todo app; request path unchanged) | todo `/` | `wrk -t8 -c128 -d10s` | 26,223 | 4.28 ms | read 22 | A |
| 2026-10-28 | `1d0023e` + working tree | security response policy middleware (opt-in, not in todo app; request path unchanged) | todo `/api/todos` | `wrk -t8 -c400 -d10s` | 17,960 | 3.88 ms | read 125,062 | A |
| 2026-10-28 | `09510bb` + working tree | status/error handler middleware (opt-in, not in todo app); `Response.generated` flag. A/B vs `09510bb` on the same machine: change −19%/−23%/−12% when run second, +3%/−9%/−16% when run first; order-dependent, not a confirmed regression | todo `/api/todos` | `wrk -t8 -c128 -d10s` | 30,331 | 4.52 ms | read 84 | A |
| 2026-10-28 | `09510bb` + working tree | status/error handler middleware (opt-in, not in todo app); `Response.generated` flag. A/B vs `09510bb` on the same machine: change −19%/−23%/−12% when run second, +3%/−9%/−16% when run first; order-dependent, not a confirmed regression | todo `/` | `wrk -t8 -c128 -d10s` | 19,211 | 5.77 ms | read 8 | A |
| 2026-10-28 | `09510bb` + working tree | status/error handler middleware (opt-in, not in todo app); `Response.generated` flag. A/B vs `09510bb` on the same machine: change −19%/−23%/−12% when run second, +3%/−9%/−16% when run first; order-dependent, not a confirmed regression | todo `/api/todos` | `wrk -t8 -c400 -d10s` | 16,578 | 4.99 ms | read 55,494 | A |
| 2026-10-28 | `14ee0c2` + working tree | 1xx/204 also sent without Content-Length (200 path unchanged; within noise) | todo `/api/todos` | `wrk -t8 -c128 -d10s` | 34,820 | 3.65 ms | read 98 | A |
| 2026-10-28 | `14ee0c2` + working tree | 1xx/204 also sent without Content-Length (200 path unchanged; within noise) | todo `/` | `wrk -t8 -c128 -d10s` | 23,253 | 5.35 ms | read 23 | A |
| 2026-10-28 | `14ee0c2` + working tree | 1xx/204 also sent without Content-Length (200 path unchanged; within noise) | todo `/api/todos` | `wrk -t8 -c400 -d10s` | 20,437 | 3.92 ms | read 90,299 | A |
| 2026-10-28 | `14ee0c2` + working tree | HTTP cache helpers; transport writes 304 head without Content-Length (other responses unchanged; within noise) | todo `/api/todos` | `wrk -t8 -c128 -d10s` | 31,511 | 4.85 ms | read 94 | A |
| 2026-10-28 | `14ee0c2` + working tree | HTTP cache helpers; transport writes 304 head without Content-Length (other responses unchanged; within noise) | todo `/` | `wrk -t8 -c128 -d10s` | 22,286 | 5.17 ms | read 25 | A |
| 2026-10-28 | `14ee0c2` + working tree | HTTP cache helpers; transport writes 304 head without Content-Length (other responses unchanged; within noise) | todo `/api/todos` | `wrk -t8 -c400 -d10s` | 19,882 | 4.19 ms | read 56,647 | A |
| 2026-10-28 | `09cfa3c` | baseline (harness rerun) | todo `/api/todos` | `wrk -t8 -c128 -d8s` | 37,855 | 3.31 ms | read 44 | A |
| 2026-10-28 | `09cfa3c` | baseline (harness rerun) | todo `/` | `wrk -t8 -c128 -d8s` | 24,221 | 4.57 ms | read 12 | A |
| 2026-10-28 | `09cfa3c` | baseline (harness rerun) | todo `/api/todos` | `wrk -t8 -c400 -d8s` | 21,362 | 3.56 ms | read 61,002 | A |
| 2026-10-28 | `09cfa3c` | baseline | todo `/api/todos` | `wrk -t8 -c128 -d10s` | 32,186 | 3.93 ms | read 80 | A |
| 2026-10-28 | `09cfa3c` | baseline | todo `/` | `wrk -t8 -c128 -d10s` | 20,963 | 5.25 ms | read 4 | A |
| 2026-10-28 | `09cfa3c` | baseline | todo `/api/todos` | `wrk -t8 -c400 -d10s` | 16,869 | 4.65 ms | read 63,071 | A |
| 2026-10-27 | — | baseline | demo `zoda serve` `/` | `wrk -t12 -c128 -d30s` | 45,019.86 | 2.33 ms | none | B |

### Environments

- **A:** 8 cores, Linux 7.0.0-38-generic, Zig 0.16.0, ReleaseFast, loopback.
  wrk and the server shared all cores (not pinned), with Chrome running.
- **B:** Zig 0.16.0, ReleaseFast, loopback, default `server.Config`. Moved from
  the README; hardware not recorded.
- **C:** Intel Core i5-8365U (4 cores, 8 threads), Ubuntu 24.04.4, Linux
  7.0.0-38-generic, AC power, `powersave` governor, Zig 0.16.0, ReleaseFast,
  loopback, wrk 4.2.0. Server pinned with `taskset -c 0,1,4,5` (physical cores
  0–1) and wrk with `taskset -c 2,3,6,7` (cores 2–3); Chrome running. Binaries
  built with `zig build-exe -OReleaseFast` from the same module graph as
  `build.zig`, and run directly rather than through `zig build run-todo`.
- **D:** as C, with Zig 0.17.1. Each round ran C and D back to back, with the
  order alternating between rounds (rounds 1 and 3: C first; rounds 2 and 4:
  D first).
