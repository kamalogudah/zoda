import { Link } from '@inertiajs/react'

// Rendered with status 404 for a link to a deleted todo.
export default function NotFound({ app, id }) {
  return (
    <main>
      <h1>{app} todos</h1>
      <p className="error">Todo {id} is gone; it was deleted.</p>
      <Link href="/todos">Back to the list</Link>
    </main>
  )
}
