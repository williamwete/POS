/// <reference types="vitest/config" />
import { fileURLToPath, URL } from 'node:url'
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
  },
  server: {
    port: 5173,
    // Dev: proxy API ke backend lokal sehingga tidak perlu CORS
    proxy: { '/api': { target: 'http://localhost:8080', changeOrigin: false } },
  },
  test: {
    environment: 'jsdom',
    include: ['src/**/*.spec.ts'],
  },
})
