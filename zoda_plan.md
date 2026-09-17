# ADR-0001: Zoda — Porting Roda's Design to Zig

**Status:** Proposed  
**Author:** Paul Oguda  
**Date:** 2026-09-17

## 1. Context and implementation baseline

Zoda is a proposed Zig web toolkit inspired by [Roda](https://github.com/jeremyevans/roda).
Its central ideas are routes expressed as nested imperative code and a small
core extended by explicitly registered plugins. The intended applications are
JSON APIs and server-rendered websites.

This checkout currently contains the Zig starter program in `src/main.zig`
and example library in `src/root.zig`. The proposed router, app, transport,
and plugins do not exist yet. All phases below remain unchecked. Examples in
this document specify intended behaviour; they are not compiled implementation.

The project includes transport hardening, a rebuild/restart development loop,
templating, and stateful plugins in its roadmap. HTTP/2 has a separate
feasibility gate; it is not a prerequisite for the first HTTP/1.1 release.

## 2. Architecture and first deliverable

The layers are transport, application dispatch, router, and response.
Tests can construct a complete request and dispatch it without opening sockets.

The first deliverable is a tested vertical slice:

`GET /users/42 → nested route → registered JSON plugin → HTTP response`

Its socket tests must also distinguish `/`, `/users`, `/users/42/extra`,
and unsupported methods. Complete this slice before adding the plugin catalogue.

## 3. Design decisions

### 3.1 Routing, consumption, and branch termination

Requests contain decoded path segments and a cursor. `onLiteral` consumes one
matching segment; `onSegment` consumes and returns a borrowed segment without
allocating or maintaining a second capture array. A failed matcher leaves the
cursor unchanged. Typed matchers must parse successfully before advancing.
Request construction propagates allocation failures as errors, never as
“no route matched.”

A successful prefix match commits the handler to that branch by convention:
the handler must `return` when the branch finishes, even when no response was
produced. Dispatch supplies the fallback 404. Matching itself does not return
from the caller. This prevents `GET /users` from falling through to a root
handler after consuming `users`.

Intentional alternatives use `mark() → cursor` and `restore(mark)`. Checkpoints
apply only to the same request and restore routing state, not response writes
or plugin side effects. Alternatives must be attempted before producing output.
Tests cover failed matches, nested failures, restoration, and branch termination.

`isGet()` checks only the method. `isRoot()` checks that no segments remain.
Terminal routes combine both explicitly; `isLiteral(x)` succeeds and consumes
only when exactly one remaining segment equals `x`. Method helpers do not
implicitly claim a path. Unhandled methods return 404 initially; automatic
405/Allow and HEAD-to-GET fallback are outside the first slice.

This is inspired by Roda rather than an exact translation. Roda's argument-free
`get` is method-only; its matching blocks finish the route when they return.
Zig requires explicit handler returns. See the
[Roda request-method documentation](https://roda.jeremyevans.net/rdoc/classes/Roda/RodaPlugins/Base/RequestMethods.html).

A nested tree shares matched prefixes, but total cost still depends on attempted
siblings and string comparisons; there is no unconditional O(depth) guarantee.

### 3.2 Plugins and typed handler context

Use `App(Plugins)`, where `Plugins` is a struct of plugin **instances**.
Each plugin type exposes methods with a receiver, including a stateless JSON
instance. Calls go through `ctx.plugins.json.render(res, T, value)`.
Registration therefore controls the capabilities visible to handlers.

Each app defines its handler context and route function type:

```zig
pub const Context = struct {
    plugins: *const Plugins,
    config: *const AppConfig,
    state: *RequestState(Plugins),
};
pub const RouteFn = *const fn (*Context, *Request, *Response) anyerror!void;
```

`AppConfig` contains immutable application configuration. The app owns plugin
instances and configuration for its lifetime. Plugins expose a `State` type
and `initRequest`/`deinitRequest` hooks; stateless plugins use an empty state.
`RequestState(Plugins)` is generated with one state field per plugin instance.
Handlers access, for example, `ctx.state.sessions`. Hooks allocate from the
request allocator, initialize in declaration order, and clean up in reverse
order, including partial initialization failures. Cleanup is infallible and
does not write responses.

Dispatch creates separate state per request and keeps it alive through
middleware and route execution. Response data must be copied into response
storage before that state is destroyed. Session-cookie persistence is an
explicit plugin operation before returning, not a side effect of cleanup.

Instances are immutable during dispatch. Any external shared mutable resource
must provide synchronization; a const pointer alone does not guarantee thread
safety. Phase 1 tests configured plugins and isolated request state using a
small test plugin, before sessions are implemented.

Explicit instance methods avoid generated method injection and namespace
merging. Runtime middleware dispatch is acceptable; generic plugin methods
remain checked at their call sites.

### 3.3 Route wrappers and middleware boundaries

A route wrapper can run before or after the inner route and can skip it.
Middleware is separate because its boundary includes route wrappers **and**
default response finalization, and because its order is configured per app.

Optional `wrapRoute(comptime inner: RouteFn) RouteFn` hooks use the app's typed
context. Compose them in an app factory with a comptime-known base route,
not by passing a runtime `route_fn` field into a comptime parameter.
Configured values remain accessible through `Context`.

The lifecycle is:

1. Transport parses and validates a bounded request.
2. Dispatch initializes per-request plugin state and a buffered response.
3. Middleware enters in registration order.
4. The terminal continuation invokes plugin route wrappers, then the route.
5. A wrapper may provide a custom fallback; otherwise an unhandled response
   becomes 404 before control returns to middleware.
6. Middleware unwinds in reverse order; after a short circuit, dispatch also
   ensures an unhandled response becomes 404.
7. Dispatch destroys request state and returns the independently owned response.
8. Transport writes the response and releases response and request storage.

For wrappers, the first registered wrapper is outermost; composition folds
from the last wrapper to the first. Tests must assert both entry and exit order.

### 3.4 Request, response, and transport ownership

The stable dispatch seam is `dispatch(req: *Request) !Response`.
The caller owns the request and its arena, and keeps them alive until dispatch
returns. Transport also owns the connection and I/O implementation; neither is
stored in the returned response.

Initial requests are fully buffered. The request arena owns copies of the raw
target, decoded segments, ordered query pairs, headers, and body. Dispatch
borrows these. Returned capture slices must not outlive the request.
The response owns its body and header copies using an explicitly supplied
response allocator. That allocator must outlive the response; the caller calls
`res.deinit()` after sending it. It must support concurrent use when serving
concurrent requests, or be isolated per request.

Initial parsing rules:

- Accept origin-form targets for application routes; split query before decoding.
- Preserve the raw target. Split paths on literal slashes, then decode once.
  Reject malformed escapes, decoded slash/backslash, NUL, and dot segments.
- Treat `/` as the root. Preserve trailing and repeated slash segments:
  `/users/` and `/users` are distinct routes.
- Query decoding interprets `+` as space and decodes percent escapes once.
  Preserve order and duplicates; `getAll(key)` returns every value and
  `getOne(key)` reports duplicates rather than silently choosing a value.
- Headers use case-insensitive lookup and retain repeated values. Response
  header insertion rejects invalid names and CR/LF values and copies input.
  Preserve separate `Set-Cookie` fields.

Proposed configurable defaults: 8 KiB request target, 100 headers / 32 KiB total
header bytes, 128 path segments, 256 query pairs, 1 MiB request body, and 1 MiB
buffered response. Enforce limits while reading, including decoded chunked
bodies, rather than after an unbounded allocation. Invalid syntax receives
400; target, header, and body limits map to 414, 431, and 413 respectively.
Segment/query-count violations receive 400. Close rejected connections unless
the adapter can safely establish the next request boundary.

Response helpers replace body/status/content type and set `handled` only on
success. Dispatch cleans up partial responses on errors. Transport generates
a generic 500 without exposing internal errors; failure to allocate that
response closes the connection. A returned response never borrows request
storage. The wire adapter enforces HEAD/bodyless-status semantics and owns
framing headers, preventing conflicting lengths or transfer encodings.

Response streaming requires a later ADR covering a body producer, ownership,
backpressure, cancellation, and errors after headers are sent. It is not
implicitly supported by returning a buffered `Response`. HTTP/1.1 chunked
request decoding remains part of the initial transport contract.

### 3.5 Errors and early returns

Handlers return `anyerror!void`. Writing a response followed by `return`
ends that handler. A helper's return only ends the helper; a caller delegating
a whole branch must use `return helper(...)`. This is an intentional difference
from Roda's nonlocal halt.

Exceptions propagate through wrappers and middleware. A component recovering
an error must clear the partial response before constructing a replacement.
Ordinary success post-processing runs only when `next.call` succeeds; cleanup
uses `defer`. No output reaches the socket until dispatch succeeds.

### 3.6 Middleware continuation and configuration

For each app, define a configured middleware entry and a continuation. `Context`
below refers to that app's context from §3.2:

```zig
pub const Next = struct {
    frame: *anyopaque,
    invoke: *const fn (*anyopaque, *Context, *Request, *Response) anyerror!void,

    pub fn call(self: Next, ctx: *Context, req: *Request, res: *Response) anyerror!void {
        return self.invoke(self.frame, ctx, req, res);
    }
};
pub const Middleware = struct {
    config: *const anyopaque,
    invoke: *const fn (
        *const anyopaque, *Context, *Request, *Response, Next,
    ) anyerror!void,
};
```

The app copies the ordered entry list at initialization; configuration objects
remain caller-owned, immutable, and valid until app shutdown. A private frame
per invocation carries the next index, app, and a shared `called` flag.
Copies of `Next` reference that same flag. Zero calls short-circuit; one call
continues; a second call returns `error.NextAlreadyCalled` before downstream
code executes again.

Continuations must not escape or run concurrently. Zig does not statically
enforce that lifetime: do not claim tests can make escaped pointers safe.
Keep frames private and document this as a caller obligation. Test supported
use, repeated-call rejection, nested ordering, errors, and concurrent requests
with independent frames.

## 4. Delivery sequence and acceptance criteria

All phases are planned. Toolchain setup comes first; the phase names below
retain the earlier roadmap's identifiers where practical.

### Phase A — Toolchain prerequisite

- [x] Select and record an exact Zig version before Phase 0; the package's
      existing minimum of 0.16.0 is not a reproducible pin.
      Pinned: Zig **0.16.0**. See [PLATFORM.md](PLATFORM.md) §1.
- [x] Add CI for formatting, `zig build`, and `zig build test`; document the
      primary supported OS/architecture and allocator/threading assumptions.
      See `.github/workflows/ci.yml` and [PLATFORM.md](PLATFORM.md).
- **Exit:** a clean checkout passes on the selected version and primary target.
      Passed: `zig fmt --check`, `zig build`, `zig build test`, and the demo
      smoke-run all succeed on `x86_64-linux` with the pinned compiler.
      Evidence recorded in [PLATFORM.md](PLATFORM.md) §7.

### Phase 0 — Router core

- [ ] Implement allocation-free consuming matchers and cursor checkpoints.
- [ ] Test method-only matching, terminal matching, slash rules, failed
      match preservation, and explicit branch returns.
- **Exit:** router tests pass without sockets or plugins.

### Phase 0.5 — Request/response contract

- [ ] Implement §3.4 ownership, bounded buffering, query/header semantics,
      copying response helpers, and cleanup.
- [ ] Test malformed encodings, duplicate queries, repeated headers, every
      limit boundary, allocation failures, and request destruction before
      reading a returned response.
- **Exit:** the response remains valid independently of the request with no leaks.

### Phase 1 — Application and first plugin

- [ ] Implement typed handler context, registered JSON instance, and plugin
      request-state initialization and cleanup.
- [ ] Test two differently configured apps, isolated request states, and
      reverse cleanup after initialization or handler failure.
- [ ] Exercise the routes in §5 with status/body assertions.
- **Exit:** JSON goes through the registered instance, with correct root,
      prefix-only, extra-segment, and unsupported-method outcomes.

### Phase 2 — HTTP/1.1 vertical slice

- [ ] Adapt the pinned version's `std.http.Server` to the complete Request.
- [ ] Use bounded concurrent connection tasks/workers, initially capped at 128.
      Each connection processes requests sequentially with independent request
      storage; the accept loop must not wait for a client to finish its request.
- [ ] Start with configurable 10-second header/body-read/write deadlines,
      5-second keep-alive idle timeout, and 100 requests per connection.
      Read deadlines are total operation budgets, not reset by every byte.
- [ ] Implement chunked-body decoding through the transport, limit enforcement,
      protocol-error handling, and safe close/drain rules for connection reuse.
- [ ] On shutdown stop accepting, allow a configurable 10-second grace period,
      then cancel and release remaining connections.
- **Exit:** automated real-socket tests verify the JSON slice and its negative
      cases; a stalled client cannot prevent a second client from completing.
      Record the concrete concurrency/I/O APIs supported by the pinned compiler.

### Phase 2b — HTTP/1.1 hardening

- [ ] Test concurrent keep-alive clients, slow reads/writes, malformed framing,
      oversized chunked bodies, disconnects, and shutdown cleanup.
- [ ] Run a repeatable 60-second load test at 64 connections and an overload
      test above the 128-connection cap; record tool, hardware, errors, and latency.
- **Exit:** no hangs, application crashes, leaked connections, or cap violations;
      allocations/connections return to baseline after clients finish.
- [ ] Decide whether streaming is needed; if so, approve its separate design
      and test producer cleanup, bounded memory, backpressure, and cancellation
      before implementing chunked response streaming.

### Phase 2c — HTTP/2 feasibility

- [ ] Check HTTP/2 server support for the pinned transport and record primary
      documentation or an upstream issue.
- **Exit:** either a separately scoped integration-tested adapter, or an explicit
      HTTP/1.1-only support statement. Do not build a partial protocol parser.

### Phase 2d — Development loop

- [ ] Add a watcher that rebuilds and restarts the demo; do not assume a
      `zig build watch` step exists.
- [ ] Keep the last working process on compilation failure; display diagnostics
      and terminate the previous process cleanly after successful builds.
- **Exit:** measure edit-to-response latency on a documented machine, targeting
      two seconds, and verify failed builds recover on the next valid edit.

### Phase 2e — Middleware

- [ ] Implement §3.6 and test ordering, single-use continuation, short circuits,
      errors, configuration lifetime, and request isolation.
- [ ] Add response timing using a monotonic clock and a copying header helper.
- [ ] Add static-file middleware with a configured document-root handle.
      Reject traversal and symlinks; resolve beneath the root without a
      check-then-open race using supported platform primitives. Fail closed
      where confinement cannot be guaranteed. No directory listing by default.
- **Exit:** static requests skip routing, other responses receive timing headers,
      and tests cover encoded traversal, symlinks, and paths outside the root.

### Phase 3 — Route wrappers

- [ ] Compose wrappers with a comptime base route and typed context.
- [ ] Implement a custom not-found wrapper before the default 404 step.
- **Exit:** entry/unwind ordering, short-circuiting, and error recovery match §3.3.

### Phase 3.5 — Templates

- [ ] Start with embedded templates and interpolation over typed data.
      Template edits use the Phase 2d rebuild loop.
- [ ] Escape HTML text by default. Initially allow interpolation only in text
      nodes; reject attribute, script, style, and URL contexts. Raw trusted HTML
      requires a distinct explicit type/API; untrusted strings cannot opt in
      implicitly.
- [ ] Return clear errors for missing fields or invalid templates.
- **Exit:** render an HTML page and test escaping of special characters,
      hostile input, unsupported interpolation contexts, and rebuild behaviour.
      Runtime loading or multiple engines require a later scoped extension.

### Phase 4 — Optional ergonomics

- [ ] Consider named captures if returned segment values prove insufficient.
- [ ] Evaluate conveniences supported by the pinned compiler while keeping
      explicit registered-plugin access available.
- **Exit:** additions preserve routing semantics and request lifetimes.

### Phase 5 — More plugins

- [ ] Typed segment matchers with overflow/invalid-value tests and no consumption
      on failure.
- [ ] Sessions using §3.2 state: application-supplied secret, authenticated cookie
      format, size limits, expiry, key rotation, secure cookie defaults, and
      tampering tests. Signing does not make cookie contents confidential.
- [ ] CSRF helpers after sessions/cookie policy, with positive and negative tests.
- **Exit:** demonstrate state isolation and cookie finalization on success,
      failure, and middleware short circuits.

### Phase 6 — Write-up

- [ ] Document supported features and measured results, then prepare the
      Roda-to-Zig design talk once the core and wrapper phases pass.

## 5. Consistent design sketches

These snippets omit imports, parsing, initialization, and version-specific
serialization/I/O internals. Helper methods describe required library APIs;
the sketches must become compiling examples during their implementation phases.

### 5.1 Allocation-free matcher and ordered query data

```zig
pub const QueryPair = struct { key: []const u8, value: []const u8 };
pub const Request = struct {
    method: Method,
    segments: []const []const u8,
    cursor: usize = 0,
    query: []const QueryPair,

    pub fn mark(self: *const Request) usize { return self.cursor; }
    pub fn restore(self: *Request, saved: usize) void { self.cursor = saved; }
    pub fn isRoot(self: *const Request) bool { return self.cursor == self.segments.len; }
    pub fn isGet(self: *const Request) bool { return self.method == .get; }

    pub fn onLiteral(self: *Request, literal: []const u8) bool {
        if (self.isRoot()) return false;
        if (!std.mem.eql(u8, self.segments[self.cursor], literal)) return false;
        self.cursor += 1;
        return true;
    }

    pub fn onSegment(self: *Request) ?[]const u8 {
        if (self.isRoot()) return null;
        const value = self.segments[self.cursor];
        self.cursor += 1;
        return value;
    }
};
```

### 5.2 App dispatch and registered plugin access

```zig
pub fn App(comptime Plugins: type) type {
    return struct {
        const Self = @This();
        pub const State = RequestState(Plugins);
        pub const Context = struct {
            plugins: *const Plugins,
            config: *const AppConfig,
            state: *State,
        };
        pub const RouteFn = *const fn (*Context, *Request, *Response) anyerror!void;

        response_allocator: std.mem.Allocator,
        config: AppConfig,
        plugins: Plugins,
        route_fn: RouteFn,

        pub fn dispatch(self: *const Self, req: *Request) !Response {
            // init cleans up successfully initialized fields if a later hook fails.
            var state = try State.init(&self.plugins, req);
            defer state.deinit(&self.plugins);
            var ctx = Context{
                .plugins = &self.plugins,
                .config = &self.config,
                .state = &state,
            };
            var res = Response.init(self.response_allocator);
            errdefer res.deinit();
            // Phase 1 direct call; later phases use the §3.3 middleware lifecycle.
            try self.route_fn(&ctx, req, &res);
            if (!res.handled) try res.text(404, "Not Found");
            return res; // Caller owns response; request is still caller-owned.
        }
    };
}
```

### 5.3 Stateless plugin instance and committed branches

```zig
pub const Json = struct {
    pub const State = struct {};
    pub fn initRequest(_: *const Json, _: *Request) !State { return .{}; }
    pub fn deinitRequest(_: *const Json, _: *State) void {}

    pub fn render(_: *const Json, res: *Response, comptime T: type, value: T) !void {
        // Library helper serializes into response-owned bounded storage.
        // On success it replaces body/status/content type and marks handled.
        try res.replaceJson(200, T, value);
    }
};

const Plugins = struct { json: Json = .{} };
const Demo = App(Plugins);

fn route(ctx: *Demo.Context, req: *Request, res: *Response) !void {
    if (req.isRoot() and req.isGet()) return res.text(200, "hello from zoda");
    if (req.onLiteral("users")) {
        if (req.onSegment()) |id| {
            if (req.isRoot() and req.isGet()) {
                return ctx.plugins.json.render(res, User, .{ .id = id, .name = "unknown" });
            }
        }
        return; // Commit this branch; dispatch supplies 404 if unhandled.
    }
}
```

Required outcomes: `GET /` → 200 text; `GET /users/42` → 200 JSON;
`GET /users`, `GET /users/42/extra`, `GET /users/42/`, and
`POST /users/42` → 404. Returning from a delegated branch must use
`return child(ctx, req, res)`.

### 5.4 Middleware example

```zig
fn timing(
    _: *const anyopaque,
    ctx: *Context,
    req: *Request,
    res: *Response,
    next: Next,
) !void {
    const start = ctx.config.clock.monotonicNow();
    try next.call(ctx, req, res);
    // Copies formatted bytes into response storage; no request allocation escapes.
    try res.setHeaderFmt(
        "X-Response-Time-Ms",
        "{d}",
        .{ctx.config.clock.elapsedMilliseconds(start)},
    );
}
```

The clock is an injected application interface implemented against the pinned
toolchain. Static-file middleware uses its configuration pointer for the
document-root handle and calls `next.call` only when it does not serve the path.

## 6. Verification and remaining decisions

No phase is complete until its implementation, acceptance tests, and pinned
CI run exist. Record exact compiler version and test commands. Documentation
examples must track the implemented public API once code lands.

Remaining decisions have explicit gates:

- ~~Exact compiler version and primary platform~~ — resolved in Phase A:
  Zig 0.16.0 on `x86_64-linux` ([PLATFORM.md](PLATFORM.md)).
- Concrete I/O/concurrency APIs: Phase 2, before the socket slice is accepted.
- Response streaming API: separate ADR in Phase 2b, only if needed.
- HTTP/2 support: Phase 2c feasibility result.
- Named capture convenience: Phase 4, based on demonstrated need.

Plugin state access, ownership, branch termination, middleware ordering, and
buffering are decisions above, not questions deferred until sessions.

## 7. References

- [Roda source](https://github.com/jeremyevans/roda)
- [Roda routing and halt semantics](https://roda.jeremyevans.net/rdoc/classes/Roda/RodaPlugins/Base/RequestMethods.html)
- [Roda plugins](https://github.com/jeremyevans/roda/tree/master/lib/roda/plugins)
- Planned implementation locations: `src/router.zig`, `src/app.zig`,
  `src/transport.zig`, and `src/plugins/`. These are future files, not
  evidence of an existing implementation.
