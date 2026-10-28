import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import { build } from '../shared/build.mjs'

export default defineConfig({
  plugins: [vue()],
  build: build('src/main.js'),
})
