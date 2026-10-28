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
