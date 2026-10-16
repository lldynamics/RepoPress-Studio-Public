import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

// @ts-expect-error process is a nodejs global
const host = process.env.TAURI_DEV_HOST;

// https://vite.dev/config/
export default defineConfig(async () => ({
  plugins: [react()],
  build: {
    // The budget check reads Vite's dependency graph, not filename heuristics.
    manifest: true,
    rollupOptions: {
      output: {
        // Lazy surfaces share React and i18n without importing the app entry.
        // i18n's existing static catalogs follow it; scoped catalogs stay local.
        manualChunks(id) {
          const moduleId = id.replaceAll("\\", "/");
          if (/\/node_modules\/(react|react-dom|scheduler)\//.test(moduleId)
            || moduleId.endsWith("/src/i18n/i18n.tsx")) return "ui-runtime";
        },
      },
    },
  },

  // Vite options tailored for Tauri development and only applied in `tauri dev` or `tauri build`
  //
  // 1. prevent Vite from obscuring rust errors
  clearScreen: false,
  // 2. tauri expects a fixed port, fail if that port is not available
  server: {
    port: 1420,
    strictPort: true,
    host: host || false,
    hmr: host
      ? {
          protocol: "ws",
          host,
          port: 1421,
        }
      : undefined,
    watch: {
      // 3. tell Vite to ignore watching `src-tauri`
      ignored: ["**/src-tauri/**"],
    },
  },
  test: {
    environment: "jsdom",
    include: ["src/**/*.test.ts", "src/**/*.test.tsx", "scripts/**/*.test.mjs"],
  },
}));
