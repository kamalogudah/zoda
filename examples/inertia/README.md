# Inertia.js todo app

A small todo list built on [`zoda.Inertia`](../../PLUGINS.md#inertiajs). One
Zoda server ([`server.zig`](server.zig)) renders every page; you pick the
frontend:

| Frontend | Page component | Adapter |
| --- | --- | --- |
| [React](react) | [`Todos/Index.jsx`](react/src/Pages/Todos/Index.jsx) | `@inertiajs/react` 3.9.1, React 19 |
| [Svelte](svelte) | [`Todos/Index.svelte`](svelte/src/Pages/Todos/Index.svelte) | `@inertiajs/svelte` 3.9.1, Svelte 5 |
| [Vue](vue) | [`Todos/Index.vue`](vue/src/Pages/Todos/Index.vue) | `@inertiajs/vue3` 3.9.1, Vue 3 |

All three render the same props, share [one stylesheet](shared/style.css),
and use the same [Vite build settings](shared/build.mjs). Todos live in
memory and disappear when the server stops. The server starts with 25
sample todos so there is something to page through.

## Run it

You need Zig 0.16.0 and Node.js 20 or newer. From the repository root:

```sh
(cd examples/inertia/react && npm install && npm run build)
zig build run-inertia -- react
```

Open <http://localhost:8080>. Replace `react` with `svelte` or `vue` in both
commands to try another frontend. With no argument the server uses `react`.
To rebuild the bundle on every save, run `npm run watch` in the frontend
directory, then restart the server so it picks up the new asset version.

### Server-side rendering (React)

`npm run build` in `react` also writes `dist/ssr/ssr.js`, a Node server
made with `@inertiajs/react/server` from [`src/ssr.jsx`](react/src/ssr.jsx).
Start it, then start Zoda with `--ssr`:

```sh
(cd examples/inertia/react && npm run ssr)      # listens on 127.0.0.1:13714
zig build run-inertia -- react --ssr
```

Each full visit then posts its page JSON to the SSR server, with a 500 ms
budget, and sends the rendered HTML: the page arrives as markup inside
`<div data-server-rendered="true" id="app">`, and `main.jsx` hydrates it
instead of mounting. The layout's `@inertiaHead` marker takes any head tags
the SSR server returns. Stop the SSR server and pages still load: Zoda falls
back to the client-rendered page and logs `SSR failed for /todos:
SsrConnectFailed`. JSON visits never use SSR. Only the React frontend has
an SSR entry.

There is no Vite dev server or hot reload. Vite writes `dist/assets/app.js`
and `dist/assets/app.css`, and Zoda serves them with `zoda.static` under
`/assets`.

## How it works

| Request | Route | Response |
| --- | --- | --- |
| `GET /` | redirect | 302 to `/todos` |
| `GET /todos[?filter=active\|done][&page=n]` | `render("Todos/Index", …)` | HTML shell on the first visit, the page JSON on Inertia visits; 10 todos per page, newest first |
| `GET /todos/:id` | show | 302 to the unfiltered page holding the todo, or the `Errors/NotFound` page with 404 |
| `POST /todos` with `{"text": "…"}` | add | flash "Todo added", then back to the current filter at `#todo-<id>`; or store `errors.text` and 303 back to the current filter |
| `POST /todos` with `Precognition: true` | validate only | 422 with `errors.text`, or 204; nothing is added |
| `PATCH /todos/:id` | toggle | 303 back |
| `DELETE /todos/:id` | delete | 303 back, or 404 |
| `DELETE /history` | forget history | flash "History cleared", ask the next page to clear history, then 303 back |

- **First visit.** The layout in `server.zig` holds the `<link>` and
  `<script>` tags. `render` replaces its `@inertia` marker with
  `<script data-page="app" type="application/json">` and `<div id="app">`,
  which `createInertiaApp` reads and mounts into.
- **Later visits.** Links, form posts, and checkbox clicks go through the
  Inertia router. The client sends `X-Inertia: true`, the server answers with
  the page object as JSON, and the client swaps the component in place.
- **Shared props.** `app` and `framework` are configured once as shared props
  and reach every page alongside the route's `todos`, `filter`, `remaining`,
  and `errors`.
- **Redirects.** After `PATCH` and `DELETE`, `inertia.redirect` sends 303,
  so the client follows with a GET. After `POST` the target has a
  `#todo-<id>` fragment. XHR drops the fragment of a redirect it follows, so
  for Inertia requests the plugin sends 409 with `X-Inertia-Redirect`
  instead, and the v3 client visits that URL and keeps the fragment. The
  target is built from the validated filter enum and the new id, never from
  request bytes.
- **Validation.** An empty or too-long todo is not re-rendered on the
  POST. `rejectTodo` calls `redirectWithErrors`, which stores
  `{text: "…"}` in the session through `zoda.Flash` and sends 303 back to
  the current filter's list, a path built from the filter enum rather than
  `Referer`. The add form posts with `errorBag: 'createTodo'`, so the
  client sends `X-Inertia-Error-Bag: createTodo` and the errors are stored
  as `{createTodo: {text: "…"}}`. The followed GET's `renderWith` sends
  them as `props.errors` and the save after it drops them; the client
  hands `errors.createTodo` to `useForm`, which shows
  `form.errors.text`. The next visit has `errors: {}` again.
- **Live validation.** The add form is
  `useForm({ text: '' }).withPrecognition('post', '/todos')`, and leaving
  the field calls `form.validate('text')`. The client posts the form with
  `Precognition: true` and `Precognition-Validate-Only: text`; the route
  runs the same check as a real submit, then `answerPrecognition` sends
  422 with `{"errors": {"text": "…"}}` or 204 before anything is added.
  The client shows the error as `form.errors.text` and marks the input
  `aria-invalid`. Type some spaces and click away to see it.
- **Partial reloads.** `router.reload({ only: ['todos'] })` sends
  `X-Inertia-Partial-Component: Todos/Index` and
  `X-Inertia-Partial-Data: todos`, and the server answers with only `todos`,
  the always prop `remaining`, and `errors`; the client keeps its other
  props. "Refresh counts" is the other way round:
  `router.reload({ except: ['todos', 'activity'] })` sends
  `X-Inertia-Partial-Except`, and gets every prop but those two, so the
  pages of todos and the activity log already loaded stay as they are.
- **Always props.** `remaining` is `zoda.plugins.inertia.always(...)`, so
  every reload sends it, even one whose `only` leaves it out. Mutations
  ask for `only: ['todos', 'stats']` and still get a fresh count.
- **Deferred props.** The footer's "1 of 2 done" comes from `stats`, a
  `zoda.plugins.inertia.deferred` prop. Every full page response leaves it
  out and lists it as `deferredProps: {"default": ["stats"]}`; the client
  then requests it with `X-Inertia-Partial-Data: stats` and the page's
  `<Deferred data="stats">` shows "counting…" until it arrives. The counts
  are cheap here; a real app would defer a slow query.
- **Once props.** `limits` (the input size and page size shown under the
  form) is `zoda.plugins.inertia.once(...)`. The first page sends it and
  lists it in `onceProps`; from then on the client sends
  `X-Inertia-Except-Once-Props: limits,server`, and the server lists the
  entry without resolving or sending the value, which the client keeps.
- **Deferred once props.** The footer's "Served by Zig …" comes from
  `about`, a `deferred(...).once().as("server").expiresIn(5 * 60 * 1000)`
  prop. The first page defers it under the key `server` with an
  `expiresAt` from the server's clock. While the client holds it, later
  pages leave it out of `deferredProps`, so it is not requested again;
  after five minutes the client drops the key and the next page loads it
  afresh.
- **Activity log.** "Show activity" calls
  `router.reload({ only: ['activity'] })`. `activity` is an optional prop,
  so no other response has it, wrapped in `deepMerge(...)` with
  `.matchOn("events.id")`. "Check for new" sends the last entry's id in an
  `X-Activity-After` header and the server answers with only the entries
  after it and the new `total`; the client deep-merges them, appending to
  `events` and replacing `total`. The store keeps the last 50 entries, and
  a log opened fresh starts at the latest 10.
- **Fragments.** Each activity entry links to `/todos/<id>#todo-<id>`. The
  route redirects to the unfiltered page that holds the todo, and XHR
  drops the fragment when it follows the redirect, so every list page is
  rendered with `preserve_fragment`: the client puts the requested
  `#todo-<id>` back and scrolls the todo into view. A deleted todo's link
  renders `Errors/NotFound` with status 404 through `renderWith`; the
  client fires its `httpException` event and shows that page.
- **Prefetching.** The filter links are `<Link prefetch cacheTags="todos">`:
  hovering one fetches its page with `Purpose: prefetch`, an ordinary
  Inertia GET for the server, and the click shows it without waiting.
  Every change posts with `invalidateCacheTags: ['todos']`, so a filter
  page prefetched before it is fetched again.
- **Infinite scroll.** `todos` is a `zoda.plugins.inertia.scroll` prop:
  the route reads `?page=`, sends that page of ten (newest first, so a new
  todo is on page 1), and says which pages are before and after it. The
  page's `<InfiniteScroll data="todos" manual>` shows "Show more", which
  reloads only `todos` with `?page=2` and
  `X-Inertia-Infinite-Scroll-Merge-Intent: append`. The answer is listed in
  `mergeProps`, so the client appends it and moves on to the next
  `scrollProps.todos.nextPage`. As you read further down, the client writes
  `?page=` into the address bar. Reload the page there and it opens on that
  page with "Show earlier", which sends `prepend` and puts the earlier page
  above. Mutations keep the page component mounted, so they send
  `only: ['todos', 'stats']` and `reset: ['todos']`; the reply
  has `scrollProps.todos.reset: true`, and the list starts again at page 1.
  Filter links are plain GET visits, which remount the page, so they need
  no reset. Drop `manual` to load pages as you scroll instead.
- **Flash.** Adding a todo queues "Todo added" with `zoda.Flash` and saves
  the session before redirecting. Every render goes through
  `renderWith(..., .{ .flash = ... })` and then saves, so the page that
  follows carries `flash: {"notice": "Todo added"}` once and the saved
  cookie drops it. The page reads `page.flash.notice` (`usePage().flash` in
  React and Vue, `page.flash` in Svelte). The add form posts with `only`, so
  the flash arrives on a partial reload, which the client shows; the next
  visit has no `flash` and the notice disappears. The deferred `stats`
  reload does not clear it, because the client keeps its current flash on
  deferred-props reloads. The session key is random per run, so a restart
  just drops pending messages.
- **History encryption.** The plugin is registered with
  `encrypt_history = true`, so every page carries `encryptHistory: true`
  and the client stores it in `history.state` encrypted with a key kept in
  the tab's `sessionStorage`. Back and Forward still restore pages without
  a request. The footer's "Forget history" button sends
  `DELETE /history`, which calls `clearHistoryOnNextRender` and redirects
  back; the page that follows carries `clearHistory: true`, and the client
  deletes the key. Back to a page seen before then cannot decrypt the
  stored copy, so the client fetches it from the server again. A real app
  does this on logout. Encryption needs a secure context; `localhost`
  counts, so the example works over plain HTTP here.
- **Asset version.** At startup the server hashes `app.js` into the Inertia
  version. After you rebuild the frontend and restart the server, an open tab
  that sends the old version gets 409 and `X-Inertia-Location` and does a full
  reload, so it never mixes old JavaScript with new props.
- **CSRF.** Each page render issues the session's CSRF token and sets it as
  the `XSRF-TOKEN` cookie (`Secure`, `SameSite=Lax`, readable by script).
  The Inertia client copies it into `X-XSRF-TOKEN` on every same-origin
  request, and the route answers any `POST`, `PATCH`, or `DELETE` without a
  matching token with 403 before reading the body, precognitive validation
  included. See
  [XSRF-TOKEN cookie](../../PLUGINS.md#xsrf-token-cookie-inertia-axios).
  The session key is new on each run, so after a restart an open tab's next
  change gets 403 until it reloads.

The session carries flash messages, validation errors, and the CSRF secret.

## Tests

`zig build test` (and `zig build test-examples`) runs the server tests in
`server.zig`, which dispatch requests without a browser or a built frontend.
They cover the HTML shell, the JSON page, add, toggle, filter, and delete,
redirect-back validation errors in the `createTodo` bag shown once, the version conflict, a partial reload of `todos`,
loading the deferred `stats`, paging `todos` forward, backward, and
after a reset, the "Todo added" flash shown once, "Forget history"
sending `clearHistory` once, precognitive posts answered with 422 or
204 without adding a todo, the once and deferred once props skipped while
the client holds them, the activity log loaded on demand and checked for
new entries, the `except` reload, and todo links that redirect or render
the 404 page.
