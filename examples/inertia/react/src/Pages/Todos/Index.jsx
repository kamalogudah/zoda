import { Deferred, Link, router, useForm } from '@inertiajs/react'

const filters = [
  ['all', 'All'],
  ['active', 'Active'],
  ['done', 'Done'],
]

export default function Index({ app, framework, todos, filter, remaining, stats }) {
  const form = useForm({ text: '' })
  // Mutations carry the filter so the server's 303 lands on the same view.
  const query = filter === 'all' ? '' : `?filter=${filter}`
  const options = { preserveScroll: true }

  function add(event) {
    event.preventDefault()
    form.post(`/todos${query}`, { ...options, onSuccess: () => form.reset() })
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

      {todos.length === 0 ? (
        <ul>
          <li className="empty">Nothing here yet.</li>
        </ul>
      ) : (
        <ul>
          {todos.map((todo) => (
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
          ))}
        </ul>
      )}

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
      </footer>
    </main>
  )
}
