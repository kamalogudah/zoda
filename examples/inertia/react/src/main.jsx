import { createInertiaApp } from '@inertiajs/react'
import '../../shared/style.css'

const pages = import.meta.glob('./Pages/**/*.jsx', { eager: true })

// Reads the page from <script data-page="app"> and mounts into #app.
createInertiaApp({
  resolve: (name) => pages[`./Pages/${name}.jsx`],
})
