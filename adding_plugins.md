# Adding a Roda-inspired plugin catalog to Zoda

## Goal

Grow Zoda's small, explicit extension system into a useful catalog of opt-in
features inspired by [Roda's plugin list](https://roda.jeremyevans.net/rdoc/classes/Roda/RodaPlugins.html).
Use Roda as a source of feature ideas, not as an API compatibility target. Each
feature should fit Zoda's Zig types, ownership rules, and buffered HTTP/1.x
transport.

## Starting point

Zoda already has four extension mechanisms:

| Mechanism | Current API | Good fit |
| --- | --- | --- |
| Registered instance | A field of `Plugins`, read through `ctx.plugins.<name>` | Configured helpers such as `Json` and `Sessions` |
| Request state | `State`, `initRequest`, `deinitRequest` | Values scoped to one request, such as session data |
| Route wrapper | `wrapRoute` via `App.composeRoute(route)` | Route-local authorization, fallback handlers, route results |
| Middleware | Ordered `App.Middleware` entries | Features that must see static responses, short circuits, and the final 404 |

Current built-ins are JSON, not-found, sessions, and CSRF helpers. Timing and
static files are middleware. There is no runtime plugin loader: the application
registers plugin instances in a Zig struct at compile time. Preserve that
model; a Roda-style `register_plugin`/`load_plugin` registry would add runtime
machinery without helping Zig callers.

## Selection rules

1. Add a feature when it has a concrete use case and a small, stable API.
   Avoid one file per Roda name when several names express the same capability.
2. Choose middleware when the behavior must cover the entire dispatch chain.
   Choose a route wrapper when it belongs only to composed routes. Use a
   registered instance when routes need configured methods or request state.
3. Keep the current contract: explicit registration and access, immutable
   shared configuration, independently owned responses, bounded allocation,
   and errors that propagate unless the feature is explicitly a recovery hook.
4. Do not add a plugin that silently changes request parsing, route cursor
   semantics, transport framing, or session persistence. Such changes need a
   separate core design decision and integration tests.
5. Document composition order and name any interaction with sessions, CSRF,
   static middleware, and the default 404.

## Proposed catalog

The names below describe Zoda features; the parenthetical names point to
corresponding ideas in the [Roda catalog](https://roda.jeremyevans.net/rdoc/classes/Roda/RodaPlugins.html).

| Priority | Feature | Form | Intended behavior and dependency |
| --- | --- | --- | --- |
| 1 | Default response headers (`default_headers`) | Middleware | Set configured headers after downstream dispatch, including route misses and static responses. Define whether a route's value wins; use `Response.setHeader` and reject framing headers managed by transport. |
| 1 | Bearer token guard (`bearer_token`) | Registered instance with a route helper or wrapper | Parse one `Authorization: Bearer ...` value, reject duplicates and malformed syntax, and let application code validate the token. Do not store tokens in errors or logs. |
| 1 | Host authorization (`host_authorization`) | Middleware | Admit only configured hosts before routing or static serving. Specify `Host` parsing, ports, duplicate fields, HTTP/1.0 behavior, and trusted-proxy policy before implementation. |
| 1 | Redirect helper (`redirect_path`, `redirect_http_to_https`) | Registered helper; HTTPS redirect as middleware | Set status and `Location` safely. Restrict path redirects to local paths by default. HTTPS redirect needs an explicit trusted proxy/source-of-scheme contract. |
| 2 | Request IDs and access logging (`common_logger`, `hooks`) | Middleware | Create or validate an ID, expose it to routes, set a response header, and log one completion record. Define error-path logging and an injectable ID source. |
| 2 | Response cache policy (`caching`) | Registered helper or middleware | Provide explicit `Cache-Control`, `ETag`, and conditional GET helpers; avoid implicit caching of personalized/session responses. Define HEAD and `Vary` behavior. |
| 2 | Flash messages (`flash`) | Registered plugin using `Sessions` | Read once, mutate session state, and require an explicit `sessions.save`; specify behavior when a handler short circuits or errors. |
| 2 | JSON request parsing (`json_parser`) | Registered helper | Decode the already bounded request body into caller-owned typed data; handle invalid JSON and content type explicitly. |
| 3 | Status and error handlers (`status_handler`, `error_handler`) | Middleware or route wrapper | Map selected errors/statuses to responses with clear precedence. Recovery must clear a partial response before replacement. |
| 3 | Security response policies (`content_security_policy`, `hsts`, `permissions_policy`) | Middleware | Validate configured policy values and emit headers on the selected response classes. HSTS requires a trustworthy HTTPS signal. |
| 3 | Files and assets (`public`, `send_file`, `assets`) | Middleware/helpers | Extend the existing confined static-file code instead of duplicating path security. Asset pipelines need a separate build-time design. |

Start with a small public catalog rather than all of Roda's modules. Several
Roda entries are Ruby-specific (`erb_h`, `sinatra_helpers`, class/module
matchers) or overlap Zoda's existing router and template design. Automatic
405/`Allow` (`not_allowed`), HEAD-to-GET fallback (`head`), streaming, and
runtime template loading need core or transport decisions recorded in
`SUPPORTED_API.md`; do not promise them as simple plugins.

## First implementation milestone

Implement **default headers**, **bearer token guard**, and **host
authorization** as three separate changes. They exercise middleware,
registered helper/wrapper, and request-header validation while remaining
independent of new transport capabilities.

### 1. Default headers

- Add `src/plugins/default_headers.zig` (or `src/default_headers.zig` if its
  public API is only middleware) and export it from `src/root.zig`.
- Accept immutable caller-owned header configuration. Apply defaults after
  `next.call`, without overwriting a header set by the route. Decide and
  document repeated-field behavior; never synthesize `Content-Length`,
  `Transfer-Encoding`, or connection framing headers.
- Verify normal route, default 404, middleware short circuit, static response,
  duplicate configuration, invalid header, and response-header limit behavior.

### 2. Bearer token guard

- Add `src/plugins/bearer_token.zig` with a narrow parser and a configured
  validator interface. Keep authentication policy in application code. A route
  helper may return a typed result; an optional wrapper can map missing or
  invalid credentials to 401 and set `WWW-Authenticate`.
- Check case-insensitive header names, repeated `Authorization` fields,
  malformed scheme/spacing, oversized values, and token secrecy in failures.
  Do not accept a token from the query string.
- Demonstrate registration in `Plugins`, explicit route access, and wrapper
  order with `NotFound`.

### 3. Host authorization

- Add `src/plugins/host_authorization.zig` as middleware, registered before
  static serving and routing. Validate syntax and exact allowed-host matching;
  avoid permissive suffix matches such as accepting `example.com.evil.test`.
- Resolve the request authority contract first. The router currently carries
  headers but no normalized authority or trusted scheme. Document whether
  ports are accepted, how duplicate `Host` headers are rejected, and how
  HTTP/1.0 requests are handled. Ignore forwarded-host headers unless a
  separately configured trusted-proxy boundary is implemented.
- Exercise direct dispatch and real socket requests so transport parsing and
  middleware agree.

## Work pattern for every addition

1. Write a one-page contract: use case, public API, registration example,
   ownership, ordering, error handling, and required core changes.
2. Implement one feature per module. Export it from `src/root.zig`; add a
   focused example to `README.md` and its support status to `SUPPORTED_API.md`.
3. Add tests for success, malformed input, configured limits, interactions with
   middleware/route wrappers, and concurrent dispatch where shared state is
   involved. Put socket tests only where wire behavior matters.
4. Run `zig fmt --check build.zig src examples`, `zig build`, and
   `zig build test`. Run the existing hardening or load suites only when a
   change touches transport, static serving, resource bounds, or concurrency.
5. Add a concise catalog table to `README.md` with the feature name,
   registration form, and link to its example. Keep the detailed API beside
   the code and in `SUPPORTED_API.md`.

## Definition of done for the catalog's first release

- The three priority-1 additions above have compiling examples and documented
  public APIs.
- Users can combine them with `Json`, `Sessions`, `NotFound`, static serving,
  and timing without undocumented ordering surprises.
- Invalid headers and malformed credentials/hosts fail predictably; response
  limits and ownership rules remain enforced.
- The README catalog clearly distinguishes available features from proposed
  ones. No entry claims automatic 405 handling, streaming, or TLS support.
