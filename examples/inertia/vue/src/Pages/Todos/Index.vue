<script setup>
import { computed } from 'vue'
import { Deferred, InfiniteScroll, Link, router, useForm, usePage } from '@inertiajs/vue3'

const props = defineProps({
  app: String,
  framework: String,
  todos: Array,
  filter: String,
  remaining: Number,
  stats: Object,
  limits: Object,
  about: Object,
  activity: Object,
})

const filters = [
  ['all', 'All'],
  ['active', 'Active'],
  ['done', 'Done'],
]
// Leaving the field asks the server to validate it (precognition), which
// answers 422 with `errors.text` or 204 without adding the todo.
const form = useForm({ text: '' }).withPrecognition('post', '/todos')
// The page's top-level `flash`, from `zoda.Flash`; `{}` once it has been shown.
const page = usePage()
// Mutations keep this component mounted, so they reset `todos`: the list
// starts again at page 1 instead of merging into the pages loaded so far.
// `remaining` is an always prop, so it comes back without being listed.
// Changes also drop prefetched filter pages, which would now be stale.
const options = { preserveScroll: true, only: ['todos', 'stats'], reset: ['todos'], invalidateCacheTags: ['todos'] }
// Mutations carry the filter so the server's 303 lands on the same view.
const query = computed(() => (props.filter === 'all' ? '' : `?filter=${props.filter}`))

function add() {
  // A rejected todo redirects back with its errors under this bag, which
  // `form.errors` reads as `form.errors.text`.
  form.post(`/todos${query.value}`, { ...options, errorBag: 'createTodo', onSuccess: () => form.reset() })
}

// `activity` is an optional prop: no response has it until this asks. It is
// deep-merged, so "Check for new" appends only the entries after the last
// one shown.
function loadActivity() {
  const after = props.activity?.events.at(-1)?.id ?? 0
  router.reload({ only: ['activity'], headers: { 'X-Activity-After': String(after) } })
}
</script>

<template>
  <main>
    <h1>{{ app }} todos <small>{{ framework }}</small></h1>

    <form class="new" @submit.prevent="add">
      <input
        v-model="form.text"
        type="text"
        placeholder="What needs doing?"
        aria-label="New todo"
        :aria-invalid="form.invalid('text')"
        autofocus
        @blur="form.validate('text')"
      />
      <button :disabled="form.processing">Add</button>
    </form>
    <p v-if="form.errors.text" class="error">{{ form.errors.text }}</p>
    <!-- `limits` is a once prop: sent with the first page, then kept by the client. -->
    <p class="hint">Up to {{ limits.max_text_bytes }} bytes; {{ limits.per_page }} todos a page.</p>
    <p v-if="page.flash.notice" class="notice" role="status">{{ page.flash.notice }}</p>

    <!-- Filter pages are fetched on hover, so the click shows them at once. -->
    <nav>
      <Link
        v-for="[value, label] in filters"
        :key="value"
        :href="value === 'all' ? '/todos' : `/todos?filter=${value}`"
        :class="{ active: filter === value }"
        prefetch
        cache-tags="todos"
      >
        {{ label }}
      </Link>
    </nav>

    <!-- Each page of `todos` is a scroll prop; the buttons load the next or previous one. -->
    <InfiniteScroll data="todos" as="ul" manual>
      <template #previous="{ hasMore, loading, fetch }">
        <button v-if="hasMore" class="more" :disabled="loading" @click="fetch">
          {{ loading ? 'Loading…' : 'Show earlier' }}
        </button>
      </template>
      <li v-for="todo in todos" :id="`todo-${todo.id}`" :key="todo.id" :class="{ done: todo.done }">
        <label>
          <input
            type="checkbox"
            :checked="todo.done"
            @change="router.patch(`/todos/${todo.id}${query}`, {}, options)"
          />
          <span>{{ todo.text }}</span>
        </label>
        <button :aria-label="`Delete ${todo.text}`" @click="router.delete(`/todos/${todo.id}${query}`, options)">×</button>
      </li>
      <li v-if="todos.length === 0" class="empty">Nothing here yet.</li>
      <template #next="{ hasMore, loading, fetch }">
        <button v-if="hasMore" class="more" :disabled="loading" @click="fetch">
          {{ loading ? 'Loading…' : 'Show more' }}
        </button>
      </template>
    </InfiniteScroll>

    <footer>
      {{ remaining }} {{ remaining === 1 ? 'item' : 'items' }} left
      <!-- `stats` is a deferred prop: the client requests it after the page renders. -->
      <Deferred data="stats">
        <template #fallback><span class="stats"> · counting…</span></template>
        <span class="stats"> · {{ stats.done }} of {{ stats.total }} done</span>
      </Deferred>
      <!-- Reloads everything but the list and the log, keeping the loaded pages. -->
      <button class="link" @click="router.reload({ except: ['todos', 'activity'] })">Refresh counts</button>
      <!-- Every page is encrypted in browser history; this clears the key. -->
      <button class="forget" @click="router.delete(`/history${query}`)">Forget history</button>
      <!-- `about` is a deferred once prop: loaded after the first page, then kept. -->
      <Deferred data="about">
        <template #fallback><p class="about">Loading server details…</p></template>
        <p class="about">
          Served by Zig {{ about.zig }}, up since {{ new Date(about.started_ms).toLocaleTimeString() }}.
        </p>
      </Deferred>
    </footer>

    <!-- Each entry links to its todo with a fragment the server keeps through
         its redirect; a deleted todo's link gets a 404 page. -->
    <section class="activity">
      <h2>
        Activity
        <small v-if="activity">{{ activity.total }} changes so far</small>
      </h2>
      <ol v-if="activity">
        <li v-for="event in activity.events" :key="event.id">
          <Link :href="`/todos/${event.todo}#todo-${event.todo}`">{{ event.text }}</Link>
        </li>
      </ol>
      <button class="more" @click="loadActivity">{{ activity ? 'Check for new' : 'Show activity' }}</button>
    </section>
  </main>
</template>
