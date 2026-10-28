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
memory and disappear when the server stops.

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

There is no Vite dev server or hot reload. Vite writes `dist/assets/app.js`
and `dist/assets/app.css`, and Zoda serves them with `zoda.static` under
`/assets`.

## How it works

| Request | Route | Response |
| --- | --- | --- |
| `GET /` | redirect | 302 to `/todos` |
| `GET /todos[?filter=active\|done]` | `render("Todos/Index", …)` | HTML shell on the first visit, the page JSON on Inertia visits |
| `POST /todos` with `{"text": "…"}` | add | back to the current filter at `#todo-<id>`, or the page again with `errors.text` |
| `PATCH /todos/:id` | toggle | 303 back |
| `DELETE /todos/:id` | delete | 303 back, or 404 |

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
- **Validation.** An empty or too-long todo re-renders the page with
  `errors: { text: "…" }`, which `useForm` exposes as `form.errors.text`.
  Other renders leave `errors` out and the plugin sends `errors: {}`.
- **Partial reloads.** `router.reload({ only: ['todos'] })` sends
  `X-Inertia-Partial-Component: Todos/Index` and
  `X-Inertia-Partial-Data: todos`, and the server answers with only `todos`
  and `errors`; the client keeps its other props. The page component has no
  reload button, but the server test below sends exactly those headers.
- **Asset version.** At startup the server hashes `app.js` into the Inertia
  version. After you rebuild the frontend and restart the server, an open tab
  that sends the old version gets 409 and `X-Inertia-Location` and does a full
  reload, so it never mixes old JavaScript with new props.

The example has no sessions. With sessions you would redirect back after a
validation error and carry the errors in a flash message, which is the usual
Inertia pattern. The JSON body parser accepts only
`Content-Type: application/json`, so a plain cross-site HTML form cannot post
here. A real app that uses cookies should still add CSRF checks; see
[PLUGINS.md](../../PLUGINS.md#inertiajs) for how Inertia's `X-XSRF-TOKEN`
relates to Zoda's CSRF helpers.

## Tests

`zig build test` (and `zig build test-examples`) runs the server tests in
`server.zig`, which dispatch requests without a browser or a built frontend.
They cover the HTML shell, the JSON page, add, toggle, filter, and delete,
validation errors, the version conflict, and a partial reload of `todos`.
