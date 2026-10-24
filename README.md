# Zoda

Zoda is a small Zig web toolkit inspired by
[Roda](https://github.com/jeremyevans/roda). You write routes as nested,
imperative code, and you extend a small core with plugins that you register
explicitly. It targets JSON APIs and server-rendered sites.

> **Status:** early development. The router, app dispatch, buffered
> responses, JSON plugin, and a hardened HTTP/1.1 socket server are
> implemented and tested. The roadmap is in [`zoda_plan.md`](zoda_plan.md).

## Requirements

- Zig **0.16.0** (exact pin). Other versions are not supported.
- Primary platform: `x86_64-linux-gnu`. Other targets are best-effort.

[`PLATFORM.md`](PLATFORM.md) covers installation, the allocator and threading
contracts, and validation evidence.

## Building and testing

```sh
zig build                                        # library + demo executable
zig build test                                   # unit and acceptance tests
zig build test-hardening -Doptimize=ReleaseSafe  # adversarial HTTP/1.1 tests over real sockets
zig build test-load -Doptimize=ReleaseSafe       # 60-second load and overload measurement
zig fmt --check build.zig src                    # formatting gate used by CI
./zig-out/bin/zoda                               # run the demo
```

The demo dispatches a few requests in memory and prints the outcomes:

```text
get / -> 200 text/plain
get /users/42 -> 200 application/json
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

- **Build fails:** it prints the compiler diagnostics and keeps the last
  working server running.
- **Build succeeds:** it stops the old server (SIGTERM, then SIGKILL after
  5 s) and starts the new one.

Press Ctrl-C to stop both. Edit-to-response time measured 1.4–1.9 s on a
4-core laptop (`zig build test-devloop` repeats the measurement on your
machine and checks failed-build recovery). The watcher supports Linux only. You can also run the demo server
directly with `./zig-out/bin/zoda serve [port]`.

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

### Routing

Routing is ordinary Zig control flow over a single path cursor. Matchers
consume path segments, and they never allocate.

| Matcher | Behavior |
|---|---|
| `req.onLiteral("users")` | Consumes the next segment if it equals `"users"`. |
| `req.onSegment()` | Consumes and returns the next segment (`?[]const u8`). |
| `req.isLiteral("echo")` | Matches when `"echo"` is the final remaining segment. |
| `req.isRoot()` | True when no segments remain. |
| `req.isGet()` / `req.method == .post` | Method checks. |
| `req.mark()` / `req.restore(saved)` | Saves and rewinds the cursor to try another alternative. |

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

## License

No license file has been added yet.
