<script>
  import { Deferred, InfiniteScroll, Link, page, router, useForm } from '@inertiajs/svelte'

  let { app, framework, todos, filter, remaining, stats, limits, about, activity } = $props()

  const filters = [
    ['all', 'All'],
    ['active', 'Active'],
    ['done', 'Done'],
  ]
  // Leaving the field asks the server to validate it (precognition), which
  // answers 422 with `errors.text` or 204 without adding the todo.
  const form = useForm({ text: '' }).withPrecognition('post', '/todos')
  // Mutations keep this component mounted, so they reset `todos`: the list
  // starts again at page 1 instead of merging into the pages loaded so far.
  // `remaining` is an always prop, so it comes back without being listed.
  // Changes also drop prefetched filter pages, which would now be stale.
  const options = { preserveScroll: true, only: ['todos', 'stats'], reset: ['todos'], invalidateCacheTags: ['todos'] }
  // Mutations carry the filter so the server's 303 lands on the same view.
  let query = $derived(filter === 'all' ? '' : `?filter=${filter}`)

  function add(event) {
    event.preventDefault()
    // A rejected todo redirects back with its errors under this bag, which
    // `form.errors` reads as `form.errors.text`.
    form.post(`/todos${query}`, { ...options, errorBag: 'createTodo', onSuccess: () => form.reset() })
  }

  // `activity` is an optional prop: no response has it until this asks. It
  // is deep-merged, so "Check for new" appends only the entries after the
  // last one shown.
  function loadActivity() {
    const after = activity?.events.at(-1)?.id ?? 0
    router.reload({ only: ['activity'], headers: { 'X-Activity-After': String(after) } })
  }
</script>

<main>
  <h1>{app} todos <small>{framework}</small></h1>

  <form class="new" onsubmit={add}>
    <!-- svelte-ignore a11y_autofocus -->
    <input
      type="text"
      bind:value={form.text}
      onblur={() => form.validate('text')}
      aria-invalid={form.invalid('text')}
      placeholder="What needs doing?"
      aria-label="New todo"
      autofocus
    />
    <button disabled={form.processing}>Add</button>
  </form>
  {#if form.errors.text}
    <p class="error">{form.errors.text}</p>
  {/if}
  <!-- `limits` is a once prop: sent with the first page, then kept by the client. -->
  <p class="hint">Up to {limits.max_text_bytes} bytes; {limits.per_page} todos a page.</p>
  <!-- The page's top-level `flash`, from `zoda.Flash`; `{}` once it has been shown. -->
  {#if page.flash?.notice}
    <p class="notice" role="status">{page.flash.notice}</p>
  {/if}

  <!-- Filter pages are fetched on hover, so the click shows them at once. -->
  <nav>
    {#each filters as [value, label] (value)}
      <Link
        href={value === 'all' ? '/todos' : `/todos?filter=${value}`}
        class={filter === value ? 'active' : ''}
        prefetch
        cacheTags="todos"
      >
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
    <!-- Reloads everything but the list and the log, keeping the loaded pages. -->
    <button class="link" onclick={() => router.reload({ except: ['todos', 'activity'] })}>Refresh counts</button>
    <!-- Every page is encrypted in browser history; this clears the key. -->
    <button class="forget" onclick={() => router.delete(`/history${query}`)}>Forget history</button>
    <!-- `about` is a deferred once prop: loaded after the first page, then kept. -->
    <Deferred data="about">
      {#snippet fallback()}<p class="about">Loading server details…</p>{/snippet}
      <p class="about">
        Served by Zig {about.zig}, up since {new Date(about.started_ms).toLocaleTimeString()}.
      </p>
    </Deferred>
  </footer>

  <!-- Each entry links to its todo with a fragment the server keeps through
       its redirect; a deleted todo's link gets a 404 page. -->
  <section class="activity">
    <h2>
      Activity
      {#if activity}<small>{activity.total} changes so far</small>{/if}
    </h2>
    {#if activity}
      <ol>
        {#each activity.events as event (event.id)}
          <li><Link href={`/todos/${event.todo}#todo-${event.todo}`}>{event.text}</Link></li>
        {/each}
      </ol>
    {/if}
    <button class="more" onclick={loadActivity}>{activity ? 'Check for new' : 'Show activity'}</button>
  </section>
</main>
