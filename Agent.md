# Agent guide

Instructions for coding agents (and people) working on Zoda.

## Keep the performance log current

[performance_improvement.md](performance_improvement.md) is the single record
of Zoda's measured throughput and of the performance proposals. Keep it
accurate after every change.

### When to benchmark

Run the standard benchmark after any change that can affect the request path:

- `src/server.zig`, `src/transport.zig`, `src/request.zig`, `src/response.zig`,
  `src/router.zig`, `src/app.zig`, `src/buffering.zig`, `src/template.zig`
- any middleware or plugin in `src/` or `src/plugins/`
- `examples/todo.zig` or `src/main.zig` server setup
- `server.Config` defaults, allocator choices, or the Zig version

Documentation-only and test-only changes do not need a new measurement.

### What to do

1. Make sure no other server is listening on the benchmark port
   (`ss -ltnp | grep 8080`). Zig 0.16 sets `SO_REUSEPORT`, so a stray process
   silently takes part of the traffic.
2. Run the commands in
   [Standard benchmark procedure](performance_improvement.md#standard-benchmark-procedure)
   exactly as written. Use a ReleaseFast build.
3. Add one row per wrk command to the top of the
   [benchmark log](performance_improvement.md#benchmark-log), with the date,
   short commit hash, a few words on the change, the exact command, req/s,
   average latency, and the full socket error counts.
4. If the machine differs from an existing environment entry, add a new
   environment letter that records cores, OS, Zig version, and whether cores
   were pinned.
5. Update **Current state** if the numbers changed.
6. If the change implements or tests a proposal, update its status in the
   **Proposals** table and name the log rows that measured it. Add new
   proposals there with the next free `P` number.
7. Run `zig build test` before and after, and say in the log row if a change
   trades safety for speed.

### Rules

- Never invent or estimate numbers. If you could not run the benchmark (no
  wrk, port in use, sandbox limits), write `not measured` and the reason in the
  log row.
- Never edit or delete earlier log rows. Correct mistakes with a new row that
  says what it corrects.
- Report regressions as plainly as improvements.
- Run-to-run variation on a shared machine is about ±15%. Do not claim an
  improvement smaller than that without repeated runs or pinned cores.
- Keep the hardening guarantees in `src/hardening.zig` passing. A speedup that
  removes a timeout, limit, or framing check needs an explicit note and owner
  approval.
