# Zoda

Zoda is a small Zig web toolkit inspired by
[Roda](https://github.com/jeremyevans/roda). You write routes as nested,
imperative code, and you extend a small core with plugins that you register
explicitly. It targets JSON APIs and server-rendered sites.

> **Status:** early development. The router, app dispatch, buffered
> responses, JSON plugin, embedded HTML templates, and a hardened HTTP/1.1 socket server are
> implemented and tested. The roadmap is in [`zoda_plan.md`](zoda_plan.md).

## Requirements

- Zig **0.16.0** (exact pin). Other versions are not supported.
- Primary platform: `x86_64-linux-gnu`. Other targets are best-effort.

[`PLATFORM.md`](PLATFORM.md) covers installation, the allocator and threading
contracts, and validation evidence.
[`SUPPORTED_API.md`](SUPPORTED_API.md) is the concise public support contract,
including defaults, unsupported capabilities, ownership, measured results,
and the compiler-checked [ADR §5 example](examples/contract.zig).

## Building and testing

The [Roda-to-Zig design talk](DESIGN_TALK.md) walks through the verified
route, plugin, ownership, middleware, and wrapper behavior with the compiling
example and measured results.

```sh
zig build                                        # library + demo executable
zig build test                                   # unit and acceptance tests
zig build test-examples                          # compiling ADR §5 API example
zig build test-hardening -Doptimize=ReleaseSafe  # adversarial HTTP/1.1 tests over real sockets
zig build test-load -Doptimize=ReleaseSafe       # 60-second load and overload measurement
zig fmt --check build.zig src examples           # formatting gate used by CI
./zig-out/bin/zoda                               # run the demo
```

The demo dispatches a few requests in memory and prints the outcomes:

```text
get / -> 200 text/plain
get /users/42 -> 200 application/json
get /page -> 200 text/html; charset=utf-8
get /users -> 404 text/plain
get /users/42/extra -> 404 text/plain
get /users/42/ -> 404 text/plain
post /users/42 -> 404 text/plain
```

## Development loop

```sh
zig build watch                 # serves the demo on http://127.0.0.1:8080
zig build watch -- serve 9000   # arguments after -- go to the demo
```

The watcher checks `src/`, `build.zig`, and `build.zig.zon` for changes
several times a second, then runs `zig build`.
Embedded template edits under `src/` follow the same rebuild loop.
If an embedded template file is missing, Zig reports the build error and the
watcher keeps serving the last working page. Restoring the file starts a new
build and serves the updated page.

- **Build fails:** it prints the compiler diagnostics and keeps the last
  working server running.
- **Build succeeds:** it stops the old server (SIGTERM, then SIGKILL after
  5 s) and starts the new one.

The demo server adds an `X-Response-Time-Ms` header to each response
(see [Response timing](#response-timing)). Press Ctrl-C to stop both. Edit-to-response time measured 1.4–1.9 s on a
4-core laptop (`zig build test-devloop` repeats the measurement on your
machine and checks failed-build recovery). The watcher supports Linux only. You can also run the demo server
directly with `./zig-out/bin/zoda serve [port] [docroot]`; with a
`docroot`, it also serves [static files](#static-files) from that directory.

## Using Zoda in your project

Add the dependency (Zoda is not tagged yet, so point it at a commit):

```sh
zig fetch --save git+https://github.com/kamalogudah/zoda
```

Then import the module in `build.zig`:

```zig
const zoda = b.dependency("zoda", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zoda", zoda.module("zoda"));
```

## Usage

### Todo example

Run the interactive, in-memory todo app from this repository:

```sh
zig build run-todo
```

Open <http://localhost:8080> to add, complete, and delete todos. The example
source is in [`examples/todo.zig`](examples/todo.zig) and
[`examples/todo.html`](examples/todo.html). Its API tests run with
`zig build test-examples`.

### A complete server

```zig
const std = @import("std");
const zoda = @import("zoda");

const router = zoda.router;
const response = zoda.response;

const User = struct { id: []const u8, name: []const u8 };

// Plugins are a struct of plugin instances. The app owns them.
const Plugins = struct { json: zoda.Json = .{} };
const App = zoda.app.App(Plugins);

fn route(ctx: *App.Context, req: *router.Request, res: *response.Response) !void {
    // GET /
    if (req.isRoot() and req.isGet()) return res.text(200, "hello from zoda");

    // GET /users/:id
    if (req.onLiteral("users")) {
        if (req.onSegment()) |id| {
            if (req.isRoot() and req.isGet()) {
                return ctx.plugins.json.render(res, User, .{ .id = id, .name = "unknown" });
            }
        }
        return; // the branch matched, so stop here; dispatch returns 404
    }

    // GET /search?q=...
    if (req.isLiteral("search") and req.isGet()) {
        const q = (try req.getOne("q")) orelse "";
        return res.text(200, q);
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // `serve` uses the allocator from concurrent connection tasks,
    // so it must be thread-safe.
    const gpa = std.heap.smp_allocator;

    const app: App = .{
        .response_allocator = gpa,
        .config = .{ .name = "example" },
        .plugins = .{},
        .route_fn = route,
    };

    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(8080) };
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    try zoda.server.serve(App, gpa, io, &listener, &app, .{});
}
```

```console
$ curl localhost:8080/
hello from zoda
$ curl localhost:8080/users/42
{"id":"42","name":"unknown"}
$ curl -i localhost:8080/users
HTTP/1.1 404 Not Found
$ curl 'localhost:8080/search?q=zig+lang'
zig lang
```

### Embedded HTML templates

Use `@embedFile` to include a template at build time. Field names refer to
fields of a Zig struct. Ordinary `{{field}}` interpolation escapes `&`, `<`,
`>`, double quotes, and apostrophes as HTML text. Rendering uses the response
allocator and respects its body size limit.

```zig
if (req.isLiteral("page") and req.isGet()) {
    const name = (try req.getOne("name")) orelse "world";
    return zoda.template.render(res, 200, @embedFile("page.html"), .{ .name = name });
}
```

For reviewed markup, `{{{field}}}` accepts only
`zoda.template.TrustedHtml.fromTrusted(html)`. Passing an ordinary string to
triple braces returns `error.UntrustedRawHtml`. Use this explicit API only for
static or sanitized HTML.

Interpolation is limited to HTML text nodes. Placeholders in tags and
attributes (including URLs), comments, `<script>`, or `<style>` return
`error.UnsupportedContext`. Missing fields return `error.MissingField`;
malformed placeholders or HTML tags return `error.InvalidTemplate`. Runtime
file loading and other template engines are later extensions.

The demo serves [`src/page.html`](src/page.html) at `/page?name=...`. The
development watcher rebuilds when that file changes.

### Routing

Routing is ordinary Zig control flow over a single path cursor. Matchers
consume path segments, and they never allocate.
Cost depends on the number of sibling alternatives tried and the string
comparisons they make; there is no unconditional O(depth) bound.

| Matcher | Behavior |
|---|---|
| `req.onLiteral("users")` | Consumes the next segment if it equals `"users"`. |
| `req.onSegment()` | Consumes and returns the next segment (`?[]const u8`). |
| `req.onInt(u64)` | Parses the next segment as a base-10 integer, then consumes it (`?u64`). |
| `req.isLiteral("echo")` | Matches when `"echo"` is the final remaining segment. |
| `req.isInt(u64)` | Parses and consumes an integer only when it is the final remaining segment (`?u64`). |
| `req.isRoot()` | True when no segments remain. |
| `req.isGet()` / `req.method == .post` | Method checks. |
| `req.mark()` / `req.restore(saved)` | Saves and rewinds the cursor to try another alternative. |

For a dynamic segment, bind the returned slice locally, as the `/users/:id`
route above does. It borrows request storage and is valid only while that
request is alive. Named capture lookup is deferred pending a demonstrated
routing need; see the [Phase 4 decision](zoda_plan.md#named-captures-decision-issue-30).
For numeric IDs, `if (req.onInt(u64)) |id| { ... }` yields a parsed value.
The integer type sets the range; malformed or overflowing values return `null`.
Both integer matchers leave the cursor unchanged on failure, so a later
alternative can still read the original segment. `onSegment()` continues to
return a borrowed slice when the original text is needed.
An additional route DSL is deferred; see the
[compiler-supported conveniences decision](zoda_plan.md#compiler-supported-conveniences-decision-issue-31).

Rules to follow:

- A failed matcher leaves the cursor unchanged.
- After a prefix matches, **`return`** at the end of that branch even if you
  wrote no response. Otherwise `GET /users` could fall through to a later
  root handler. To delegate a whole branch, use `return child(ctx, req, res)`.
- Try alternatives before you write a response or cause side effects.
  `restore` rewinds only the routing cursor.
- If the route leaves the response unhandled, dispatch returns
  `404 Not Found`. Automatic 405/`Allow` and HEAD-to-GET fallback are not
  implemented yet.
- `/users` and `/users/` are different routes. Path segments are
  percent-decoded once. Dot segments, `\`, decoded `/`, and NUL are rejected
  with 400.

Query strings, headers, and the body are available on the request. The
returned slices borrow request storage and must not outlive the request:

```zig
var tags = req.getAll("tag");             // every ?tag= value, in order
while (tags.next()) |tag| { _ = tag; }
const page = try req.getOne("page");      // ?[]const u8; error.DuplicateQueryValue if repeated
const ua = try req.getHeaderOne("user-agent"); // case-insensitive lookup
const body = req.body;                    // fully buffered body
```

### Responses

A `Response` owns copies of its body and headers, allocated from the app's
`response_allocator`. Responses are fully buffered (1 MiB body limit by
default). Streaming is not supported.

```zig
try res.text(201, "created");                       // text/plain
try res.replaceJson(200, User, user);               // application/json
try ctx.plugins.json.render(res, User, user);       // same, through the plugin
try res.setHeader("Cache-Control", "no-store");     // CR, LF, and NUL are rejected
try res.setHeaderFmt("X-Request-Id", "{d}", .{id});
```

For a local redirect, choose the status explicitly in a route:

```zig
if (req.isLiteral("old") and req.isGet()) {
    return res.redirectPath(.found, "/new"); // 302
}
if (req.isLiteral("submit") and req.method == .post) {
    return res.redirectPath(.see_other, "/receipt"); // 303
}
```

`redirectPath` accepts a path beginning with one `/`, including an optional
query or fragment. It rejects external and ambiguous destinations, header
injection bytes, malformed escapes, and an existing `Location` header. The
redirect has an empty body and respects response header limits. Choose `.found`
(302) or `.see_other` (303) when a client may follow with GET; choose
`.temporary_redirect` (307) or `.permanent_redirect` (308) to preserve the
request method and body. See `examples/contract.zig` for a compiling route.
HTTPS redirection is not provided until the server has a trusted request-scheme
contract; forwarded scheme headers are not trusted by default.

Repeated headers such as `Set-Cookie` are kept as separate fields. The
transport sets `Content-Length` and other framing headers itself.

### Plugins

A plugin is a struct instance in your `Plugins` struct. If it declares a
`State` type and an `initRequest` hook, Zoda creates per-request state, which
the route can read through `ctx.state.<name>`:

```zig
const RequestId = struct {
    prefix: []const u8,

    pub const State = struct { id: []const u8 };

    pub fn initRequest(self: *const RequestId, req: *zoda.router.Request) !State {
        _ = req;
        return .{ .id = self.prefix };
    }

    pub fn deinitRequest(_: *const RequestId, _: *State) void {}
};

const Plugins = struct {
    json: zoda.Json = .{},
    request_id: RequestId = .{ .prefix = "req" },
};
```

- State is initialized in declaration order and cleaned up in reverse order,
  including after a partial initialization failure.
- `deinitRequest` cannot fail and must not write a response.
- Plugin instances are immutable during dispatch. Any shared mutable resource
  they reference must do its own synchronization.
- Call plugin methods through `ctx.plugins.<name>` so the registered instance
  stays explicit. See the [Phase 4 decision](zoda_plan.md#compiler-supported-conveniences-decision-issue-31).

#### Bearer tokens

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

#### Cookie sessions

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

#### CSRF helpers

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

### Middleware

Middleware wraps the whole route, including the default 404. Each entry pairs a
configuration pointer with a function that receives a single-use `next`
continuation:

```zig
const ApiKey = struct { expected: []const u8 };

fn requireKey(
    raw: *const anyopaque,
    ctx: *App.Context,
    req: *zoda.router.Request,
    res: *zoda.response.Response,
    next: App.Next,
) anyerror!void {
    const cfg: *const ApiKey = @ptrCast(@alignCast(raw));
    const key = (try req.getHeaderOne("x-api-key")) orelse "";
    // Short circuit: return without calling `next`.
    if (!std.mem.eql(u8, key, cfg.expected)) return res.text(401, "unauthorized");

    try next.call(ctx, req, res);
    // Success post-processing runs only if `next.call` succeeded.
    try res.setHeader("X-Authenticated", "1");
}

const api_key: ApiKey = .{ .expected = "secret" }; // must outlive the app

var app = try App.init(gpa, .{
    .response_allocator = gpa,
    .plugins = .{},
    .route_fn = route,
    .middleware = &.{.{ .config = &api_key, .invoke = requireKey }},
});
defer app.deinit();
```

- Entries run in registration order and unwind in reverse. After the route,
  an unhandled response becomes 404 before middleware unwinds, so every entry
  sees the 404. A short circuit that writes nothing skips the route, so outer
  entries see an unhandled response; `dispatch` applies the 404 after the
  chain returns.
- `App.init` copies the entry list, so the caller's array can be reused or go
  out of scope. The configuration objects are borrowed: keep them immutable
  and alive until `app.deinit()`. Static, stack, and heap configuration all
  work under that rule, and one configuration object can serve several entries,
  apps, and threads, because nothing writes to it.
- `next` runs the rest of the chain once. A second call, including a call
  through a copy, returns `error.NextAlreadyCalled` without running anything
  again.
- Errors propagate through middleware to `dispatch`. Put cleanup in `defer`.
  To recover from an error, call `res.clear()` before writing a replacement.
- Each request gets its own continuation frames, including a request
  dispatched from inside middleware. Concurrent requests do not share them.
- Do not store `next`, return it, or call it after your function returns or
  from another thread. Zig cannot check this for you, and the tests do not
  make an escaped `next` safe: they cover only the supported uses above.

### Route wrappers

A plugin can wrap the route by declaring an optional `wrapRoute` hook. The
hook runs at comptime and returns a new route function. `H` describes the app
and this plugin: `H.Context` and `H.RouteFn` are the app's types,
`H.plugin(ctx)` is the configured plugin instance, and `H.state(ctx)` is its
request state, if it has one.

```zig
const RequireHeader = struct {
    name: []const u8,

    pub fn wrapRoute(comptime H: type, comptime inner: H.RouteFn) H.RouteFn {
        return struct {
            fn run(ctx: *H.Context, req: *zoda.router.Request, res: *zoda.response.Response) anyerror!void {
                const self = H.plugin(ctx);
                // Skip the inner wrappers and the route.
                if (try req.getHeaderOne(self.name) == null) return res.text(400, "missing header");
                try inner(ctx, req, res);
                try res.setHeader("X-Checked-By", ctx.config.name);
            }
        }.run;
    }
};

const Plugins = struct { require: RequireHeader = .{ .name = "x-client" } };
const App = zoda.app.App(Plugins);

var app = try App.init(gpa, .{
    .response_allocator = gpa,
    .plugins = .{},
    // Compose at comptime; `route` must be comptime-known.
    .route_fn = App.composeRoute(route),
});
defer app.deinit();
```

- `App.composeRoute(route)` wraps `route` with every plugin hook. The first
  plugin field is outermost: wrappers enter in declaration order and exit in
  reverse. Plugins without a hook are skipped. Without any hooks, you get
  `route` back.
- Wrappers run inside the middleware chain, just before the default 404. A
  wrapper that returns after a route miss still sees an unhandled response,
  so it can write its own fallback. Otherwise the 404 is applied afterwards,
  and middleware sees it.
- To skip the route, return without calling `inner`. Errors from the route
  propagate through the wrappers to middleware and `dispatch`.
- A route passed to `route_fn` without `composeRoute` runs no wrappers.

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

### Host authorization

`zoda.host_authorization.middleware(App, &hosts)` rejects requests before
routing or static serving unless exactly one `Host` field matches an allowed
authority. Put it before `zoda.static.middleware` and every other middleware
that can answer a request:

```zig
const hosts: zoda.host_authorization.Config = .{
    .allowed_hosts = &.{ "example.com", "example.com:8080" },
};
var app = try App.init(gpa, .{
    .response_allocator = gpa,
    .plugins = .{},
    .route_fn = route,
    .middleware = &.{
        try zoda.host_authorization.middleware(App, &hosts),
        zoda.static.middleware(App, &static_config),
    },
});
defer app.deinit();
```

The allowlist is validated when the middleware entry is created. A Host is an
ASCII DNS-style name (including IPv4-style names) with optional `:port`.
Names are compared case-insensitively, with no suffix matching. Ports must be
decimal from 1 through 65535, with no leading zeroes; a configured port only
matches that port, and an entry without a port only matches an unported Host.
Empty labels, trailing dots, internal whitespace, userinfo, bracketed IP literals,
and other malformed authorities are rejected. Surrounding spaces and tabs on a
request's Host field are ignored, as with the socket parser; allowlist entries
must contain no surrounding whitespace. Missing or duplicate Host fields
receive 403, including on HTTP/1.0 requests. An unauthorized request receives
`403 Forbidden` with a fixed body and never reaches downstream middleware or
the route. `X-Forwarded-Host` and `Forwarded` are ignored; no trusted-proxy
boundary is configured. The transport retains the ordered Host fields and does
not expose a normalized authority, so direct dispatch uses the same rule.
Keep the configuration and its strings immutable and alive until `app.deinit()`.

### Default response headers

`zoda.default_headers.middleware(App, &config)` adds configured headers after
downstream middleware and routing complete. Place it first to cover static
files, short circuits, and the default 404:

```zig
const defaults: zoda.default_headers.Config = .{
    .headers = &.{
        .{ .name = "X-Frame-Options", .value = "DENY" },
        .{ .name = "Referrer-Policy", .value = "no-referrer" },
    },
};
var app = try App.init(gpa, .{
    .response_allocator = gpa,
    .plugins = .{},
    .route_fn = route,
    .middleware = &.{try zoda.default_headers.middleware(App, &defaults)},
});
defer app.deinit();
```

The middleware validates its configuration when the entry is created. Header
names are case-insensitive: duplicate default names are rejected, and any
existing response field with that name wins. Default fields are appended only
after successful downstream dispatch; an error propagates without adding
them. `Content-Type` and transport-owned framing or connection fields cannot
be configured as defaults. Response header count and byte limits still apply.
The configuration and its nested strings must remain immutable and valid until
`app.deinit()`. The [compiling contract example](examples/contract.zig) includes
this middleware.

### Response timing

`zoda.timing.middleware(App)` adds `X-Response-Time-Ms` (whole milliseconds,
truncated) to every response that completes without an error. It reads the
application clock from `config.clock`:

```zig
var app = try App.init(gpa, .{
    .response_allocator = gpa,
    // CLOCK_MONOTONIC on Linux, read through the app's `std.Io`.
    .config = .{ .clock = .monotonic(io) },
    .plugins = .{},
    .route_fn = route,
    // Register timing first so it also times the other middleware.
    .middleware = &.{ zoda.timing.middleware(App), .{ .config = &api_key, .invoke = requireKey } },
});
defer app.deinit();
```

- Routed responses, short circuits, and the default 404 are all timed. If
  `next.call` returns an error, the header is not added and the error
  propagates.
- The value is copied into the response, so it stays valid after the request
  is released.
- If `config.clock` is `null`, every request fails with
  `error.ClockNotConfigured` before downstream code runs.
- For deterministic tests, inject a clock with
  `.{ .source = .{ .context = &fake, .now = readFake } }`, where `readFake`
  returns a `std.Io.Timestamp`. A clock read by concurrent requests must be
  thread-safe; `.monotonic(io)` is.

### Request IDs and access logs

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

### Static files

`zoda.static.middleware(App, &config)` serves `GET` and `HEAD` requests for
regular files beneath a document-root directory handle that you open and own:

```zig
const public = try std.Io.Dir.cwd().openDir(io, "public", .{});
defer public.close(io); // after app.deinit()
// Fails with error.ConfinementUnavailable where requests would fail closed.
try zoda.static.checkSupport(public);

const static_config: zoda.static.Config = .{
    .root = public,
    .prefix = &.{"assets"}, // GET /assets/app.css -> public/app.css
};

var app = try App.init(gpa, .{
    .response_allocator = gpa,
    .config = .{ .clock = .monotonic(io) },
    .plugins = .{},
    .route_fn = route,
    // Static first: hits skip timing and the route; everything else is timed.
    // Put timing first instead to time static hits too.
    .middleware = &.{ zoda.static.middleware(App, &static_config), zoda.timing.middleware(App) },
});
defer app.deinit();
```

- A hit writes a 200 with a content type chosen by extension and
  `X-Content-Type-Options: nosniff`, and does not call `next`, so the route
  never runs. Everything else calls `next` with the request unchanged: other
  methods, paths outside the prefix, missing files, directories, symlinks,
  dotfiles, and special files such as FIFOs.
- Files are opened with Linux `openat2` and
  `RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS`, so the kernel refuses `..` escapes,
  absolute paths, and symlinks in any path component in the same call that
  opens the file. There is no check-then-open race. Encoded traversal such as
  `%2e%2e` or `..%2F` is rejected earlier, by the request parser, with 400.
- Directory listing is not implemented, and directories are never served.
  There is no index-file lookup.
- Dotfiles (`.env`, `.git/…`) are hidden unless `allow_dotfiles = true`.
- Files are buffered. A file larger than `max_file_bytes` or the 1 MiB
  response limit fails with `error.BodyTooLarge`, which the transport answers
  with a generic 500. Treat that as a configuration error.
- **Platform support:** Linux 5.6 or later. On other systems, or where
  `openat2` is missing or blocked (for example by a seccomp filter), requests
  fail with `error.ConfinementUnavailable` instead of opening files without
  confinement. Run `checkSupport` at startup to find out early.
- A hard link inside the root to a file outside it is served like any other
  file. Keep the document root read-only to the server process.

### Dispatching without sockets

Tests can build a request and dispatch it directly, without the network:

```zig
var req_arena = try zoda.request.parseOriginForm(std.testing.allocator, .default, "/users/42");
defer req_arena.deinit();
var req = req_arena.requestView(.get);

var res = try app.dispatch(&req);
defer res.deinit();

try std.testing.expectEqual(@as(u16, 200), res.status_code);
try std.testing.expectEqualStrings("application/json", res.content_type);
```

### Server configuration

`zoda.server.serve` accepts connections until its task is canceled or the
listener is closed. All `server.Config` fields have defaults:

| Field | Default |
|---|---|
| `max_connections` | 128 (connections above the cap are rejected immediately) |
| `header_timeout` / `body_read_timeout` / `write_timeout` | 10 s each, as absolute deadlines |
| `keep_alive_idle_timeout` | 5 s |
| `shutdown_grace_period` | 10 s, then remaining sockets are shut down |
| `max_requests_per_connection` | 100 |
| `request_limits` | 8 KiB target, 100 headers / 32 KiB header bytes, 128 path segments, 256 query pairs, 1 MiB body |
| `stats` | optional `*server.Stats` with live `active`/`peak`/`admitted`/`rejected` counters |

Requests that break a limit get a 400, 413, 414, or 431 response, and the
connection is closed. The server rejects `Expect`, content codings, and
ambiguous framing (for example, a signed `Content-Length` or malformed
chunked encoding).

### Performance

Benchmark results, the standard `wrk` procedure, and the list of performance
proposals are kept in [performance_improvement.md](performance_improvement.md).
The default `max_connections` is 128, so a 400-connection run exceeds that cap
and reports socket read errors.

## License

No license file has been added yet.
