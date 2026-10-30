# Supported API and evidence

This is the public contract for the first Zoda HTTP/1.x release. It implements
[ADR-0001](zoda_plan.md) §4 Phase 6, §5, and §6. The runnable counterpart to
every applicable §5 sketch is [`examples/contract.zig`](examples/contract.zig),
compiled in `zig build test` and separately with `zig build test-examples`.

## Toolchain and commands

The exact compiler is **Zig 0.16.0**; the primary target is
**x86_64-linux-gnu**. The socket server and static confinement use Linux APIs;
other targets are best effort. See [PLATFORM.md](PLATFORM.md) for installation
and host details.

```sh
zig version                                      # must print 0.16.0
zig fmt --check build.zig src examples
zig build
zig build test                                  # includes examples/contract.zig
zig build test-examples
zig build test-hardening -Doptimize=ReleaseSafe --summary all
zig build test-load -Doptimize=ReleaseSafe --summary all
zig build test-devloop --summary all
./zig-out/bin/zoda                             # in-memory route demo
zig build watch                                # Linux dev server on 127.0.0.1:8080
```

CI pins the compiler and runs formatting, build, tests, the ReleaseSafe
hardening and 60-second load suites, development-loop recovery, and the demo
([workflow](.github/workflows/ci.yml)). The exact `test-examples` step also
runs inside `zig build test`.

## Supported surface

- `zoda.router.Request`: consuming literal, borrowed segment, and integer
  matchers; `mark`/`restore` cursor checkpoints; explicit method checks.
- `zoda.request.parseOriginForm`: strict origin-form parsing into a caller-owned
  `RequestArena`. Path segments are decoded once; repeated and trailing slashes
  remain distinct. Query pairs retain order and duplicates, with `+` decoded
  to space. `getAll` iterates all values; `getOne` errors on duplicates. Header
  names are case-insensitive; repeated fields remain separate, and
  `getHeaderOne` errors on duplicates. The body is fully buffered.
