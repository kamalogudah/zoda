# Getting started with Zoda

This tutorial builds a small notes app with Zoda in three steps: a plain JSON
and HTML server, then a React front end through Inertia, then several plugins
working together.

Zoda is a small Zig web toolkit inspired by Ruby's
[Roda](https://github.com/jeremyevans/roda). Routes are nested, imperative
code: each request walks a tree of `if` checks that consume the path segment
by segment. A small core is extended with plugins you register explicitly in a
struct, so the compiler knows every plugin your app uses.

You need:

- Zig **0.16.0** exactly (other versions are not supported)
- Linux on x86_64 (the primary platform; others are best-effort)
- Node.js and npm, for Part 2 only

Zoda is in early development, so pin a specific commit when you depend on it.
Every snippet here was compiled and run with Zig 0.16.0 against Zoda commit
`ccef738`, using `@inertiajs/react` 3.9.1 and Vite 8.3.5.

- [Project setup](#project-setup)
- [Part 1: A plain Zoda app](#part-1-a-plain-zoda-app)
- [Part 2: Adding React with Inertia](#part-2-adding-react-with-inertia)
- [Part 3: Using multiple plugins together](#part-3-using-multiple-plugins-together)
- [Next steps](#next-steps)

## Project setup

Create a project, add Zoda as a dependency, and import its `zoda` module into
your executable.

```sh
mkdir notes && cd notes
zig init
zig fetch --save git+https://github.com/kamalogudah/zoda
```

Zoda has no tagged release yet, so `zig fetch` records the current commit's
hash in `build.zig.zon`. Replace the executable in the generated `build.zig`
with this:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zoda = b.dependency("zoda", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "notes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zoda", .module = zoda.module("zoda") }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    b.step("run", "Run the notes server").dependOn(&run.step);
}
```

`setCwd` matters in Part 2: the server reads the built front-end assets from
paths relative to the project root.

## Part 1: A plain Zoda app

By the end of this part you have a notes server with an HTML home page, a JSON
API, typed request parsing, a middleware, and an in-memory test, all without
any JavaScript.

### Step 1: Hello, Zoda

Every Zoda app has three pieces: a `Plugins` struct, an `App` type built from
it, and a route function. Put this in `src/main.zig`:

```zig
const std = @import("std");
const zoda = @import("zoda");

const Plugins = struct {};
const App = zoda.app.App(Plugins);

fn route(ctx: *App.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    _ = ctx;
    if (req.isRoot() and req.isGet()) return res.text(200, "hello from zoda");
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // `serve` uses the allocator from concurrent connection tasks,
    // so it must be thread-safe.
    const gpa = std.heap.smp_allocator;

    const app: App = .{
        .response_allocator = gpa,
        .config = .{ .name = "notes" },
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
$ zig build run
$ curl localhost:8080/
hello from zoda
$ curl -i localhost:8080/missing
HTTP/1.1 404 Not Found
```

Any request the route leaves unanswered becomes `404 Not Found` automatically.

### Step 2: How routing works

A route is ordinary Zig control flow over a path cursor. Each matcher either
consumes a segment and returns a value, or fails and leaves the cursor where it
was.

| Matcher | What it does |
| --- | --- |
| `req.onLiteral("notes")` | Consumes the next segment if it is `notes` |
| `req.onSegment()` | Consumes and returns the next segment (`?[]const u8`) |
| `req.onInt(u64)` | Parses and consumes the next segment as an integer (`?u64`) |
| `req.isLiteral("about")` | Matches when `about` is the last remaining segment |
| `req.isRoot()` | True when no segments remain |
| `req.isGet()`, `req.method == .post` | Method checks |
| `req.getOne("q")`, `req.getAll("tag")` | Query string values |
| `req.getHeaderOne("user-agent")` | Case-insensitive header lookup |

Two rules prevent most routing bugs:

1. After a prefix matches, `return` at the end of that branch, even when you
   wrote no response. Otherwise `GET /notes/abc` could fall through to a later
   handler.
2. `/notes` and `/notes/` are different routes.

Slices returned by `onSegment`, `getOne` and `req.body` borrow request memory.
Copy them if they must outlive the request. The full matcher list is in the
[README](README.md#routing).

### Step 3: Application state as a plugin

Plugins are any struct you put in `Plugins`, so the simplest way to hand the
route your data store is a plugin that holds a pointer to it. The server
handles requests concurrently, so the store guards its list with a mutex.

```zig
const Note = struct { id: u64, title: []const u8, body: []const u8 };

const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(Note) = .empty,
    next_id: u64 = 1,

    fn deinit(self: *Store) void {
        for (self.items.items) |n| {
            self.allocator.free(n.title);
            self.allocator.free(n.body);
        }
        self.items.deinit(self.allocator);
    }

    fn add(self: *Store, title: []const u8, body: []const u8) !u64 {
        const t = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(t);
        const b = try self.allocator.dupe(u8, body);
        errdefer self.allocator.free(b);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const id = self.next_id;
        try self.items.append(self.allocator, .{ .id = id, .title = t, .body = b });
        self.next_id += 1;
        return id;
    }

    fn count(self: *Store) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.items.items.len;
    }
};

const Plugins = struct {
    store: struct { value: *Store },
    json: zoda.Json = .{},
    json_parser: zoda.JsonParser = .{},
};
```

`zoda.Json` renders typed values as JSON. `zoda.JsonParser` parses a request
body into a type you choose, with a 1 MiB default limit.

### Step 4: A JSON API

Nest the matchers to build `/api/notes` and `/api/notes/:id`. Delegating a
whole branch to its own function keeps the tree readable.

```zig
const NewNote = struct { title: []const u8, body: []const u8 };

fn route(ctx: *App.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    if (req.isRoot() and req.isGet()) return home(ctx, res);
    if (req.onLiteral("api")) return api(ctx, req, res);
}

fn api(ctx: *App.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    if (!req.onLiteral("notes")) return;
    const store = ctx.plugins.store.value;

    // GET /api/notes, POST /api/notes
    if (req.isRoot()) {
        if (req.isGet()) {
            store.mutex.lockUncancelable(store.io);
            defer store.mutex.unlock(store.io);
            return ctx.plugins.json.render(res, []const Note, store.items.items);
        }
        if (req.method == .post) {
            var parsed = ctx.plugins.json_parser.parse(res.allocator, req, NewNote) catch |err| switch (err) {
                error.BodyTooLarge => return res.text(413, "body too large"),
                error.OutOfMemory => return err,
                else => return res.text(400, "expected {\"title\",\"body\"}"),
            };
            defer parsed.deinit();
            const id = try store.add(parsed.value.title, parsed.value.body);
            try res.setHeaderFmt("Location", "/api/notes/{d}", .{id});
            return res.text(201, "created");
        }
        return;
    }

    // GET /api/notes/:id
    if (req.isInt(u64)) |id| {
        if (!req.isGet()) return;
        store.mutex.lockUncancelable(store.io);
        defer store.mutex.unlock(store.io);
        for (store.items.items) |note| {
            if (note.id == id) return ctx.plugins.json.render(res, Note, note);
        }
        return res.text(404, "note not found");
    }
}
```

`JsonParser` requires `Content-Type: application/json` and rejects unknown
fields, so a client mistake becomes a clear 400:

```console
$ curl -X POST localhost:8080/api/notes -H 'content-type: application/json' \
    -d '{"title":"Zig","body":"Learn comptime"}'
created
$ curl localhost:8080/api/notes/1
{"id":1,"title":"Zig","body":"Learn comptime"}
```

### Step 5: An HTML page from an embedded template

Create `src/home.html`. Templates are compiled into the binary with
`@embedFile`, and `{{field}}` reads a field from the struct you pass,
HTML-escaped.

```html
<!doctype html>
<html>
  <head><meta charset="utf-8"><title>Notes</title></head>
  <body>
    <h1>{{app}}</h1>
    <p>You have {{count}} notes.</p>
  </body>
</html>
```

```zig
fn home(ctx: *App.Context, res: *zoda.response.Response) !void {
    return zoda.template.render(res, 200, @embedFile("home.html"), .{
        .app = ctx.config.name,
        .count = ctx.plugins.store.value.count(),
    });
}
```

Placeholders are allowed only in text nodes. One inside an attribute,
`<script>` or `<style>` returns `error.UnsupportedContext`, which closes off a
whole class of injection bugs.

### Step 6: Add middleware

Middleware wraps the whole route, including the automatic 404. Zoda ships
several; `zoda.timing` adds an `X-Response-Time-Ms` header. Apps with
middleware are built with `App.init` instead of a struct literal. Update
`main`:

```zig
var store: Store = .{ .allocator = gpa, .io = io };
defer store.deinit();

var app = try App.init(gpa, .{
    .response_allocator = gpa,
    .config = .{ .name = "notes", .clock = .monotonic(io) },
    .plugins = .{ .store = .{ .value = &store } },
    .route_fn = route,
    .middleware = &.{zoda.timing.middleware(App)},
});
defer app.deinit();
```

A custom middleware is a function that receives a single-use `next`
continuation. Return without calling `next` to short-circuit:

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
    if (!std.mem.eql(u8, key, cfg.expected)) return res.text(401, "unauthorized");
    try next.call(ctx, req, res);
}

const api_key: ApiKey = .{ .expected = "secret" }; // must outlive the app
// .middleware = &.{ zoda.timing.middleware(App), .{ .config = &api_key, .invoke = requireKey } },
```

Entries run in registration order and unwind in reverse, so put `timing` first
to time everything after it.

### Step 7: Test without a socket

`app.dispatch` runs a request in memory, so route tests need no running
server. Add a test step at the end of `build` in `build.zig`:

```zig
const tests = b.addTest(.{ .root_module = exe.root_module });
b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);
```

Then add a test to `src/main.zig` and run it with `zig build test`:

```zig
test "creating and fetching a note" {
    var store: Store = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer store.deinit();
    const app: App = .{
        .response_allocator = std.testing.allocator,
        .config = .{},
        .plugins = .{ .store = .{ .value = &store } },
        .route_fn = route,
    };

    var arena = try zoda.request.parseOriginForm(std.testing.allocator, .default, "/api/notes/1");
    defer arena.deinit();
    _ = try store.add("Zig", "Learn comptime");
    var req = arena.requestView(.get);
    var res = try app.dispatch(&req);
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 200), res.status_code);
}
```

The repository's [`examples/todo.zig`](examples/todo.zig) is a complete app in
this style; run it with `zig build run-todo`.

## Part 2: Adding React with Inertia

Inertia lets the Zig server keep routing and data while React renders the
pages, with no separate JSON API to design. You will add `zoda.Inertia`, serve
a Vite-built React bundle with `zoda.static`, and turn the notes list into a
React page.

### How Inertia fits in

1. The first visit gets a full HTML document: your layout, with the page's
   component name and props embedded as JSON.
2. The React client reads that JSON and mounts the named component.
3. Later link clicks and form posts send `X-Inertia: true`. The same Zoda
   route answers with only the page JSON, and React swaps the component in
   place.

The route code is identical for both cases: it calls
`inertia.render(req, res, "Notes/Index", props)` and the plugin picks HTML or
JSON.

### Step 1: The React client

Create a `frontend` directory next to `src`:

```sh
mkdir -p frontend/src/Pages/Notes frontend/src/Pages/Errors && cd frontend
npm init -y
npm install @inertiajs/react@3.9.1 react@19.3.1 react-dom@19.3.1
npm install -D vite@8.3.5 @vitejs/plugin-react@6.1.2
```

Add `"type": "module"` and a build script to `frontend/package.json`:

```json
{
  "type": "module",
  "scripts": { "build": "vite build", "watch": "vite build --watch" }
}
```

The Zig layout links fixed file names, so configure Vite to always write
`dist/assets/app.js` and `dist/assets/app.css`. `frontend/vite.config.js`:

```js
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    rolldownOptions: {
      input: 'src/main.jsx',
      output: {
        entryFileNames: 'assets/app.js',
        chunkFileNames: 'assets/[name].js',
        assetFileNames: 'assets/app[extname]',
      },
    },
  },
})
```

The entry point resolves a component name such as `Notes/Index` to a file
under `Pages`. Importing a stylesheet makes Vite write `app.css`, which the
layout links. `frontend/src/main.jsx`:

```jsx
import { createInertiaApp } from '@inertiajs/react'
import './style.css'

const pages = import.meta.glob('./Pages/**/*.jsx', { eager: true })

// Reads the page from <script data-page="app"> and mounts into #app.
createInertiaApp({
  resolve: (name) => pages[`./Pages/${name}.jsx`],
})
```

Create `frontend/src/style.css` with any styles, for example:

```css
body { font-family: system-ui, sans-serif; max-width: 40rem; margin: 2rem auto; padding: 0 1rem; }
```

### Step 2: The page components

Props arrive as ordinary React props. `useForm` posts through the Inertia
router, so the server's redirect becomes an in-place page update.
`frontend/src/Pages/Notes/Index.jsx`:

```jsx
import { Link, useForm } from '@inertiajs/react'

export default function Index({ app, notes }) {
  const form = useForm({ title: '', body: '' })

  function add(event) {
    event.preventDefault()
    form.post('/notes', { preserveScroll: true, onSuccess: () => form.reset() })
  }

  return (
    <main>
      <h1>{app}</h1>
      <form onSubmit={add}>
        <input value={form.data.title} onChange={(e) => form.setData('title', e.target.value)} placeholder="Title" />
        <textarea value={form.data.body} onChange={(e) => form.setData('body', e.target.value)} />
        <button disabled={form.processing}>Save</button>
      </form>
      <ul>
        {notes.map((note) => (
          <li key={note.id}>
            <Link href={`/notes/${note.id}`}>{note.title}</Link>
          </li>
        ))}
      </ul>
    </main>
  )
}
```

The server in Step 4 also renders `Notes/Show` and `Errors/NotFound`, so add
those components. `frontend/src/Pages/Notes/Show.jsx`:

```jsx
import { Link } from '@inertiajs/react'

export default function Show({ note }) {
  return (
    <main>
      <h1>{note.title}</h1>
      <p>{note.body}</p>
      <Link href="/notes">Back to notes</Link>
    </main>
  )
}
```

`frontend/src/Pages/Errors/NotFound.jsx`:

```jsx
import { Link } from '@inertiajs/react'

export default function NotFound({ id }) {
  return (
    <main>
      <h1>Note {id} not found</h1>
      <Link href="/notes">Back to notes</Link>
    </main>
  )
}
```

Build it once with `npm run build`, or keep `npm run watch` running while you
work.

### Step 3: Register the plugin

`zoda.Inertia(Shared)` takes a struct of props sent with every page. Add it to
`Plugins` next to what you already have, and write the layout. The `@inertia`
marker is where the page goes.

```zig
const Shared = struct { app: []const u8 };

const Plugins = struct {
    inertia: zoda.Inertia(Shared),
    store: struct { value: *Store },
    json: zoda.Json = .{},
    json_parser: zoda.JsonParser = .{},
};
const App = zoda.app.App(Plugins);

const layout =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1">
    \\  <title>Notes</title>
    \\  <link rel="stylesheet" href="/assets/app.css">
    \\  <script type="module" src="/assets/app.js"></script>
    \\</head>
    \\<body>@inertia</body>
    \\</html>
;
```

### Step 4: Inertia routes

Add a `/notes` branch beside the JSON API from Part 1. `render` sends the
page; `redirect` answers a form post with 303 so the client follows with a
GET.

```zig
fn route(ctx: *App.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    const inertia = &ctx.plugins.inertia;
    if (req.isRoot() and req.isGet()) return inertia.redirect(req, res, "/notes");
    if (req.onLiteral("api")) return api(ctx, req, res);
    if (req.onLiteral("notes")) return notes(ctx, req, res);
}

fn notes(ctx: *App.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    const inertia = &ctx.plugins.inertia;
    const store = ctx.plugins.store.value;

    if (req.isRoot()) {
        if (req.isGet()) {
            store.mutex.lockUncancelable(store.io);
            defer store.mutex.unlock(store.io);
            return inertia.render(req, res, "Notes/Index", .{ .notes = store.items.items });
        }
        if (req.method == .post) {
            var parsed = ctx.plugins.json_parser.parse(res.allocator, req, NewNote) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return res.text(400, "expected a title and body"),
            };
            defer parsed.deinit();
            _ = try store.add(parsed.value.title, parsed.value.body);
            return inertia.redirect(req, res, "/notes");
        }
        return;
    }

    // GET /notes/:id renders a second component, Notes/Show.
    if (req.isInt(u64)) |id| {
        if (!req.isGet()) return;
        store.mutex.lockUncancelable(store.io);
        defer store.mutex.unlock(store.io);
        for (store.items.items) |note| {
            if (note.id == id) return inertia.render(req, res, "Notes/Show", .{ .note = note });
        }
        return inertia.renderWith(req, res, "Errors/NotFound", .{ .id = id }, .{ .status = 404 });
    }
}
```

Shared props are merged first, so `Notes/Index` receives `app` and `notes`. A
route prop with the same name as a shared prop replaces it, and the clash is
checked at comptime.

### Step 5: Serve the bundle and set the asset version

`zoda.static` serves the built files under `/assets`. The asset version is a
hash of `app.js`: after you rebuild and restart, an open tab that sends the
old version gets a 409 and reloads, so it never mixes old JavaScript with new
props.

```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.smp_allocator;

    var assets = try std.Io.Dir.cwd().openDir(io, "frontend/dist/assets", .{});
    defer assets.close(io);
    try zoda.static.checkSupport(assets);

    const bundle = try assets.readFileAlloc(io, "app.js", gpa, .limited(16 << 20));
    defer gpa.free(bundle);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bundle, &digest, .{});
    const version = std.fmt.bytesToHex(digest[0..8], .lower);

    var store: Store = .{ .allocator = gpa, .io = io };
    defer store.deinit();

    const static_config: zoda.static.Config = .{
        .root = assets,
        .prefix = &.{"assets"},
        .etag = true, // names are not fingerprinted, so revalidate with an ETag
    };
    var app = try App.init(gpa, .{
        .response_allocator = gpa,
        .config = .{ .name = "notes", .clock = .monotonic(io) },
        .plugins = .{
            .inertia = .{
                .layout = layout,
                .version = .{ .value = &version },
                .shared = .{ .value = .{ .app = "Zoda Notes" } },
            },
            .store = .{ .value = &store },
        },
        .route_fn = route,
        .middleware = &.{
            zoda.timing.middleware(App),
            zoda.static.middleware(App, &static_config),
        },
    });
    defer app.deinit();
    try app.plugins.inertia.validate(); // catch a bad layout before the first request

    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(8080) };
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    try zoda.server.serve(App, gpa, io, &listener, &app, .{});
}
```

```sh
(cd frontend && npm run build)
zig build run
```

Open <http://localhost:8080>. Adding a note posts JSON with `X-Inertia: true`,
the server redirects with 303, and the client fetches the new page JSON
without a full reload. The `/api/notes` routes from Part 1 still work beside
it.

### Step 6: Make expensive props lazy

Plain props are computed before `render`. Wrap costly ones so they are only
computed when sent. A resolver takes a context and an allocator, and runs
inside `render`, so it must not take a lock the route already holds, such as
the store mutex:

```zig
const Stats = struct {
    total: usize,

    // Called by `render` while the route holds the store lock, so no locking here.
    fn compute(store: *Store, _: std.mem.Allocator) Stats {
        return .{ .total = store.items.items.len };
    }
};

// In the GET /notes branch, still under the lock:
const inertia_props = zoda.plugins.inertia;

return inertia.render(req, res, "Notes/Index", .{
    .notes = store.items.items,
    // Left out of the first response; the client fetches it right after.
    .stats = inertia_props.deferred(store, Stats.compute),
    // Sent on every reload, even `router.reload({ only: ['notes'] })`.
    .count = inertia_props.always(store.items.items.len),
});
```

On the React side, wrap the part that needs `stats` in
`<Deferred data="stats" fallback="…">`. Other wrappers include `optional`,
`once`, `merge` and `scroll`; see [PLUGINS.md](PLUGINS.md#inertiajs).

## Part 3: Using multiple plugins together

This part grows the notes app into something you could deploy: signed
sessions, CSRF protection, flash messages, validation errors, request IDs,
error pages and security headers, all working beside Inertia.

### Five ways a plugin plugs in

Every plugin is registered explicitly, but not all in the same place. Knowing
which kind you have tells you where it goes.

| Kind | Where it goes | Examples |
| --- | --- | --- |
| Registered instance | A field in `Plugins`, called as `ctx.plugins.<name>` | `Json`, `JsonParser`, `Inertia`, `Flash` |
| Instance with request state | A field in `Plugins`; per-request data at `ctx.state.<name>` | `Sessions`, `RequestTrace` |
| Route wrapper | A field in `Plugins`, plus `.route_fn = App.composeRoute(route)` | `NotFound`, `BearerToken` (optional) |
| Middleware entry | An entry in `.middleware` | `request_trace`, `status_handler`, `error_handler`, `security_policy`, `static`, `timing` |
| Helper functions | Called directly; no registration | `plugins.csrf`, `plugins.http_cache` |

Plugin state is initialized in field order and cleaned up in reverse. Plugin
instances are immutable during dispatch, so anything shared and mutable they
point to, like the notes store, needs its own lock.

### Step 1: Declare the plugins

```zig
const csrf = zoda.plugins.csrf;
const status_handler = zoda.plugins.status_handler;
const error_handler = zoda.plugins.error_handler;
const security_policy = zoda.plugins.security_policy;

/// Sent with every page. `user` comes from the session on each render.
const Shared = struct { app: []const u8, user: ?[]const u8 };

const Plugins = struct {
    trace: zoda.RequestTrace,
    sessions: zoda.Sessions,
    flash: zoda.Flash = .{}, // lives inside the session cookie
    inertia: zoda.Inertia(Shared),
    json: zoda.Json = .{},
    json_parser: zoda.JsonParser = .{ .max_body_bytes = 16 * 1024 },
    store: struct { value: *Store },
};
const App = zoda.app.App(Plugins);
```

`Flash` has no state of its own. It reads and writes the session that
`Sessions` loads, which is why you always pass it `&ctx.state.sessions`.

### Step 2: Shared props from the session

`.fromContext` builds shared props on every render from request state, here
the signed-in user stored in the session payload:

```zig
fn shared(ctx: *App.Context, _: *const zoda.router.Request) Shared {
    const user = ctx.state.sessions.value();
    return .{ .app = "Zoda Notes", .user = if (user.len == 0) null else user };
}
```

### Step 3: One helper for every page

Each Inertia page now does four things: issue the CSRF cookie, pass the
context for shared props, send pending flash and validation errors, then save
the session so they are consumed. Put that in one function:

```zig
fn page(
    ctx: *App.Context,
    req: *zoda.router.Request,
    res: *zoda.response.Response,
    component: []const u8,
    props: anytype,
) !void {
    const session = &ctx.state.sessions;
    // The Inertia client copies XSRF-TOKEN into X-XSRF-TOKEN on every change.
    try csrf.setXsrfCookie(res, try csrf.token(ctx.plugins.store.value.io, session));
    try ctx.plugins.inertia.renderWith(req, res, component, props, .{
        .context = .of(ctx),
        .flash = flashSource(ctx),
    });
    return ctx.plugins.sessions.save(session, res);
}

fn flashSource(ctx: *App.Context) zoda.plugins.inertia.FlashSource {
    return .{ .plugin = &ctx.plugins.flash, .session = &ctx.state.sessions };
}
```

### Step 4: Routes that use them together

The CSRF check runs before any body is parsed. A failed form stores its errors
and redirects back; a successful one flashes a notice. The trace ID ties a log
line to the response's `X-Request-Id` header.

```zig
fn notes(ctx: *App.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    const session = &ctx.state.sessions;
    if (req.method != .get and req.method != .head and
        !csrf.validHeader(req, session, csrf.xsrf_header_name))
    {
        return res.text(403, "Missing or stale CSRF token; reload the page.");
    }

    const store = ctx.plugins.store.value;
    if (!req.isRoot()) return;

    if (req.isGet()) {
        store.mutex.lockUncancelable(store.io);
        defer store.mutex.unlock(store.io);
        return page(ctx, req, res, "Notes/Index", .{ .notes = store.items.items });
    }

    if (req.method == .post) {
        var parsed = ctx.plugins.json_parser.parse(res.allocator, req, NewNote) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return res.text(400, "expected a title and body"),
        };
        defer parsed.deinit();
        const title = std.mem.trim(u8, parsed.value.title, " \t\r\n");
        if (title.len == 0) {
            try ctx.plugins.inertia.redirectWithErrors(req, res, flashSource(ctx), "/notes", .{
                .title = "Give the note a title.",
            });
            return ctx.plugins.sessions.save(session, res);
        }
        const id = try store.add(title, parsed.value.body);
        std.log.info("request {s} created note {d}", .{ ctx.state.trace.id(), id });
        try ctx.plugins.flash.add(session, "notice", "Note saved");
        try ctx.plugins.sessions.save(session, res);
        return ctx.plugins.inertia.redirect(req, res, "/notes");
    }
}
```

In React, `form.errors.title` shows the stored error and
`usePage().flash.notice` shows the notice, each exactly once:

```jsx
const { flash } = usePage()
// ...
{form.errors.title && <p className="error">{form.errors.title}</p>}
{flash.notice && <p role="status">{flash.notice}</p>}
```

A login route is just a session write: `try ctx.state.sessions.set("ada")`,
then `save` and `redirect`. The next page's shared `user` is `"ada"`. Logging
out is `clear()` then `save`.

### Step 5: Configure and order the middleware

Middleware runs in registration order on the way in and in reverse on the way
out. Each entry only covers what runs after it, so order is the main decision:

1. `request_trace` first, so every response, including recovered errors and
   static files, gets an ID and one access record.
2. `timing`, to time everything below it.
3. `security_policy`, so error pages and static files also get CSP and
   Permissions-Policy.
4. `status_handler` outside `error_handler`, so one error page serves both
   error statuses and recovered errors.
5. `error_handler`, which clears a failed response and writes a 500.
6. `static` last, just before route wrappers and the route.

```zig
fn writeAccess(_: *anyopaque, r: zoda.plugins.request_trace.Record) void {
    std.log.info("id={s} method={t} path={s} status={?d} ms={d}", .{
        r.id, r.method, r.path, r.status, r.duration_ms,
    });
}

fn notFoundPage(_: *App.Context, _: *zoda.router.Request, res: *zoda.response.Response) !void {
    try res.text(404, "Page not found");
}

fn logError(_: *App.Context, req: *zoda.router.Request, _: *zoda.response.Response, err: anyerror) !void {
    std.log.err("{s} failed: {t}", .{ req.target, err }); // writing nothing leaves the generated 500
}

fn behindTls(_: *App.Context, _: *const zoda.router.Request) bool {
    return false; // return true only when every request really arrived over HTTPS
}

// Middleware configs are borrowed and must outlive the app.
const pages = status_handler.Config(App){ .handlers = &.{.{ .status = 404, .run = notFoundPage }} };
const recovery = error_handler.Config(App){ .handler = logError };
const policies = security_policy.Config(App){
    .content_security_policy = .{ .value = "default-src 'self'; frame-ancestors 'none'" },
    .permissions_policy = .{ .value = "camera=(), geolocation=(), microphone=()" },
    .hsts = .{ .max_age = 31536000, .include_subdomains = true, .https = behindTls },
};
```

In `main`, load a session secret and register everything. Sessions need a wall
clock; `clock_io` is a global set at startup because the clock callback takes
no arguments.

```zig
var clock_io: std.Io = undefined;
fn unixSeconds() i64 {
    return std.Io.Clock.real.now(clock_io).toSeconds();
}

// inside main, after opening assets and hashing the version:
clock_io = io;
var secret: [32]u8 = undefined;
try std.Io.randomSecure(io, &secret); // a real app loads a stable secret from config

var app = try App.init(gpa, .{
    .response_allocator = gpa,
    .config = .{ .name = "notes", .clock = .monotonic(io) },
    .plugins = .{
        .trace = .{
            .source = .{ .io = io },
            .incoming = .accept_valid,
            .clock = .monotonic(io),
            .sink = .{ .context = undefined, .write = writeAccess },
        },
        .sessions = .{
            .keys = &.{.{ .id = 1, .secret = &secret }},
            .lifetime_seconds = 60 * 60,
            .now_seconds = unixSeconds,
        },
        .inertia = .{
            .layout = layout,
            .version = .{ .value = &version },
            .shared = .fromContext(App.Context, shared),
        },
        .store = .{ .value = &store },
    },
    .route_fn = route,
    .middleware = &.{
        zoda.plugins.request_trace.middleware(App, "trace"),
        zoda.timing.middleware(App),
        try security_policy.middleware(App, &policies),
        try status_handler.middleware(App, &pages),
        error_handler.middleware(App, &recovery),
        zoda.static.middleware(App, &static_config),
    },
});
defer app.deinit();
try app.plugins.inertia.validate();
```

The session cookie is `__Host-` prefixed and `Secure`. Browsers accept it on
`http://localhost`, but in production serve the app over HTTPS. Because the
key is random per run here, a restart signs everyone out and an open tab's
next change gets 403 until it reloads.

### Step 6: Add a plugin of your own

A plugin is any struct. Give it a `State` type and an `initRequest` hook to
get per-request data, or a `wrapRoute` hook to wrap the route. This one
rejects requests missing a header:

```zig
const RequireHeader = struct {
    name: []const u8,

    pub fn wrapRoute(comptime H: type, comptime inner: H.RouteFn) H.RouteFn {
        return struct {
            fn run(ctx: *H.Context, req: *zoda.router.Request, res: *zoda.response.Response) anyerror!void {
                const self = H.plugin(ctx);
                if (try req.getHeaderOne(self.name) == null) return res.text(400, "missing header");
                try inner(ctx, req, res);
            }
        }.run;
    }
};

// const Plugins = struct { require: RequireHeader = .{ .name = "x-client" }, ... };
// .route_fn = App.composeRoute(route),
```

Wrappers run inside the middleware chain. The first plugin field is the
outermost wrapper, and a route passed to `route_fn` without `composeRoute`
runs no wrappers at all. See [Route wrappers](README.md#route-wrappers) for
the full rules.

## Next steps

- Run the full reference app:
  `(cd examples/inertia/react && npm install && npm run build)` then
  `zig build run-inertia -- react`. It adds partial reloads, infinite scroll,
  precognitive validation, history encryption and optional server-side
  rendering; see its [README](examples/inertia/README.md).
- Read [PLUGINS.md](PLUGINS.md) for every plugin's options and limits, and
  [SUPPORTED_API.md](SUPPORTED_API.md) for what is and is not supported.
- Use `zig build watch` while developing; it rebuilds on save and keeps the
  last working server running when a build fails.
