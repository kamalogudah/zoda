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
})

const filters = [
  ['all', 'All'],
  ['active', 'Active'],
  ['done', 'Done'],
]
const form = useForm({ text: '' })
// The page's top-level `flash`, from `zoda.Flash`; `{}` once it has been shown.
const page = usePage()
// Mutations keep this component mounted, so they reset `todos`: the list
// starts again at page 1 instead of merging into the pages loaded so far.
const options = { preserveScroll: true, only: ['todos', 'remaining', 'stats'], reset: ['todos'] }
// Mutations carry the filter so the server's 303 lands on the same view.
const query = computed(() => (props.filter === 'all' ? '' : `?filter=${props.filter}`))

function add() {
  // A rejected todo redirects back with its errors under this bag, which
  // `form.errors` reads as `form.errors.text`.
  form.post(`/todos${query.value}`, { ...options, errorBag: 'createTodo', onSuccess: () => form.reset() })
}
</script>

<template>
  <main>
    <h1>{{ app }} todos <small>{{ framework }}</small></h1>

    <form class="new" @submit.prevent="add">
      <input v-model="form.text" type="text" placeholder="What needs doing?" aria-label="New todo" autofocus />
      <button :disabled="form.processing">Add</button>
    </form>
    <p v-if="form.errors.text" class="error">{{ form.errors.text }}</p>
    <p v-if="page.flash.notice" class="notice" role="status">{{ page.flash.notice }}</p>

    <nav>
      <Link
        v-for="[value, label] in filters"
        :key="value"
        :href="value === 'all' ? '/todos' : `/todos?filter=${value}`"
        :class="{ active: filter === value }"
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
    </footer>
  </main>
</template>
