import { Deferred, InfiniteScroll, Link, router, useForm, usePage } from '@inertiajs/react'

const filters = [
  ['all', 'All'],
  ['active', 'Active'],
  ['done', 'Done'],
]

export default function Index({ app, framework, todos, filter, remaining, stats, limits, about, activity }) {
  // Leaving the field asks the server to validate it (precognition), which
  // answers 422 with `errors.text` or 204 without adding the todo.
  const form = useForm({ text: '' }).withPrecognition('post', '/todos')
  // The page's top-level `flash`, from `zoda.Flash`; `{}` once it has been shown.
  const { flash } = usePage()
  // Mutations carry the filter so the server's 303 lands on the same view.
  const query = filter === 'all' ? '' : `?filter=${filter}`
  // They also keep this component mounted, so reset `todos`: the list
  // starts again at page 1 instead of merging into the pages loaded so far.
  // `remaining` is an always prop, so it comes back without being listed.
  // Changes also drop prefetched filter pages, which would now be stale.
  const options = { preserveScroll: true, only: ['todos', 'stats'], reset: ['todos'], invalidateCacheTags: ['todos'] }

  function add(event) {
    event.preventDefault()
    // A rejected todo redirects back with its errors under this bag, which
    // `form.errors` reads as `form.errors.text`.
    form.post(`/todos${query}`, { ...options, errorBag: 'createTodo', onSuccess: () => form.reset() })
  }

  return (
    <main>
      <h1>
        {app} todos <small>{framework}</small>
      </h1>

      <form className="new" onSubmit={add}>
        <input
          type="text"
          value={form.data.text}
          onChange={(event) => form.setData('text', event.target.value)}
          onBlur={() => form.validate('text')}
          aria-invalid={form.invalid('text')}
          placeholder="What needs doing?"
          aria-label="New todo"
          autoFocus
        />
        <button disabled={form.processing}>Add</button>
      </form>
      {form.errors.text && <p className="error">{form.errors.text}</p>}
      {/* `limits` is a once prop: sent with the first page, then kept by the client. */}
      <p className="hint">
        Up to {limits.max_text_bytes} bytes; {limits.per_page} todos a page.
      </p>
      {flash.notice && (
        <p className="notice" role="status">
          {flash.notice}
        </p>
      )}

      <nav>
        {filters.map(([value, label]) => (
          // Fetched on hover, so the click shows the page at once.
          <Link
            key={value}
            href={value === 'all' ? '/todos' : `/todos?filter=${value}`}
            className={filter === value ? 'active' : ''}
            prefetch
            cacheTags="todos"
          >
            {label}
          </Link>
        ))}
      </nav>

      {/* Each page of `todos` is a scroll prop; the buttons load the next or previous one. */}
      <InfiniteScroll
        data="todos"
        as="ul"
        manual
        previous={(scroll) => <More {...scroll} label="Show earlier" />}
        next={(scroll) => <More {...scroll} label="Show more" />}
      >
        {todos.length === 0 ? (
          <li className="empty">Nothing here yet.</li>
        ) : (
          todos.map((todo) => (
            <li key={todo.id} id={`todo-${todo.id}`} className={todo.done ? 'done' : ''}>
              <label>
                <input
                  type="checkbox"
                  checked={todo.done}
                  onChange={() => router.patch(`/todos/${todo.id}${query}`, {}, options)}
                />
                <span>{todo.text}</span>
              </label>
              <button
                onClick={() => router.delete(`/todos/${todo.id}${query}`, options)}
                aria-label={`Delete ${todo.text}`}
              >
                ×
              </button>
            </li>
          ))
        )}
      </InfiniteScroll>

      <footer>
        {remaining} {remaining === 1 ? 'item' : 'items'} left
        {/* `stats` is a deferred prop: the client requests it after the page renders. */}
        <Deferred data="stats" fallback={<span className="stats"> · counting…</span>}>
          {() => (
            <span className="stats">
              {' '}
              · {stats.done} of {stats.total} done
            </span>
          )}
        </Deferred>
        {/* Reloads everything but the list and the log, keeping the loaded pages. */}
        <button className="link" onClick={() => router.reload({ except: ['todos', 'activity'] })}>
          Refresh counts
        </button>
        {/* Every page is encrypted in browser history; this clears the key. */}
        <button className="forget" onClick={() => router.delete(`/history${query}`)}>
          Forget history
        </button>
        {/* `about` is a deferred once prop: loaded after the first page, then kept. */}
        <Deferred data="about" fallback={<p className="about">Loading server details…</p>}>
          {() => (
            <p className="about">
              Served by Zig {about.zig}, up since {new Date(about.started_ms).toLocaleTimeString()}.
            </p>
          )}
        </Deferred>
      </footer>

      <Activity activity={activity} />
    </main>
  )
}

function More({ hasMore, loading, fetch, label }) {
  if (!hasMore) return null
  return (
    <button className="more" onClick={fetch} disabled={loading}>
      {loading ? 'Loading…' : label}
    </button>
  )
}

// `activity` is an optional prop: no response has it until this asks. It is
// deep-merged, so "Check for new" appends only the entries after the last
// one shown. Each entry links to its todo with a fragment the server keeps
// through its redirect; a deleted todo's link gets a 404 page.
function Activity({ activity }) {
  function load() {
    const after = activity?.events.at(-1)?.id ?? 0
    router.reload({ only: ['activity'], headers: { 'X-Activity-After': String(after) } })
  }

  return (
    <section className="activity">
      <h2>
        Activity {activity && <small>{activity.total} changes so far</small>}
      </h2>
      {activity && (
        <ol>
          {activity.events.map((event) => (
            <li key={event.id}>
              <Link href={`/todos/${event.todo}#todo-${event.todo}`}>{event.text}</Link>
            </li>
          ))}
        </ol>
      )}
      <button className="more" onClick={load}>
        {activity ? 'Check for new' : 'Show activity'}
      </button>
    </section>
  )
}
