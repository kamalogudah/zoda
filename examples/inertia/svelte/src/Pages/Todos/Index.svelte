<script>
  import { Deferred, InfiniteScroll, Link, router, useForm } from '@inertiajs/svelte'

  let { app, framework, todos, filter, remaining, stats } = $props()

  const filters = [
    ['all', 'All'],
    ['active', 'Active'],
    ['done', 'Done'],
  ]
  const form = useForm({ text: '' })
  // Mutations keep this component mounted, so they reset `todos`: the list
  // starts again at page 1 instead of merging into the pages loaded so far.
  const options = { preserveScroll: true, only: ['todos', 'remaining', 'stats'], reset: ['todos'] }
  // Mutations carry the filter so the server's 303 lands on the same view.
  let query = $derived(filter === 'all' ? '' : `?filter=${filter}`)

  function add(event) {
    event.preventDefault()
    form.post(`/todos${query}`, { ...options, onSuccess: () => form.reset() })
  }
</script>

<main>
  <h1>{app} todos <small>{framework}</small></h1>

  <form class="new" onsubmit={add}>
    <!-- svelte-ignore a11y_autofocus -->
    <input type="text" bind:value={form.text} placeholder="What needs doing?" aria-label="New todo" autofocus />
    <button disabled={form.processing}>Add</button>
  </form>
  {#if form.errors.text}
    <p class="error">{form.errors.text}</p>
  {/if}

  <nav>
    {#each filters as [value, label] (value)}
      <Link href={value === 'all' ? '/todos' : `/todos?filter=${value}`} class={filter === value ? 'active' : ''}>
        {label}
      </Link>
    {/each}
  </nav>

  <!-- Each page of `todos` is a scroll prop; the buttons load the next or previous one. -->
  <InfiniteScroll data="todos" as="ul" manual>
    {#snippet previous({ hasMore, loading, fetch })}
      {#if hasMore}
        <button class="more" disabled={loading} onclick={fetch}>{loading ? 'Loading…' : 'Show earlier'}</button>
      {/if}
    {/snippet}
    {#each todos as todo (todo.id)}
      <li id={`todo-${todo.id}`} class:done={todo.done}>
        <label>
          <input
            type="checkbox"
            checked={todo.done}
            onchange={() => router.patch(`/todos/${todo.id}${query}`, {}, options)}
          />
          <span>{todo.text}</span>
        </label>
        <button onclick={() => router.delete(`/todos/${todo.id}${query}`, options)} aria-label={`Delete ${todo.text}`}>
          ×
        </button>
      </li>
    {:else}
      <li class="empty">Nothing here yet.</li>
    {/each}
    {#snippet next({ hasMore, loading, fetch })}
      {#if hasMore}
        <button class="more" disabled={loading} onclick={fetch}>{loading ? 'Loading…' : 'Show more'}</button>
      {/if}
    {/snippet}
  </InfiniteScroll>

  <footer>
    {remaining} {remaining === 1 ? 'item' : 'items'} left
    <!-- `stats` is a deferred prop: the client requests it after the page renders. -->
    <Deferred data="stats">
      {#snippet fallback()}<span class="stats"> · counting…</span>{/snippet}
      <span class="stats"> · {stats.done} of {stats.total} done</span>
    </Deferred>
  </footer>
</main>
