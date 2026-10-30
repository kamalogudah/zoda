import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { build, ssrBuild } from '../shared/build.mjs'

export default defineConfig(({ isSsrBuild }) => ({
  plugins: [react()],
  build: isSsrBuild ? ssrBuild('src/ssr.jsx') : build('src/main.jsx'),
}))
