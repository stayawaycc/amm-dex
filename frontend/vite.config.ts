import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { resolve } from "node:path";

/**
 * The frontend lives in `frontend/` while the repo root holds the Foundry project, so Vite is
 * pointed at the subdirectory explicitly rather than relying on the default root discovery.
 */
export default defineConfig({
  root: resolve(__dirname),
  plugins: [react()],
  server: {
    port: 5173,
    strictPort: false,
    open: false,
  },
  build: {
    outDir: resolve(__dirname, "../dist"),
    emptyOutDir: true,
    sourcemap: true,
  },
  resolve: {
    alias: {
      "@": resolve(__dirname, "src"),
    },
  },
  define: {
    // wagmi/viem expect a browser-ish global in a few code paths.
    global: "globalThis",
  },
});
