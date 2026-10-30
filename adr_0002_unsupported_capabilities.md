# ADR-0002: Paths to the Unsupported Capabilities

**Status:** Proposed  
**Author:** Paul Oguda  
**Date:** 2026-10-30  
**Relates to:** [ADR-0001](zoda_plan.md) §4.2.5, §4.2.6, Phase 3.5, Phase 4,
§6; [SUPPORTED_API.md](SUPPORTED_API.md#defaults-and-unsupported-capabilities)

## 1. Context

[SUPPORTED_API.md](SUPPORTED_API.md#defaults-and-unsupported-capabilities)
lists capabilities Zoda does not support:

- response streaming
- HTTP/2
- native TLS
- automatic 405/`Allow` responses
- HEAD-to-GET fallback
- named captures
- runtime template loading
- directory listing and index-file lookup

ADR-0001 deferred each one. Some were deferred for lack of a demonstrated need
(streaming in §4.2.5, named captures in Phase 4). Some were deferred because
the pinned transport cannot support them (HTTP/2 and TLS in §4.2.6). The rest
were left outside the first slice (405, HEAD, templates, static).

This ADR records, for each capability, what supporting it would require in the
current code. It also sets the order in which they may be taken up. It
**approves no implementation by itself**. Each capability still needs its own
scoped issue linked from roadmap
[#38](https://github.com/kamalogudah/zoda/issues/38). Where ADR-0001 requires a
separate ADR (streaming, HTTP/2, TLS dependencies), that ADR is still required.

The following constraints from ADR-0001 apply to every option below:

- Routing is imperative and uses a single cursor (§3.1). There is no route
  table. Matchers never allocate. `mark`/`restore` rewind routing state only.
- Responses are buffered (§4.2.5). Dispatch finishes before any byte is
  written, so a handler error can still become a clean generic 500. The
  transport owns framing and emits exactly one Content-Length.
- Plugins are explicit (§3.2). No behavior changes for an app that does not
  register or configure the new feature.
- Any change to `src/router.zig`, `src/transport.zig`, `src/response.zig`,
  `src/app.zig`, or a plugin requires a new
  [benchmark](performance_improvement.md#standard-benchmark-procedure) row
  ([Agent.md](Agent.md)).

## 2. Decision summary

| # | Capability | Tier | Gate | Depends on |
| --- | --- | --- | --- | --- |
| 1 | HEAD-to-GET fallback | Low | Scoped issue | — |
| 2 | Index-file lookup | Low | Scoped issue | — |
| 3 | Directory listing | Low/medium | Scoped issue plus security review | 2 |
| 4 | Automatic 405/`Allow` | Medium | Scoped issue defining matcher semantics | — |
| 5 | Named captures | Medium | ADR-0001 Phase 4 reopening condition | — |
| 6 | Runtime template loading | Medium | ADR-0001 Phase 3.5 scoped extension | — |
| 7 | Response streaming | High | ADR-0001 §4.2.5 reopening condition plus its own ADR | — |
| 8 | Native TLS | High | Dependency ADR, or a `std` TLS server | — |
| 9 | HTTP/2 | High | ADR-0001 §4.2.6 reopening condition | 7, 8 |

Recommended order: 1 → 2 → 4 → 3. After that, 5 and 6 when a concrete route
or app needs them. Then 7. Then 8 and 9, only with a maintained dependency.
Until 8 and 9 land, a reverse proxy remains the supported deployment for TLS
and HTTP/2.

## 3. Low tier

### 3.1 HEAD-to-GET fallback

**Current state.** `router.Method` includes `.head`, but `isGet()` matches only
`.get`, so an unmatched HEAD request becomes 404 (`src/router.zig` module doc).
The transport already does the protocol half of the work: for HEAD it keeps the
representation's Content-Length and sends no body (`src/transport.zig` test
"HEAD retains representation length and emits no body").

**Required.**

- Add an opt-in matcher. Either add `Request.isGetOrHead()`, or add an
  `AppConfig.head_fallback: bool = false` setting that makes `isGet()` accept
  `.head`. Prefer the explicit matcher so existing routes don't change meaning.
- Do not rewrite the method to GET before dispatch. Handlers must still be able
  to see `.head`, so that GET handlers with side effects can opt out. Examples
  are session writes, CSRF token issuance, and work the `http_cache` plugin
  would otherwise do.
- Decide how `http_cache` behaves. A HEAD request should get the same `ETag`,
  and a 304 should still apply to a conditional HEAD.

**Tests.** HEAD on a GET route returns the GET status, headers, and
Content-Length with no body. HEAD on a route without the fallback is still
404. A handler that checks `req.method == .head` can skip a side effect. A
conditional HEAD can return 304.

**Docs.** Update the `router.zig` module doc, `SUPPORTED_API.md`, the README
routing section, and `PLUGINS.md` if the feature ships as a plugin.

### 3.2 Index-file lookup

**Current state.** `src/static.zig` serves regular files only. A request for a
directory falls through to `next` (`static.zig` module doc). Opens are confined
and refuse symlinks, and tests cover swap races between a directory and a
symlink.

**Required.**

- Add `Config.index_file: ?[]const u8 = null`, for example `"index.html"`.
  When it is set and the resolved target is a directory, open the index file
  through the same confined, no-follow path, relative to the directory handle
  that was already opened. Do not re-resolve a path string.
- A directory URL without a trailing slash should redirect to the slash form,
  so relative links in the index page resolve. Use `Response.redirectPath`. Do not
  serve the file at the slashless URL.
- Dotfile hiding, `max_file_bytes`, and the response limit apply to the index
  file unchanged.

**Tests.** The index is served for `/dir/`. `/dir` redirects. A missing index
falls through to `next`. A symlinked index is refused. The existing race tests
still pass with lookup enabled.

### 3.3 Directory listing

**Required, on top of §3.2.**

- Add `Config.listing: bool = false`. When it is on and no index file exists,
  enumerate the directory handle.
- Skip dotfiles (whether `hidden` covers this is decided by the existing
  dotfile rule), symlinks, and special files. List only what the static
  middleware would actually serve.
- Bound the output. Cap the number of entries, and fail closed with a 500 or
  fall through to `next` if the rendered page would exceed `max_body_bytes`.
  Sort names for deterministic output.
- Escape every name with the escaping already used by `src/template.zig`. Emit
  links with each segment percent-encoded.

**Security review required.** A listing can reveal files that operators never
meant to be discoverable. The feature stays off by default, and the docs must
say so plainly.

## 4. Medium tier

### 4.1 Automatic 405 with `Allow`

**Problem.** Zoda has no route table, so nothing knows which methods would have
matched a given path. The method and the path are checked separately
(`isRoot()` and `isGet()`).

**Required.** Adopt the approach of Roda's `not_allowed` plugin:

- Add terminal verb matchers to `router.Request`: `get()`, `post()`, `put()`,
  `patch()`, `delete()`. Each returns `isRoot() and method == X`.
- When `isRoot()` is true but the method differs, record `X` in an
  `allowed: std.EnumSet(Method)` field on `Request`. This needs no allocation.
- In `src/app.zig` dispatch, at the `if (!res.handled)` sites: if
  `allowed` is not empty, respond 405 with
  `Allow: <methods in canonical order>`. Otherwise call `defaultNotFound()`.
- Enable the behavior only through an explicit `not_allowed` plugin or config
  setting, so existing apps keep their 404s.

**Decisions to make in the scoped issue.**

- Should `restore` clear methods recorded inside a failed alternative?
  Recommendation: no. `allowed` describes the path, not a branch. This must be
  stated next to the §3.1 checkpoint rule, which currently says checkpoints
  restore only the cursor.
- Whether `Allow` lists HEAD when GET is allowed and §3.1 fallback is enabled,
  and whether it lists OPTIONS.
- Ordering with the `not_found` and `status_handler` plugins.

**Tests.** `POST /users/42` on a GET-only route returns 405 with
`Allow: GET`. Multiple methods are listed in order. A route that does not
exist still returns 404. Without the plugin, behavior is unchanged. Nested and
failed alternatives behave as specified.

### 4.2 Named captures

**Current state.** Deferred under ADR-0001 Phase 4 (issue
[#30](https://github.com/kamalogudah/zoda/issues/30)). `onSegment()` returns a
borrowed slice that the route binds locally.

**Reopening condition (unchanged).** A concrete route cannot conveniently pass
returned segments through local bindings or function arguments.

**Required when reopened.**

- A fixed-capacity capture store on `Request`, for example
  `[N]struct { name, value }` plus a count. It must not allocate. Exceeding
  `N` is a defined error.
- Restore semantics. `mark()` must also save the capture count, and
  `restore()` must truncate back to it. This keeps captures consistent across
  failed and nested alternatives.
- Defined lookup and duplicate-name behavior. Recommendation: the innermost
  capture wins, and `getCapture(name)` returns the last match.
- Lifetimes. Values borrow from the request arena, as `onSegment()` values do
  today.

**Tests.** Lookup, duplicates, capacity overflow, `restore` truncation across
nested alternatives, and unchanged cursor semantics.

### 4.3 Runtime template loading

**Current state.** `template.render` takes `comptime source` and reflects over
the data struct at compile time (`src/template.zig`). Runtime loading falls
under ADR-0001 Phase 3.5's "later scoped extension".

**Required.**

- Split the parser. Parse the same grammar into an IR made of text, escaped
  fields, and trusted fields. Keep the current comptime entry point as a
  wrapper, so embedded templates still fail at build time.
- Add a runtime loader: `Template.load(allocator, dir, path, limits)`. It opens
  the file with the same confinement rules as `static.zig`, enforces a
  maximum source size, and reports parse errors with positions. The returned
  `Template` owns its IR and must be freed by the caller.
- Supply data at runtime. Keep `render(res, status, tmpl, data: anytype)`,
  with field lookup by name through a comptime-generated accessor for
  `@TypeOf(data)`. This avoids a dynamic value type.
- Keep the security rules. The context restrictions (no attribute, script,
  style, URL, or comment interpolation) and `TrustedHtml` raw insertion are
  checked when the template loads, not when it renders.
- Reload policy. Load once at startup in production. An optional reload in
  development may reuse `src/watch.zig`, but it must be off by default.

**Tests.** Every existing template test also passes through the runtime path,
and load-time rejection of unsupported contexts is tested. Also test missing
files, oversize sources, confinement, and freeing on every error path.

## 5. High tier

### 5.1 Response streaming

**Current state.** Responses are buffered only (ADR-0001 §4.2.5).

**Reopening conditions (unchanged).** Any one of these is accepted on the
roadmap:

- an endpoint whose body cannot be bounded in advance (SSE, long polling)
- downloads larger than a reasonable buffered limit
- proxying an upstream body

**Required: a separate ADR before any code.** It must define:

1. A new response kind, for example `StreamingResponse`, that carries a body
   producer, either a writer callback or a pull iterator. The buffered
   `Response` contract does not change.
2. Ownership of the producer and its cleanup on every exit path: success,
   error, client disconnect, and server shutdown through `Io.Group`
   cancellation.
3. Framing. Use Content-Length when the producer declares a size, and chunked
   encoding otherwise. The transport still owns framing.
4. Backpressure against slow readers, within the existing `write_timeout`
   budget. The `src/hardening.zig` slow-reader scenario must cover streaming.
5. Errors after headers are sent abort the connection. Zoda never sends a
   second status line.
6. Middleware compatibility. Plugins that read or rewrite the body
   (`http_cache` ETags, `json`, `error_handler`, `inertia`) must skip streamed
   responses or reject them explicitly.

**Transport change.** `src/transport.zig` gains a path that writes the head and
then pumps the producer. The dispatch-before-output guarantee holds only for
buffered responses, and the docs must say so.

### 5.2 Native TLS

**Current state.** Zig 0.16 `std.crypto.tls` provides only `Client` (ADR-0001
§4.2.6). No TLS server exists in the pinned toolchain.

**Options.**

- **A. Wait for `std`.** No dependency is added. Revisit when a pinned Zig
  release ships a TLS server.
- **B. A C library through interop**, such as BearSSL, s2n-tls, OpenSSL, or
  rustls-ffi. This requires its own dependency ADR covering:
  - supply-chain and update policy
  - how the build handles the library (`build.zig.zon` pinning)
  - the platform matrix in `PLATFORM.md`

**Required either way.**

- A `tls` option in `server.Config`, with certificate and key loading,
  validated at startup.
- A `std.Io.Reader`/`Writer` wrapper inserted in `ConnectionIo`
  (`src/server.zig`) beneath `transport.serveConnection`. The transport stays
  unaware of TLS.
- Handshake time counts against `header_timeout`. Failed handshakes close the
  connection without dispatch.
- ALPN advertises only `http/1.1` until §5.3 lands.
- Certificate rotation without restart is out of scope for the first cut.

**Recommendation.** Option A. Keep the reverse proxy as the supported
deployment.

### 5.3 HTTP/2

**Current state.** HTTP/1.0 and HTTP/1.1 only (ADR-0001 §4.2.6). The h2c
prior-knowledge preface is rejected with 400, and `Upgrade: h2c` is ignored.

**Reopening conditions (unchanged).** Any one of these:

- `std.http` ships an HTTP/2 server
- a maintained HTTP/2 library is proposed in its own ADR
- native TLS (§5.2) lands

**Required.**

- A new transport adapter beside `src/transport.zig`, not inside it. It must
  handle framing, HPACK, stream multiplexing, flow control,
  SETTINGS/PING/GOAWAY, and RST_STREAM.
- ADR-0001 forbids a partial in-house protocol parser, so in practice this
  means a library dependency.
- ALPN `h2` negotiation, which depends on §5.2. Browsers do not use h2c.
- Map each stream to a `RequestArena` and one dispatch. Buffered responses can
  be sent as DATA frames under flow control. Per-stream backpressure works
  best with §5.1 streaming.
- Per-connection limits: concurrent streams, header list size, and
  rapid-reset protection (CVE-2023-44487).
- Integration tests against real h2 clients such as curl `--http2` and h2load,
  plus hardening scenarios equivalent to `src/hardening.zig`.

**Recommendation.** Do not reopen until both §5.1 and §5.2 exist. Until then,
TLS and HTTP/2 terminate at a reverse proxy (nginx, Caddy, HAProxy) that
forwards HTTP/1.1 to Zoda.

## 6. Consequences

- The "unsupported" list becomes a staged roadmap with explicit gates, instead
  of a flat list of deferrals.
- Low-tier items can proceed on scoped issues alone. They keep the buffered,
  explicit-plugin contract, and existing apps see no behavior change.
- Medium-tier items each add one documented rule to existing contracts:
  - 405 changes what `restore` leaves untouched.
  - Named captures change what `mark`/`restore` save.
  - Runtime templates move the security checks to load time.
- High-tier items change the transport. Each still requires its own ADR, and
  this ADR does not pre-approve any dependency.

## 7. Follow-up

When this ADR is accepted:

1. Open scoped issues for §3.1, §3.2, and §4.1, linked to roadmap
   [#38](https://github.com/kamalogudah/zoda/issues/38).
2. Link this ADR from `SUPPORTED_API.md` (Defaults and unsupported
   capabilities) and from ADR-0001 §6.
3. Update `SUPPORTED_API.md`, the README, and `PLUGINS.md` as each capability
   ships, following [Agent.md](Agent.md).
