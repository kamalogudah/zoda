# From Roda to Zig: explicit control flow, typed capabilities

**Talk length:** about 12 minutes, plus questions. **Status:** design talk based on
the implemented Zoda HTTP/1.x contract, not a proposal for new API. All Zig
snippets below are excerpts from the compiling
[`examples/contract.zig`](examples/contract.zig) or the tested
[`README.md`](README.md#route-wrappers) wrapper example. Build with **Zig
0.16.0** on the primary **x86_64-linux-gnu** target.

## 1. The question (1 minute)

Roda's useful idea is a route written as nested imperative code. What survives
when that idea moves to Zig, where a request has explicit storage, the handler
must return explicitly, and capabilities are types and values registered on an
app? Zoda's answer is a consuming path cursor, typed plugin instances, and a
response that owns its output. The implemented scope is buffered HTTP/1.0 and
HTTP/1.1. [Design contract](zoda_plan.md#3-design-decisions) ·
[supported API](SUPPORTED_API.md#supported-surface)

**Say:** This is an adaptation of Roda's route shape, not a source translation.
The examples and failure cases are tests, so the rest of the talk describes
observed behavior.

## 2. A route is a small program (1½ minutes)

```zig
if (req.isRoot() and req.isGet()) return res.text(200, "hello from zoda");

if (req.onLiteral("users")) {
    if (req.onSegment()) |id| {
        if (req.isRoot() and req.isGet()) {
            return ctx.plugins.json.render(res, User, .{ .id = id, .name = "unknown" });
        }
    }
    return;
}
```

`onLiteral` consumes a prefix; `onSegment` borrows the next decoded segment.
`isRoot` checks the remaining path, and `isGet` checks only the method. The
`return` after the inner checks is part of the route contract: `/users` and
`/users/42/extra` stay inside the matched branch and finish unhandled, so
dispatch supplies 404. A matcher cannot return from its caller. To delegate a
matched branch, use `return child(ctx, req, res)`. Failed matchers leave the
cursor unchanged; `mark`/`restore` supports alternatives before response writes
or plugin effects. [Compiling route and seven-case matrix](examples/contract.zig) ·
[fall-through and delegation tests](src/router.zig) ·
[Roda request methods](https://roda.jeremyevans.net/rdoc/classes/Roda/RodaPlugins/Base/RequestMethods.html)

**Say:** A shared prefix avoids repeating `users` comparisons, but attempted
siblings and string comparisons still count. There is no unconditional
O(depth) routing guarantee.

## 3. Registration makes capabilities visible (1 minute)

```zig
const Plugins = struct {
    json: zoda.Json = .{},
    request_id: RequestId = .{ .prefix = "example" },
};
const App = zoda.app.App(Plugins);
```

The route calls `ctx.plugins.json.render(...)`; `request_id` supplies
`ctx.state.request_id.value`. `App(Plugins)` derives the typed context and
request-state fields from registered instances. State initializes in field
order and cleans up in reverse, including partial initialization failure.
Plugin instances are immutable during dispatch; mutable resources behind them
need synchronization. [Compiling registration and state hook](examples/contract.zig) ·
[initialization, failure, and isolation tests](src/app.zig)

**Say:** The explicit call shows which registered plugin produced JSON. Zoda
does not inject plugin methods into a shared handler namespace.

## 4. The request and response have different lifetimes (1 minute)

```zig
var arena = try zoda.request.parseOriginForm(std.testing.allocator, .default, target);
defer arena.deinit();
var req = arena.requestView(method);
return app.dispatch(&req);
```

The caller owns the request arena through dispatch. Captures, query/header
values, and body slices borrow it. The returned `Response` independently owns
body and header copies through `response_allocator`; its caller must
`res.deinit()`, and that allocator must outlive the response. Socket service
needs thread-safe allocators. Allocation failure propagates as an error, never
as a route miss. [Compiled lifetime example](examples/contract.zig) ·
[response-after-arena test](src/app.zig) ·
[ownership rules](SUPPORTED_API.md#ownership-and-lifecycle)

**Say:** The example helper releases its arena before its caller checks the
response. That is the ownership seam between routing and transport.

## 5. Middleware surrounds finalization (1 minute)

```zig
fn addRequestId(
    raw: *const anyopaque,
    ctx: *App.Context,
    req: *zoda.router.Request,
    res: *zoda.response.Response,
    next: App.Next,
) anyerror!void {
    const cfg: *const HeaderConfig = @ptrCast(@alignCast(raw));
    try next.call(ctx, req, res);
    try res.setHeader(cfg.name, ctx.state.request_id.value);
}
```

Entries enter in registration order and unwind in reverse. The terminal
continuation runs wrappers and route, then applies the default 404, so a route
miss is visible during middleware unwind. Middleware may short circuit;
`Next.call` runs downstream at most once, including through copied `Next`
values. `App.init` copies the entry list but borrows each immutable config
pointer until `app.deinit()`. Recovery from a partial response requires
`res.clear()` before replacement. [Compiling middleware and timing](examples/contract.zig) ·
[order, short-circuit, recovery, and concurrent-frame tests](src/app.zig)

## 6. Wrappers are composed at comptime (1½ minutes)

```zig
pub fn wrapRoute(comptime H: type, comptime inner: H.RouteFn) H.RouteFn {
    return struct {
        fn run(ctx: *H.Context, req: *zoda.router.Request, res: *zoda.response.Response) anyerror!void {
            const self = H.plugin(ctx);
            if (try req.getHeaderOne(self.name) == null) return res.text(400, "missing header");
            try inner(ctx, req, res);
            try res.setHeader("X-Checked-By", ctx.config.name);
        }
    }.run;
}
// In App.init: .route_fn = App.composeRoute(route),
```

This is the tested `RequireHeader` example. `H` supplies the app's typed route
and context, the configured plugin through `H.plugin(ctx)`, and request state
through `H.state(ctx)` when needed. `App.composeRoute(route)` takes a
comptime-known base route. The first registered wrapper is outermost; a wrapper
can skip the inner chain, see an unhandled route miss, or write a fallback.
Passing `route` directly as `route_fn` runs no wrappers. The built-in
`NotFound` plugin uses this boundary for a configured 404; middleware that
short circuits before the terminal continuation still gets dispatch's default
404. [Tested public example](README.md#route-wrappers) ·
[composition/order tests](src/app.zig) · [full lifecycle tests](src/lifecycle.zig)

**Say:** Middleware encloses the wrappers and finalization; wrappers enclose
only the route. The test traces pin entry, exit, skip, error, and 404 order.

## 7. Demo: run the contract (1 minute)

```sh
zig version                                      # 0.16.0
zig build test-examples --summary all
./zig-out/bin/zoda
```

The example asserts seven outcomes: `GET /` gives 200 text;
`GET /users/42` gives 200 JSON; `/users`, `/users/42/extra`,
`/users/42/`, and `POST /users/42` give 404; a decoded search query gives
200 text. It also checks a middleware-added request ID, timing header, and
duplicate query rejection. The demo executable prints the route outcomes.
[Exact test](examples/contract.zig) · [build steps](build.zig) ·
[public commands](SUPPORTED_API.md#toolchain-and-commands)

## 8. Measurements, with their scope (1½ minutes)

On an Intel i5-8365U Ubuntu 24.04.4 host, a local Zig 0.16.0 ReleaseSafe
rerun held 64 loopback keep-alive clients for 60.004 seconds: **1,051,224
verified responses, 17,519/s, zero client errors**, mean 3.321 ms,
p95 ≤8.191 ms, and p99 ≤16.383 ms. Percentiles are histogram bucket upper
bounds. In the overload run, 128 incomplete requests were admitted and all 32
excess clients were rejected; active connections and counted allocations
returned to zero. The earlier recorded run on the same CPU with Ubuntu 24.04.1
measured 6,414/s and p95 ≤32.767 ms. These characterize two host/build
conditions, not a throughput guarantee. [Method and both results](SUPPORTED_API.md#reproducible-measurements-and-decisions) ·
[pinned load CI](https://github.com/kamalogudah/zoda/actions/runs/36153064159)

The Debug rebuild loop's recorded 18 edits took 1,390–1,890 ms
edit-to-response, with a 1,534 ms median for valid edits. A compile error left
the old server answering; the next valid edit recovered. A later local rerun
measured five valid edits at 1,458–1,663 ms and recovery at 1,665 ms.
[Method and results](zoda_plan.md#427-phase-2d-recovery-and-latency-evidence--issue-21)

## 9. Shipped boundary and next decisions (1 minute)

**Shipped:** strict origin-form parsing, nested consuming routes, typed
registered plugins, ordered middleware, opt-in comptime route wrappers,
buffered responses, embedded HTML templates, static-file middleware, signed
cookie sessions and session-bound CSRF, and bounded cleartext HTTP/1.x socket
service. [Supported surface](SUPPORTED_API.md#supported-surface)

**Unsupported or deferred:** response streaming, native HTTP/2 and TLS,
automatic 405/`Allow` or HEAD-to-GET fallback, named captures, a route DSL,
runtime templates, and directory listing. HTTP/2/TLS may terminate at a
reverse proxy forwarding HTTP/1.1. Streaming needs a separate ADR and a
demonstrated use; HTTP/2 needs a new transport decision and integration tests.
Named captures and conveniences wait for a concrete route that justifies them.
[Boundaries](SUPPORTED_API.md#defaults-and-unsupported-capabilities) ·
[conditional follow-ups](zoda_plan.md#6-verification-and-remaining-decisions) ·
[roadmap issue](https://github.com/kamalogudah/zoda/issues/38)

**Close:** The portable part of Roda's design is the readable nested route.
Zig makes branch termination, registration, storage, and composition explicit.

## Evidence and presentation gate

The router core acceptance gate passed on pinned Zig 0.16.0 in
[CI run 35216960748](https://github.com/kamalogudah/zoda/actions/runs/35216960748).
The registered-plugin application gate passed in
[CI run 35260529918](https://github.com/kamalogudah/zoda/actions/runs/35260529918).
Wrapper composition and lifecycle are covered by the
[`src/app.zig`](src/app.zig) and [`src/lifecycle.zig`](src/lifecycle.zig) tests
and passed pinned CI in
[wrapper run 40175900524](https://github.com/kamalogudah/zoda/actions/runs/40175900524)
and [not-found lifecycle run 40229156453](https://github.com/kamalogudah/zoda/actions/runs/40229156453).
The
Phase 6 API write-up is [issue #36](https://github.com/kamalogudah/zoda/issues/36)
and [`SUPPORTED_API.md`](SUPPORTED_API.md). The current documentation commit
has no hosted CI run yet; the talk adds no implementation or tests.

To verify the checked examples and gates locally:

```sh
zig version                                      # exactly 0.16.0
zig fmt --check build.zig src examples
zig build
zig build test --summary all
zig build test-examples --summary all
zig build test-hardening -Doptimize=ReleaseSafe --summary all
zig build test-load -Doptimize=ReleaseSafe --summary all
zig build test-devloop --summary all
./zig-out/bin/zoda
```

For this talk change, local `zig version` printed `0.16.0`;
`zig fmt --check build.zig src examples` passed;
`zig build test --summary all` passed 172/172; and
`zig build test-examples --summary all` passed 1/1. The remaining commands
above reproduce the previously recorded socket, load, and development-loop
evidence; this documentation change did not rerun those longer measurements.
