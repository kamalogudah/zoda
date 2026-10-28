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
JavaScript submissions, send the token in one `X-CSRF-Token` header. For HTML
forms, extract exactly one token field and call `csrf.validToken`; reject
duplicate fields. Missing, malformed, duplicate-header, and cross-session
tokens fail validation. The token is stable until the session is cleared; do
not put it in a URL or log. Protect every state-changing route, including
unsafe GET routes if the application has any. Keep the secure cookie and HTTPS
policy above, and do not allow untrusted cross-origin requests to send the
custom header through permissive CORS. The [compiling app dispatch example](src/plugins/csrf.zig)
exercises explicit plugin access, session persistence, and rejection before
the protected action.

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
| `layout` | required | Full HTML document with the `@inertia` marker exactly once. It holds your asset tags and is copied verbatim. Zoda loads no templates at runtime. |
| `root_id` | `"app"` | `id` of the generated root element; 1–64 `[A-Za-z0-9_-]` bytes. |
| `initial_page` | `.script` | `.script` for Inertia v3 clients, `.attribute` for v1 and v2. See below. |
| `version` | `.none` | `.value = "..."` or `.callback = fn (*const Request) []const u8`. `.none` sends `"version":null` and skips version checks. |
| `shared` | `.none` | `.value = SharedProps{...}` or `.callback = fn (*const Request) SharedProps`. Use `zoda.Inertia(struct {})` for no shared props. |

### Responses

- **`render(req, res, component, props)`** builds the page object
  `{"component", "props", "url", "version"}`. `props` must be a struct.
  Shared props come first and a route prop with the same name replaces the
  shared one (checked at comptime). The status is 200.
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
  - `props.errors` is always an object: a route `errors` prop wins, then a
    configured shared `errors`, and otherwise the plugin adds `errors: {}`,
    as the Laravel adapter does.
  - With shared props configured, the page also lists their names in
    `sharedProps`. v3 clients use it to keep shared props during instant
    client-side visits.
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
  returns `error.DuplicateVersionHeader`. There is no silent HTML fallback.
  `zoda.plugins.inertia.isInertia(req)` applies the same rules.
- **Limits.** The finished HTML or JSON must fit `max_body_bytes`
  (`error.BodyTooLarge`), and every header the call adds must fit the
  response's header limits (`error.TooManyHeaders`,
  `error.HeaderBytesExceeded`). These failures, header errors, and
  configuration errors (`InvalidLayout`, `InvalidRootId`, `InvalidComponent`
  for an empty name) leave the response unchanged. The page JSON is built in
  full before the body limit is checked, as with `Response.replaceJson`.
- **Errors propagate.** Nothing is mapped to a status. Register
  [`error_handler`](#status-and-error-handlers) to turn header errors into a
  400 page; an `OutOfMemory` can leave headers added before it failed, and
  `error_handler` clears the partial response.
- **Ownership.** The response owns every serialized byte. Shared values and
  the version string are borrowed from the instance and must outlive the app;
  callback results must stay valid until the call returns. Callbacks must be
  safe to call concurrently.

### Interactions

- **Sessions, CSRF, and flash.** Shared-props callbacks receive only the
  request, not `ctx`, so put session-derived values (the current user, flash
  messages, validation `errors`) in route props. Save the session before
  `render` or `redirect` as usual. `csrf.valid` reads `X-CSRF-Token`, not
  the `X-XSRF-TOKEN` header that Inertia's axios client sends from an
  `XSRF-TOKEN` cookie. Either set `X-CSRF-Token` in your client's request
  headers or pass the submitted value to `csrf.validToken`.
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
and fragment redirects, and filter links. The other rows are covered by the
plugin's unit tests only.

The features not yet implemented are tracked in
[#80](https://github.com/kamalogudah/zoda/issues/80), with one issue each.

| Inertia v3 feature | Status |
| --- | --- |
| Initial page in `<script data-page type="application/json">` | Implemented (default `initial_page = .script`) |
| v1/v2 `data-page` attribute | Implemented (`initial_page = .attribute`) |
| JSON page visits, `X-Inertia`, `Vary: X-Inertia` | Implemented |
| Shared props, route precedence, `sharedProps` list | Implemented |
| `props.errors` always present | Implemented (`{}` by default) |
| Asset version 409 + `X-Inertia-Location` (missing header = empty version) | Implemented |
| 303 after PUT/PATCH/DELETE/POST | Implemented (`redirect`) |
| Fragment redirects, 409 + `X-Inertia-Redirect` | Implemented (`redirect` with `#`) |
| External and full-page visits, 409 + `X-Inertia-Location` | Implemented (`location`) |
| Prefetching (`Purpose: prefetch`) | Not special-cased: a prefetch is an ordinary Inertia GET and gets a full response. Not exercised by the example. |
| Partial reloads (`X-Inertia-Partial-Data`, `-Component`, `-Except`) | Not implemented: headers are ignored and every prop is sent. v3 merges the response into the current props, so pages stay correct, but nothing is skipped on the server. |
| Top-level `flash` | Not implemented: the client defaults it to `{}`. Pass flash messages as props, as the example's README describes. |
| Deferred, optional, once, merge, and scroll props | Not implemented |
| Error bags (`X-Inertia-Error-Bag`) | Not implemented: the header is ignored |
| History encryption (`encryptHistory`, `clearHistory`) | Not implemented: never sent, so off |
| Precognition validation | Not implemented |
| Server-side rendering | Not implemented |
