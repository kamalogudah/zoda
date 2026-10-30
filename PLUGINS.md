# Zoda plugins

Detailed usage for every built-in plugin. For how the plugin system works
(registration, request state, route wrappers, and middleware), see
[Plugins in the README](README.md#plugins). Each plugin's full API is
documented beside its code in `src/plugins/`, and its support status is in
[SUPPORTED_API.md](SUPPORTED_API.md).

| Plugin | Registration | Form | Section |
| --- | --- | --- | --- |
| JSON responses | `json: zoda.Json = .{}` | Registered instance | [JSON responses](#json-responses) |
| Not-found fallback | `not_found: zoda.NotFound` + `App.composeRoute` | Route wrapper | [Not-found fallback](#not-found-fallback) |
| Bearer tokens | `bearer: zoda.BearerToken` | Registered instance, optional route wrapper | [Bearer tokens](#bearer-tokens) |
| Cookie sessions | `sessions: zoda.Sessions` | Registered instance with request state | [Cookie sessions](#cookie-sessions) |
| CSRF helpers | `zoda.plugins.csrf` functions | Helpers over session state | [CSRF helpers](#csrf-helpers) |
| Flash messages | `flash: zoda.Flash = .{}` next to `Sessions` | Registered instance over session state | [Flash messages](#flash-messages) |
| HTTP caching | `zoda.plugins.http_cache` functions | Explicit response helpers | [HTTP caching](#http-caching) |
| Request IDs and access logs | `trace: zoda.RequestTrace` + middleware entry | Registered instance with request state and middleware | [Request IDs and access logs](#request-ids-and-access-logs) |
| Status and error handlers | `zoda.plugins.status_handler` / `error_handler` middleware entries | Middleware | [Status and error handlers](#status-and-error-handlers) |
| Security response policies | `zoda.plugins.security_policy` middleware entry | Middleware | [Security response policies](#security-response-policies) |
| Inertia.js pages | `inertia: zoda.Inertia(Shared)` | Registered instance | [Inertia.js](#inertiajs) |

Core middleware that is not a plugin (host authorization, default response
headers, response timing, and static files) is documented in the
[README](README.md#middleware).

## JSON responses

`zoda.Json` is a stateless instance. `render` serializes a value with
`std.json`, replaces the status (200), body, and content type
(`application/json`), and marks the response handled. Serialization and
allocation errors propagate; the configured body limit applies.

```zig
const User = struct { id: []const u8, name: []const u8 };
const Plugins = struct { json: zoda.Json = .{} };
const App = zoda.app.App(Plugins);

fn route(ctx: *App.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    if (req.onLiteral("users")) {
        if (req.onSegment()) |id| {
            if (req.isRoot() and req.isGet()) {
                return ctx.plugins.json.render(res, User, .{ .id = id, .name = "unknown" });
            }
        }
    }
}
```

For another status, call `res.replaceJson(status, T, value)` directly. The
[compiling contract example](examples/contract.zig) uses this registration.

## Not-found fallback

For a configured text fallback, add the built-in `NotFound` plugin. It writes
only when the inner route leaves the response unhandled; a middleware short
circuit that never reaches the route still receives dispatch's default 404.

```zig
const Plugins = struct { not_found: zoda.NotFound };
const App = zoda.app.App(Plugins);

var app = try App.init(gpa, .{
    .response_allocator = gpa,
    .plugins = .{ .not_found = .{ .body = "No route matched" } },
    .route_fn = App.composeRoute(route),
});
defer app.deinit();
```

`NotFound` must be passed through `App.composeRoute`; see
[Route wrappers](README.md#route-wrappers) for wrapper order. The body is
borrowed and copied into each response.

## Bearer tokens

Register `zoda.BearerToken` with an application validator. The parser reads
only one `Authorization: Bearer <token>` field. It accepts the RFC 6750
`b64token` alphabet, rejects duplicate, malformed, and oversized credentials,
and returns a slice borrowed from the request. The plugin does not store
tokens or perform identity lookup.

```zig
const std = @import("std");
const zoda = @import("zoda");

fn validate(token: []const u8) bool {
    // Replace with application-owned validation and identity lookup.
    return std.mem.eql(u8, token, "example-token");
}

const Plugins = struct {
    bearer: zoda.BearerToken = .{ .validate = validate, .guard_routes = true },
    not_found: zoda.NotFound = .{ .body = "Not Found" },
};
const App = zoda.app.App(Plugins);

fn route(ctx: *App.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    _ = ctx;
    if (req.isLiteral("private") and req.isGet()) return res.text(200, "ok");
}

fn makeApp(gpa: std.mem.Allocator) !App {
    return App.init(gpa, .{
        .response_allocator = gpa,
        .plugins = .{},
        .route_fn = App.composeRoute(route),
    });
}

// For a selected route, leave guard_routes false and check the registered
// plugin directly before doing protected work.
fn explicitRoute(ctx: *App.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    if (req.isLiteral("private") and req.isGet()) {
        if (!ctx.plugins.bearer.authorized(req)) return ctx.plugins.bearer.unauthorized(res);
        return res.text(200, "ok");
    }
}

fn makeExplicitApp(gpa: std.mem.Allocator) !App {
    return App.init(gpa, .{
        .response_allocator = gpa,
        .plugins = .{ .bearer = .{ .validate = validate, .guard_routes = false } },
        .route_fn = explicitRoute,
    });
}
```

`guard_routes` defaults to false. With `true`, the wrapper returns 401 with
`WWW-Authenticate: Bearer` before calling the inner route on any failed
credential. The fixed response contains no token. With `NotFound` registered,
unauthenticated route misses receive 401 and authenticated misses
receive 404. Call `ctx.plugins.bearer.token(req)` when a route needs the
borrowed credential or a specific parse error. The validator must not retain
the slice. Query strings are never searched for credentials.

## Cookie sessions

Register `zoda.Sessions` as a plugin instance. Supply a trusted UTC Unix-second
clock, a lifetime from 1 second to 30 days, and one or more application-owned
keys of at least 32 cryptographically random bytes. The first key signs new cookies; older keys remain
available for verification during rotation. Key IDs must be unique.

```zig
const Plugins = struct { sessions: zoda.Sessions };

// `unixSeconds` is the application's trusted wall-clock function. Keep the
// secret bytes alive for the app lifetime; load them from secure configuration.
const plugins = Plugins{ .sessions = .{
    .keys = &.{.{ .id = 1, .secret = app_secret }},
    .lifetime_seconds = 3600,
    .now_seconds = unixSeconds,
} };

// Inside a route or middleware:
try ctx.state.sessions.set("user=42");
try ctx.plugins.sessions.save(&ctx.state.sessions, res); // before returning
// Read with ctx.state.sessions.value(); call clear() and save() to delete.
```

The cookie is `__Host-zoda_session=v1.<key-id>.<expiry>.<base64url-payload>.<base64url-HMAC-SHA256>`
until a CSRF token is issued. It then uses
`v2.<key-id>.<expiry>.<base64url-payload>.<base64url-CSRF-secret>.<base64url-HMAC-SHA256>`.
While flash messages are pending it uses
`v3.<key-id>.<expiry>.<base64url-payload>.<base64url-CSRF-secret-or-empty>.<base64url-flash>.<base64url-HMAC-SHA256>`.
The MAC covers every field before it. Invalid, expired,
oversized, or duplicate session cookies load as an empty session. Payloads are
limited to 2,048 bytes and cookie values to 4,096 bytes. Signing authenticates
contents but **does not make them confidential**; do not put secrets in the
payload. A copied cookie can be replayed until its expiry. Removing a key stops
accepting cookies signed by that key.

`save` appends a separate `Set-Cookie` field with `Path=/; Secure; HttpOnly;
SameSite=Lax` and `Max-Age` set to the configured lifetime. The `__Host-`
prefix requires HTTPS and prevents a Domain attribute. `clear` followed by
`save` appends a deletion cookie. Unsaved changes are discarded when the request
ends; cleanup is infallible and never writes a response. The route or
middleware decides when to persist, including on short circuits. Configure
CSRF protection before using cookie sessions for state-changing requests.
If a route fails after `save`, a propagated error discards its partial response.
Recovery middleware can call `res.clear()` and then explicitly `save` the
recovered session; cleanup never creates or restores a cookie.

## CSRF helpers

Use `zoda.plugins.csrf` with a registered `zoda.Sessions` instance. On a GET
that renders a form, issue a token from `ctx.state.sessions`, put it in the
form, and explicitly save the session before returning the response. The first
issue upgrades an existing v1 session to a v2 cookie containing a random
32-byte CSRF secret. The opaque application payload stays separate. A cleared
session invalidates its token. Existing v1 cookies still load normally.

```zig
const csrf = zoda.plugins.csrf;

// GET /form, inside a route with registered `sessions` plugin:
const issued = try csrf.token(io, &ctx.state.sessions);
try ctx.plugins.sessions.save(&ctx.state.sessions, res);
try res.text(200, issued); // render as a hidden form field or pass to client code

// POST /submit, before any protected action:
if (!csrf.valid(req, &ctx.state.sessions)) return res.text(403, "forbidden");
try performProtectedAction();
```

`io` is the application's `std.Io`; token creation uses
`std.Io.randomSecure` and can fail if secure entropy is unavailable. For
JavaScript submissions, send the token in one `X-CSRF-Token` header, or read
another header with `csrf.validHeader(req, state, name)`. For HTML
forms, extract exactly one token field and call `csrf.validToken`; reject
duplicate fields. Missing, malformed, duplicate-header, and cross-session
tokens fail validation. The token is stable until the session is cleared; do
not put it in a URL or log. Protect every state-changing route, including
unsafe GET routes if the application has any. Keep the secure cookie and HTTPS
policy above, and do not allow untrusted cross-origin requests to send the
custom header through permissive CORS. The [compiling app dispatch example](src/plugins/csrf.zig)
exercises explicit plugin access, session persistence, and rejection before
the protected action.

### XSRF-TOKEN cookie (Inertia, axios)

Inertia's HTTP client and axios read a cookie named `XSRF-TOKEN` and send its
value back as `X-XSRF-TOKEN` on same-origin requests. To use that, set the
cookie when you issue the token and validate that header:

```zig
// On every page render, before `sessions.save`:
try csrf.setXsrfCookie(res, try csrf.token(io, &ctx.state.sessions));

// Before any protected action:
if (!csrf.validHeader(req, &ctx.state.sessions, csrf.xsrf_header_name)) return res.text(403, "forbidden");
```

`setXsrfCookie` writes `XSRF-TOKEN=<token>; Path=/; Secure; SameSite=Lax`
and refuses anything that is not a `token` value (`error.InvalidToken`).
Only `xsrf_header_name` is read, and a repeated header fails like a repeated
`X-CSRF-Token`. Trade-offs:

- **No `HttpOnly`.** Script on the page has to read the cookie, so any script
  that runs on your origin, including injected script, can read the token.
  That is no weaker than a token in the page, but keep XSS defenses (such as
  [`security_policy`](#security-response-policies)) in place.
- **The session decides.** The token is checked against the secret in the
  signed `__Host-` session cookie, not against this cookie. A sibling
  subdomain that overwrites `XSRF-TOKEN` can only make requests fail.
- **`Secure` and `SameSite=Lax`.** The cookie is sent over HTTPS only
  (browsers also accept it on `http://localhost`), and not on cross-site
  subrequests. Other origins cannot read it, which is what makes copying it
  into a header a proof of same-origin script.
- **Lifetime.** It has no `Max-Age`, so it ends with the browser session.
  Set it on every page so a browser that dropped it gets it back. After the
  session cookie expires or the key rotates out, the old token fails until
  the page reloads and issues a new one.

The [Inertia example](examples/inertia/server.zig) protects every change
this way.

## Flash messages

Register `zoda.Flash` next to `zoda.Sessions`. Messages live in the signed
session cookie. Like other session changes, they persist only through an
explicit `sessions.save`.

```zig
const Plugins = struct { sessions: zoda.Sessions, flash: zoda.Flash = .{} };

// POST /items: queue a message for the next request, save, and redirect.
try ctx.plugins.flash.add(&ctx.state.sessions, "notice", "Item created");
try ctx.plugins.sessions.save(&ctx.state.sessions, res);
return res.redirectPath(.see_other, "/");

// GET /: read what this request received, then save to consume it.
var messages = ctx.plugins.flash.read(&ctx.state.sessions);
while (messages.next()) |message| {
    // message.kind and message.text are borrowed until the request ends;
    // copy them into the response and escape them for HTML.
}
try ctx.plugins.sessions.save(&ctx.state.sessions, res);
```

- **Read once.** `read` returns the messages loaded with this request, in the
  order they were added, and marks them consumed. Calling it again in the same
  request returns the same messages. The next saved cookie drops them. If the
  request does not save, the browser keeps its old cookie and shows the
  messages again. Reading an empty flash does not dirty the session.
- **Next request.** `add` queues a message for the next request that loads the
  saved cookie. A saved cookie holds unread received messages first, then
  queued ones. A request that saves without calling `read` therefore keeps
  pending messages for a later page.
- **Limits.** Kinds are 1–32 bytes of ASCII letters, digits, `_`, or `-`.
  Text is arbitrary bytes. A session holds at most 8 messages and 512 encoded
  bytes (3 bytes of framing plus kind and text per message). Unread received
  messages count toward both limits. `add` returns `error.InvalidFlashKind`,
  `error.TooManyFlashMessages`, or `error.FlashTooLarge` and leaves the
  session unchanged.
- **Short circuits and errors.** An unsaved short circuit neither consumes
  nor queues anything. A propagated error discards the response, including
  any saved cookie. Request state is not rolled back, so recovery middleware
  that saves would also persist the failed handler's flash changes. Call
  `flash.reset` first to restore the received messages and drop queued ones:

  ```zig
  next.call(ctx, req, res) catch {
      res.clear();
      ctx.plugins.flash.reset(&ctx.state.sessions);
      try ctx.plugins.flash.add(&ctx.state.sessions, "alert", "Something went wrong");
      try ctx.plugins.sessions.save(&ctx.state.sessions, res);
      return res.text(503, "unavailable");
  };
  ```
- **Inertia.** `Inertia.renderWith(..., .{ .flash = ... })` sends the
  received messages as the page's top-level `flash`; see
  [Inertia.js flash](#flash). `Inertia.redirectWithErrors` stores
  validation errors as one message of the reserved kind `inertia-errors`;
  see [Validation errors](#validation-errors).
  `Inertia.clearHistoryOnNextRender` stores one of the reserved kind
  `inertia-clear-history`; see [History encryption](#history-encryption).
  `peek` returns the received messages without
  consuming them, for integrations that `read` only once they have sent
  them.
- **Clearing.** `clear` drops received and queued messages. `add` after `clear`
  keeps a cookie with an empty payload, so a logout page can still show a
  notice.
- **Not confidential.** Flash contents are signed, not encrypted, so the
  client can read them. Do not flash secrets. Tampered, expired, or malformed
  cookies load an empty session with no messages. Cleanup never writes a
  cookie.

The [compiling example](examples/contract.zig) registers both plugins and
round-trips a message through POST, redirect, and GET.

## HTTP caching

`zoda.plugins.http_cache` provides explicit helpers; nothing is registered and
no policy is applied by default. A route without a `Cache-Control` call sends
none. Build the full 2xx response, set its policy, validator, and `Vary`, save
any session, then call `evaluate` last:

```zig
const http_cache = zoda.plugins.http_cache;

if (req.isLiteral("report") and (req.isGet() or req.method == .head)) {
    try res.text(200, report_text);
    try http_cache.setCacheControl(req, res, .{ .private = .{ .no_cache = true } });
    try http_cache.setBodyETag(res); // or .setETag(res, .strong("v42"))
    try http_cache.addVary(res, "Accept-Encoding");
    _ = try http_cache.evaluate(req, res); // .full or .not_modified
    return;
}
```

Policies are `.no_store`, `.private`, and `.public`, with optional `max_age`,
`no_cache`, `must_revalidate`, and `immutable`; `public` also takes
`s_maxage`. Lifetimes above 2147483648 seconds and a second `Cache-Control`
are rejected. `public` is refused when the response already has `Set-Cookie`.
It is also refused when the request carries `Authorization` or `Cookie`,
unless the route sets `.allow_credentials = true` to state that the body does
not depend on them. Choose `.private` or `.no_store` for session and other
personalized pages. Call `setCacheControl` after `sessions.save` so the
`Set-Cookie` check can see the cookie.

`setETag` takes a strong or weak tag of at most 128 visible ASCII bytes
without `"`. `setBodyETag` derives a strong tag from the content type and
body. `addVary` adds one field name once, case-insensitively across repeated
`Vary` fields, and refuses `*` (use `.no_store`).

`evaluate` checks `If-None-Match` only on handled GET and HEAD 2xx responses.
Comparison is weak, so `W/"v1"` and `"v1"` match. Repeated fields form one
list, empty list elements are accepted, and `*` matches only as the sole
member. A malformed request field voids the whole condition and sends the
full response. When the condition matches, the response becomes `304 Not
Modified`. It keeps every header (`ETag`, `Cache-Control`, `Vary`,
`Set-Cookie`) and drops its body and content type. The transport sends a 304
with no `Content-Length`, `Content-Type`, or body, and keeps the connection
open. HEAD has no GET fallback, so answer it explicitly. A 200 HEAD response
still reports the representation's `Content-Length`. Other methods are left
unchanged; check their preconditions before acting. `If-Modified-Since`,
`If-Match`, and ranges are not supported.

## Request IDs and access logs

Register `zoda.RequestTrace` as a plugin and add
`zoda.plugins.request_trace.middleware(App, "trace")` as the first middleware
entry. The second argument is the plugin's field name. Each request gets an ID
before any middleware runs, stored in request-local state. Routes read it with
`ctx.state.trace.id()`. Every completed response gets an `X-Request-Id` header,
and the sink receives exactly one `Record` per dispatch.

```zig
fn writeAccess(_: *anyopaque, r: zoda.plugins.request_trace.Record) void {
    std.log.info("id={s} method={t} path={s} status={?d} ms={d} failed={}", .{
        r.id, r.method, r.path, r.status, r.duration_ms, r.failed,
    });
}

const Plugins = struct { trace: zoda.RequestTrace };
const App = zoda.app.App(Plugins);

var app = try App.init(gpa, .{
    .response_allocator = gpa,
    .plugins = .{ .trace = .{
        .source = .{ .io = io }, // 16 bytes from std.Io.randomSecure, hex-encoded
        .incoming = .accept_valid, // default .ignore always generates
        .clock = .monotonic(io),
        .sink = .{ .context = undefined, .write = writeAccess },
    } },
    .route_fn = route,
    .middleware = &.{ zoda.plugins.request_trace.middleware(App, "trace"), zoda.timing.middleware(App) },
});
```

The [compiling contract example](examples/contract.zig) uses the same
registration.

- **Incoming IDs.** With `.accept_valid`, the plugin accepts exactly one
  `X-Request-Id` value of 1–64 bytes containing only `[A-Za-z0-9_-]`. A missing,
  repeated, empty, oversized, or malformed value is discarded and a new ID is
  generated. With `.ignore` (the default), the plugin always generates an ID.
- **Record fields.** A `Record` has `id`, `method`, `path` (the target without
  its query string), `status`, `duration_ms`, and `failed`. Its slices are valid
  only during the sink call. Records never include headers, cookies, query
  strings, or bodies, so bearer tokens and session values cannot be logged.
- **Completion.** Timing is measured around everything downstream of the entry.
  A route miss or a silent short circuit is recorded as the same 404 that
  dispatch would send. A short circuit that writes a response is recorded with
  its own status. If anything downstream returns an error, the record has
  `status = null` and `failed = true`, the error propagates unchanged, and no
  header is added.
- **Ordering.** Register this entry before timing, static files, host or
  bearer authorization, and any error-recovery middleware. It then sees their
  final statuses, and recovered errors are logged as the response the recovery
  middleware wrote. An entry placed before it never gets a record when it
  short-circuits.
- **Concurrency.** The ID lives in per-request state, with no shared mutable
  data. A custom `IdSource.custom` and the sink are called from concurrent
  requests, so both must be thread-safe. Sinks cannot fail; handle write errors
  inside the callback.

## Status and error handlers

Two middleware entries replace selected responses and recover errors.
`zoda.plugins.status_handler` runs a configured handler for selected 4xx or
5xx statuses. `zoda.plugins.error_handler` catches errors from the rest of the
chain, clears the partial response, and writes a replacement.

```zig
const status_handler = zoda.plugins.status_handler;
const error_handler = zoda.plugins.error_handler;

fn notFoundPage(_: *App.Context, _: *zoda.router.Request, res: *zoda.response.Response) !void {
    try res.text(404, "Page not found");
}

fn serverErrorPage(_: *App.Context, _: *zoda.router.Request, res: *zoda.response.Response) !void {
    try res.text(500, "Something went wrong");
}

fn logError(_: *App.Context, req: *zoda.router.Request, _: *zoda.response.Response, err: anyerror) !void {
    std.log.err("{s} failed: {t}", .{ req.target, err });
    // Writing nothing leaves the generated 500 for the status handler.
}

// Both configs are borrowed and must outlive the app.
const pages = status_handler.Config(App){ .handlers = &.{
    .{ .status = 404, .run = notFoundPage },
    .{ .status = 500, .run = serverErrorPage },
} };
const recovery = error_handler.Config(App){ .handler = logError };

var app = try App.init(gpa, .{
    .response_allocator = gpa,
    .plugins = .{},
    .route_fn = route,
    .middleware = &.{
        try status_handler.middleware(App, &pages), // validates the config
        error_handler.middleware(App, &recovery),
        zoda.static.middleware(App, &static_config),
    },
});
```

The [compiling contract example](examples/contract.zig) uses the same
registration and checks each outcome below.

- **Precedence.** For one request, from innermost to outermost:
  1. The route (or a route wrapper such as `NotFound`) writes a response.
  2. If the response is still unhandled, dispatch writes the default
     `404 Not Found` before middleware unwinds.
  3. If anything downstream fails, `error_handler` clears the partial response
     and writes its replacement.
  4. `status_handler` replaces a response whose status it selects, but only
     when the body is empty or framework-generated. The default 404 and the
     recovery 500 are generated; a body written by a route, `NotFound`, static
     files, or middleware is not, so it wins. For example, `res.text(404, "")`
     is replaced and `res.text(404, "this report was removed")` is kept.
     `Response.generated` reports which case applies.
- **Coverage.** Each entry covers only what runs after it: inner middleware,
  static files, route wrappers, the route, and the default 404. A silent inner
  short circuit is turned into the generated 404 and handled. A short circuit
  or error in an entry registered before these is not covered, and dispatch's
  final 404 after an outer short circuit is not handled.
- **Order between the two.** Put `status_handler` outside `error_handler`, as
  above, to render one error page for both recovered errors and error statuses.
  Its own handler errors then propagate to the transport, which sends a
  generic 500. Put it inside to have `error_handler` recover status-handler
  failures; the recovery 500 is then not styled.
- **Status handlers.** A handler has the route signature. It receives the
  matched response with its status and headers. Writing with `text`,
  `replaceJson`, or another helper replaces the body, status, and content
  type and keeps headers such as `WWW-Authenticate`. Writing nothing keeps the
  matched response. Handlers run once and are not re-matched against the
  status they write. Only distinct statuses from 400 to 599 are accepted, so
  redirects and bodyless 1xx, 204, and 304 responses are never replaced.
  Errors from downstream propagate without running a status handler.
- **Recovery.** `error_handler` calls `res.clear()` before the handler, so
  nothing from the failed attempt survives: no partial body, status, or
  headers, including `Set-Cookie`. A handler that needs a session change must
  make it again (for example `Flash.reset` and a save). If the handler writes
  nothing, or none is configured, the response is a generated
  `500 Internal Server Error`. Errors from the handler propagate. Middleware
  outside the entry sees a recovery as a success, so its post-processing runs.
- **Errors that are not recovered.** By default, `error.OutOfMemory`,
  `error.Canceled`, and the transport failures `ReadFailed`, `WriteFailed`,
  `BrokenPipe`, `ConnectionResetByPeer`, and `ConnectionTimedOut` propagate
  unchanged (`error_handler.default_passthrough`). Set `passthrough` to your
  own list, or to `&.{}` to recover every error.
- **Other middleware.** Register `RequestTrace` and timing before both entries
  so they record the final response. Register `default_headers` before them so
  replacement pages also get the default headers.

## Security response policies

`zoda.plugins.security_policy` adds `Content-Security-Policy`,
`Content-Security-Policy-Report-Only`, `Permissions-Policy`, and
`Strict-Transport-Security` to responses. Nothing is sent unless you configure
it, and every policy is validated when the middleware entry is created.

```zig
const security_policy = zoda.plugins.security_policy;

/// This app listens only on a loopback port that the TLS terminator reaches,
/// so every request it receives arrived over HTTPS.
fn behindTlsTerminator(_: *App.Context, _: *const zoda.router.Request) bool {
    return true;
}

// Borrowed with its strings; must outlive the app.
const policies = security_policy.Config(App){
    .content_security_policy = .{ .value = "default-src 'self'; frame-ancestors 'none'" },
    .permissions_policy = .{ .value = "camera=(), geolocation=(), microphone=()" },
    .hsts = .{ .max_age = 31536000, .include_subdomains = true, .https = behindTlsTerminator },
};

var app = try App.init(gpa, .{
    .response_allocator = gpa,
    .plugins = .{},
    .route_fn = route,
    .middleware = &.{
        try security_policy.middleware(App, &policies), // validates the config
        try zoda.default_headers.middleware(App, &defaults),
        try status_handler.middleware(App, &pages),
        error_handler.middleware(App, &recovery),
        zoda.static.middleware(App, &static_config),
    },
});
```

The [compiling contract example](examples/contract.zig) uses the same
policies and checks the headers on a route and on the default 404.

- **Validation.** `middleware` returns a `ConfigError` instead of an entry
  when the configuration is wrong:
  - `content_security_policy` and `content_security_policy_report_only` take
    one serialized CSP policy: `;`-separated directives whose names are
    letters, digits, and `-`, and whose values are printable ASCII. A `,`
    (a policy list), control bytes, non-ASCII bytes, no directive at all, or a
    repeated directive name is rejected. Both fields may be set together, to
    enforce one policy and trial a stricter one.
  - `permissions_policy` takes a structured-field dictionary of lowercase
    `feature=allowlist` members, where the allowlist is `*`, `self`, a quoted
    origin, or a list of those in parentheses, such as
    `geolocation=(self "https://maps.example")`. A bare `feature`, malformed
    syntax, or a repeated feature is rejected.
  - `hsts.preload` requires `include_subdomains` and a `max_age` of at least
    one year (`min_preload_max_age`). `max_age = 0` is allowed, to tell
    browsers to forget an earlier policy.
  - A configuration with no policy, or a policy whose `classes` select no
    responses, is rejected.
  - The configured fields together must fit `limits` (`response.Limits`, the
    default used by `App.dispatch`), or `TooManyHeaders` or
    `HeaderBytesExceeded` is returned.
- **Response classes.** Each policy has `classes`, a `ResponseClasses` with
  `success` (1xx–2xx, including static-file hits), `redirection` (3xx,
  including 304), `client_error` (4xx, including the default 404), and
  `server_error` (5xx, including the recovery 500). All four are on by
  default. A response left unhandled by a middleware short circuit counts as
  a client error, because dispatch turns it into the default 404.
- **HSTS needs an HTTPS signal.** `hsts.https` is required and has no
  default. The header is sent only when it returns true for the request. Zoda
  does not terminate TLS, and this middleware never reads `X-Forwarded-Proto`
  or `Forwarded`, because a client can send them. Return true only when you
  can trust the answer: for example, when the listener is reachable only
  through your TLS terminator, or when the terminator adds a secret header
  that it strips from client requests and the signal checks it. Browsers
  ignore HSTS received over plain HTTP, so an HTTP-to-HTTPS redirect needs no
  HSTS.
- **Existing fields win.** A field the response already has, set by the route
  or by an inner middleware entry, is kept and not repeated. The check uses
  the exact field name, so a route's `Content-Security-Policy` does not stop
  the report-only header.
- **Limits.** Before adding anything, the entry checks that every selected
  field fits the response's header count and byte limits. If they do not, it
  adds none of them and returns `error.TooManyHeaders` or
  `error.HeaderBytesExceeded`, which propagates like any other error.
- **Middleware order.** The entry adds headers after downstream succeeds, so
  it covers only entries registered after it. Register it before
  `zoda.static`, `error_handler`, and `status_handler` so static files,
  recovered errors, and error pages get the policies, as above. An error that
  propagates past it (for example with no `error_handler` inside it) gets no
  policy headers.
- **With `default_headers`.** Both entries keep existing fields, so when both
  configure the same field, the inner entry's value wins. Configure each field
  in one place. Use `default_headers` for fields this middleware does not
  manage, such as `X-Frame-Options` or `Referrer-Policy`.
- **Sessions and caching.** The policies do not depend on the request, except
  for the HSTS signal, and do not touch `Set-Cookie`, `Cache-Control`, or
  `Vary`.

## Inertia.js

`zoda.Inertia(SharedProps)` renders [Inertia.js](https://inertiajs.com/)
pages, inspired by [inertia-roda](https://github.com/holamendi/inertia-roda).
It is a registered instance with no request state and no route wrapper: the
route picks the component, passes a props struct, and calls the instance
explicitly. Ordinary route dispatch is unchanged.

```zig
const Shared = struct { app_name: []const u8 };
const Plugins = struct { inertia: zoda.Inertia(Shared) };
const App = zoda.app.App(Plugins);

const layout =
    \\<!doctype html>
    \\<html><head><script type="module" src="/assets/app.js"></script></head>
    \\<body>@inertia</body></html>
;

fn route(ctx: *App.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    const inertia = &ctx.plugins.inertia;
    if (req.onLiteral("users")) {
        if (!req.isRoot()) return;
        if (req.isGet()) return inertia.render(req, res, "Users/Index", .{ .users = &[_][]const u8{"ada"} });
        if (req.method == .post) return inertia.redirect(req, res, "/users");
    }
}

// .plugins = .{ .inertia = .{
//     .layout = layout,
//     .version = .{ .value = "1" },
//     .shared = .{ .value = .{ .app_name = "Zoda" } },
// } },
```

The [compiling contract example](examples/contract.zig) uses this
registration. For a complete app with React, Svelte, and Vue frontends, see
[the Inertia todo example](examples/inertia/README.md). Call `app.plugins.inertia.validate()` at startup to catch a bad
layout or root id before the first request; `render` checks again.

### Configuration

| Field | Default | Meaning |
| --- | --- | --- |
| `layout` | required | Full HTML document with the `@inertia` marker exactly once, and optionally `@inertiaHead` once before it for server-rendered head tags (removed without SSR). It holds your asset tags and is copied verbatim. Zoda loads no templates at runtime. |
| `root_id` | `"app"` | `id` of the generated root element; 1–64 `[A-Za-z0-9_-]` bytes. |
| `initial_page` | `.script` | `.script` for Inertia v3 clients, `.attribute` for v1 and v2. See below. |
| `version` | `.none` | `.value = "..."` or `.callback = fn (*const Request) []const u8`. `.none` sends `"version":null` and skips version checks. |
| `shared` | `.none` | `.value = SharedProps{...}`, `.callback = fn (*const Request) SharedProps`, or `.fromContext(App.Context, fn (*App.Context, *const Request) SharedProps)` for props built from request state (see [Shared props from request state](#shared-props-from-request-state)). Use `zoda.Inertia(struct {})` for no shared props. |
| `now_milliseconds` | `null` | Trusted UTC Unix-millisecond clock, `fn () i64`, for once props with an expiry. See [Once props](#once-props). |
| `encrypt_history` | `false` | Sends `encryptHistory: true` on every page; `renderWith` can override it per page. See [History encryption](#history-encryption). |
| `ssr` | `null` | `zoda.plugins.inertia.Ssr` settings to render full visits through an SSR server. See [Server-side rendering](#server-side-rendering). |
| `on_ssr_failure` | `null` | `fn (*const Request, SsrFailure) void`, called before each fallback to client rendering. |

### Responses

- **`render(req, res, component, props)`** builds the page object
  `{"component", "props", "url", "version"}`. `props` must be a struct.
  Shared props come first and a route prop with the same name replaces the
  shared one (checked at comptime). The status is 200; `renderWith` can
  choose another (see [Per-render options](#per-render-options)).
  - Without `X-Inertia`, the response is `text/html; charset=utf-8`: the
    layout with `@inertia` replaced by the initial page. With the default
    `.script`, the form Inertia v3 reads, that is
    `<script data-page="app" type="application/json">{...}</script><div id="app"></div>`.
    The JSON writes `<`, `>`, and `&` as `\u003c`, `\u003e`, and `\u0026`,
    so no prop value can close the script element. With `.attribute`, for
    v1 and v2 clients, it is `<div id="app" data-page="..."></div>` and the
    JSON is escaped for a double-quoted attribute (`&`, `<`, `>`, `"`, `'`).
  - With `X-Inertia: true`, the body is the page object as
    `application/json`, with `X-Inertia: true`.
  - Both add `Vary: X-Inertia` unless a `Vary` field already lists it.
  - On an Inertia **GET** with a configured version, a different
    `X-Inertia-Version` returns `409` with an empty body and
    `X-Inertia-Location` set to the current URL. Ordinary visits and non-GET
    Inertia requests are never sent a conflict. A missing field counts as
    the empty version, because the client leaves it out when the page
    version is empty; so an empty configured version never causes a reload
    loop. The check runs inside `render`, so a route that redirects instead
    does not run it.
  - `props.errors` is always an object: a route `errors` prop wins, then
    errors stored by `redirectWithErrors` (with `renderWith`'s `.flash`
    option; see [Validation errors](#validation-errors)), then a configured
    shared `errors`, and otherwise the plugin adds `errors: {}`, as the
    Laravel adapter does.
  - With shared props configured, the page also lists their names in
    `sharedProps`. v3 clients use it to keep shared props during instant
    client-side visits.
  - On an Inertia visit with `X-Inertia-Partial-Component`, only some props
    are sent; see [Partial reloads](#partial-reloads).
  - Props wrapped in `deferred` are left out of the first response and
    listed in `deferredProps`; see [Deferred props](#deferred-props).
  - Props wrapped in `merge`, `prepend`, or `deepMerge` are listed in
    `mergeProps`, `prependProps`, or `deepMergeProps` so a partial reload
    adds to them; see [Merge props](#merge-props).
  - Props wrapped in `scroll` are merge props with pagination state in
    `scrollProps`, for `<InfiniteScroll>`; see [Scroll props](#scroll-props).
  - Props made with `once` are listed in `onceProps` and not resolved again
    while the client holds them; see [Once props](#once-props).
  - Nested empty values need a named type: in Zig an empty `.{}` literal is
    a tuple and serializes as `[]`. Pass a named empty struct such as
    `struct {}{}` for an empty nested object. Tuples with values are a
    compile error as `props`.
- **`redirect(req, res, path)`** sends a local path under the
  `Response.redirectPath` rules: 302 after GET/HEAD and 303 after POST, PUT,
  PATCH, DELETE, or any other method, so the client follows with GET.
  External URLs are refused with `error.InvalidRedirectPath`. XHR drops the
  `#fragment` of a redirect it follows, so for an Inertia request to a path
  with `#`, `redirect` sends `409` with `X-Inertia-Redirect` and an empty
  body. The v3 client then visits that URL with GET and keeps the fragment.
  Ordinary requests always get a `Location` redirect. `redirect` reads
  `X-Inertia`, so a malformed one is an error here too.
- **`location(req, res, destination)`** forces a full page load, for example to
  an external payment page or a non-Inertia route. It accepts a local path or
  an absolute `http`/`https` URL with a host, without userinfo (`@`),
  backslashes, spaces, controls, or bad percent escapes. An Inertia request
  gets 409, `X-Inertia-Location`, and `Vary: X-Inertia`; any other request
  gets a 302/303 `Location`.
- **`redirectWithErrors(req, res, source, path, errors)`** stores validation
  errors in the session and redirects back with 303; see
  [Validation errors](#validation-errors).

### Partial reloads

`router.reload({ only: [...] })` and `except: [...]` send
`X-Inertia-Partial-Component` with `X-Inertia-Partial-Data` (only) and/or
`X-Inertia-Partial-Except`. `render` honors them like the Laravel adapter:

- They apply only to Inertia visits whose `X-Inertia-Partial-Component`
  equals the component being rendered. Any other visit gets the full page.
  Ordinary HTML visits ignore the headers.
- `-Data` keeps only the listed props, `-Except` removes the listed props,
  and when both are sent `-Except` wins. A component header with no list
  sends every prop, including `optional` ones.
- Shared props are filtered the same way. `errors` is always sent, and
  `sharedProps` still names every shared prop.
- Filtering is top-level only. A dot path such as `user.name` in `-Data`
  keeps the whole `user` prop; in `-Except` it removes nothing. So the
  server never sends less than was asked for, and the client merges the
  result into its current props.

Plain values are computed by the route before `render` is called; a partial
reload only skips serializing them. Wrap expensive values so they are never
computed unless sent:

```zig
const Report = struct {
    fn totals(ids: []const u32, allocator: std.mem.Allocator) error{OutOfMemory}![]u32 {
        const sums = try allocator.alloc(u32, 1);
        sums[0] = 0;
        for (ids) |id| sums[0] += id;
        return sums;
    }
};

return ctx.plugins.inertia.render(req, res, "Reports/Index", .{
    .ids = ids,
    // Resolved only when a partial reload asks for `totals`.
    .totals = zoda.plugins.inertia.optional(ids, Report.totals),
    // Sent on every visit, even `only: ['totals']`.
    .notice = zoda.plugins.inertia.always("ready"),
});
```

- **`optional(context, resolve)`** returns an `Optional(Context, resolve)`
  prop. `resolve` is `fn (Context, std.mem.Allocator) T` or `... E!T`.
  It is left out of full visits and called at most once, during `render`,
  only when a partial reload keeps the prop (listed in `-Data`, or not
  excluded when only `-Except` is sent). `allocator` is an arena owned by
  `render` and freed once the page is serialized, so the result may live
  there or borrow from `context`. Pass a pointer as `context` for state and
  `{}` for none. Keep in mind that it runs inside `render`: do not take a
  lock there that the route already holds.
- **`always(value)`** returns an `Always(T)` prop that is sent on every
  visit, whatever the lists say.
- **Errors.** An error from `resolve` is returned by `render` unchanged and
  leaves the response untouched. `render`'s error set is
  `Inertia(S).Error(@TypeOf(props))`: the plugin errors plus those of every
  `optional`, `deferred`, and `once` route and shared prop.
- **Shared props.** Fields of `SharedProps` may use the same wrappers, for
  example `stats: zoda.plugins.inertia.Optional(*Stats, Stats.compute)` and
  `auth: zoda.plugins.inertia.Always([]const u8)`, initialized as
  `.{ .value = "..." }`.
- **Headers.** Each list (including `X-Inertia-Reset`; see
  [Merge props](#merge-props)) holds 1 to `max_partial_props` (64)
  comma-separated names in at most `max_partial_bytes` (1024) bytes; larger
  lists return `error.PartialHeaderTooLarge`. A name is one or more
  non-empty `.`-separated segments of `[A-Za-z0-9_$-]`; an empty item,
  whitespace, or any other byte returns `error.MalformedPartialHeader`.
  A repeated `X-Inertia-Partial-*`, `X-Inertia-Reset`, or
  `X-Inertia-Infinite-Scroll-Merge-Intent` field returns
  `error.DuplicatePartialHeader`. On Inertia visits all five are checked
  even when the component does not match (the merge intent rules are under
  [Scroll props](#scroll-props)). These failures leave the response
  unchanged.
- **Caching.** Partial and full responses share `Vary: X-Inertia`; no
  `Vary` is added for the partial headers, so do not let a shared cache
  store Inertia JSON responses.

### Deferred props

A deferred prop is left out of the first response, so the page renders
without waiting for it, and the client fetches it right after with a partial
reload. The v3 client components render a fallback meanwhile:

```zig
return ctx.plugins.inertia.render(req, res, "Dashboard", .{
    .user = user,
    // Both load in one follow-up request for the "default" group.
    .stats = zoda.plugins.inertia.deferred(store, Stats.compute),
    .totals = zoda.plugins.inertia.deferred(ids, Report.totals),
    // A separate group is fetched with its own request, in parallel.
    .feed = zoda.plugins.inertia.deferredGroup("social", store, Feed.load),
});
```

```jsx
<Deferred data="stats" fallback={<p>Loading…</p>}>
  {() => <Stats {...stats} />}
</Deferred>
```

- **Full visits.** The HTML shell and full Inertia JSON visits leave
  deferred props out of `props` without calling `resolve`, and add
  `"deferredProps": {"default": ["stats", "totals"], "social": ["feed"]}`
  after `version`. Groups appear in the order their first prop is declared,
  shared props first. With no deferred props the field is left out. A
  partial reload for another component counts as a full visit.
- **Loading.** For each group the client sends a partial reload with
  `X-Inertia-Partial-Data` set to that group's names. `render` resolves
  deferred props exactly as it resolves `optional` ones, so `-Data`,
  `-Except`, and a bare component header behave as described above, and
  `resolve` runs only for the props a reload keeps.
- **Partial reloads never send `deferredProps`.** The values a reload asks
  for are sent; the others stay unsent and unlisted, so the client does not
  start another round. This matches the Laravel adapter.
- **`deferred(context, resolve)`** returns a
  `Deferred("default", Context, resolve)` prop and
  **`deferredGroup(group, context, resolve)`** a `Deferred(group, ...)`
  one. `resolve` follows the `optional` rules: same signature, arena,
  error propagation, and the same warning about locks the route holds. The
  group is comptime: 1-64 `[A-Za-z0-9_-]` bytes, checked at compile time.
- **Shared props.** A `SharedProps` field may be deferred, for example
  `notifications: zoda.plugins.inertia.Deferred("default", *Store, Notes.count)`.
  It is listed only when shared values are configured and no route prop of
  the same name overrides it.
- **Rules checked at compile time.** `errors` cannot be deferred. A
  deferred prop's name must be non-empty `[A-Za-z0-9_$-]`, since the client
  sends it back in `X-Inertia-Partial-Data`. `always` takes a plain value,
  so `always(deferred(...))` is rejected; wrappers do not nest.
- **Request headers.** Deferred loading adds no headers of its own; the
  partial-reload header rules and errors apply unchanged.

### Merge props

A merge prop is added to the value the client already has instead of
replacing it, for "load more" lists and infinite feeds. The client merges
only on a partial reload of the same component; full visits replace every
prop as usual.

```zig
const inertia = zoda.plugins.inertia;
return ctx.plugins.inertia.render(req, res, "Messages/Index", .{
    .page = page,
    // A reload with `only: ['messages']` appends; an item with an
    // `id` the client already has replaces it in place.
    .messages = inertia.merge(pages[page - 1]).matchOn("id"),
    // Deferred, then deep-merged into the current object.
    .activity = inertia.deepMerge(inertia.deferred({}, Activity.load)),
});
```

```js
router.reload({ data: { page: page + 1 }, only: ['messages', 'page'] })
router.reload({ only: ['messages'], reset: ['messages'] }) // start over
```

- **Wrappers.** `merge(prop)` appends arrays, `prepend(prop)` puts new items
  first, and `deepMerge(prop)` merges objects recursively, appending nested
  arrays. Objects are shallow-merged by `merge` and `prepend`. `prop` is a
  plain value, an `optional(...)`, or a `deferred(...)` prop, which keeps
  its own rules: an optional merge prop is resolved only when a reload asks
  for it, and a deferred one is left out of full visits, listed in
  `deferredProps`, and merged when its group loads. The types are
  `Merge(T)`, `Prepend(T)`, and `DeepMerge(T)`, or
  `Mergeable(mode, T, match_on)` with match keys, for `SharedProps`
  fields, for example
  `notices: zoda.plugins.inertia.Mergeable(.append, []const Notice, &.{"id"})`.
- **Page fields.** After `version`, the page lists the props it sends that
  are wrapped: `"mergeProps"`, `"prependProps"`, and `"deepMergeProps"`,
  each an array of names in declaration order (shared props first). Props
  left out by the partial-reload lists, deferred props on a full visit,
  and shared props overridden by a route prop or not configured are not
  listed. A field with no names is left out.
- **Match keys.** `.matchOn(key)` adds `"<name>.<key>"` to `matchPropsOn`.
  The client then replaces an existing array item whose `key` field equals
  a new item's instead of adding a duplicate (`prepend` moves it to the
  front). `merge` and `prepend` take one field name. `deepMerge` takes a dot
  path to an array below the prop, such as `.matchOn("posts.id")` for
  `feed.posts`, and may be called more than once.
- **Reset.** `router.reload({ reset: ['messages'] })` sends
  `X-Inertia-Reset: messages` (and lists the name in `-Data`). On a partial
  reload of the rendered component, a reset prop is sent without its merge
  listing or match keys, so the client replaces it. Only whole top-level
  names count; names that are not merge props are ignored. On other visits
  the header is validated but changes nothing, because the client would
  not merge anyway. It follows the partial-list rules and errors above.
- **Rules checked at compile time.** `errors` cannot be merged. A merge
  prop's name must be non-empty `[A-Za-z0-9_$-]`, since the client reads it
  as a dot path. Match-key segments use the same bytes, are not repeated,
  and only `deepMerge` keys may contain `.`. Merge wrappers do not nest and
  do not take `always(...)`, and `always` does not take a merge prop.

### Scroll props

A scroll prop is one page of items for v3's `<InfiniteScroll>` component,
which loads the previous or next page as the user scrolls and merges it
into the list. `scroll(prop, page)` wraps the items and states where they
sit; the route does the paging itself:

```zig
fn usersRoute(ctx: *App.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    if (req.onLiteral("users") and req.isRoot() and req.isGet()) {
        const per_page = 2;
        const users = &all_users;
        const last: u32 = @max(1, (users.len + per_page - 1) / per_page);
        // The route owns pagination: `<InfiniteScroll>` only sets `?page=`.
        const raw = (req.getOne("page") catch null) orelse "1";
        const page = std.fmt.parseInt(u32, raw, 10) catch 0;
        if (page < 1 or page > last) return res.text(404, "No such page");
        const start = (page - 1) * per_page;
        const inertia = zoda.plugins.inertia;
        return ctx.plugins.inertia.render(req, res, "Users/Index", .{
            .users = inertia.scroll(users[start..@min(start + per_page, users.len)], .{
                .previous = if (page > 1) page - 1 else null,
                .next = if (page < last) page + 1 else null,
                .current = page,
            }).matchOn("id"),
        });
    }
}
```

```jsx
<InfiniteScroll data="users" as="ul">
  {users.map((user) => <li key={user.id}>{user.name}</li>)}
</InfiniteScroll>
```

- **Pagination is the route's job.** `render` never slices or counts
  anything. The route reads the page number from the query parameter named
  by `page_name` (default `"page"`), picks that page of its data, and
  passes `previous`, `next`, and `current`. `previous` or `next` is null
  when there is no such page. The client sends the number it was given
  back as `?page=<n>` and also writes it into the address bar as the user
  scrolls (unless `preserveUrl`), so a reload or shared link can open on a
  later page; that page's `previous` is then loaded when the user scrolls
  up. Decide how to answer an out-of-range or malformed page yourself, as
  the route above does with 404.
- **Page fields.** Every response that sends the prop adds
  `"scrollProps": {"users": {"pageName": "page", "previousPage": null,
  "nextPage": 2, "currentPage": 1, "reset": false}}` after the merge
  fields. This is `ScrollProp` in `@inertiajs/core` 3.9.1. The prop is also
  a merge prop, listed in `mergeProps` (and `.matchOn(key)` in
  `matchPropsOn`, under the `merge` rules), so a loaded page is added to
  the client's list. Props the partial-reload lists leave out get no
  entry, and the field is left out when there are none.
- **Merge intent.** `<InfiniteScroll>` loads a page with a partial reload
  of the prop that sends `X-Inertia-Infinite-Scroll-Merge-Intent: append`
  for the next page or `prepend` for the previous one. On a partial reload
  of the rendered component, `prepend` lists the prop in `prependProps`
  instead of `mergeProps`, so the page goes before the current items. A
  missing header means `append`. Only those two exact lowercase values are
  accepted; anything else returns `error.MalformedPartialHeader`, and a
  repeated field `error.DuplicatePartialHeader`, on every Inertia visit,
  leaving the response unchanged. On full visits and reloads for another
  component the header is checked but unused. Ordinary HTML visits ignore
  it.
- **Reset.** When `X-Inertia-Reset` names the prop on a partial reload of
  the rendered component, it is sent without its merge listing, so the
  client replaces the list, and its entry has `"reset": true`, which makes
  `<InfiniteScroll>` start over from the new `previousPage` and
  `nextPage`. Send `reset` with any visit that keeps the page component
  mounted, such as a form post or `router.patch`, otherwise the component
  keeps paging from where it was. Plain GET link visits remount the page
  and need no reset.
- **Wrapping.** `prop` is a plain value, an `optional(...)`, or a
  `deferred(...)` prop, with their usual rules; an optional or deferred
  scroll prop has a `scrollProps` entry only on the responses that send
  it, and `<InfiniteScroll>` throws if it mounts before one arrives. The
  type is `Scroll(T)`, or `Scrollable(T, match_on)` with match keys, for
  `SharedProps` fields. The merge prop compile-time rules apply, and
  `scroll` does not take or go inside another merge wrapper or `always`.
- **Page names.** `page_name` is 1-64 `[A-Za-z0-9_-]` bytes, so the route
  can read it back without decoding. Another value returns
  `error.InvalidScrollPageName` before the response changes, whether or
  not the prop is sent.

### Once props

A once prop is sent on the first visit and then reused by the client, for
data that rarely changes, such as a list of plans or a country list. On later
Inertia visits the client says which values it still holds, and `render`
skips them without calling `resolve`:

```zig
const inertia = zoda.plugins.inertia;
return ctx.plugins.inertia.render(req, res, "Billing/Plans", .{
    .user = user,
    // Resolved on the first visit, then reused by the client.
    .plans = inertia.once(store, Plans.load),
    // Shared with any other page that uses the key "rates"; the client
    // fetches it again after an hour.
    .exchange = inertia.once(store, Rates.load).as("rates").expiresIn(60 * 60 * 1000),
});

// .plugins = .{ .inertia = .{
//     .layout = layout,
//     // `unixMilliseconds` is the application's trusted wall-clock function.
//     .now_milliseconds = unixMilliseconds,
// } },
```

- **`once(context, resolve)`** returns a `Once(Context, resolve)` prop.
  `resolve` follows the `optional` rules (signature, arena, error
  propagation, and the warning about locks the route holds), but a once prop
  is sent like a plain value: on full visits and on partial reloads that
  keep it.
- **Page fields.** Every response that would send the prop adds an entry to
  `"onceProps": {"plans": {"prop": "plans", "expiresAt": null}, "rates":
  {"prop": "exchange", "expiresAt": 1767225600000}}`, after `deferredProps`
  and in declaration order, shared props first. This is `Page.onceProps` in
  `@inertiajs/core` 3.9.1. Props left out by the partial-reload lists, and
  shared props overridden by a route prop or not configured, get no entry;
  the field is left out when there are none.
- **Keys.** The entry is keyed by the prop name, or by `.as(key)`. Props on
  different pages with the same key share one value on the client. A key is
  one or more non-empty `.`-separated segments of `[A-Za-z0-9_$-]`, and two
  once props of one page cannot share a key; both are checked at compile
  time.
- **Later visits.** The v3 client sends `X-Inertia-Except-Once-Props` with
  the keys of the current page's once props that it holds and that have not
  expired. On an Inertia visit, a once prop whose key is listed is not
  resolved or sent, but its entry stays in `onceProps`, and the client
  carries its current value over. Prop names that are not keys are ignored.
  The header applies to every Inertia visit, including visits to other
  components. Ordinary HTML visits ignore it, since a full page load has no
  client copy.
- **Partial reloads.** A partial reload of the rendered component that
  lists the prop in `X-Inertia-Partial-Data` always resolves and sends it,
  even when its key is in `X-Inertia-Except-Once-Props`, so
  `router.reload({ only: ['plans'] })` refreshes it. As with the other
  filters, a dot path such as `plans.0` asks for the whole prop. An
  except-only reload or a bare component header does not count as asking,
  so held props stay with the client.
- **Expiry.** `.expiresIn(ms)` sets `expiresAt` to the
  `now_milliseconds` clock's time plus `ms`, as Unix milliseconds. Once it has
  passed, the client stops listing the key and the next visit resolves the
  prop again. Without an expiry, `expiresAt` is `null` and the client keeps
  the value until a visit's response has no entry for the key. `render`
  reads the clock at most once, and only when a listed once prop has an
  expiry. It returns `error.OnceClockNotConfigured`
  when `now_milliseconds` is unset, and `error.InvalidOnceTime` when the clock
  is negative or `expiresAt` would exceed `max_once_expires_at`
  (2<sup>53</sup> − 1, the largest integer a JavaScript number holds
  exactly). Both happen before the response changes. When the client
  holds the value, it keeps the `expiresAt` it already has.
- **Request headers.** `X-Inertia-Except-Once-Props` follows the
  partial-list rules: 1 to `max_partial_props` names in at most
  `max_partial_bytes` bytes (`error.PartialHeaderTooLarge`), each non-empty
  `.`-separated segments of `[A-Za-z0-9_$-]`
  (`error.MalformedPartialHeader`). A repeated field returns
  `error.DuplicatePartialHeader`. These failures leave the response unchanged.
- **Shared props.** A `SharedProps` field may be a once prop, typed
  `Once(Context, resolve)`, or `Onceable(key, Context, resolve)` with a key,
  for example `plans: zoda.plugins.inertia.Onceable("plans", *Store, Plans.load)`.
- **Rules checked at compile time.** `errors` cannot be a once prop, and a
  once prop's name must be non-empty `[A-Za-z0-9_$-]`, since the client
  reads `prop` as a dot path. Once props, deferred once props included,
  cannot be wrapped in `merge`, `prepend`, `deepMerge`, `scroll`, or
  `always`.

#### Deferred once props

`deferred(context, resolve).once()`, or `deferredGroup(...).once()`, is
Laravel's `Inertia::defer(...)->once()`: a deferred prop the client keeps
after loading it. It returns a `DeferredOnce(group, key, Context, resolve)`
prop, which takes `.as(key)` and `.expiresIn(ms)` like `once`.

```zig
// Loaded after the first page renders, then reused until it expires.
.plans = inertia.deferred(store, Plans.load).once().expiresIn(10 * 60 * 1000),
```

- **Full visits** list it in `deferredProps` and `onceProps` without
  resolving it. When `X-Inertia-Except-Once-Props` names its key, it is
  left out of `deferredProps`, so the client does not request it again and
  carries its value over; the `onceProps` entry stays.
- **Partial reloads** follow the once rules: the client's deferred reload
  lists it in `X-Inertia-Partial-Data` and gets a fresh value with its
  entry, and an except-only reload leaves a held value to the client.

### Flash

`renderWith` is `render` with per-call options. Its `.flash` option sends the
messages this request received through [`zoda.Flash`](#flash-messages) as
the page's top-level `flash`, which v3 clients expose as `page.flash` and
pass to `flash` events and `onFlash` callbacks:

```zig
// POST /todos: queue the message, save, and redirect as usual.
try ctx.plugins.flash.add(&ctx.state.sessions, "notice", "Todo added");
try ctx.plugins.sessions.save(&ctx.state.sessions, res);
return ctx.plugins.inertia.redirect(req, res, "/todos");

// GET /todos: send pending messages, then save to consume them.
try ctx.plugins.inertia.renderWith(req, res, "Todos/Index", props, .{
    .flash = .{ .plugin = &ctx.plugins.flash, .session = &ctx.state.sessions },
});
return ctx.plugins.sessions.save(&ctx.state.sessions, res);
```

- **Shape.** `"flash": {"notice": "Todo added"}`, after every other page
  field: one `kind: text` entry per kind, in the order each kind was last
  added. A later message of a kind replaces an earlier one, like the
  client's `router.flash(key, value)`; use distinct kinds to show several.
  Text that is not valid UTF-8 is written as an array of byte values, as
  `std.json` does for any string prop. In the HTML shell it is escaped like
  the rest of the page. Errors stored by `redirectWithErrors` are sent as
  `props.errors`, never in `flash`.
- **Default.** With no messages, or without the option, the field is left
  out; the client reads a missing `flash` as `{}`. `render` never sends it.
- **Read once.** `renderWith` reads the messages with `Flash.peek` and calls
  `Flash.read` only after the response is committed, so a header, limit,
  configuration, or prop-callback error, or a version-conflict 409, leaves
  them unread. As with any `read`, the consumption persists only through
  the `sessions.save` that follows `renderWith`; without it the browser
  keeps the old cookie and gets the messages again. A short circuit that
  never renders leaves them for the next page.
- **Partial reloads.** Flash is sent and consumed on every render, partial
  reloads included, as the Laravel and Rails adapters do. A form posted
  with `only` is followed by a partial reload, and the v3 client shows its
  flash. The one exception is the client's deferred-props reload, whose
  flash it ignores; no header marks it, so the server cannot skip it. That
  reload comes right after a full visit that has already consumed the
  messages, so it only loses a message queued in between, for example by
  another tab. A prefetch is an ordinary visit and consumes them too.
- **Limits.** Flash holds at most 8 messages and 512 encoded bytes (see
  [Flash messages](#flash-messages)), and the page must still fit
  `max_body_bytes`; script-element escaping can make a message up to six
  times longer.

### Validation errors

The usual Inertia form flow redirects back after a failed submission and
shows the errors on the GET that follows. `redirectWithErrors` stores them in
the session through [`zoda.Flash`](#flash-messages), and `renderWith` with
`.flash` sends them as `props.errors` once:

```zig
const source: zoda.plugins.inertia.FlashSource = .{
    .plugin = &ctx.plugins.flash,
    .session = &ctx.state.sessions,
};

// POST /todos: on failure, store the errors and go back to the form's page.
if (text.len == 0) {
    try ctx.plugins.inertia.redirectWithErrors(req, res, source, "/todos", .{ .text = "Write something first." });
    return ctx.plugins.sessions.save(&ctx.state.sessions, res);
}

// GET /todos: send stored errors (and flash), then save to consume them.
try ctx.plugins.inertia.renderWith(req, res, "Todos/Index", props, .{ .flash = source });
return ctx.plugins.sessions.save(&ctx.state.sessions, res);
```

```js
form.post('/todos', { errorBag: 'createTodo' }) // form.errors.text
```

- **Errors.** A struct with named fields, serialized with `std.json`, such
  as `.{ .text = "Required" }` or a type with optional fields; null
  optional fields are left out, so `struct { text: ?[]const u8 = null }`
  with nothing set stores `{}`. A `std.json.ArrayHashMap` works for field
  names known only at run time. Tuples are a compile error.
- **Destination.** `path` is a local path under the `Response.redirectPath`
  rules, chosen by the route, usually the form's page. `Referer` is never
  read, so a request cannot pick where it is sent back to. The status is
  303, whatever the method, so the client follows with GET. An Inertia
  request to a path with `#` gets 409 and `X-Inertia-Redirect`, as with
  `redirect`.
- **Error bags.** On an Inertia request, `X-Inertia-Error-Bag: name`, which
  the client sends for `{ errorBag: 'name' }`, nests the errors as
  `{"name": {...}}`. The client then hands `errors.name` to `onError` and
  `useForm`, so two forms on one page keep their errors apart. The bag is
  applied when the errors are stored, so the GET that follows does not
  need the header. A bag is 1 to `max_error_bag_bytes` (64)
  `[A-Za-z0-9_-]` bytes; another value returns
  `error.MalformedErrorBagHeader` and a repeated field
  `error.DuplicateErrorBagHeader`. Ordinary requests ignore the header.
  `zoda.plugins.inertia.errorBag(req)` applies the same rules.
- **Reading.** `renderWith` with `.flash` sends the stored errors as
  `props.errors` on every render, partial reloads included, since `errors`
  is always sent. A route `errors` prop still wins; stored errors win over
  a shared `errors`. They are consumed together with the flash messages,
  only once the response is committed, so a header, limit, configuration,
  or prop-callback error, or a version-conflict 409, leaves them unread.
  Without stored errors, `errors` is `{}` (or the shared value) as usual.
  `render`, which has no session, never reads them.
- **Storage.** The errors are one flash message of the reserved kind
  `errors_flash_kind` (`"inertia-errors"`) whose text is the JSON object;
  `renderWith` leaves it out of `flash`. Do not add messages of that kind
  yourself; one whose text is not a JSON object is ignored. The newest one
  wins if several are pending. Like flash, they are signed but not
  encrypted, so do not echo secrets in error messages.
- **Limits and atomicity.** The JSON shares the flash budget of 512 encoded
  bytes and 8 messages with unread flash messages, minus 17 bytes for the
  entry; errors that do not fit return `error.FlashTooLarge`. The bag
  header, the path, an existing `Location` (`error.LocationAlreadySet`),
  and the response header limits are checked first, so any failure leaves
  both the response and the session unchanged. Call `sessions.save`
  afterwards, or the errors are lost with the unsaved session.

### Per-render options

`renderWith(req, res, component, props, options)` is `render` with a
`RenderOptions` struct; `render` is `renderWith` with `.{}`. Every field
defaults to `render`'s behavior:

| Field | Default | Meaning |
| --- | --- | --- |
| `context` | `null` | `.of(ctx)`, the route's context, for `.fromContext` shared props. See [Shared props from request state](#shared-props-from-request-state). |
| `flash` | `null` | `FlashSource` to read flash, stored validation errors, and a stored history clear from. See [Flash](#flash). |
| `encrypt_history` | `null` | `true` or `false` overrides the instance's `encrypt_history` for this page. |
| `clear_history` | `false` | Sends `clearHistory: true`. |
| `preserve_fragment` | `false` | Sends `preserveFragment: true`. |
| `status` | `200` | Response status, for an error page rendered through Inertia. |

```zig
try ctx.plugins.inertia.renderWith(req, res, "Errors/NotFound", .{ .path = req.target }, .{ .status = 404 });
```

- **Status.** 200–299 other than 204 and 205, which cannot carry the page,
  or 400–599. Anything else, redirects included, returns
  `error.InvalidStatus` before the response changes; use `redirect` or
  `location` for those. A v3 client given an Inertia page with a status of
  400 or more fires its `httpException` event and then shows the page. A
  stale asset version still gets the 409 conflict instead.
- **`preserveFragment`.** The client normally drops the `#fragment` the
  user asked for when the response is for a different URL, as after a
  redirect. With `preserveFragment: true` it keeps the requested fragment
  on the page it shows. Pass it on the page the redirect lands on.

### Shared props from request state

`.shared = .fromContext(App.Context, resolve)` builds the shared props on
each render by calling `resolve(ctx, req)`, so they can come from session
state such as the signed-in user. The plugin is declared before the app and
cannot name `App.Context` itself, so each render passes the context in
`renderWith`'s `.context`:

```zig
const Shared = struct { user: ?[]const u8 };
const Plugins = struct { sessions: zoda.Sessions, inertia: zoda.Inertia(Shared) };
const App = zoda.app.App(Plugins);

fn shared(ctx: *App.Context, _: *const zoda.router.Request) Shared {
    const user = ctx.state.sessions.value();
    return .{ .user = if (user.len == 0) null else user };
}

fn route(ctx: *App.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    return ctx.plugins.inertia.renderWith(req, res, "Home", .{}, .{ .context = .of(ctx) });
}

// .plugins = .{ .inertia = .{ .layout = layout, .shared = .fromContext(App.Context, shared) }, ... },
```

- **Precedence.** Unchanged: a route prop with the same name replaces the
  shared one, checked at comptime, and `sharedProps` still names every
  shared prop.
- **Missing or wrong context.** `render`, or `renderWith` without
  `.context`, returns `error.MissingRouteContext`; a context of another type
  returns `error.RouteContextMismatch`. Both are checked before the response
  changes. `.context` is ignored for the other `shared` forms.
- **Lifetime.** `resolve` runs once per render, after the version check, on
  the request's task. What it returns, such as a slice of the session
  payload, must stay valid until `renderWith` returns.

The [test](src/plugins/inertia.zig) builds `user` from the session payload
across a login redirect and checks precedence.

### History encryption

The v3 client stores each page object in the browser's `history.state` so
Back and Forward can restore it without a request. With
`encryptHistory: true` it encrypts that copy with AES-GCM under a key kept
in the tab's `sessionStorage`; `clearHistory: true` deletes the key, so
pages stored before it can no longer be decrypted. Back to such a page
makes the client fetch it from the server again instead of showing the old
props. This is what you want after a logout on a shared computer.

```zig
// Registration: encrypt every page.
.inertia = .{ .layout = layout, .encrypt_history = true },

// POST /logout: end the session, ask the next page to clear history.
const source: zoda.plugins.inertia.FlashSource = .{ .plugin = &ctx.plugins.flash, .session = &ctx.state.sessions };
ctx.state.sessions.clear();
try ctx.plugins.inertia.clearHistoryOnNextRender(source);
try ctx.plugins.sessions.save(&ctx.state.sessions, res);
return ctx.plugins.inertia.redirect(req, res, "/login");

// GET /login: sends `clearHistory: true` once.
try ctx.plugins.inertia.renderWith(req, res, "Auth/Login", .{}, .{ .flash = source });
return ctx.plugins.sessions.save(&ctx.state.sessions, res);
```

- **Fields.** `encryptHistory`, `clearHistory`, and `preserveFragment` follow
  `version` in the page object and are sent only when true, so a default
  page is unchanged. The client reads a missing field as false.
- **Encrypting.** `encrypt_history = true` encrypts every page;
  `renderWith`'s `.encrypt_history` overrides it for one page either way,
  for example to encrypt only pages that show account data.
- **Clearing.** `.clear_history = true` clears on the page being rendered.
  A logout usually redirects, so `clearHistoryOnNextRender(source)` stores
  the request in the session through [`zoda.Flash`](#flash-messages), as
  one message of the reserved kind `history_flash_kind`
  (`"inertia-clear-history"`), and the next `renderWith` with `.flash`
  sends `clearHistory: true` and consumes it with the flash messages. It
  is left out of `flash`. Calling it again before the next render adds
  nothing. Call it after `State.clear`, which would drop it, and save the
  session afterwards; a queued message keeps the cookie alive. It counts
  toward the flash budget like any message (24 bytes) and returns the
  `zoda.Flash` errors if that is full.
- **Secure context.** The client encrypts with Web Crypto, which browsers
  offer only on HTTPS pages and on `localhost`. Elsewhere the 3.9.1 client
  logs "SSL is required" and fails the visit with "Unable to encrypt
  history", so enable it only where the app is served over HTTPS.
- **What it protects.** It keeps page props from being read back out of
  this tab's history after `clearHistory`. It does not protect anything
  from the server, which sends the props in plain JSON, or from script
  running on the page, which can read the key from `sessionStorage`. The
  key lives as long as the tab, so without `clearHistory` encrypted pages
  stay readable; it is not a substitute for ending the session or for
  `Cache-Control: no-store` on private pages.

### Precognition

`useForm(...).withPrecognition(method, url)` validates a form live: each
`form.validate('field')` sends the form data to `url` with
`Precognition: true` and `Precognition-Validate-Only` naming the fields the
user has touched. The route runs its validation and answers before doing
anything, then the client shows the errors in `form.errors`. The contract
is laravel-precognition's (2.1.1, bundled by `@inertiajs/core` 3.9.1).

```zig
// POST /todos: the same route answers precognition and real submits.
const problem: ?[]const u8 = if (text.len == 0) "Write something first." else null;
if (try zoda.plugins.inertia.precognition(req) != null) {
    // 422 {"errors":{"text":...}} or 204; nothing is stored.
    return ctx.plugins.inertia.answerPrecognition(req, res, .{ .text = problem });
}
if (problem) |message| return ctx.plugins.inertia.redirectWithErrors(req, res, source, "/todos", .{ .text = message });
```

```jsx
const form = useForm({ text: '' }).withPrecognition('post', '/todos')
<input value={form.data.text} onChange={(e) => form.setData('text', e.target.value)} onBlur={() => form.validate('text')} />
```

- **Detecting.** `precognition(req)` returns null unless the request has
  exactly one `Precognition: true`; a repeated field is
  `error.DuplicatePrecognitionHeader` and any other value
  `error.MalformedPrecognitionHeader`, like `X-Inertia`. Only then is
  `Precognition-Validate-Only` read: absent, every field is validated;
  empty, which the client sends when nothing is touched, none is; else 1 to
  `max_precognition_fields` (64) comma-separated names in at most
  `max_precognition_bytes` (1024), each dot-separated non-empty segments of
  `[A-Za-z0-9_$-]` or `*`. Repeated, malformed, or oversized lists return
  `DuplicatePrecognitionHeader`, `MalformedPrecognitionHeader`, or
  `PrecognitionHeaderTooLarge`. `Precognition.validates(name)` reports
  whether a field was asked for, so a route can skip costly checks.
- **Answering.** `answerPrecognition(req, res, errors)` takes the same
  kind of struct as `redirectWithErrors`. It keeps the fields that
  `validates` accepts, leaving out null optional fields; a `*` segment
  matches any one segment, so `items.*.name` keeps `.@"items.0.name"`. If
  any are left, it sends 422 with `{"errors": {...}}` as JSON (a string or
  a list of strings per field; the client takes the first); otherwise 204
  with `Precognition-Success: true`. Both add `Precognition: true`, which
  the client requires, and `Vary: Precognition`. Error bags do not apply.
- **No side effects.** Call it after validating and before writing
  anything, and return. A non-precognitive request gets
  `error.NotPrecognitive`, so a route cannot answer a real submit by
  mistake; a second answer gets `error.PrecognitionAlreadySet`. Header,
  limit, and body-size failures leave the response unchanged. `render` and
  the redirects ignore `Precognition`.
- **Caching.** A route that answers precognitive GETs should call
  `varyOnPrecognition(res)` on its ordinary responses too, so a cache
  never serves a 204 for a page or the reverse.
- **Not covered.** File validation (`validateFiles`) needs multipart
  bodies, which `zoda.JsonParser` does not read.

### Server-side rendering

With `ssr` set, a full (non-`X-Inertia`) visit posts the page JSON to an
Inertia SSR server, such as the one `@inertiajs/react/server` starts, and
sends its rendered markup. The client then hydrates instead of mounting. The
decision and its trade-offs are recorded in
[zoda_plan.md §4.2.14](zoda_plan.md).

```zig
const layout =
    \<!doctype html>
    \<html><head><script type="module" src="/assets/app.js"></script>
    \@inertiaHead</head>
    \<body>@inertia</body></html>
;

fn logSsrFailure(req: *const zoda.router.Request, failure: zoda.plugins.inertia.SsrFailure) void {
    std.log.warn("SSR failed for {s}: {s}", .{ req.target, @errorName(failure) });
}

// .inertia = .{
//     .layout = layout,
//     .ssr = .{ .timeout_ms = 500 }, // POST http://127.0.0.1:13714/render
//     .on_ssr_failure = logSsrFailure,
// },
```

| `Ssr` field | Default | Meaning |
| --- | --- | --- |
| `address` | `127.0.0.1:13714` | Literal `std.Io.net.IpAddress` of the SSR server. No name lookup happens. |
| `path` | `"/render"` | Request path: `/` then printable ASCII without spaces, at most 256 bytes. |
| `timeout_ms` | `1000` | Total budget for connecting, sending, and reading, 1 to 60,000. |
| `max_response_bytes` | 1 MiB | Most bytes of the SSR server's answer, head included. |

- **Request.** `POST <path> HTTP/1.1` with `Content-Type: application/json`
  and `Connection: close`. The body is exactly the page object an
  `X-Inertia` visit would get, unescaped.
- **Answer.** 200 with `{"head": [string], "body": string}` (`head` may be
  missing; other fields are ignored), framed by `Content-Length`, chunked
  encoding, or the connection close. The `head` elements, joined with
  newlines, replace `@inertiaHead`; `body` replaces `@inertia`. Both are
  inserted as is: the SSR server is trusted like the layout. In v3 `body`
  holds the `<script data-page>` element and
  `<div data-server-rendered="true" id="app">`, built from the page JSON
  Zoda sent, so `root_id` and `initial_page` must match the SSR server's
  own setup.
- **Fallback.** Any failure is passed to `on_ssr_failure` and the page is
  the client-side shell, as without `ssr`: `SsrConnectFailed`,
  `SsrTimeout`, `SsrIoFailed`, `SsrResponseTooLarge`, `SsrBadStatus`,
  `SsrMalformedResponse`, `SsrPageTooLarge` (the document is over
  `max_body_bytes`), and `SsrUnsupported` off Linux. Only `OutOfMemory`
  propagates. The callback runs concurrently with other requests.
- **Deadline.** The budget is one absolute deadline on the monotonic clock,
  checked before every syscall, so a hung or slow SSR server costs at most
  `timeout_ms`. During that time the request holds its connection task:
  keep the SSR server local and the timeout short.
- **Settings.** `validate()` and `render` return `error.InvalidSsr` for a
  zero or over-limit `timeout_ms`, a zero `max_response_bytes`, or a bad
  `path`. `@inertiaHead` after `@inertia`, or twice, is
  `error.InvalidLayout`.
- **Not covered.** Only full visits are rendered; `X-Inertia` responses are
  JSON as always. The SSR server's error details (its 500 body) are not
  read, only the status.

### URL and origin policy

The page `url` and the conflict's `X-Inertia-Location` are the raw
origin-form request target, so path and query are kept byte for byte
(repeated query keys included). Zoda never builds an absolute URL from `Host`
or forwarded headers. The Inertia client resolves the relative URL against
the page it is already on, so the conflict reload always stays on the same
origin. A target that starts with `//` or contains `\` is refused with
`error.UnsafeRequestTarget`; a request with no target (a hand-built
`router.Request` in a test) returns `error.MissingRequestTarget`.

### Errors, limits, and ownership

- **Headers.** `X-Inertia` must appear once with the exact value `true`.
  Another value returns `error.MalformedInertiaHeader`; a repeated field
  returns `error.DuplicateInertiaHeader`; a repeated `X-Inertia-Version`
  returns `error.DuplicateVersionHeader`. Partial-reload headers have their
  own errors; see [Partial reloads](#partial-reloads). There is no silent
  HTML fallback.
  `zoda.plugins.inertia.isInertia(req)` applies the same rules.
- **Limits.** The finished HTML or JSON must fit `max_body_bytes`
  (`error.BodyTooLarge`), and every header the call adds must fit the
  response's header limits (`error.TooManyHeaders`,
  `error.HeaderBytesExceeded`). These failures, header errors, and
  configuration errors (`InvalidLayout`, `InvalidRootId`, `InvalidComponent`
  for an empty name, `InvalidStatus`) leave the response unchanged. The page JSON is built in
  full before the body limit is checked, as with `Response.replaceJson`.
- **Errors propagate.** Nothing is mapped to a status. Register
  [`error_handler`](#status-and-error-handlers) to turn header errors into a
  400 page; an `OutOfMemory` can leave headers added before it failed, and
  `error_handler` clears the partial response.
- **Ownership.** The response owns every serialized byte. Shared values and
  the version string are borrowed from the instance and must outlive the app;
  callback results must stay valid until the call returns. Callbacks,
  including `now_milliseconds`, must be safe to call concurrently.

### Interactions

- **Sessions, CSRF, and flash.** Build session-derived shared props (the
  current user) with `.fromContext` (see
  [Shared props from request state](#shared-props-from-request-state)), and
  send flash messages and redirected validation errors with `renderWith`
  (see [Flash](#flash) and [Validation errors](#validation-errors)). Save
  the session before `redirect`, after `redirectWithErrors` and
  `clearHistoryOnNextRender`, and after `renderWith` when it sends flash, so
  the read is persisted. Inertia's client sends the `XSRF-TOKEN` cookie as
  `X-XSRF-TOKEN`: set the cookie with `csrf.setXsrfCookie` and check
  `csrf.validHeader(req, state, csrf.xsrf_header_name)`; see
  [XSRF-TOKEN cookie](#xsrf-token-cookie-inertia-axios). The check covers
  precognitive requests too, which the client sends with the same header.
- **Caching.** Do not mark Inertia pages `public` without `Vary: X-Inertia`,
  which `render` already adds; add other `Vary` fields with
  `http_cache.addVary`.
- **Middleware.** It is not middleware. `default_headers`,
  `security_policy`, and `status_handler` see its responses like any route
  response; a status handler replaces the 409 only if you configure 409.

### Supported protocol features

Checked against `@inertiajs/core`, `@inertiajs/react`, `@inertiajs/svelte`,
and `@inertiajs/vue3` 3.9.1. The three frontends in
[examples/inertia](examples/inertia/README.md) were driven in headless Chrome
through the script-element page, JSON visits, shared props, `errors`, 303
and fragment redirects, filter links, the deferred `stats` prop that each
renders with `<Deferred>`, and the `todos` scroll prop paged forward and
backward with `<InfiniteScroll>` and reset after a toggle. The "Todo added"
flash was driven in Chrome in all three: shown after the add form's partial
reload, kept through the deferred `stats` reload, and gone on the next
visit. So was redirect-back validation: an empty todo posted with
`errorBag: 'createTodo'` sent `X-Inertia-Error-Bag`, got a 303, and the
followed GET carried `errors: {"createTodo": {"text": ...}}`, which
`useForm` showed as `form.errors.text`; the next visit had `errors: {}`.
History encryption was driven in Chrome in all three: `history.state.page`
was an encrypted `ArrayBuffer`, Back before "Forget history" restored the
previous page with no request, and Back after it fetched the page from the
server again. Precognition was driven in Chrome with the React frontend:
leaving the add field blank and blurring it sent a precognitive POST that
got 422 and showed "Write something first." before any submit, and a valid
value got 204 and cleared it, with no todo added. Server-side rendering
was driven in Chrome with the React frontend and its `npm run ssr` server:
the page arrived server-rendered, hydrated with no console messages, and
the add form worked; with the SSR server stopped or hung, pages fell back
to client rendering and the failure was logged. The rest of the protocol
was driven in Chrome in all three frontends. The `limits` once prop came
with the first page and later visits sent `X-Inertia-Except-Once-Props:
limits,server` and got no value. The deferred once `about` prop loaded
after the first page and was neither deferred nor requested again. Hovering
a filter link prefetched it with `Purpose: prefetch` and the click used
that response; a change sent with `invalidateCacheTags` made the next
click fetch the page again. A toggle sent with `only: ['todos', 'stats']`
got the always prop `remaining` back too. "Show activity" loaded the
optional `activity` prop, and "Check for new" sent the last id and
appended only the new entry through `deepMergeProps` and `matchPropsOn`.
"Refresh counts" sent `X-Inertia-Partial-Except: todos,activity` and
kept the loaded list and log. An activity link to `/todos/18#todo-18`
was redirected to `/todos?page=2`, and `preserveFragment` kept
`#todo-18` in the address bar and scrolled the todo into view. A link
to a deleted todo got the `Errors/NotFound` page with status 404 after
one `httpException` event and no error dialog. React's SSR server
rendered both pages. The `.expiresIn` expiry passing, `deferredGroup`,
and merge props other than `scroll` and `deepMerge` are covered by the
plugin's unit tests only.

| Inertia v3 feature | Status |
| --- | --- |
| Initial page in `<script data-page type="application/json">` | Implemented (default `initial_page = .script`) |
| v1/v2 `data-page` attribute | Implemented (`initial_page = .attribute`) |
| JSON page visits, `X-Inertia`, `Vary: X-Inertia` | Implemented |
| Shared props, route precedence, `sharedProps` list | Implemented |
| `props.errors` always present | Implemented (`{}` by default) |
| Session-backed validation errors (redirect back) | Implemented (`redirectWithErrors`, read by `renderWith` with `.flash`): stored through `zoda.Flash`, sent once as `props.errors` after a 303 to a route-supplied local path. Driven in a browser through the example's add form. |
| Asset version 409 + `X-Inertia-Location` (missing header = empty version) | Implemented |
| 303 after PUT/PATCH/DELETE/POST | Implemented (`redirect`) |
| Fragment redirects, 409 + `X-Inertia-Redirect` | Implemented (`redirect` with `#`) |
| External and full-page visits, 409 + `X-Inertia-Location` | Implemented (`location`) |
| Prefetching (`Purpose: prefetch`) | Not special-cased: a prefetch is an ordinary Inertia GET and gets a full response, so a route that consumes flash or other one-time state consumes it on the prefetch. Driven in a browser through the example's filter links, with `cacheTags` invalidated by each change. |
| Partial reloads (`X-Inertia-Partial-Data`, `-Component`, `-Except`) | Implemented, top-level names only (dot paths select the whole top-level prop). Driven in a browser through deferred loading and "Show activity" (`only`) and "Refresh counts" (`except`). |
| Top-level `flash` | Implemented (`renderWith` with `.flash`): `zoda.Flash` messages as `{kind: text}`, consumed once the response is committed and left out when empty. Sent on partial reloads too; the client ignores it only on deferred-props reloads. Driven in a browser through the example's "Todo added" notice. |
| Optional props (`optional`) and always props (`always`) | Implemented. Driven in a browser through the example's activity log (`optional`) and remaining count (`always`). |
| Deferred props (`deferred`, `deferredGroup`, `deferredProps`) | Implemented, including groups and shared deferred props. Driven in a browser through `stats` and `about`; groups are covered by unit tests only. |
| Merge props (`merge`, `prepend`, `deepMerge`, `matchOn`; `mergeProps`, `prependProps`, `deepMergeProps`, `matchPropsOn`) | Implemented, including optional, deferred, and shared merge props. Driven in a browser through the scroll prop and the activity log's `deepMerge(optional(...)).matchOn("events.id")`. |
| Reset (`X-Inertia-Reset`) | Implemented: listed props are sent without merge metadata on partial reloads of the rendered component |
| Scroll props (`scroll`; `scrollProps`, `X-Inertia-Infinite-Scroll-Merge-Intent`) | Implemented: one page of items per response with route-supplied page numbers; the intent picks `mergeProps` or `prependProps`, and `X-Inertia-Reset` sets `reset`. Driven in a browser through the example's paged todo list. |
| Once props (`once`, `.as(key)`, `.expiresIn(ms)`; `onceProps`, `X-Inertia-Except-Once-Props`) | Implemented: held keys are listed but not resolved, a partial reload that lists the prop in `-Data` always sends it, and `expiresAt` comes from the injected `now_milliseconds` clock. Driven in a browser through the example's `limits`. |
| Error bags (`X-Inertia-Error-Bag`) | Implemented for `redirectWithErrors`: errors nest under the validated bag name. Route-supplied `errors` props are sent as given. Driven in a browser through the example's `createTodo` bag. |
| History encryption (`encryptHistory`, `clearHistory`) | Implemented: `encrypt_history` (instance) with a per-render override, `.clear_history`, and `clearHistoryOnNextRender` for a page reached through a redirect. Fields are sent only when true. Driven in a browser through the example's "Forget history" button. |
| Deferred once props (`deferred(...).once()`) | Implemented: listed in `deferredProps` and `onceProps`, and left out of `deferredProps` while the client holds the key. Driven in a browser through the example's `about`. |
| `preserveFragment` | Implemented (`renderWith` with `.preserve_fragment`). Driven in a browser through the example's activity links, which redirect to the page holding the todo. |
| Error pages with a non-200 status | Implemented (`renderWith` with `.status`, 200–299 except 204/205, or 400–599). Driven in a browser through the example's 404 page for a deleted todo. |
| Precognition (`Precognition`, `Precognition-Validate-Only`, `Precognition-Success`) | Implemented (`precognition`, `answerPrecognition`): 422 with the listed fields' `errors` or 204, both with `Precognition: true` and `Vary: Precognition`. Driven in a browser through the example's add form in React. |
| Server-side rendering (`@inertiajs/*/server`, `@inertiaHead`) | Implemented, opt-in (`ssr`): one bounded POST per full visit with fallback to the client-side shell, reported through `on_ssr_failure`. Linux only. Driven in a browser through the React example with `--ssr`. |
