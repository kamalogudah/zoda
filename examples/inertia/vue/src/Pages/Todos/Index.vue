<script setup>
import { computed } from 'vue'
import { Link, router, useForm } from '@inertiajs/vue3'

const props = defineProps({
  app: String,
  framework: String,
  todos: Array,
  filter: String,
  remaining: Number,
})

const filters = [
  ['all', 'All'],
  ['active', 'Active'],
  ['done', 'Done'],
]
const form = useForm({ text: '' })
const options = { preserveScroll: true }
// Mutations carry the filter so the server's 303 lands on the same view.
const query = computed(() => (props.filter === 'all' ? '' : `?filter=${props.filter}`))

function add() {
  form.post(`/todos${query.value}`, { ...options, onSuccess: () => form.reset() })
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

    <ul>
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
    </ul>

    <footer>{{ remaining }} {{ remaining === 1 ? 'item' : 'items' }} left</footer>
  </main>
</template>
