import { createInertiaApp } from '@inertiajs/svelte'
import '../../shared/style.css'

const pages = import.meta.glob('./Pages/**/*.svelte', { eager: true })

// Reads the page from <script data-page="app"> and mounts into #app.
createInertiaApp({
  resolve: (name) => pages[`./Pages/${name}.svelte`],
})
