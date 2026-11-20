import { createInertiaApp } from '@inertiajs/react'
import createServer from '@inertiajs/react/server'
import { renderToString } from 'react-dom/server'

const pages = import.meta.glob('./Pages/**/*.jsx', { eager: true })

// The SSR server for `zig build run-inertia -- react --ssr`: Zoda posts each
// full visit's page to http://127.0.0.1:13714/render and puts the answer's
// head and body into its layout. main.jsx then hydrates the markup.
// Inertia's default host is 0.0.0.0; this server sees every page prop and
// its markup is inserted unescaped, so it must listen on loopback only.
createServer((page) =>
  createInertiaApp({
    page,
    render: renderToString,
    resolve: (name) => pages[`./Pages/${name}.jsx`],
    setup: ({ App, props }) => <App {...props} />,
  }),
  { host: '127.0.0.1', port: 13714 },
)
