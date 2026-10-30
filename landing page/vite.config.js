import { defineConfig } from 'vite';

export default defineConfig({
  base: '/Framecast-Studio/',
  build: {
    assetsDir: 'assets',
    outDir: 'dist',
    emptyOutDir: true,
  },
});
