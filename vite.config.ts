import { defineConfig } from 'vite';

export default defineConfig({
  base: './',
  server: { port: 5183, host: '127.0.0.1' },
  build: { target: 'es2022', chunkSizeWarningLimit: 1200 },
  test: { environment: 'node', testTimeout: 120000 },
} as any);
