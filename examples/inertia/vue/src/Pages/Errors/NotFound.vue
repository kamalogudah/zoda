<script setup>
import { Link } from '@inertiajs/vue3'

// Rendered with status 404 for a link to a deleted todo.
defineProps({ app: String, id: Number })
</script>

<template>
  <main>
    <h1>{{ app }} todos</h1>
    <p class="error">Todo {{ id }} is gone; it was deleted.</p>
    <Link href="/todos">Back to the list</Link>
  </main>
</template>