- `zoda.JsonParser` (`zoda.plugins.json_parser`) is an opt-in registered
  request plugin. `parse(allocator, req, T)` accepts exactly one
  `Content-Type: application/json` field, optionally with `charset=utf-8`,
  and parses the buffered body into `std.json.Parsed(T)`. It reports missing,
  duplicate, or unsupported content types, empty or oversized bodies, invalid
  JSON (including duplicate or unknown object fields), and allocation failure
  distinctly. Its default body limit is 1 MiB. The caller owns the parsed
  value and calls `deinit()`; parsed strings are copied and may outlive the
  request until then. See the [compiling route](examples/contract.zig) and
  [README](README.md#typed-json-requests).
- `zoda.app.App(Plugins)`: typed context, explicit plugin access, request
  state lifecycle, `composeRoute` wrappers, ordered middleware, default 404,
  and owned `Response` return from `dispatch`.
- Buffered text, JSON, and embedded HTML template responses; JSON and
  configured not-found plugins; host-authorization, default-header, timing, and static-file
  middleware; signed cookie sessions, session-bound CSRF helpers, and one-time flash messages; bounded
  cleartext HTTP/1.0 and HTTP/1.1 socket service.
- `Response.redirectPath(status, path)` sets an explicit 302, 303, 307, or 308
  and a copied `Location` for a local path. It rejects external or ambiguous
  destinations, invalid header bytes, malformed escapes, and a preexisting
  `Location`; header limits apply. A successful redirect has an empty body.
  302/303 may lead a client to use GET; 307/308 preserve method and body.
  HTTPS redirect middleware is deferred until the transport or trusted-proxy
  scheme contract is specified and covered by integration tests. Forwarded
  scheme headers are not trusted by default.
- `zoda.plugins.http_cache` holds explicit helpers; no cache policy is applied
  by default, including to session or authenticated responses.
  `setCacheControl(req, res, policy)` writes one `no-store`, `private`, or
  `public` field with optional `max-age`, `s-maxage` (public only),
  `no-cache`, `must-revalidate`, and `immutable`. It rejects a second policy
  and lifetimes over 2147483648 s. It also rejects `public` when the response
  has `Set-Cookie`, or when the request has `Authorization` or `Cookie`
  without `allow_credentials`. `setETag` (strong or weak, ≤128 bytes of
  `%x21 / %x23-7E`), `setBodyETag` (SHA-256 of content type and body, 128
  bits hex), and `addVary` (deduplicated token, `*` refused) append fields
  under the response header limits and fail without partial changes.
  `evaluate(req, res)` applies weak `If-None-Match` comparison to handled GET
  and HEAD 2xx responses. Repeated fields are one list, and `*` is valid
  alone. A malformed field voids the condition. A match calls
  `Response.notModified()`, which keeps headers and drops the body and content
  type. The transport writes a 304 without `Content-Length`, `Content-Type`,
  or body, and keeps the connection alive. `If-Modified-Since`, `If-Match`,
  unsafe-method preconditions, and ranges are unsupported.
- `zoda.BearerToken` is an opt-in registered plugin. `token(req)` returns a
  request-borrowed credential or null, and reports duplicate, malformed, or
  oversized Authorization credentials as errors. `authorized(req)` maps all
  failures to false and calls the application-supplied validator for a parsed
  credential. The parser accepts exactly one `Authorization: Bearer <token>`
  field with case-insensitive scheme, one SP separator, and RFC 6750 b64token
  syntax; it never reads query parameters. The default maximum is 4096 token
  bytes. The callback must not retain the borrowed token.
- `zoda.RequestTrace` is an opt-in registered plugin. It creates an ID once
  per dispatch in request-local state (`ctx.state.<name>.id()`). The ID comes
  from 16 bytes of `IdSource` (`std.Io.randomSecure` or a thread-safe custom
  fill), hex-encoded. With `incoming = .accept_valid`, it instead takes one
  `X-Request-Id` value of 1–64 `[A-Za-z0-9_-]` bytes.
  `request_trace.middleware(App, name)` sets `X-Request-Id` on completed
  responses. It calls the sink once per dispatch with `Record{ id, method,
  path, status, duration_ms, failed }`; errors give `status = null` and
  `failed = true`. Records exclude headers, query strings, and bodies.
  Register it outermost.
- `zoda.plugins.status_handler` and `zoda.plugins.error_handler` are opt-in
  middleware. `status_handler.middleware(App, &config)` validates distinct
  400–599 statuses and, after downstream succeeds, runs the matching handler
  only when the body is empty or `Response.generated` (the default 404 or the
  recovery 500). Route-written bodies win; headers are kept; errors propagate.
  `error_handler.middleware(App, &config)` clears the partial response, runs
  the optional handler with the error, and otherwise writes a generated 500.
  `OutOfMemory`, `Canceled`, and transport I/O errors propagate unless
  `passthrough` is overridden. Both cover only entries registered after them.
  See [PLUGINS.md](PLUGINS.md#status-and-error-handlers).
- `zoda.plugins.security_policy` is opt-in middleware.
  `security_policy.middleware(App, &config)` validates CSP (enforced and
  report-only), Permissions-Policy, and HSTS settings and the configured
  header budget at setup. After downstream succeeds, it adds each configured
  field on the selected `ResponseClasses` (all by default) unless the response
  already has that field, and adds either every selected field or none when
  response header limits would be exceeded. HSTS is sent only when the
  required `hsts.https` signal returns true; forwarded scheme headers are
  never read. It covers only entries registered after it.
  See [PLUGINS.md](PLUGINS.md#security-response-policies).
- `zoda.Inertia(SharedProps)` (`zoda.plugins.inertia`) is an opt-in
  registered plugin for a subset of the Inertia.js protocol.
  `render(req, res, component, props)` writes the page object
  `{component, props, url, version}` either into the configured layout's
  single `@inertia` marker (HTML) or, for
  `X-Inertia: true`, as `application/json` with `X-Inertia: true`; both add
  `Vary: X-Inertia`. The HTML page defaults to the Inertia v3 form, a
  `<script data-page type="application/json">` with `<`, `>`, and `&`
  `\u`-escaped, followed by the empty root element; `initial_page =
  .attribute` writes the v1/v2 attribute-escaped `data-page` instead. Route
  props replace shared props of the same name; `props.errors` defaults to
  `{}`; configured shared props are named in `sharedProps`. An Inertia GET whose
  `X-Inertia-Version` (missing counts as empty) differs from the configured
  version gets 409 and `X-Inertia-Location`. Checked against
  `@inertiajs/react`, `@inertiajs/svelte`, and `@inertiajs/vue3` 3.9.1 by
  [examples/inertia](examples/inertia/README.md). `redirect` sends a local
  path with 302 after GET/HEAD and 303 otherwise, or, for an Inertia request
  to a path with a `#fragment`, 409 and `X-Inertia-Redirect`; `location` sends 409 and `X-Inertia-Location`
  to Inertia requests and 302/303 otherwise, for a local path or a validated
  absolute `http(s)` URL without userinfo. URLs are the raw origin-form target;
  no origin is read from `Host` or forwarded headers. Duplicate or malformed
  `X-Inertia`/`X-Inertia-Version` fields, unsafe targets, configuration, and
  limit failures return errors and leave the response unchanged. Partial
  reloads apply when `X-Inertia-Partial-Component` names the rendered
  component: `X-Inertia-Partial-Data` keeps and `X-Inertia-Partial-Except`
  removes top-level props (except wins; a dot path selects its top-level
  prop), shared props included, and `errors` is always sent.
  `zoda.plugins.inertia.optional(context, resolve)` props call
  `resolve(context, arena)` only when a partial reload keeps them, and
  `render` returns its errors unchanged (`Inertia(S).Error(Props)`);
  `always(value)` props are always sent. `deferred(context, resolve)` and
  `deferredGroup(group, context, resolve)` props are left out of full visits
  without calling `resolve` and listed as `deferredProps: {group: [names]}`
  (route and shared props); a partial reload resolves them like `optional`
  props and sends no `deferredProps`. `merge(prop)`, `prepend(prop)`, and
  `deepMerge(prop)` wrap a plain, `optional`, or `deferred` prop; when it is
  sent, its name is listed in `mergeProps`, `prependProps`, or
  `deepMergeProps`, and each `.matchOn(key)` adds `name.key` to
  `matchPropsOn`. On a partial reload of the rendered component, props named
  in `X-Inertia-Reset` are sent without that metadata.
  `scroll(prop, .{ .page_name = "page", .previous = ?u32, .next = ?u32,
  .current = u32 })` (types `Scroll(T)`, `Scrollable(T, match_on)`) is a
  merge prop for `<InfiniteScroll>` that also adds
  `scrollProps: {name: {pageName, previousPage, nextPage, currentPage,
  reset}}` when sent; a partial reload with
  `X-Inertia-Infinite-Scroll-Merge-Intent: prepend` lists it in
  `prependProps`, otherwise it is in `mergeProps`, and `X-Inertia-Reset`
  sets `reset: true`. The route reads the page query parameter and pages
  its own data. The intent accepts only `append` or `prepend`; an invalid
  `page_name` (1-64 `[A-Za-z0-9_-]` bytes) returns
  `error.InvalidScrollPageName`. `once(context, resolve)` props (types
  `Once(Context, resolve)`, `Onceable(key, Context, resolve)`) are resolved
  like plain props and listed as `onceProps: {key: {prop, expiresAt}}`,
  keyed by the prop name or `.as(key)`; on an Inertia visit whose
  `X-Inertia-Except-Once-Props` names the key they keep the entry but are
  neither resolved nor sent, unless a partial reload of the component lists
  them in `X-Inertia-Partial-Data`. `.expiresIn(ms)` sets `expiresAt` from
  the instance's `now_milliseconds` clock (UTC Unix milliseconds); an unset
  clock returns `error.OnceClockNotConfigured` and a negative time or an
  `expiresAt` above `max_once_expires_at` returns `error.InvalidOnceTime`.
  Lists (including `X-Inertia-Reset` and `X-Inertia-Except-Once-Props`) are
  bounded by `max_partial_props` and `max_partial_bytes`; malformed,
  oversized, or duplicate partial headers return errors.
  `renderWith(req, res, component, props, .{ .flash = .{ .plugin, .session } })`
  sends the `zoda.Flash` messages the request received as the top-level
  `flash: {kind: text}` (a later message of a kind replaces an earlier one),
  on every render including partial reloads, leaves the field out when there
  are none, and marks them read only after the response is committed;
  `sessions.save` after it persists that.
  `redirectWithErrors(req, res, source, path, errors)` stores a struct of
  validation errors in the session as one `zoda.Flash` message of the
  reserved kind `errors_flash_kind` and redirects with 303 to the
  route-supplied local `path` (409 and `X-Inertia-Redirect` for an Inertia
  request to a path with `#`); `Referer` is never read. On Inertia requests
  `X-Inertia-Error-Bag` (1 to `max_error_bag_bytes` `[A-Za-z0-9_-]` bytes,
  else `error.MalformedErrorBagHeader`; repeated,
  `error.DuplicateErrorBagHeader`; also `errorBag(req)`) nests them under
  the bag. Header, path, header-limit, and flash-budget
  (`error.FlashTooLarge`) failures leave the response and session unchanged.
  The next `renderWith` with `.flash` sends them as `props.errors`, after
  route `errors` and before shared `errors`, and consumes them with the
  flash; without stored errors the default stays `errors: {}`.
  `RenderOptions` also has `encrypt_history: ?bool` (overrides the
  instance's `encrypt_history: bool = false`), `clear_history`, and
  `preserve_fragment`, which add `encryptHistory`, `clearHistory`, and
  `preserveFragment` after `version` only when true, and `status` (200,
  default; 200-299 except 204/205, or 400-599, else `error.InvalidStatus`
  before the response changes). `clearHistoryOnNextRender(source)` stores a
  `zoda.Flash` message of the reserved kind `history_flash_kind`, at most
  one queued, so the next `renderWith` with `.flash` sends
  `clearHistory: true` and consumes it; it is never sent in `flash`.
  History encryption needs a secure context (HTTPS or localhost) and does
  not hide props from the server or from script on the page.
  `zoda.plugins.inertia.precognition(req)` returns null without exactly one
  `Precognition: true` (repeated, `error.DuplicatePrecognitionHeader`;
  other values, `error.MalformedPrecognitionHeader`) and otherwise a
  `Precognition` whose `only` is the validated `Precognition-Validate-Only`
  (null when absent, empty to validate nothing, else at most
  `max_precognition_fields` names in `max_precognition_bytes`, else
  `error.PrecognitionHeaderTooLarge`) and whose `validates(name)` matches
  listed names with `*` segments. `answerPrecognition(req, res, errors)`
  keeps the requested non-null fields of the errors struct and sends 422
  with `{"errors": {...}}`, or 204 with `Precognition-Success: true` when
  none are left, both with `Precognition: true` and `Vary: Precognition`;
  `error.NotPrecognitive` and `error.PrecognitionAlreadySet` guard misuse,
  and header, limit, and body failures leave the response unchanged.
  `varyOnPrecognition(res)` adds `Vary: Precognition` to ordinary
  responses. With `ssr` set (`zoda.plugins.inertia.Ssr`: literal
  `address`, default `127.0.0.1:13714`; `path`, default `/render`;
  `timeout_ms`, default 1000; `max_response_bytes`, default 1 MiB), full
  visits post the page JSON to an Inertia SSR server under one monotonic
  deadline and insert its `head` at the optional `@inertiaHead` marker and
  its `body` at `@inertia`, as is. Any failure (`SsrFailure`) goes to
  `on_ssr_failure` and the page falls back to the client-side shell; bad
  settings are `error.InvalidSsr`. Linux only, like `zoda.static`; a render
  holds its connection task for up to `timeout_ms`. Deferred once props are
  not implemented. See
  [PLUGINS.md](PLUGINS.md#inertiajs).
- `zoda.response.validateRedirectPath(path)` checks the `redirectPath`
  local-path rules without changing a response.
- `BearerToken.guard_routes = true` adds a wrapper through `App.composeRoute`.
  It sends 401, `WWW-Authenticate: Bearer`, and a fixed body before the inner
  route on failure. The default is false. With `NotFound` registered,
  unauthenticated misses receive 401 and authenticated misses receive 404,
  regardless of these two wrappers' order. Routes may call
  `ctx.plugins.<name>.authorized(req)` and `.unauthorized(res)` explicitly.

The route is ordinary Zig control flow. After `onLiteral` consumes a prefix,
return from that branch even on a miss; dispatch writes 404 for an unhandled
response. Use `return child(ctx, req, res)` to delegate the branch. A failed
matcher does not move the cursor. `restore` rewinds only the cursor, never
response writes or plugin effects. Match cost depends on attempted siblings
and comparisons; **there is no unconditional O(depth) routing guarantee**.

## Ownership and lifecycle

The caller owns each `RequestArena` and keeps it alive through dispatch.
Captures, query/header values, and body slices borrow that storage. The
returned response independently owns copies of its body and headers through
the app's `response_allocator`; call `res.deinit()` even after the request
arena is released. The allocator must outlive every response. For concurrent
socket service, pass thread-safe allocators to both `App` and `server.serve`
(for example, `std.heap.smp_allocator`). Allocation errors propagate; they
are not route misses.

`App.init` copies middleware entries and `app.deinit()` frees them. Their
configuration pointers remain caller-owned, immutable, and valid until app
shutdown. Plugin instances are immutable during dispatch; shared mutable
resources they reference need synchronization. Per-request plugin state is
initialized in field declaration order and cleaned up in reverse, including
partial initialization failure. Cleanup is infallible and writes no response.
`wrapRoute` hooks run only when `route_fn` uses `App.composeRoute(route)`.
Middleware enters in registration order and unwinds in reverse. `Next.call`
may run once, only within that middleware invocation; copies share the same
single-use state. Do not store or move it to another thread. Route errors
propagate; recovery middleware must `res.clear()` before replacing a partial
response.

Default-header middleware validates immutable configuration at entry creation.
It rejects duplicate names, invalid syntax, and transport-owned framing or
connection fields. Place it before static serving and other middleware to
cover their short circuits. Existing response fields win by case-insensitive
name; configured defaults are appended only after downstream success. Response
header count and byte limits still apply. See the [README](README.md#default-response-headers)
and [compiling example](examples/contract.zig).

`zoda.host_authorization.middleware(App, &hosts)` validates an exact allowlist
at entry creation. Register it before static serving and any middleware that
can answer a request. It requires exactly one `Host` header on HTTP/1.0 and
HTTP/1.1 requests; missing, duplicate, malformed, or unlisted authorities get
403 before downstream dispatch. Hosts are ASCII DNS-style names, compared
without case, optionally followed by a canonical decimal port (1–65535, no
leading zeroes). Port presence and value must match exactly. No suffix matching
is performed. Empty labels, trailing dots, internal whitespace, userinfo, and
bracketed IP literals are unsupported. Surrounding spaces and tabs on a Host
field are ignored; allowlist entries must contain no whitespace. The transport preserves ordered headers and
does not expose a normalized authority; direct dispatch follows the same
Host-header rule. `Forwarded` and `X-Forwarded-Host` are ignored because no
trusted-proxy boundary is configured. Configuration slices must remain
immutable and alive through app shutdown. See the [README](README.md#host-authorization).

## Safe content and sessions

`template.render` escapes HTML text interpolation. `{{{field}}}` requires
`TrustedHtml.fromTrusted` with reviewed or sanitized markup. Interpolation in
HTML attributes, URLs, scripts, styles, and comments is rejected. Templates
are embedded at build time; `zig build watch` rebuilds them after edits.

Static files require a caller-owned document-root handle that outlives the app.
Run `static.checkSupport` at startup. On Linux 5.6+, `openat2` confines opens
beneath that handle without following symlinks; unsupported kernels or blocked
syscalls fail closed. Dotfiles are hidden by default. Static files are buffered
and bounded; keep the document root read-only to the server process.
`static.Config.cache_control` (an `http_cache.Policy`) and `etag` apply to
hits only and are off by default. `static.sendFile(req, res, root, path,
options)` sends one file from a route through the same confined open: `path`
is relative, `/`-separated, and checked per segment like a request path. It
returns `false` with the response untouched for missing or refused files and
fails with `error.BodyTooLarge` above `min(max_file_bytes, max_body_bytes)`.
Content-Disposition, ranges, and an asset pipeline are not supported.

Session keys and their bytes must outlive the app. Use at least 32 random
bytes per key, unique IDs, a trusted UTC clock, and HTTPS for the `__Host-`
cookie. The signed payload is **not encrypted**. Mutations and CSRF-token
issuance require an explicit `sessions.save` before returning; cleanup never
persists. `zoda.Flash` stores at most 8 messages / 512 encoded bytes in the
same signed (not encrypted) cookie. `add` queues a message for the next
request. `read` returns this request's messages and marks them consumed for
the next `save`. Without a save, they are shown again. `peek` returns them
without consuming them. `reset` undoes this
request's flash changes before a recovery save. Call `csrf.valid` before protected actions and reject duplicate form
tokens before `validToken`. See the [README](PLUGINS.md#cookie-sessions) for
rotation and cookie behavior.

## Defaults and unsupported capabilities

`AppConfig` defaults to `name = "zoda"` and `clock = null`; timing middleware
needs `.clock = .monotonic(io)`. Response bodies default to a 1 MiB maximum.
`server.Config` defaults to 128 connections, 10 s header/body/write deadlines,
5 s keep-alive idle timeout, 10 s shutdown grace, and 100 requests per
connection. `request.Limits` defaults to an 8 KiB target, 100 headers / 32 KiB
header bytes, 128 path segments, 256 query pairs, and a 1 MiB body. Static
middleware defaults to the response's 1 MiB effective file limit, hidden
dotfiles, and no URL prefix (`max_file_bytes` itself is unbounded). Session
keys, clock, and lifetime have no usable defaults; supply all
three explicitly.

Response streaming, HTTP/2, native TLS, automatic 405/`Allow`, HEAD-to-GET
fallback, named captures, a route DSL, runtime template loading, directory
listing, and index-file lookup are unsupported. HTTP/2 and TLS can terminate
at a reverse proxy that forwards HTTP/1.1. Streaming requires a separate ADR
and demonstrated use; HTTP/2 requires a new transport decision and integration
tests. These gates and other conditional follow-ups are in
[the roadmap](zoda_plan.md#6-verification-and-remaining-decisions).

## Reproducible measurements and decisions

The local load run on 2026-09-25 used Zig 0.16.0 ReleaseSafe, Ubuntu
24.04.1/x86_64, Intel i5-8365U (4 cores, 8 threads), and 15 GiB RAM.
`zig build test-load -Doptimize=ReleaseSafe --summary all` holds 64 loopback
keep-alive clients for at least 60 s, checks every response, then holds 128
incomplete requests while probing 32 excess connections. It observed 384,921
successful requests in 60.011 s (6,414/s), zero client errors, mean latency
9.052 ms, p50 ≤16.383 ms, p95/p99 ≤32.767 ms, and max 57.620 ms. Percentiles
are histogram bucket upper bounds. Peak counted allocator bytes were 49,098.
All 32 excess connections were rejected; mean rejection time was 350 µs,
p95 ≤511 µs. The 128 admitted requests completed and active connections and
counted allocations returned to zero. These are host/workload measurements,
not throughput guarantees. See [method and CI evidence](zoda_plan.md#424-phase-2b-load-and-overload-measurements--issue-17).

A local rerun on 2026-10-27 with Zig 0.16.0 ReleaseSafe on Ubuntu 24.04.4,
Linux 7.0.0-38-generic, and the same i5-8365U recorded 1,051,224 successful
requests in 60.004 s (17,519/s), zero client errors, mean latency 3.321 ms,
p50 ≤4.095 ms, p95 ≤8.191 ms, p99 ≤16.383 ms, and max 30.594 ms. Peak
counted allocator bytes were 49,528. Overload admitted 128 and rejected all
32 excess clients (mean 65 µs; p95 ≤127 µs), then returned to zero active
connections and counted allocations. Host scheduling and build environment
can change these numbers between runs.

The Debug development-loop run on an i5-8365U Ubuntu 24.04.4 host measured
18 edits at 1,390–1,890 ms edit-to-response (median valid edit 1,534 ms).
The real-build recovery test verifies that a compile error leaves the last
working server answering and a valid edit restores updates. Reproduce with
`zig build test-devloop --summary all`; see [method and evidence](zoda_plan.md#427-phase-2d-recovery-and-latency-evidence--issue-21).
The 2026-10-27 rerun on the Ubuntu 24.04.4 host measured five valid edits at
1,458–1,663 ms (median 1,604 ms), recovery at 1,665 ms, and no edits over
the reported 2 s target.

The [streaming decision](zoda_plan.md#425-phase-2b-response-streaming-decision--issue-18)
is buffered-only. The [HTTP/2 decision](zoda_plan.md#426-phase-2c-http2-feasibility--issue-19)
is HTTP/1.0 and HTTP/1.1 only because pinned `std.http.Server` has no HTTP/2
server path. The transport tests pin prior-knowledge h2c rejection and lack of
an h2c upgrade. Zoda differs from Roda in Zig's explicit allocator and slice
lifetimes, explicit plugin registration and calls, single-cursor routing,
buffered responses, and no implicit method fallback or runtime template engine.
