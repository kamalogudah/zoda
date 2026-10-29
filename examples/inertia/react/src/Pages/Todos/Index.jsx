import { Deferred, InfiniteScroll, Link, router, useForm, usePage } from '@inertiajs/react'

const filters = [
  ['all', 'All'],
  ['active', 'Active'],
  ['done', 'Done'],
]

export default function Index({ app, framework, todos, filter, remaining, stats }) {
  const form = useForm({ text: '' })
  // The page's top-level `flash`, from `zoda.Flash`; `{}` once it has been shown.
  const { flash } = usePage()
  // Mutations carry the filter so the server's 303 lands on the same view.
  const query = filter === 'all' ? '' : `?filter=${filter}`
  // They also keep this component mounted, so reset `todos`: the list
  // starts again at page 1 instead of merging into the pages loaded so far.
  const options = { preserveScroll: true, only: ['todos', 'remaining', 'stats'], reset: ['todos'] }

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
          placeholder="What needs doing?"
          aria-label="New todo"
          autoFocus
        />
        <button disabled={form.processing}>Add</button>
      </form>
      {form.errors.text && <p className="error">{form.errors.text}</p>}
      {flash.notice && (
        <p className="notice" role="status">
          {flash.notice}
        </p>
      )}

      <nav>
        {filters.map(([value, label]) => (
          <Link
            key={value}
            href={value === 'all' ? '/todos' : `/todos?filter=${value}`}
            className={filter === value ? 'active' : ''}
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
        {/* Every page is encrypted in browser history; this clears the key. */}
        <button className="forget" onClick={() => router.delete(`/history${query}`)}>
          Forget history
        </button>
      </footer>
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
