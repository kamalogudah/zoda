<script>
  import { Link } from '@inertiajs/svelte'

  // Rendered with status 404 for a link to a deleted todo.
  let { app, id } = $props()
</script>

<main>
  <h1>{app} todos</h1>
  <p class="error">Todo {id} is gone; it was deleted.</p>
  <Link href="/todos">Back to the list</Link>
</main>
