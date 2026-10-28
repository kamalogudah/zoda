import { createInertiaApp } from '@inertiajs/vue3'
import '../../shared/style.css'

const pages = import.meta.glob('./Pages/**/*.vue', { eager: true })

// Reads the page from <script data-page="app"> and mounts into #app.
createInertiaApp({
  resolve: (name) => pages[`./Pages/${name}.vue`],
})
