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
templating, and stateful plugins in its roadmap. HTTP/2 had a separate
feasibility gate; it is not a prerequisite for the first HTTP/1.1 release, and
Zoda is HTTP/1.1-only (§4.2.6).

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

A plugin type is declared before its app exists, so it cannot name that app's
`RouteFn`. The hook is therefore generic over a comptime descriptor that the
app generates for each plugin field (implemented in issue #26, §4.2.12):
`wrapRoute(comptime H: type, comptime inner: H.RouteFn) H.RouteFn`, where
`H.Context` and `H.RouteFn` are the app's own types.

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
request decoding remains part of the initial transport contract. Issue #18
decided responses are **buffered-only** for the first HTTP/1.1 release; the
decision, its evidence, and its reopening conditions are in §4.2.5.

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

The app copies the ordered entry list at initialization (`App.init`);
configuration objects remain caller-owned, immutable, and valid until app
shutdown (`app.deinit()`). A private frame
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
      Evidence recorded in [PLATFORM.md](PLATFORM.md) §7; passing CI runs
      [35214468944](https://github.com/kamalogudah/zoda/actions/runs/35214468944)
      (CI workflow commit) and [35213342849](https://github.com/kamalogudah/zoda/actions/runs/35213342849)
      (original Phase A setup).

### Phase 0 — Router core

- [x] Implement allocation-free consuming matchers and cursor checkpoints.
- [x] Test method-only matching, terminal matching, slash rules, failed
      match preservation, and explicit branch returns.
- **Exit:** router tests pass without sockets or plugins.
      Passed on `x86_64-linux` with the pinned compiler; implementation lives
      in `src/router.zig` (exported from `src/root.zig`) with the §5.1 sketch
      brought up to date (including the terminal `isLiteral`). Evidence
      recorded in §4.0.1.

### §4.0.1 Phase 0 evidence

Recorded for Phase 0 on the primary platform with the pinned compiler
(Zig `0.16.0`, `x86_64-linux`, Ubuntu 24.04):

- Implementation: `src/router.zig` — `Request` with `mark`/`restore`,
  method-only `isGet`, terminal `isRoot`, prefix `onLiteral`, borrowed
  `onSegment` (no allocation, no capture array), and terminal-consuming
  `isLiteral`. Exported from `src/root.zig`; test blocks live beside the code.
- Documented contract: same-request checkpoints, borrowed-capture lifetime,
  restore affecting routing state only, and alternatives preceding output or
  side effects (§3.1, §5.1, `src/router.zig` header docs).
- Test coverage: method-only matching, terminal matching, slash rules
  (trailing/repeated slash segments), failed-match cursor preservation,
  mark/restore per request, nested failures, borrowed-slice identity, and the
  §5.3 committed-branch route outcomes.
- Validation: `zig fmt --check build.zig src`, `zig build`, `zig build test`
  (13/13 tests), and `./zig-out/bin/zoda` smoke-run all pass.
- CI: both jobs ("Format check" and "Build and test") pass on the pinned
  compiler at commit `8f43b69` — run
  [35215723208](https://github.com/kamalogudah/zoda/actions/runs/35215723208).

### §4.0.2 Phase 0 verification (terminal routes and committed branches)

Verification-only pass for terminal routes and committed branch semantics
(§3.1, §3.5, §5.3), on the pinned compiler (`0.16.0`, `x86_64-linux`):

- Socket-free, plugin-free tests in `src/router.zig` cover method-only and
  terminal checks, failed and nested matches, restoration, root, trailing and
  repeated slashes, explicit branch returns, the consumed-`/users` fall-through
  hazard (with and without the branch `return`), and `return child(...)`
  delegation — plus the discarded-result variant that loses the child's
  decision.
- Documented in `src/router.zig` header docs and §3.1/§3.5/§5.3: matchers do
  not return from callers; unsupported methods initially use 404; automatic
  405/Allow and HEAD-to-GET fallback are outside this slice; and cost depends
  on attempted siblings and string comparisons (no O(depth) guarantee).
- Validation: `zig fmt --check build.zig src`, `zig build`, `zig build test`
  (15/15 tests), and `./zig-out/bin/zoda` smoke-run all pass.
- CI: both jobs pass on the pinned compiler at commit `9a706b7` — run
  [35216960748](https://github.com/kamalogudah/zoda/actions/runs/35216960748).

### Phase 0.5 — Request/response contract

- [x] Implement §3.4 owned request storage and strict origin-form
      target/query parsing (issue #5): a `RequestArena` owning the raw
      target, decoded path segments, ordered query pairs, repeated headers,
      and body, with construction propagating allocation failures.
- [x] Implement §3.4 independently owned buffered responses and safe headers
      (issue #6): a `Response` owning body/status/content-type copies and
      repeated header fields through an explicitly supplied allocator, with
      token/CR-LF validation, case-insensitive lookup, bounded storage, and
      `clear` for error recovery.
- [x] Implement §3.4 bounded buffering and error-to-status mappings
      (issue #7): status mappings for malformed or oversized requests and a
      `BoundedAccumulator` for incremental body reads within configured limits.
- [x] Test malformed encodings, duplicate queries, repeated headers, limit
      boundaries, allocation failures, arena-owned copies, and request
      destruction before reading a returned response (issues #5/#6).
- [x] Verification pass for parsing boundaries, allocation-failure
      propagation, and independent response lifetime (issue #8).
- **Exit:** the response remains valid independently of the request with no leaks.

### §4.0.3 Phase 0.5 evidence — issue #5 (owned request storage and parsing)

Recorded on the primary platform with the pinned compiler (Zig `0.16.0`,
`x86_64-linux`, Ubuntu 24.04):

- Implementation: `src/request.zig` — `parseOriginForm` builds a
  `RequestArena` owning the raw target, decoded path segments, ordered query
  pairs, repeated headers, and body (`copyHeaders`/`copyBody`), with `Limits`
  enforcing §3.4 constraints (8 KiB target, 128 path segments, 256 query
  pairs, 100 headers / 32 KiB header bytes, 1 MiB body) and `errdefer`
  cleanup on any parse/construction failure. `Request.query` accessors
  (`getAll`/`getOne`) land on `router.Request` in `src/router.zig`.
- Parsing contract (§3.4, §5.1): origin-form only; the query is split on the
  first raw `?` before decoding; the path splits on literal `/` so root and
  trailing/repeated slashes survive as segments; percent escapes decode
  exactly once; `+` means space in query mode only; decoded `/`, `\`, NUL,
  and dot segments are rejected in paths; decoded NUL is rejected in queries;
  malformed escapes, fragments (`#`), spaces, and control bytes are rejected.
- Test coverage (28/28): root to zero segments, trailing/repeated slash
  segments, query-split-before-decode with escaped-`?` separation, plus-to-
  space, decode-once (`%252F` stays `%2F`), malformed escapes, decoded
  slash/backslash/NUL, raw/decoded dot segments, non-origin-form and invalid
  raw targets, delta-ownership of copies after source mutation, repeated
  case-insensitive header lookup, every limit boundary, allocation-failure
  propagation without leaks (`checkAllAllocationFailures`), and a router
  integration scan with `getAll`/`getOne` duplicate reporting.
- Validation: `zig fmt --check build.zig src`, `zig build`, and `zig build
  test` all pass (28/28 tests via `zig test -Mroot=src/root.zig`).
- CI: both jobs ("Format check" and "Build and test") pass on the pinned
  compiler — see the workflow run for this commit.

### §4.0.4 Phase 0.5 evidence — issue #6 (owned responses and safe headers)

Recorded on the primary platform with the pinned compiler (Zig `0.16.0`,
`x86_64-linux`, Ubuntu 24.04):

- Implementation: `src/response.zig` — `Response` owns its body, status,
  content type, and repeated header fields through an explicitly supplied
  allocator, exposes `deinit`/`clear`, and never borrows request storage,
  plugin state, connection, or I/O. `text`/`replaceJson` replace
  body/status/content type and set `handled` only on success (a rejected
  replacement leaves the prior response intact); `setHeader`/`setHeaderFmt`
  copy validated fields; `getAllHeaders`/`getHeaderOne` read them
  case-insensitively with duplicate reporting. Exported from `src/root.zig`.
- Header safety (§3.4): names validated as RFC 7230 tokens (empty, spaces,
  `:`, control bytes rejected); values reject CR, LF, and NUL to block header
  injection; repeated names append separate fields so multiple `Set-Cookie`
  values survive. `Limits` bounds header count, header bytes, and body bytes.
  Framing headers remain the wire adapter's responsibility.
- Ownership/concurrency documented in the module header and matching
  PLATFORM.md §5/§6: the response allocator must outlive the response and
  support concurrent use (or be isolated per request); a single `Response` is
  not safe for concurrent use.
- Test coverage (11 response tests; 39/39 total): fresh state, text metadata,
  full replacement, failed-replacement preservation, copied headers after
  source mutation, repeated/case-insensitive lookup, invalid-name and
  CR/LF/NUL rejection, header count/byte limits without partial inserts,
  `setHeaderFmt`, `clear`/idempotency, response independence after request
  `deinit`, and allocation-failure propagation without leaks
  (`checkAllAllocationFailures`).
- Validation: `zig fmt --check build.zig src`, `zig build`, and `zig test
  -Mroot=src/root.zig` all pass (39/39 tests).
- CI: both jobs ("Format check" and "Build and test") pass on the pinned
  compiler — see the workflow run for this commit.

### §4.0.5 Phase 0.5 evidence — issue #7 (bounded buffering and protocol error mappings)

Recorded on the primary platform with the pinned compiler (Zig `0.16.0`,
`x86_64-linux`, Ubuntu 24.04):

- Implementation: `src/buffering.zig` — exported from `src/root.zig` as
  `zoda.buffering`.
- Default limits re-exported from `request.Limits` and `response.Limits`
  (`default_request_limits` / `default_response_limits`): 8 KiB target, 100
  headers / 32 KiB header bytes, 128 path segments, 256 query pairs, and 1 MiB
  request body; 100 response headers / 32 KiB header bytes and 1 MiB buffered
  response body.
- Protocol status mappings (`ProtocolStatus`): 400 for invalid syntax and
  segment/query-count violations; 414 for target length; 431 for header count
  or byte limits; 413 for body size; 500 for allocation failures / generic
  error responses. Mapping functions cover `request.ParseError`,
  `request.HeaderStoreError`, `request.BodyStoreError`, `response.HeaderError`,
  and `response.BodyError`.
- `BoundedAccumulator`: incremental byte accumulator bound by `max_bytes`. The
  transport can append decoded chunked-body chunks without unbounded
  intermediate allocations; `append` returns `error.BodyTooLarge` without
  altering state when the limit would be exceeded.
- Connection-close policy documented in the module header: the transport
  closes the connection after sending a 400/414/431/413 response unless it can
  safely establish the next request boundary.
- Test coverage (8 buffering tests; 47/47 total): default-limit values,
  parse/header/body error-to-status mappings, response error mappings,
  accumulator chunking up to the limit, rejection without partial writes,
  simulated decoded chunked-body reads, and allocation-failure propagation
  without leaks (`checkAllAllocationFailures`).
- Validation: `zig fmt --check build.zig src`, `zig build`, and `zig build
  test` all pass (47/47 tests via `zig test -Mroot=src/root.zig`).
- CI: both jobs ("Format check" and "Build and test") pass on the pinned
  compiler — see the workflow run for this commit.

### §4.0.6 Phase 0.5 verification evidence — issue #8 (parsing boundaries, allocation failures, and independent response lifetime)

Recorded on the primary platform with the pinned compiler (Zig `0.16.0`,
`x86_64-linux`, Ubuntu 24.04):

- Scope: verification-only pass over the Phase 0.5 contract in ADR-0001 §3.4
  and the issues that implemented it (#5, #6, #7). No new implementation
  types were added; the existing `RequestArena`, `Response`, and
  `BoundedAccumulator` are exercised against the acceptance criteria.
- Parsing boundary coverage (`src/request.zig`): malformed and double
  percent-encodings (`%`, `%2`, `%2G`, `%252F`); forbidden decoded characters
  (`%2F`, `%5C`, `%00`, raw `\`); dot segments raw and decoded (`/..`,
  `/%2E`); slash preservation (`/`, `/users/`, `//users`, `//`); duplicate
  query pairs with `getAll`/`getOne`; and repeated/case-insensitive header
  lookup.
- Limit boundary coverage (`src/request.zig`, `src/response.zig`): below/at/above
  checks for target length, path-segment count, query-pair count, header count,
  header byte total, and request/response body size. Response header insertion
  rejects invalid names (empty, spaces, `:`, control bytes) and unsafe values
  (`\r`, `\n`, `\x00`). Separate `Set-Cookie` fields are preserved as distinct
  entries.
- Allocation-failure injection: `std.testing.checkAllAllocationFailures`
  exercises every allocation point during request construction
  (`parseOriginForm`, `copyHeaders`, `copyBody`) and response replacement
  (`text`, `replaceJson`, `setHeader`, `setHeaderFmt`, `clear`). A dedicated
  test also asserts that the first induced allocation failure returns
  `error.OutOfMemory` rather than a route "no match" error. Failures
  propagate without leaks and the prior response remains intact.
- Independent response lifetime (`src/response.zig`): tests construct a
  response that borrows request segments/target, destroy the request arena,
  and then read body and headers (including repeated `Set-Cookie` values).
  The response allocator remains alive and the response cleans up without
  leaks.
- Validation:
  - `zig version` → `0.16.0`.
  - `zig fmt --check build.zig src` → clean.
  - `zig build` → success.
  - `zig test -Mroot=src/root.zig` → 52/52 tests pass.
  - `zig build test` → success.
  - `./zig-out/bin/zoda` → exits 0.
- CI: run by `.github/workflows/ci.yml` on the next push; recorded locally on
  the pinned compiler above.

### Phase 1 — Application and first plugin

- [x] Implement typed handler context, registered JSON instance, and plugin
      request-state initialization and cleanup.
- [x] Test two differently configured apps, isolated request states, and
      reverse cleanup after initialization or handler failure.
- [x] Exercise the routes in §5 with status/content-type/body assertions and a
      compiling executable demo.
- **Exit:** JSON goes through the registered instance, with correct root,
      prefix-only, extra-segment, and unsupported-method outcomes.

### §4.0.7 Phase 1 evidence — application dispatch, JSON plugin, and request state

Recorded on the primary platform with the pinned compiler (Zig `0.16.0`,
`x86_64-linux`, Ubuntu 24.04):

- Implementation:
  - `src/app.zig` — `App(Plugins)` with typed `Context`, `RequestState(Plugins)`
    generated from plugin instances, declaration-order initialization, and
    reverse-order cleanup on both success and partial failure.
  - `src/plugins/json.zig` — stateless `Json` plugin instance with empty `State`,
    request hooks, and `render` that serializes values through
    `Response.replaceJson`.
  - `src/main.zig` — compiling route demo using the registered JSON plugin:
    `GET /` returns 200 text, `GET /users/42` returns 200 JSON, and
    `GET /users`, `GET /users/42/extra`, `GET /users/42/`, and `POST /users/42`
    return 404.
  - All modules are exported from `src/root.zig`.
- Contract (ADR-0001 §3.2, §5.2, §5.3): plugins declare `State`,
  `initRequest`, and `deinitRequest`; stateless plugins use an empty state;
  handlers call `ctx.plugins.json.render(res, T, value)` so registration controls
  available capabilities; serialization uses bounded response-owned storage with
  replacement semantics and error propagation; cleanup runs in reverse
  declaration order and is infallible; dispatch returns an independently owned
  response; unhandled routes receive the fallback 404.
- Test coverage: init/deinit order and reverse cleanup on partial initialization
  failure, §5.3 route outcomes with status/content-type/body assertions for
  `GET /`, `GET /users/42`, `GET /users`, `GET /users/42/extra`,
  `GET /users/42/`, and `POST /users/42`, two differently configured apps,
  state cleanup after handler failure, response lifetime after request arena
  destruction, and JSON plugin rendering. Library tests pass 60/60; executable
  tests cover the same route demo.
- Validation:
  - `zig version` → `0.16.0`.
  - `zig fmt --check build.zig src` → clean.
  - `zig build` → success.
  - `zig test -Mroot=src/root.zig` → 60/60 tests pass.
  - `zig build test` → success.
  - `./zig-out/bin/zoda` → exits 0 and prints the route demo output.

### §4.0.8 Phase 1 verification evidence — issue #11 (configured apps, request isolation, and failure cleanup)

Verification-only pass for the Phase 1 contract in ADR-0001 §3.2 and §5.3, on
the pinned compiler (Zig `0.16.0`, `x86_64-linux`). The implementation from
issue #10 (`src/app.zig`, `src/plugins/json.zig`, `src/main.zig`) is exercised
against the acceptance criteria; no new public types were added.

- Configured apps and request isolation (`src/app.zig`):
  - `two differently configured apps are independent` dispatches the same
    route through two apps with different configs and asserts each response
    reflects only its own app's config.
  - New `sequential requests through one app get distinct per-request state`
    uses a small configured stateful test plugin (`Capture`) whose per-request
    state captures the request's `v` query value. Two dispatches through the
    same app each initialize, use, and release their own state: the responses
    carry only their own request's value, both states are released, and no
    state leaks across requests. This stands in for the sessions plugin until
    Phase 5.
- Reverse cleanup and failure paths (`src/app.zig`):
  - Partial initialization failure: `request state initializes in order and
    cleans up in reverse on failure` asserts `initRequest` runs in declaration
    order (`A`, `B`, then failing `G`) and cleanup runs in reverse (`B`, `A`).
  - Handler failure: `state cleanup runs after handler failure` now writes a
    partial response (body plus header) before returning `error.Boom`;
    dispatch must release the response storage as well as deinitializing the
    request state. The response release is verified explicitly:
    `std.testing.allocator` reports a leak if the partial body/header survive
    the unwinding.
- §5.3 route matrix through socket-free dispatch and the registered JSON
  instance (`src/app.zig` `demo app route outcomes`, `src/main.zig` route
  demo): every case asserts status, content type, and body — `GET /` → 200
  `text/plain` "hello from zoda"; `GET /users/42` → 200 `application/json`
  `{"id":"42","name":"unknown"}`; and `GET /users`, `GET /users/42/extra`,
  `GET /users/42/`, `POST /users/42` → 404 `text/plain` "Not Found".
- Validation:
  - `zig version` → `0.16.0`.
  - `zig fmt --check build.zig src` → clean.
  - `zig build` → success.
  - `zig test -Mroot=src/root.zig` → 73/73 library tests pass.
  - `zig build test` → success (76/76 total: 73 library + 3 executable).
  - `./zig-out/bin/zoda` → exits 0 and prints the six route outcomes.
- CI: both jobs ("Format check" and "Build and test") pass on the pinned
  compiler at commit `0780726` — run
  [35260529918](https://github.com/kamalogudah/zoda/actions/runs/35260529918).

### Phase 2 — HTTP/1.1 vertical slice

- [x] Adapt the pinned version's `std.http.Server` to the complete Request.
- [x] Use bounded concurrent connection tasks/workers, initially capped at 128.
      Each connection processes requests sequentially with independent request
      storage; the accept loop must not wait for a client to finish its request.
- [x] Start with configurable 10-second header/body-read/write deadlines,
      5-second keep-alive idle timeout, and 100 requests per connection.
      Read deadlines are total operation budgets, not reset by every byte.
- [x] Implement chunked-body decoding through the transport, limit enforcement,
      protocol-error handling, and safe close/drain rules for connection reuse.
- [x] On shutdown stop accepting, allow a configurable 10-second grace period,
      then force-close, cancel, and release remaining connections.
- **Exit:** automated real-socket tests verify the JSON slice and its negative
      cases; a stalled client cannot prevent a second client from completing.
      Record the concrete concurrency/I/O APIs supported by the pinned compiler.

### §4.2.1 Phase 2 framing evidence — issue #12

The bounded wire adapter is implemented in `src/transport.zig` and exported as
`zoda.transport`. On pinned Zig 0.16.0 it uses `std.http.Server.receiveHead`,
`Request.iterateHeaders`, `std.http.Reader.bodyReader`, and `Request.respond`.
The caller supplies the connection reader/writer, allocator, and application;
`zoda.server` supplies socket acceptance, deadlines, and bounded connection
concurrency. Shutdown grace is implemented in `src/server.zig`; the framing adapter delegates lifecycle ownership to the server runtime.

- A fixed maximum head length bounds wire buffering. Target, header byte/count,
  path-segment, query-pair, and decoded-body limits are checked before dispatch.
- Content-Length plus Transfer-Encoding, unsupported content codings, malformed
  chunks, unsafe headers, and unsupported expectations receive 400 and close.
  Target, header, and body limits receive 414, 431, and 413 respectively.
- Content-Length bodies use the standard-library body reader. Chunked bodies
  are decoded by Zoda's strict RFC 9112 §7.1 decoder (`readChunked`), because
  the pinned `std.http.ChunkParser` is lenient (see §4.2.3); the Zoda
  accumulator bounds decoded bytes. Valid trailers share the request header
  count/byte budget and are appended to the complete request.
- Each keep-alive iteration constructs and destroys a fresh request arena.
  Reuse occurs only after the body reader establishes the next boundary;
  protocol and dispatch failures respond and close instead of attempting a
  risky drain.
- The transport strips application Content-Length/Transfer-Encoding fields and
  lets `Request.respond` emit one Content-Length. It preserves representation
  length while suppressing HEAD bodies and sends an empty representation for
  1xx, 204, 205, and 304 statuses.
- Dispatch completes before application output is written. Dispatch failures
  produce a static generic 500 with no error detail and close; this fallback
  requires no allocation. Response and request storage are released after the
  send attempt.
- In-memory wire tests exercise the real pinned `std.http.Server` parser and
  writer for sequential requests, decoded chunked limits, malformed/conflicting
  framing, status mappings, generic 500 behavior, and response semantics.

Local validation on Zig `0.16.0` (`x86_64-linux-gnu`):

```sh
zig version
zig fmt --check build.zig src
zig build
zig test -Mroot=src/root.zig
zig build test
./zig-out/bin/zoda
```

A passing hosted CI run must be linked before the remaining Phase 2 exit is
marked complete. Real-socket shutdown grace acceptance is covered by the
`a stalled connection does not block a second client` test in `src/server.zig`.

### §4.2.2 Phase 2 bounded runtime evidence — issue #13

The bounded socket runtime is implemented in `src/server.zig` and exported as
`zoda.server`. It uses the pinned Zig 0.16.0 `std.Io.net.Server.accept`,
`std.Io.Group.concurrent`, atomic admission accounting, and independent
per-connection reader/writer buffers. The initial admission cap is 128; excess
accepted sockets are closed immediately, so accepting never waits for a client
request. Each connection is processed sequentially by `transport.serveConnection`
with a fresh request arena per request.

The default budgets are 10 seconds for header reads, body reads, and writes; 5
seconds for keep-alive idle; and 100 requests per connection. The runtime sets
`SO_RCVTIMEO`/`SO_SNDTIMEO` to the remaining absolute monotonic budget before
each operation, so partial reads cannot refresh a total deadline. The pinned
POSIX backend maps `EAGAIN` to the runtime timeout path and all connection/task
resources are released on overload, timeout, cancellation, or normal close.
The supplied allocator is documented as concurrent; `std.heap.smp_allocator` is
the recommended strategy. Shutdown stops accepting on cancellation or listener
closure, waits the configurable 10-second grace period, then closes every
registered socket before canceling the connection group. Connection records use
one-shot close ownership and are removed and destroyed on normal completion,
cancellation, and forced shutdown.

Tests in `src/server.zig` verify the defaults and cap, a total (not per-byte)
header deadline over a real loopback socket, and that a stalled client does not
prevent a second client from receiving a response. Validation on Zig 0.16.0:

```sh
zig version
zig fmt --check build.zig src
zig build
zig test -Mroot=src/root.zig
zig build test
./zig-out/bin/zoda
```

Shutdown is implemented in `src/server.zig`: `Config.shutdown_grace_period`
defaults to 10 seconds; cancellation or listener closure stops acceptance,
allows the grace period, shuts down registered sockets, and cancels the group
(`shutdown(2)` rather than `close(2)` since issue #16; see §4.2.3).
The loopback acceptance test uses a stalled client with a 25 ms configured grace
period and asserts shutdown completes in under one second. Connection records
and all per-connection resources are released through one-shot close and
registry removal on every exit path.

### Phase 2b — HTTP/1.1 hardening

- [x] Test concurrent keep-alive clients, slow reads/writes, malformed framing,
      oversized chunked bodies, disconnects, and shutdown cleanup (issue #16,
      §4.2.3).
- [x] Run a repeatable 60-second load test at 64 connections and an overload
      test above the 128-connection cap; record tool, hardware, errors, and latency.
- **Exit:** no hangs, application crashes, leaked connections, or cap violations;
      allocations/connections return to baseline after clients finish.
- [x] Decide whether streaming is needed; if so, approve its separate design
      and test producer cleanup, bounded memory, backpressure, and cancellation
      before implementing chunked response streaming. Decided buffered-only
      (issue #18, §4.2.5); streaming is deferred, not implemented.

### §4.2.3 Phase 2b adversarial and resource-recovery evidence — issue #16

The suite lives in `src/hardening.zig`. Every scenario runs `server.serve` on
a real loopback listener with a thread-safe counting allocator and
caller-owned `server.Stats`, a new optional `Config.stats` field with `active`,
`peak`, `admitted`, and `rejected` counters. The connection task now releases
its admission slot last, so `active == 0` means every per-connection
allocation has already been freed. After each scenario the harness waits for
`active == 0`, then asserts zero live allocations and bytes. Teardown asserts
that shutdown finishes in under 2 s with no connection or allocation left. Test clients set their
own `SO_RCVTIMEO` (3 s), so a server hang fails a test instead of blocking the
run.

| Scenario | What it asserts |
| --- | --- |
| Concurrent keep-alive | 16 clients × 25 requests alternate Content-Length and chunked bodies. Every echo matches, `admitted == 16` (each client reuses one connection), and `peak ≤ 16`. |
| Pipelining and request cap | Five pipelined requests (Content-Length, chunked with trailer, HEAD, Content-Length, GET) with a cap of 4. Response boundaries hold, the 4th response says `connection: close`, and the 5th request is never read. |
| Malformed or ambiguous framing | 34 payloads: CL+TE in both orders; duplicate, list, signed, non-numeric, and overflowing lengths; unsupported or obfuscated codings; malformed chunks; obs-fold; colonless or NUL-containing fields; bad request lines; absolute-form targets; `Expect`; TE on HTTP/1.0. Each gets 400 and a close. A request pipelined behind each payload is never dispatched or answered. |
| Oversized bodies and heads | Content-Length above the limit; 64 small chunks crossing the limit; one 1 GiB declared chunk that is refused before its data. Target, header count, header bytes, and wire head each map to 414/431. Peak allocator bytes stay below 16 KiB. |
| Slow trickles | One byte per 20 ms into the head, a Content-Length body, and a chunked body. Each connection closes after its total 250 ms budget (measured about 264 ms), not per byte. An idle keep-alive connection closes after its idle budget. |
| Slow reader | A 32 MiB response to a client that never reads is abandoned within the 250 ms write budget. A second client is served meanwhile. |
| Disconnects | FIN and RST (SO_LINGER 0) before the head, mid-head, mid-body, mid-chunk, and after a complete request, including a 1 MiB response. Each returns to baseline, and the server keeps serving. |
| Bounded admission | 128 held connections (the default cap) plus 32 overflow connections, each closed immediately. `rejected == 32`, `peak == 128`, held clients still complete, and capacity is reusable afterwards. |
| Shutdown during active requests | Clients in dispatch, mid-body, mid-head, and keep-alive idle all close within the 50 ms grace. No late success body is sent; a canceled dispatch may receive the generic 500. |

Defects found by the suite and fixed in the same change:

1. **Forced shutdown panicked (`src/server.zig`).** Closing registered
   descriptors raced the owning task's next `setsockopt`. The pinned std
   treats `EBADF` as `unreachable`, and the race also allowed fd reuse.
   Shutdown now calls `shutdown(2)` on each socket, which wakes blocked
   syscalls. Each task unregisters before closing its own descriptor.
2. **An expired write budget panicked (`src/server.zig`).** `SO_SNDTIMEO`
   reports expiry as `EAGAIN`, which the pinned `Io.Threaded.netWrite`
   treats as a programmer bug. POSIX writes now use `sendmsg` directly, with
   `MSG_NOSIGNAL`, `EAGAIN` → `Timeout`, and cancellation checks on `EINTR`.
3. **Lenient chunk parsing (`src/transport.zig`).** The pinned
   `std.http.ChunkParser` reads `g`–`z` as size digits (`zz` = 595, so the
   server waited for a body timeout). It also treats an empty size or `-1`
   as the final chunk and accepts bare LF and extensions without a `;`.
   Zoda now decodes chunked bodies itself. Sizes must be `1*HEXDIG` with
   overflow checks and line endings must be CRLF. Extensions must start with
   `;` and contain no control bytes. A chunk-size line is limited to
   1024 bytes, and a declared size above the remaining body budget gets 413
   before any data is read.
4. **Lenient header fields (`src/transport.zig`).** Lines without `:` were
   accepted as empty fields, and `Content-Length: +1` was accepted. Both now
   get 400. So does Transfer-Encoding on an HTTP/1.0 request (RFC 9112 §6.1).
5. **An interim response before rejection (`src/transport.zig`).** `respond`
   wrote `100 Continue` ahead of the 400 for an `Expect` request, inviting
   the body of a request that was being refused. Rejections now clear
   `expect` first.

In-memory regressions for items 3–5 are in `src/transport.zig`. Validation on
Zig `0.16.0` (`x86_64-linux-gnu`):

```sh
zig version                                          # 0.16.0
zig fmt --check build.zig src
zig build
zig build test                                       # 89/89 (86 library + 3 exe)
zig build test-hardening -Doptimize=ReleaseSafe      # adversarial suite only
./zig-out/bin/zoda
```

For stability, the suite binary ran 10/10 times in Debug and 10/10 in
ReleaseSafe, and 4 copies ran in parallel under CPU contention without
failure. CI runs `zig build test-hardening -Doptimize=ReleaseSafe` as a
separate step. Hosted CI passed in
[run 36151521763](https://github.com/kamalogudah/zoda/actions/runs/36151521763).
The load and overload measurements are recorded in §4.2.4.

### §4.2.4 Phase 2b load and overload measurements — issue #17

The opt-in `zig build test-load -Doptimize=ReleaseSafe --summary all` step runs
two real-loopback measurements from `src/load.zig`, using the same counting
allocator and admission counters as §4.2.3. CI also runs this step. Each client
has a 3-second socket read timeout, so a hang fails the run. The load test uses
64 closed-loop clients, each sending `GET / HTTP/1.1` with `Host: load` and
checking a `200` response containing `ok` before its next request. It raises
only `max_requests_per_connection` above the default to keep the same 64
connections open for the full 60 seconds. A start gate waits until all 64
clients are connected and the server reports 64 active admissions. It records every send-through-body
latency using monotonic time and a bounded logarithmic histogram. Reported
percentiles are inclusive bucket **upper bounds**, not interpolated values.
The overload test holds 128 incomplete request heads, then connects 32 excess
clients and times each server-initiated close. It completes the 128 held
requests and waits for all sockets and counted allocations to drain.

Local measurement on 2026-09-25, repository base `65591be`, pinned Zig
`0.16.0`, native `x86_64-linux-gnu`, `-Doptimize=ReleaseSafe`:

| Environment | Value |
| --- | --- |
| Host | Intel Core i5-8365U, 4 cores / 8 logical CPUs; 15 GiB RAM |
| OS | Ubuntu 24.04.1, Linux `7.0.0-31-generic` x86_64 |
| Tool | Zig's built-in test runner and the Zoda loopback harness; no external load generator |

| Measurement | Result |
| --- | --- |
| 64-connection load | 60,011 ms; 384,921 successful requests; 0 client errors; 6,414 requests/s |
| Load latency, send through response body | Mean 9,052 µs; p50 ≤16,383 µs; p95 ≤32,767 µs; p99 ≤32,767 µs; max 57,620 µs |
| Load server state | Peak/admitted 64/64; rejected 0; peak counted allocator bytes 49,098; active and counted live allocations/bytes returned to 0 |
| 160-connection overload | 128 held/admitted; 32/32 excess rejected; peak 128; 128 held requests completed successfully |
| Overload rejection latency | Mean 350 µs; p50 ≤511 µs; p95 ≤511 µs; max 465 µs |
| Overload recovery | Active connections and counted live allocations/bytes returned to 0; bounded teardown passed |

Reproduce from the repository root:

```sh
zig version                                            # 0.16.0
zig fmt --check build.zig src
zig build test
zig build test-hardening -Doptimize=ReleaseSafe --summary all
zig build test-load -Doptimize=ReleaseSafe --summary all
```

The final local load step passed 2/2 selected tests; the normal test and
ReleaseSafe hardening suites also passed after the test-root split.
There were no observed hangs, application crashes, leaks, or admission-cap
violations. These loopback numbers characterize this host and workload only.
Hosted CI passed on pinned Zig 0.16.0 in
[run 36153064159](https://github.com/kamalogudah/zoda/actions/runs/36153064159),
including the dedicated 60-second step.

### §4.2.5 Phase 2b response-streaming decision — issue #18

**Outcome: buffered responses only.** The first HTTP/1.1 release does not
support response streaming. No streaming ADR is approved, no streaming API
exists, and the roadmap must not count streaming as implemented.

No demonstrated need exists on the current roadmap:

- The JSON slice (Phases 1–2) produces bodies well under the 1 MiB buffered
  limit. The §4.2.4 load run held peak counted allocator bytes at 49,098
  across 64 connections.
- Static files (issue #25) already require "enforce buffered response
  limits". A file above `response.Limits.max_body_bytes` is a configuration
  error, not a reason to stream.
- Templates (issues #28, #29) render typed data into a bounded body. Sessions,
  CSRF, and timing middleware (issues #24, #33, #34) add headers or small
  bodies only.
- No roadmap item calls for server-sent events, long polling, large downloads,
  or proxying.

Buffering also keeps guarantees that streaming would need a new design for.
Dispatch completes before any output (§3.5), so a handler error can still
become a clean generic 500. Every response is framed with one transport-owned
Content-Length. Memory per connection is bounded by `max_body_bytes`.

What this means for the current API:

- `Response` owns a complete body. `text` and `replaceJson` return
  `error.BodyTooLarge` above `max_body_bytes` (default 1 MiB) and leave the
  previous body unchanged. If a handler propagates that error, the transport
  sends the generic 500 and closes.
- Applications cannot choose streaming or chunked framing. The transport
  strips any application `Content-Length` or `Transfer-Encoding` header and
  emits exactly one Content-Length.
- Raising `max_body_bytes` is the supported path for larger bounded bodies.
  It raises per-request memory, so size the allocator for it.

Evidence (existing tests, no code change needed):

| Test | What it proves |
| --- | --- |
| `src/response.zig` "body limit accepts at-limit length and rejects one byte over" | The buffered body is bounded; rejection keeps the prior body. |
| `src/transport.zig` "dispatch failures are generic and response framing is transport owned" | An application `Transfer-Encoding: chunked` or false `Content-Length` never reaches the wire. |
| `src/transport.zig` "HEAD retains representation length and emits no body" | Framing is computed by the transport from the complete body. |
| `src/hardening.zig` slow-reader scenario (§4.2.3) | A 32 MiB buffered response (limit raised for the test) to a non-reading client is abandoned within the write budget without blocking other clients. |

Reopening conditions. Revisit this decision only when one of these is
accepted on the roadmap:

1. An endpoint whose body cannot be bounded in advance, such as server-sent
   events or long polling.
2. Static or generated downloads that must exceed a buffered limit that is
   reasonable per connection.
3. Proxying or relaying an upstream body.

Reopening requires, in order:

1. A separate ADR defining body-producer ownership and cleanup, bounded
   memory, backpressure against slow readers under the write budget,
   cancellation on disconnect and shutdown, and error handling after headers
   are sent (abort the connection, never a second status line).
2. Separately scoped implementation and test issues, linked from the roadmap
   (#38), with acceptance tests for producer cleanup on every exit path,
   bounded memory, backpressure, and cancellation.
3. Only then, implementation. Buffered `Response` keeps its current contract.

No follow-up issues are opened now because no condition is met. The
roadmap records streaming as explicitly deferred.

Validation on pinned Zig `0.16.0` (`x86_64-linux-gnu`). This change only edits
documentation, so the existing suites confirm the cited tests still pass:

```sh
zig version                                          # 0.16.0
zig fmt --check build.zig src
zig build test --summary all                         # 89/89 (86 library + 3 exe)
zig build test-hardening -Doptimize=ReleaseSafe --summary all   # 10/10
```

### Phase 2c — HTTP/2 feasibility

- [x] Check HTTP/2 server support for the pinned transport and record primary
      documentation or an upstream issue. Unsupported upstream; Zoda is
      HTTP/1.1-only (issue #19, §4.2.6).
- **Exit:** either a separately scoped integration-tested adapter, or an explicit
      HTTP/1.1-only support statement. Do not build a partial protocol parser.

### §4.2.6 Phase 2c HTTP/2 feasibility — issue #19

**Outcome: HTTP/1.1 only.** Zoda supports HTTP/1.0 and HTTP/1.1 over cleartext
TCP. It does not support HTTP/2 in any form: not prior-knowledge h2c, not the
h2c `Upgrade`, and not h2 over TLS. No adapter is chosen or scheduled, and
HTTP/2 does not block the first HTTP/1.1 release.

The pinned transport has no HTTP/2 server support. The primary documentation
is the Zig 0.16.0 standard library source (`zig env` → `lib_dir`):

- `std/http.zig`: `pub const Version = enum { @"HTTP/1.0", @"HTTP/1.1" }`.
  There is no HTTP/2 version, frame, stream, or HPACK type in `std.http`.
- `std/http/Server.zig` `Request.Head.parse`: any request-line version other
  than `HTTP/1.0` or `HTTP/1.1` returns `error.HttpHeadersInvalid`. The RFC 9113
  client preface (`PRI * HTTP/2.0`) is therefore a malformed HTTP/1 request.
- `std/crypto/tls.zig` exports only `Client`. With no TLS server, there is no
  ALPN path to negotiate `h2`, which is how browsers reach HTTP/2.

No upstream issue for HTTP/2 server support in `std.http` was found as of
2026-10-24. Third-party Zig HTTP/2 libraries exist but are outside the pinned
transport.

Supporting HTTP/2 would mean writing framing, HPACK, stream multiplexing, and
flow control ourselves, or depending on an external library. The first is the
partial protocol parser this phase forbids. Both would replace, not extend, the
pinned transport, and the buffered-only response contract (§4.2.5) does not
map onto per-stream flow control. Deployments that need HTTP/2 or TLS should
terminate them at a reverse proxy that speaks HTTP/1.1 to Zoda.

Current behavior, pinned by `src/transport.zig` test "HTTP/2 prior knowledge
and h2c upgrade stay HTTP/1.1 only":

- The HTTP/2 client preface is answered with `HTTP/1.1 400`, the connection is
  closed, and the application is never dispatched.
- A request with `Upgrade: h2c` and `HTTP2-Settings` is served as plain
  HTTP/1.1. There is no `101 Switching Protocols` and no `Upgrade` header in
  the response.

Reopening conditions. Revisit only if one of these is accepted on the roadmap:

1. The pinned Zig version ships an HTTP/2 server in `std.http`.
2. A maintained HTTP/2 library is proposed as a dependency in its own ADR.
3. Native TLS termination is added, making ALPN `h2` negotiation possible.

Reopening requires a separately scoped adapter implementation issue and an
integration-test issue, linked from the roadmap (#38) and here, delivered
before any HTTP/2 support is claimed.

Validation on pinned Zig `0.16.0` (`x86_64-linux-gnu`):

```sh
zig version                                          # 0.16.0
zig fmt --check build.zig src
zig build test --summary all                         # 90/90 (87 library + 3 exe)
zig build test-hardening -Doptimize=ReleaseSafe --summary all   # 10/10
```

### Phase 2d — Development loop

- [x] Add a watcher that rebuilds and restarts the demo; do not assume a
      `zig build watch` step exists. (issue #20, §4.2.6)
- [x] Keep the last working process on compilation failure; display diagnostics
      and terminate the previous process cleanly after successful builds.
      (issue #20, §4.2.6)
- [x] **Exit:** measure edit-to-response latency on a documented machine,
      targeting two seconds, and verify failed builds recover on the next valid
      edit. (issue #21, §4.2.7)

### §4.2.6 Phase 2d development-loop evidence — issue #20

`zig build watch [-- <demo args>]` runs `src/watch.zig` (`zoda-watch`). The
step is defined in this repository's `build.zig`. It does not use
`zig build --watch` or any upstream `watch` step. The watcher polls `src/`,
`build.zig`, and `build.zig.zon` every 200 ms and hashes file contents. It
rebuilds after a change has stayed the same for one further poll. Hidden files
and names ending in `~` are ignored. The demo gains `zoda serve [port]`, which
serves the §5.3 routes on `127.0.0.1` (default 8080). Plain `zoda` still runs
the in-memory demo, so the CI smoke-run is unchanged.

Contract as implemented:

- The watcher runs `<zig> build` with the compiler that ran `zig build watch`,
  captures its output, and prints it. On failure the previous process keeps
  running and serving. The next change triggers another build attempt.
- On success the previous process gets SIGTERM and 5 s to exit, then SIGKILL.
  It is always reaped before the new binary starts, so two generations never
  share the port.
- A process that exits on its own is reaped and reported. The next successful
  build starts a new one.
- SIGINT or SIGTERM to the watcher stops the running process the same way
  before the watcher exits.
- Pinned-std findings: `std.process.Child.kill` in Zig 0.16.0 sends SIGTERM,
  not SIGKILL, and then blocks in `wait4`. It never returns for a process that
  ignores SIGTERM, so the watcher sends SIGKILL itself first. Exit is detected
  with `waitid(WEXITED|WNOHANG|WNOWAIT)`, which does not consume the status.
  The default `Io.File.Writer.init` writes stdout positionally. When the
  output is redirected to a file, the watcher and the demo share the
  descriptor and overwrite each other's lines, so both now use
  `initStreaming`.

Tests in `src/watch.zig` drive the watcher with `sh` build and run scripts
in a temporary directory, and `zig build test` runs them, which puts them in CI:

| Test | Shows |
|---|---|
| repeated edits rebuild and restart | Three edits produce three restarts. Each previous generation handles SIGTERM and has been reaped (`kill(pid, 0)` → `ESRCH`) before its replacement runs. |
| failed build keeps the last working process | Diagnostics are displayed. The same PID stays alive, a repeat poll does nothing, and the next valid edit replaces the process. |
| initial build failure starts nothing | No process starts until a valid edit arrives. |
| deinit stops the process | A process that ignores SIGTERM is killed after the grace period and reaped, and a second stop does nothing. |
| a process that exits on its own | The exit is reaped and reported, and the next build starts a new process. |
| ignored names | Swap and backup files do not change the fingerprint. Creating a missing watched path does change it. |

End-to-end measurement with `zig build watch -- serve 18080` on a scratch copy
of the repository. Each edit changed the `GET /` body in `src/main.zig`, and
latency was timed from the `sed -i` write until `curl` first returned the new
body (polled every 10 ms). Machine: Intel Core i5-8365U (4 cores / 8 threads),
15 GiB RAM, Ubuntu 24.04.4 LTS, Linux 7.0.0-38-generic, Zig 0.16.0, Debug
build:

| Step | Result |
|---|---|
| Cold start (first build + start) | 5,282 ms |
| Edit v1 / v2 / v3 → new response | 1,519 / 1,752 / 1,710 ms |
| Syntax error edit | Diagnostics printed. The old PID kept serving the v3 body. |
| Fixing edit → new response | 1,824 ms |
| Ctrl-C (SIGINT to the process group) | Watcher and demo gone, no leftover processes |
| SIGTERM to the watcher alone | Demo stopped and reaped, no leftover processes |

Every edit-to-response time is under the 2 s target. The time includes the
400 ms poll-and-settle window, and the `zig build` step took 1.1–1.4 s.

Validation on pinned Zig `0.16.0` (`x86_64-linux-gnu`):

```sh
zig version                                          # 0.16.0
zig fmt --check build.zig src
zig build
zig build test --summary all                         # 96/96 (87 library + 3 exe + 6 watcher), 3 consecutive runs
zig build test-hardening -Doptimize=ReleaseSafe --summary all   # 10/10
./zig-out/bin/zoda
zig build watch                                      # manual end-to-end check above
```

Hosted CI passed on Zig 0.16.0 for the watcher commit `2c70385` in
[run 40121173731](https://github.com/kamalogudah/zoda/actions/runs/40121173731)
and for the `main` merge head `3938940` in
[run 40121239653](https://github.com/kamalogudah/zoda/actions/runs/40121239653).
The watcher tests run inside CI's `zig build test` step.

### §4.2.7 Phase 2d recovery and latency evidence — issue #21

`zig build test-devloop` runs `src/devloop.zig`. It copies `src/`,
`build.zig`, and `build.zig.zon` into a temporary directory and runs the
`watch.Watcher` from §4.2.6 there, with the real build command (`<zig> build`,
the compiler that ran `zig build test-devloop`) and the real demo
(`zig-out/bin/zoda serve <free port>`). Each edit rewrites the `GET /` body in
the copied `src/main.zig`, so the repository itself is never changed. The
watcher runs in its own task with its default 200 ms poll, as under
`zig build watch`. CI runs the step on every push and pull request.

Checks, in order, all asserted:

| Step | Asserted |
|---|---|
| Cold start | `GET /` returns `hello from zoda` from the first build. |
| 5 valid edits | Each new body is served. 6 starts and 5 stops are logged, so every previous process was stopped and reaped before its replacement. |
| Compile-failure edit | An undeclared identifier is added. The watcher logs `build failed; keeping previous process`, and the compiler diagnostics (`error:` and the identifier) appear in its output. Three later `GET /` requests still return the last good body, and no new process starts. |
| Next valid edit | The new body is served. Starts reach 7 and stops reach 6. |
| Watcher stop | The last demo PID is gone (`kill(pid, 0)` → `ESRCH`), and the port refuses connections. |

The test's only Watcher change is a new `Config.run_stdout` field. The test
sets it to `.ignore` because the test runner's stdout carries the build-system
protocol. `zig build watch` keeps the default `.inherit`.

Methodology. Latency runs from the moment the edited file is written until
`GET /` first returns the new body. The test sends a new
`Connection: close` request every 10 ms, and refused or incomplete
connections during a restart count as "not yet". The time includes the
watcher's poll-and-settle window (one poll to detect the change and one to
confirm it, 200–400 ms), `zig build`, stopping the old process, and starting
the new one. The watcher's own `started pid … after N ms` lines give the
build-and-start part separately. The demo builds in Debug, which is the
`zig build` default the watcher uses. The 2 s target is printed with each
result. It is not asserted, because hosted runner speed is not measured here.

Machine: Intel Core i5-8365U (4 cores / 8 threads), 15 GiB RAM, Ubuntu 24.04.4
LTS, Linux 7.0.0-38-generic, Zig 0.16.0 (`x86_64-linux-gnu`). Three
consecutive local runs, with a warm global cache and a fresh local cache in
each copy:

| Run | Cold start | Edits 1–5 → new response | Failure reported | Recovery → new response |
|---|---|---|---|---|
| 1 | 4,511 ms | 1,603 / 1,573 / 1,529 / 1,390 / 1,655 ms | 1,393 ms | 1,643 ms |
| 2 | 3,926 ms | 1,433 / 1,501 / 1,518 / 1,580 / 1,648 ms | 1,400 ms | 1,510 ms |
| 3 | 4,229 ms | 1,647 / 1,534 / 1,500 / 1,429 / 1,890 ms | 1,515 ms | 1,669 ms |

Across the 18 timed edits (15 valid edits and 3 recoveries), latency ranged
from 1,390 to 1,890 ms. The median valid edit took 1,534 ms. All 18 met the
2 s target on this machine. Build and start after an edit took 992–1,466 ms.
These numbers cover only this machine. The value printed by a CI run reflects
that runner and is not a claim for other hardware.

Validation on pinned Zig `0.16.0` (`x86_64-linux-gnu`):

```sh
zig version                                          # 0.16.0
zig fmt --check build.zig src
zig build
zig build test --summary all                         # 96/96
zig build test-hardening -Doptimize=ReleaseSafe --summary all   # 10/10
zig build test-devloop --summary all                 # 1/1, 3 consecutive runs, no leftover processes
```

### Phase 2e — Middleware

- [x] Implement §3.6 and test ordering, single-use continuation, short circuits,
      errors, configuration lifetime, and request isolation. (issue #22, §4.2.8;
      verified in issue #23, §4.2.9)
- [x] Add response timing using a monotonic clock and a copying header helper.
      (issue #24, §4.2.10)
- [x] Add static-file middleware with a configured document-root handle.
      Reject traversal and symlinks; resolve beneath the root without a
      check-then-open race using supported platform primitives. Fail closed
      where confinement cannot be guaranteed. No directory listing by default.
      (issue #25, §4.2.11)
- **Exit:** static requests skip routing, other responses receive timing headers,
      and tests cover encoded traversal, symlinks, and paths outside the root.

### §4.2.8 Phase 2e middleware and single-use continuation evidence — issue #22

Implements the contract in §3.3, §3.5, and §3.6 in `src/app.zig`. Route
wrappers remain Phase 3. Response timing and static files are the remaining
Phase 2e items.

API as implemented, per `App(Plugins)`:

- `App.Next { frame, invoke }` with `call(ctx, req, res)` and
  `App.Middleware { config: *const anyopaque, invoke }`, both over the app's
  typed `Context`, exactly as in §3.6. `zoda.app.NextError` declares
  `error.NextAlreadyCalled`.
- `App.init(allocator, .{ .response_allocator, .config, .plugins, .route_fn,
  .middleware })` copies the ordered entry slice into `allocator`-owned
  storage. The caller may reuse its array afterwards. Configuration objects are
  **not** copied: they stay caller-owned and immutable, and must stay valid
  until `app.deinit()`, which frees the copied list. Apps built as struct
  literals still work and have no middleware.
- Each middleware invocation gets a private stack `Frame { app, next_index,
  called }`. `Next.frame` points at it, so every copy of a `Next` shares the
  same `called` flag. The first call sets the flag before running downstream
  code. Any later call returns `error.NextAlreadyCalled` and does not run
  downstream middleware or the route again. Zero calls short-circuit.
- Entries run in registration order and unwind in reverse. The terminal
  continuation runs the route and then the default 404, so middleware sees and
  can decorate the 404 while unwinding. `dispatch` applies the 404 again after
  the chain returns, which covers short circuits that write nothing.
- Errors propagate unchanged through the chain to `dispatch`, which releases
  the partial response. Middleware runs success post-processing after
  `try next.call(...)` and puts cleanup in `defer`. A middleware that recovers
  an error clears the response before it writes a replacement (§3.5).
- Caller obligations, documented on `Next` but not enforced by Zig: a `Next` is
  valid only while the invocation that received it runs. It must not escape
  (be stored, returned, or called later) and must not run concurrently. No test
  claims to make an escaped continuation safe.

Tests in `src/app.zig`:

| Test | Shows |
|---|---|
| middleware enters in registration order and unwinds in reverse | Three entries and the route log `abcRCBA`. |
| app copies the entry list but borrows caller-owned configuration | Overwriting the caller's array after `init` does not change the order. The stored `config` pointer is the caller's object. |
| app without middleware dispatches straight to the route | 200 and default 404 with an empty chain. |
| short circuit skips downstream middleware and the route | A 401 short circuit runs no inner entry or route (`axA`). A short circuit that writes nothing gets dispatch's fallback 404. |
| a second next call is rejected before downstream runs again | Calling the same `Next` or a copy a second time returns `error.NextAlreadyCalled`, and downstream ran only once (`cRC`). Left unhandled, the error propagates out of `dispatch`. |
| errors propagate and skip success post-processing but run deferred cleanup | On success the header and post-processing run (`aRpdA`). When the route fails, `error.Boom` propagates, post-processing is skipped, `defer` cleanup runs in reverse (`aRdA`), and the testing allocator finds no leaks. |
| middleware recovering an error replaces the partial response | The partial body and header are cleared and replaced with a 503. |
| terminal continuation applies the default 404 before middleware unwinds | Middleware observes the 404 after `next.call` and adds a header to it. |
| middleware shares the per-request context and plugin state | Middleware reads `ctx.config` and `ctx.state` for the same request as the route. |
| concurrent requests use independent continuation frames | 4 threads × 500 dispatches through one app with two guard entries. Each first call succeeds and each second call is rejected, with no cross-request rejection, and every response echoes its own query value. |

Validation on pinned Zig `0.16.0` (`x86_64-linux-gnu`):

```sh
zig version                                          # 0.16.0
zig fmt --check build.zig src
zig build
zig build test --summary all                         # 106/106 (97 library + 3 exe + 6 watcher), 3 consecutive runs
zig build test -Doptimize=ReleaseSafe --summary all  # 106/106
zig build test-hardening -Doptimize=ReleaseSafe --summary all   # 10/10
./zig-out/bin/zoda
```

Hosted CI: pending the first push of this change.

### §4.2.9 Phase 2e middleware verification evidence — issue #23

Verification-only pass for the contract in §3.3, §3.5, and §3.6 against the
issue #22 implementation in `src/app.zig`. No public API changed. Ten tests
were added beside the §4.2.8 tests. Each acceptance criterion maps to tests
as follows (tests from §4.2.8 are marked †):

| Criterion | Tests in `src/app.zig` | Asserted |
|---|---|---|
| Enter/unwind order, nested chains | enters in registration order †; nested short circuits unwind every outer entry and leave the 404 to dispatch | `abcRCBA`; in a five-entry chain the third entry short-circuits, the fourth entry and the route never run, and the outer entries unwind (`abxBA`). |
| Handled and unhandled short circuits | short circuit skips downstream †; nested short circuits … | A 401 short circuit is what outer entries see. When a short circuit writes nothing, outer entries see an *unhandled* response (the terminal continuation never ran) and `dispatch` applies the 404 afterwards. |
| Copied-`Next` rejection, one downstream invocation | a second next call is rejected † ; repeated next in a nested entry runs downstream once and leaves outer frames intact | A copy taken *after* the first call, the original, and the copy again all return `error.NextAlreadyCalled`. Downstream entries and the route run once whether the repeating entry is in the middle (`acdRDC!A`) or innermost (`aR!A`), and the outer entry's own continuation is unaffected. |
| Errors | errors propagate … deferred cleanup †; middleware errors before or after next propagate and release the response | An error raised before `next` skips the route (`adA`). An error raised after the route wrote a body propagates (`aRdA`). The testing allocator finds no leak of either partial response. |
| Recovery after clearing | recovering an error replaces the partial response †; outer recovery clears an inner failure before replacing or falling back to 404 | An outer entry recovers an inner *middleware* failure: the inner header and route body are cleared, and post-processing continues. With a replacement the result is 503. Cleared without one, dispatch's 404 applies. |
| Default 404 visibility | terminal continuation applies the default 404 †; default 404 is visible to every nested entry while unwinding | Both the innermost and outermost entries observe 404 after a route miss. |
| Configured middleware | configured middleware reads its own entry configuration | The README `requireKey` example compiles and runs. The same function in two apps with different keys accepts and rejects independently, and decorates an authenticated 404. |
| Configuration lifetimes | app copies the entry list but borrows configuration †; supported configuration lifetimes; init failure copies nothing and leaks nothing | Static configuration; heap configuration freed after `app.deinit()`; one configuration object shared by two apps; a caller entry array poisoned right after `init`. `init` on an allocator that fails returns `error.OutOfMemory` with zero bytes allocated. |
| Independent frames (deterministic) | a request dispatched from inside middleware gets its own frames | While the outer request holds an unused `next`, a second request runs the full chain through the same app (`[aRA]aRA`). The outer continuation still runs once and rejects a second call. |
| Concurrent frames and state | concurrent requests use independent continuation frames †; concurrent requests keep frames, plugin state, and outcomes independent | 4 threads × 400 requests through a four-entry chain with a stateful plugin and one shared configuration object. Each entry checks before and after `next` that `ctx.state` belongs to its own request. Outcomes are mixed (200 echo, 403 short circuit, 503 recovered error, 404 miss) and each matches its request. Plugin state inits and deinits both equal 1,600, and a thread-safe `DebugAllocator` reports no leaks. |

Mutation check (seeded locally and reverted, not committed). Each test suite
was rerun with a deliberate defect:

| Defect | Failing tests |
|---|---|
| `invokeNext` ignores `called` | both repeated-call tests and both concurrent tests |
| Terminal continuation skips the default 404 | both 404-visibility tests |
| Frames stored in static storage shared across requests | the re-entrant frame test (3/3 runs) and the † concurrent frame test |

The new concurrent test did not detect shared frames: its allocator mutex
serializes most of each request, so thread interleaving is probabilistic. The
deterministic re-entrant test was added for that reason. The new concurrent
test's value is plugin-state and outcome isolation under real threads.

Caller obligations, as documented on `Next`, `Middleware`, and in the README:

- Configuration objects are caller-owned, immutable, and valid until
  `app.deinit()`. The entry array is copied by `init`.
- A `Next` is valid only during the invocation that received it. It must not
  be stored, returned, called after that invocation returns, or called from
  another thread.
- Zig does not enforce the second obligation. None of these tests make an
  escaped continuation safe, and none claim to. They exercise supported use
  only.

Validation on pinned Zig `0.16.0` (`x86_64-linux-gnu`):

```sh
zig version                                          # 0.16.0
zig fmt --check build.zig src
zig build
zig build test --summary all                         # 116/116 (107 library + 3 exe + 6 watcher), 3 consecutive runs
zig build test -Doptimize=ReleaseSafe --summary all  # 116/116
zig build test-hardening -Doptimize=ReleaseSafe --summary all   # 10/10
./zig-out/bin/zoda
```

Hosted CI: pending the first push of this change.

### §4.2.10 Phase 2e response-timing evidence — issue #24

Implements the timing item of Phase 2e and the §5.4 sketch in `src/timing.zig`,
exported as `zoda.timing`. Static-file middleware is the remaining Phase 2e item.

API as implemented:

- `zoda.timing.Clock` (also `zoda.app.Clock`) is a union of `.io: std.Io` and
  `.source: Clock.Source { context, now }`. `Clock.monotonic(io)` reads
  `Io.Clock.awake` (`CLOCK_MONOTONIC` on Linux) on the pinned toolchain.
  `monotonicNow()` returns an `Io.Timestamp`. `elapsedMilliseconds(start)`
  returns whole milliseconds, truncated, and clamps a backwards reading to 0.
- The clock is injected per app as `AppConfig.clock: ?Clock = null`, so
  middleware reads `ctx.config.clock` as in §5.4. Existing `AppConfig`
  literals compile unchanged.
- `zoda.timing.middleware(App)` returns an `App.Middleware` without its own
  configuration. It reads the clock before `next.call` and, only if that
  succeeds, adds `X-Response-Time-Ms` with `Response.setHeaderFmt`. That
  helper formats into transient storage and copies the value into
  response-owned header storage, so the value does not borrow the request,
  the frame, or plugin state. With no clock configured, the entry returns
  `error.ClockNotConfigured` before any downstream code runs.
- Register it first so it is outermost. Routed responses, short circuits, and
  the terminal continuation's default 404 all receive the header. When a short
  circuit writes nothing, dispatch's fallback 404 keeps the header, because
  `Response.text` replaces only the body, status, and content type.
- The demo server (`zoda serve`, `zig build watch`) registers the entry with
  `Clock.monotonic(io)`. README "Response timing" documents the usage.

Tests in `src/timing.zig`, using a `ManualClock` source that only the test
advances (the route advances it by 42 ms):

| Test | Shows |
|---|---|
| elapsedMilliseconds truncates and clamps a backwards reading to zero | 7.999999 ms → `7`. A reading earlier than `start` → `0`. |
| monotonic clock reads the pinned toolchain clock and never goes backwards | A reading falls between two direct `Io.Clock.awake` reads. 1,000 consecutive reads never decrease. A 5 ms sleep measures ≥ 5. |
| ordinary response gets the injected clock's elapsed milliseconds | 200 `root` with `X-Response-Time-Ms: 42`. The clock is read twice, once before `next` and once after. |
| fallback 404 from the terminal continuation is timed | 404 `Not Found` with `42`. |
| empty short circuit keeps the header through dispatch's fallback 404 | An inner entry that writes nothing → dispatch's 404 with `0`. A 401 short circuit → 401 with `0`. |
| errors propagate without a timing header and leak nothing | `error.Boom` propagates out of `dispatch`. The clock is read only once, and the testing allocator finds no leak. |
| an inner recovery is a success and is timed | An inner entry clears the failed response and writes 503. `next.call` succeeded, so the header is `42`. |
| a header-limit failure after next propagates and releases the response | `error.TooManyHeaders` from the header helper propagates. No leak. |
| missing clock fails the request before downstream runs | `error.ClockNotConfigured`. The route never ran. |
| timing value is response-owned and outlives the request and the frame | The request arena is freed before the header is read. The value is `42` and lives in the response's own header storage. |
| real monotonic clock times requests through the default 404 and a 200 | With `Clock.monotonic(std.testing.io)`, both responses carry a header that parses as an unsigned integer. |

Mutation check (seeded locally and reverted, not committed):

| Defect | Failing tests |
|---|---|
| Header also added when `next.call` fails | the error-propagation and header-limit tests |
| No clamp on a backwards reading | the truncate/clamp test |
| Header only on status 200 | the fallback 404, empty short circuit, inner recovery, and real-clock tests |
| `Io.Clock.real` instead of `Io.Clock.awake` | the monotonic-clock test (after the bracketing assertion was added; the first version missed this defect) |

Manual check: `./zig-out/bin/zoda serve 9137`, then `curl -i` on `/` and
`/nope` returned 200 and 404, both with `X-Response-Time-Ms: 0`.

Validation on pinned Zig `0.16.0` (`x86_64-linux-gnu`):

```sh
zig version                                          # 0.16.0
zig fmt --check build.zig src
zig build
zig build test --summary all                         # 127/127 (118 library + 3 exe + 6 watcher), 3 consecutive runs
zig build test -Doptimize=ReleaseSafe --summary all  # 127/127
zig build test-hardening -Doptimize=ReleaseSafe --summary all   # 10/10
./zig-out/bin/zoda
```

Hosted CI: pending the first push of this change.

### §4.2.11 Phase 2e static-file evidence — issue #25

Implements the static-file item of Phase 2e and the §5.4 note in
`src/static.zig`, exported as `zoda.static`. With it, every Phase 2e item and
the exit criterion are met.

API as implemented:

- `zoda.static.Config { root: Io.Dir, prefix, allow_dotfiles = false,
  max_file_bytes }`. The root is a caller-owned directory handle. Like every
  middleware configuration, the struct is borrowed, immutable, and must stay
  valid until `app.deinit()`. The middleware never closes the handle.
- `zoda.static.middleware(App, &config)` returns an `App.Middleware`. For
  `GET` and `HEAD`, when the remaining segments start with `prefix` and name a
  regular file, it writes a 200 and returns without calling `next`, so the
  route never runs. Every other request calls `next.call` with the request and
  cursor unchanged.
- A hit reads the file into one response-owned buffer and hands it to the new
  `Response.replaceOwnedBody` (no second copy). The content type comes from a
  fixed extension table, defaulting to `application/octet-stream`, and
  `X-Content-Type-Options: nosniff` is added.
- `openBeneath(root, path)` is the confinement primitive. `checkSupport(root)`
  runs the same probe at startup. The demo server takes an optional third
  argument, `zoda serve [port] [docroot]`, and calls `checkSupport` before
  listening.

Confinement:

- Files are opened with Linux `openat2(2)` (raw syscall; the pinned std has no
  wrapper) relative to the root handle, with `RESOLVE_BENEATH |
  RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS` and `O_RDONLY | O_CLOEXEC |
  O_NOFOLLOW | O_NONBLOCK | O_NOCTTY`. The kernel resolves the whole path in
  the call that opens it: `..` escapes and absolute paths fail with `EXDEV`,
  and a symlink in any component, including the last, fails with `ELOOP`. No
  path is checked before the open, so nothing can change between a check and
  the open. The file type and size come from `statx` on the opened descriptor.
- Before the kernel sees a path, the middleware rejects empty segments, `.`,
  `..`, segments containing `/`, `\`, or NUL, and (by default) segments
  starting with `.`. The request parser already rejects most of these
  (§3.4); the middleware repeats the check so it does not rely on the parser.
  Confinement does not rely on either check; the kernel enforces it.
- Fail closed: `ENOSYS`, `EPERM`, `EINVAL`, `E2BIG`, and `EOPNOTSUPP` from
  `openat2` become `error.ConfinementUnavailable`, and every non-Linux target
  returns that error without opening anything. There is no unconfined
  fallback. The pinned std's `Io.Dir.OpenOptions.resolve_beneath` was
  considered and rejected: on Linux it only sets `posix.O.RESOLVE_BENEATH`
  when that field exists, which it does not, so it is silently ignored.
- Directory listing is not implemented. Directories, FIFOs, devices, and
  sockets are misses. `O_NONBLOCK` keeps a FIFO from blocking the open.
- Buffered limits: a file larger than `min(max_file_bytes,
  res.limits.max_body_bytes)` fails with `error.BodyTooLarge` before any body
  is allocated. At most the `statx` size is read, so a file that grows during
  the read cannot raise memory use. A file that shrinks is served at its
  shorter length.
- Not covered: a hard link inside the root to a file outside it is an
  ordinary file and is served. Creating one needs write access to the root;
  deployments should keep the root read-only to the server.

Platform support is recorded in [PLATFORM.md](PLATFORM.md) §2: Linux 5.6+
(`x86_64-linux-gnu` primary, CI on `ubuntu-latest`). Other targets fail closed.

Tests in `src/static.zig` (a temporary tree with files inside and outside the
root, symlinks, dotfiles, and a FIFO):

| Test | Shows |
|---|---|
| confinement is available on the CI platform | `checkSupport` passes on the root and returns `error.NotDir` for a file handle. |
| ordinary hits are served with content types and skip routing | `.txt`, `.html`, `.css`, `.bin`, empty, nested `.json`, and a percent-encoded name are served with the right content type and `nosniff`. The route never runs. `HEAD` gets the representation. |
| misses call next with the request unchanged | Missing files, a file used as a directory, paths outside the prefix, the bare prefix, empty and trailing segments, and `POST`/`PUT`/`DELETE`/`OPTIONS` reach the route with the cursor at 0 and end in 404. The route still answers its own path. |
| directories are never listed or served | `/`, `/sub`, `/sub/` reach the route and 404. |
| symlinks are rejected in every component, inside or outside the root | Final-component links to a file inside, outside, and an absolute target, and directory-component links outside and inside, are all misses. `openBeneath` reports `.symlink` for each, so the kernel refused them. |
| encoded traversal never reaches the file system | `..`, `%2e%2e`, `%2E%2E`, `.%2e`, nested `%2e%2e`, `..%2F`, `%2e%2e%2f`, `..%5C`, raw `\`, `%00`, and `%2F` are rejected by the parser (`DotSegment` / `ForbiddenPathCharacter`). `%252e%252e` decodes once to a literal name and misses. Hand-built segments that bypass the parser (`..`, `../x`, `sub/../../x`, `/etc/passwd`, `\`, NUL, `.`, empty) are rejected by the middleware. |
| paths outside the root are refused by the kernel | Raw paths given straight to `openBeneath` (`../secret.txt`, `sub/../../secret.txt`, `/etc/passwd`, …) return `.escape`. `sub/../hello.txt`, which stays beneath the root, opens. |
| dotfiles are hidden by default and opt-in | `.env` and `.hidden/a.txt` miss by default; with `allow_dotfiles` the latter is served. |
| special files are not opened or served | A FIFO with no writer is a miss and does not block. |
| buffered limits: at-limit files are served and larger files fail | With `max_file_bytes = 5`, a 5-byte file is served and a 9-byte file fails with `error.BodyTooLarge`. With no configuration, a file of exactly 1 MiB is served and 1 MiB + 1 fails. |
| descriptors and buffers are released on hits, misses, and errors | 200 rounds of hits, misses, directories, symlinks, a FIFO, and `BodyTooLarge` leave the lowest free descriptor unchanged. The testing allocator finds no leaked buffers. |
| a concurrent symlink swap never redirects an open outside the root | A thread atomically exchanges (`renameat2(RENAME_EXCHANGE)`) a real directory and a symlink to an outside directory holding a same-named secret file, while at least 2,000 requests alternate between both names. The secret is never served, the real directory is served in between, and swaps did happen. |
| unavailable or unenforceable confinement fails closed | The errno mapping turns `ENOSYS`, `EPERM`, `EINVAL`, `E2BIG`, and `EOPNOTSUPP` into `error.ConfinementUnavailable`. |
| content types fall back to octet-stream | Extension matching ignores case; unknown and missing extensions get `application/octet-stream`. |
| configured ordering decides which responses are timed | With `[static, timing]`, a static hit has no `X-Response-Time-Ms` and skips the route, while a routed 200 and the default 404 both get it. With `[timing, static]`, the static hit is timed too. |

`src/response.zig` adds "replaceOwnedBody takes ownership only on success":
an oversized body or a content type with CR/LF is rejected and leaves the
previous response and the caller's ownership unchanged; on success the
response owns the exact buffer.

Mutation check (seeded locally and reverted, not committed):

| Defect | Failing tests |
|---|---|
| `RESOLVE_NO_SYMLINKS` dropped | the symlink test |
| `RESOLVE_BENEATH` dropped | the kernel-refusal test |
| A check-then-open implementation: `statx(AT_SYMLINK_NOFOLLOW)` on each component, refusing `..` and symlinks, then a plain `openat` | the concurrent-swap test (3/3 runs) and the kernel-refusal test. Every static symlink test still passed, which is why the race test exists. |
| Descriptor never closed | the cleanup test |
| Segment validation skipped | the dotfile and encoded-traversal tests. The kernel still refused every escape. |

Manual check: `./zig-out/bin/zoda serve 9139 <dir>` with `site.css` and a
`leak.txt -> ../secret.txt` symlink. `curl -i` returned `/site.css` as 200
`text/css; charset=utf-8` with `nosniff` and no timing header. `/`, `/users/42`,
and `/nope` returned 200, 200, and 404 with `X-Response-Time-Ms`. `/leak.txt`
returned 404. With `curl --path-as-is`, `/../secret.txt`, `/%2e%2e/secret.txt`,
and `/%2E%2E%2Fsecret.txt` returned 400.

Validation on pinned Zig `0.16.0` (`x86_64-linux-gnu`, kernel 7.0.0-38-generic):

```sh
zig version                                          # 0.16.0
zig fmt --check build.zig src
zig build
zig build test --summary all                         # 143/143 (134 library + 3 exe + 6 watcher), 3 consecutive runs
zig build test -Doptimize=ReleaseSafe --summary all  # 143/143
zig build test-hardening -Doptimize=ReleaseSafe --summary all   # 10/10
zig build test-devloop --summary all                 # 1/1, no leftover processes
./zig-out/bin/zoda
```

Hosted CI: pending the first push of this change.

### §4.2.12 Phase 3 route-wrapper composition evidence — issue #26

Implements the composition contract in §3.3 in `src/app.zig`. The custom
not-found wrapper and full lifecycle tests remain for issue #27.

API as implemented, per `App(Plugins)`:

- A plugin type may declare an optional hook
  `pub fn wrapRoute(comptime H: type, comptime inner: H.RouteFn) H.RouteFn`.
  `H` is `App.RouteHook(name)`, a comptime descriptor for the plugin field
  `name`. It exposes `App`, `Context`, `RouteFn`, `Plugin`, `plugin_name`,
  `plugin(ctx)` (the configured instance, `*const Plugin`), and `state(ctx)`
  (that plugin's request state). This deviates from the §3.3 one-argument
  signature only by the descriptor. A plugin is declared before its app, so
  it cannot name the app's `RouteFn` directly.
- `App.composeRoute(comptime base: RouteFn) RouteFn` folds the hooks from the
  last plugin field to the first at comptime, so the first declared wrapper
  is outermost. Plugins without the hook add nothing. With no hooks it returns
  `base` itself. Both the base and the result are comptime-known. No runtime
  `route_fn` value is passed into a comptime parameter.
- The caller passes the composed function as `route_fn`. The terminal
  middleware continuation calls `route_fn` and then applies the default 404,
  so wrappers run inside middleware and before default response
  finalization. A wrapper sees an unhandled miss as unhandled and may write
  a fallback, or skip the inner wrappers and route by returning without
  calling `inner`. A middleware short circuit runs no wrapper.
- Wrappers are plain functions over the request's `Context`. Configured values
  come from `H.plugin(ctx)` and `ctx.config`, and per-request values come from
  `H.state(ctx)`. One composed route can serve several differently configured
  apps. Wrappers hold no per-request storage of their own.
- Caller obligation: a route passed to `route_fn` without `composeRoute` runs
  no wrappers. Zig cannot detect this, because composition must happen on a
  comptime-known route.

Tests in `src/app.zig`:

| Test | Shows |
|---|---|
| route wrappers fold so the first registered wrapper is outermost | Plugins `a`, `json` (no hook), `b`, `c` log `abcRCBA`: entry order and exit order. The app is a struct literal, so composition needs no `init`. |
| composing without hooks returns the base route | `composeRoute(base) == base` at comptime for a JSON-only app and for an empty plugin set. |
| a wrapper can skip inner wrappers and the route | `b` writes 401 without calling `inner` (`abBA`): `c` and the route never run, and `a` still unwinds. When `a` skips without writing (`aA`), the terminal continuation's default 404 applies. |
| wrappers run inside the terminal continuation before the default 404 | With one middleware entry, a miss logs `mwRWM`. The outer wrapper sees the response unhandled after `inner`, and the middleware then sees 404. A middleware short circuit (403) runs no wrapper. |
| wrappers read plugin, application, and request configuration through Context | One composed route in two apps produces `X-Stamp: p1:one:x` and `p2:two:y`, from the plugin instance's `prefix`, `ctx.config.name`, and `H.state(ctx)`. The route reads the same state. |
| route errors propagate through every wrapper and release the response | `error.Boom` from the route leaves `dispatch`. Deferred exits unwind as `abcRCBA`, and the testing allocator reports no leak. |
| README route-wrapper example compiles and runs | The README `RequireHeader` plugin returns 200 with `X-Checked-By` from `ctx.config.name`. Without the header it skips the route with 400. On a miss its header survives the default 404. |

Mutation check (seeded locally and reverted, not committed):

| Defect | Failing tests |
|---|---|
| Fold from first to last (last wrapper outermost) | the ordering, skip, and error-propagation tests |
| Hooks ignored (`composeRoute` returns `base`) | all five runtime wrapper tests |
| Default 404 applied around the base route, inside the wrappers | the no-hooks identity assertion at compile time. With that assertion disabled, the terminal-continuation test fails. |

Validation on pinned Zig `0.16.0` (`x86_64-linux-gnu`, kernel 7.0.0-38-generic):

```sh
zig version                                          # 0.16.0
zig fmt --check build.zig src
zig build
zig build test --summary all                         # 150/150 (141 library + 3 exe + 6 watcher), 3 consecutive runs
zig build test -Doptimize=ReleaseSafe --summary all  # 150/150
zig build test-hardening -Doptimize=ReleaseSafe --summary all   # 10/10
zig build test-devloop --summary all                 # 1/1
./zig-out/bin/zoda
```

Hosted CI: pending the first push of this change.

### §4.2.13 Phase 3 custom not-found wrapper and lifecycle evidence — issue #27

`src/plugins/not_found.zig` supplies `NotFound`, a configured plugin with a
`wrapRoute` hook. Its `body` is copied into a 404 response only after the inner
route and wrappers return unhandled. `src/root.zig` exports it as
`zoda.NotFound` and `zoda.plugins.not_found.NotFound`; the README shows the
public setup. Dispatch's default 404 still covers middleware short circuits
that never call the terminal continuation.

The acceptance tests in `src/lifecycle.zig` combine request parsing, request
state initialization and teardown, two middleware entries, route wrappers,
the route, fallback finalization, errors, recovery, and response lifetime.
They assert the complete entry/exit trace `sabwRWBAS` on handled routes,
custom misses, and recovery. Wrapper short circuits trace `sabwWBAS` and
either return a 401 or reach the default 404 without running the inner wrapper
or route. An unhandled middleware short circuit traces `sabBAS` and gets the
default 404 without running any wrapper; middleware sees the custom 404 before
unwinding. Tests also check configured app and plugin values, per-request
state, error propagation, clearing of a partial response before replacement
or default 404, and that a returned response survives request state, request
arena, and app teardown.

Validation on pinned Zig `0.16.0` (`x86_64-linux-gnu`):

```sh
zig version                                          # 0.16.0
zig fmt --check build.zig src
zig build
zig build test --summary all                         # 152/152
zig build test -Doptimize=ReleaseSafe --summary all
zig build test-hardening -Doptimize=ReleaseSafe --summary all
zig build test-devloop --summary all
```

Hosted CI: pending a push of this change; link the passing run before closing
issue #27.

### Phase 3 — Route wrappers

- [x] Compose wrappers with a comptime base route and typed context.
      (issue #26, §4.2.12)
- [x] Implement a custom not-found wrapper before the default 404 step.
      (issue #27, §4.2.13; hosted CI evidence pending)
- **Exit:** entry/unwind ordering, short-circuiting, and error recovery match §3.3.

### Phase 3.5 — Templates

- [x] Start with embedded templates and interpolation over typed data.
      Template edits use the Phase 2d rebuild loop.
- [x] Escape HTML text by default. Initially allow interpolation only in text
      nodes; reject attribute, script, style, and URL contexts. Raw trusted HTML
      requires a distinct explicit type/API; untrusted strings cannot opt in
      implicitly.
- [x] Return clear errors for missing fields or invalid templates.
- **Exit:** render an HTML page and test escaping of special characters,
      hostile input, unsupported interpolation contexts, and rebuild behaviour.
      Runtime loading or multiple engines require a later scoped extension.

Issue #28 implementation: [`src/template.zig`](src/template.zig) exposes
`render` and the explicit `TrustedHtml` type. The demo embeds
[`src/page.html`](src/page.html) and serves `/page?name=...`; the
[`README`](README.md#embedded-html-templates) documents the API. Tests cover
escaping, hostile input, unsupported contexts, missing fields, malformed
templates, response limits, and failed-render preservation. The development
loop test edits the template file and observes the rebuilt page.

Issue [#29](https://github.com/kamalogudah/zoda/issues/29) verifies all five
HTML escapes, hostile input, rejected attribute/URL/script/style/comment
contexts, explicit trusted markup, missing fields, and invalid templates. The
Phase 2d development-loop test now removes the embedded file in a temporary
project, checks Zig's build diagnostic and the still-running previous page,
then restores a valid edited template and checks escaped output after rebuild.
Runtime loading or multiple engines remain conditional extensions; open a
separately scoped issue if either becomes necessary.

Validation on pinned Zig `0.16.0` (`x86_64-linux-gnu`):

```sh
zig version                                           # 0.16.0
zig fmt --check build.zig src
zig build
zig build test --summary all                          # 158/158
zig build test -Doptimize=ReleaseSafe --summary all   # 158/158
zig build test-hardening -Doptimize=ReleaseSafe --summary all # 10/10
zig build test-load -Doptimize=ReleaseSafe --summary all # 2/2
zig build test-devloop --summary all                  # 1/1
```

Hosted CI for issue #29: link the passing run before closing the issue.

### Phase 4 — Optional ergonomics

- [x] Evaluate named captures against demonstrated routes (issue
      [#30](https://github.com/kamalogudah/zoda/issues/30)); defer the
      addition. See the decision and evidence below.
- [x] Evaluate conveniences supported by the pinned compiler while keeping
      explicit registered-plugin access available (issue
      [#31](https://github.com/kamalogudah/zoda/issues/31)); retain the
      current API. See the decision below.
- **Exit:** additions preserve routing semantics and request lifetimes.

#### Named captures decision (issue #30)

**Outcome: no API change.** The implemented `GET /users/:id` route binds
`id` directly from `req.onSegment()` in [`src/main.zig`](src/main.zig#L26) and
[`src/server.zig`](src/server.zig#L28). The same pattern serves the JSON response
in [`src/app.zig`](src/app.zig#L418), and [`README.md`](README.md#routing) shows it
to callers. [`src/request.zig`](src/request.zig#L590) tests a parsed request's
borrowed `id`; [`src/router.zig`](src/router.zig#L259) tests slice identity with
segment storage, cursor movement, and checkpoint restoration. These are the
current routing needs, and a local binding supplies the only requested name.
No route needs to look up a capture after leaving its lexical scope.

A named-capture store would add state to synchronize with `mark`/`restore`,
including failed and nested alternatives, while offering no demonstrated
benefit to these routes. `onSegment()` stays allocation-free and returns a
slice borrowed from the request arena. The route must use that slice before
the request is destroyed; copying it into a longer-lived value is the
caller's explicit responsibility. The existing cursor and lifetime contracts
in §3.1 and §3.4 remain in force.

Reopen this decision when a concrete route cannot conveniently pass returned
segments through local bindings or function arguments. Before implementing,
open a separate scoped issue linked to [#30](https://github.com/kamalogudah/zoda/issues/30)
and the [roadmap #38](https://github.com/kamalogudah/zoda/issues/38).
That issue must define lookup and duplicate-name behavior, how captures are
restored across failed and nested alternatives, allocation ownership and
failure behavior, and request-lifetime rules. Tests must cover those cases
and existing cursor semantics before the implementation issue closes.

Decision-only validation on pinned Zig `0.16.0`:
`zig version` → `0.16.0`; `zig build test --summary all` → 158/158 passed;
`git diff --check` → clean. No implementation or test changed, so this
decision does not require a new hosted CI run.

#### Compiler-supported conveniences decision (issue #31)

**Outcome: no new API or implementation issue.** On pinned Zig `0.16.0`,
[`App(Plugins)`](src/app.zig) already uses comptime reflection to generate
per-request state and dispatch hooks by registered field name. Its typed
`Context` exposes `ctx.plugins.<name>` and `ctx.state.<name>`. The
[`JSON route`](src/main.zig) and [`server route`](src/server.zig) compile and
call the registered JSON instance directly; the [README server example](README.md#a-complete-server)
shows the same public API. The optional `App.composeRoute` hook is the
compiler-supported convenience already accepted in issue
[#26](https://github.com/kamalogudah/zoda/issues/26), with composition,
ordering, short-circuit, and error tests in [`src/app.zig`](src/app.zig).
It retains access to each configured instance through `H.plugin(ctx)`.

| Candidate | Decision and evidence |
|---|---|
| Inject plugin methods into the handler namespace or generate unqualified forwarding methods | Reject. Zig `0.16.0` rejects `pub usingnamespace Mix;` in a struct (probe below). Generated forwarding methods could still be written, but the registered instance and its configuration would be less visible at the call site, and method names from two plugins could collide. `ctx.plugins.json.render(...)` is short and already used by working routes. Keep explicit instance access as the contract in §3.2. |
| Implicitly compose every registered route wrapper | Reject. `App.composeRoute(route)` is a compile-time, opt-in operation; [`src/app.zig`](src/app.zig) tests composition, while `route_fn` also accepts the base route directly. Making registration silently change `route_fn` would change existing dispatch behavior. |
| Automatic branch termination | Reject. A successful prefix consumes routing state, and the handler explicitly returns from the branch, including on a miss. Inserting generated control flow would change this contract; [`src/router.zig`](src/router.zig) tests why the explicit return is needed to prevent fallthrough after `/users`. |
| Route DSL or generated capture store | Defer pending a concrete route that needs either. The [`/users/:id` route](src/main.zig) needs only a local borrowed slice. [`src/router.zig`](src/router.zig) tests failed matches and `mark`/`restore`; either addition would need to preserve cursor, committed-branch, and request-lifetime behavior. The named-capture decision is [#30](https://github.com/kamalogudah/zoda/issues/30). |

No new addition was accepted, so there is no implementation or regression-test
issue to open for #31. If a concrete application later needs one of these
conveniences, open a scoped implementation and test issue linked to
[#31](https://github.com/kamalogudah/zoda/issues/31) and the
[roadmap #38](https://github.com/kamalogudah/zoda/issues/38) before changing
the API. Specify the compiler feature, collision rules, compatibility with
explicit instance access, routing cursor behavior, and borrowed lifetimes.
Phase 5's required typed segment matchers and plugins remain separately scoped
in [#32](https://github.com/kamalogudah/zoda/issues/32),
[#33](https://github.com/kamalogudah/zoda/issues/33), and
[#34](https://github.com/kamalogudah/zoda/issues/34); this optional decision
does not gate them.

Decision-only validation on pinned Zig `0.16.0`:
`zig version` → `0.16.0`; `zig build test --summary all` → 158/158 passed;
`zig build && ./zig-out/bin/zoda` → the seven documented route outcomes;
`git diff --check` → clean.
For a temporary struct containing `pub usingnamespace Mix;`, `zig test`
reports `expected function or variable declaration after pub` at that line.
The cited tests and examples exercise the existing compiler-supported API;
no implementation or test changed for #31, so no new hosted CI run is required.

### Phase 5 — More plugins

- [x] Typed base-10 integer segment matchers (`onInt(T)` and terminal
      `isInt(T)`) with overflow/invalid-value tests and no consumption on
      failure ([#32](https://github.com/kamalogudah/zoda/issues/32)).
- [x] Sessions using §3.2 state: application-supplied secret, authenticated cookie
      format, size limits, expiry, key rotation, secure cookie defaults, and
      tampering tests. Signing does not make cookie contents confidential.
- [ ] CSRF helpers after sessions/cookie policy, with positive and negative tests.
- **Exit:** demonstrate state isolation and cookie finalization on success,
      failure, and middleware short circuits.

#### Typed segment matcher evidence (issue #32)

[`src/router.zig`](src/router.zig) implements `onInt(T)` and `isInt(T)` by
parsing before incrementing the cursor. Its tests cover signed and unsigned
range boundaries, overflow, invalid values, path exhaustion, terminal-only
matching, same-request `mark`/`restore`, and borrowed `onSegment()` slices
after a failed parse. [`README.md`](README.md#routing) documents the public API.
Implementation and review: [PR #52](https://github.com/kamalogudah/zoda/pull/52).
Sessions and CSRF remain separately tracked in [#33](https://github.com/kamalogudah/zoda/issues/33)
and [#34](https://github.com/kamalogudah/zoda/issues/34).

Validation on exact pinned Zig `0.16.0`: `zig fmt --check build.zig src`;
`zig build`; `zig build test --summary all` (160/160 tests);
`zig build test-hardening -Doptimize=ReleaseSafe --summary all` (10/10);
`zig build test-load -Doptimize=ReleaseSafe --summary all` (2/2);
`zig build test-devloop --summary all` (1/1); `./zig-out/bin/zoda`
(seven documented route outcomes); and `git diff --check`. All passed locally.
[CI run 40326884371](https://github.com/kamalogudah/zoda/actions/runs/40326884371)
passed both format and build/test jobs for implementation commit `e678bf9`.

#### Cookie session evidence (issue #33)

[`src/plugins/sessions.zig`](src/plugins/sessions.zig) implements a generated
per-request `State`, HMAC-SHA256 authenticated cookie payloads, expiry, bounded
payloads and cookie values, key rotation, and explicit `save`/`clear` operations.
Its tests cover round trips, tampering, invalid/expired/oversized and duplicate
cookies, unsuitable configuration, key rotation, response header failure, and
app dispatch with isolated state and a middleware short circuit.
[`README.md`](README.md#cookie-sessions) documents setup, cookie policy, and
the lack of confidentiality. CSRF remains separately tracked in
[#34](https://github.com/kamalogudah/zoda/issues/34).

Validation on exact pinned Zig `0.16.0`: `zig fmt --check build.zig src`;
`zig build`; `zig build test --summary all` (165/165 tests); and
`git diff --check`. All passed locally. Hosted CI evidence will be linked
after the implementation is pushed.

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

    // Terminal matcher: succeeds and consumes only when exactly one remaining
    // segment equals `literal`; otherwise it fails without consuming, and the
    // caller must keep the branch open.
    pub fn isLiteral(self: *Request, literal: []const u8) bool {
        if (self.segments.len - self.cursor != 1) return false;
        if (!std.mem.eql(u8, self.segments[self.cursor], literal)) return false;
        self.cursor += 1;
        return true;
    }
};
```

Checkpoints (`mark`/`restore`) apply only to the same request, restore routing
state only — never response writes or plugin side effects — and alternatives
must be attempted before producing output or side effects.

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
        middleware: []const Middleware = &.{}, // app-owned copy made by `init` (§3.6)

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
            // Middleware chain (§3.6); the terminal continuation runs the
            // route and the default 404.
            try self.runFrom(0, &ctx, req, &res);
            // Covers middleware short circuits that left the response unhandled.
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
    const clock = ctx.config.clock orelse return error.ClockNotConfigured;
    const start = clock.monotonicNow();
    try next.call(ctx, req, res);
    // Copies formatted bytes into response storage; no request allocation escapes.
    try res.setHeaderFmt(
        "X-Response-Time-Ms",
        "{d}",
        .{clock.elapsedMilliseconds(start)},
    );
}
```

The clock is an injected application interface implemented against the pinned
toolchain (`AppConfig.clock: ?Clock`, `Clock.monotonic(io)` over
`Io.Clock.awake`; implemented as `zoda.timing.middleware(App)`, §4.2.10). Static-file middleware uses its configuration pointer for the
document-root handle and calls `next.call` only when it does not serve the path
(implemented as `zoda.static.middleware(App, &config)`, §4.2.11).

## 6. Verification and remaining decisions

No phase is complete until its implementation, acceptance tests, and pinned
CI run exist. Record exact compiler version and test commands. Documentation
examples must track the implemented public API once code lands.

Remaining decisions have explicit gates:

- ~~Exact compiler version and primary platform~~ — resolved in Phase A:
  Zig 0.16.0 on `x86_64-linux` ([PLATFORM.md](PLATFORM.md)).
- Concrete I/O/concurrency APIs: Phase 2, before the socket slice is accepted.
- ~~Response streaming API~~ — resolved in Phase 2b as buffered-only for the
  first HTTP/1.1 release (issue #18, §4.2.5). Streaming stays unsupported
  until a reopening condition there is met and a separate ADR is approved.
- ~~HTTP/2 support~~ — resolved in Phase 2c as HTTP/1.1-only: the pinned
  `std.http` has no HTTP/2 server (issue #19, §4.2.6). HTTP/2 stays
  unsupported until a reopening condition there is met.
- ~~Named capture convenience~~ — Phase 4 decision: deferred for lack of a
  demonstrated need (issue [#30](https://github.com/kamalogudah/zoda/issues/30),
  §4 Phase 4). Open a scoped implementation issue linked to roadmap
  [#38](https://github.com/kamalogudah/zoda/issues/38) if a concrete route
  needs it.
- ~~Additional compiler-supported conveniences~~ — Phase 4 decision: retain
  explicit plugin calls and current routing syntax (issue
  [#31](https://github.com/kamalogudah/zoda/issues/31), §4 Phase 4). If a
  concrete application needs an addition, open a scoped implementation and
  regression-test issue linked to [#31](https://github.com/kamalogudah/zoda/issues/31)
  and roadmap [#38](https://github.com/kamalogudah/zoda/issues/38).

Plugin state access, ownership, branch termination, middleware ordering, and
buffering are decisions above, not questions deferred until sessions.

## 7. References

- [Roda source](https://github.com/jeremyevans/roda)
- [Roda routing and halt semantics](https://roda.jeremyevans.net/rdoc/classes/Roda/RodaPlugins/Base/RequestMethods.html)
- [Roda plugins](https://github.com/jeremyevans/roda/tree/master/lib/roda/plugins)
- Planned implementation locations: `src/router.zig`, `src/app.zig`,
  `src/transport.zig`, and `src/plugins/`. These are future files, not
  evidence of an existing implementation.
