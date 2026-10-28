import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { build } from '../shared/build.mjs'

export default defineConfig({
  plugins: [react()],
  build: build('src/main.jsx'),
})
