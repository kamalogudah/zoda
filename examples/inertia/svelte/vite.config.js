import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'
import { build } from '../shared/build.mjs'

export default defineConfig({
  plugins: [svelte()],
  build: build('src/main.js'),
})
