// Build settings shared by the three frontends. The Zoda layout links fixed
// names, so the bundle is always `dist/assets/app.js` and `dist/assets/app.css`.
// The server hashes app.js into the Inertia asset version instead.
export function build(entry) {
  return {
    outDir: 'dist',
    emptyOutDir: true,
    rolldownOptions: {
      input: entry,
      output: {
        entryFileNames: 'assets/app.js',
        chunkFileNames: 'assets/[name].js',
        assetFileNames: 'assets/app[extname]',
      },
    },
  }
}

// The Node SSR server bundle, `dist/ssr/ssr.js`, built after the client
// bundle, which empties `dist`. Zoda's static middleware serves only
// `dist/assets`, so it is never sent to browsers.
export function ssrBuild(entry) {
  return {
    outDir: 'dist/ssr',
    emptyOutDir: false,
    ssr: true,
    rolldownOptions: {
      input: entry,
      output: { entryFileNames: 'ssr.js' },
    },
  }
}
