import { resolve } from "node:path";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// The build is the setup page the gateway serves: it lands in ../src/setup-ui and is committed,
// so users run Homebot without installing anything (DECISIONS item 16). The page's CSP allows
// only same-origin files, so nothing is inlined as a data: URL.
export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      "@": resolve(import.meta.dirname, "./src"),
    },
  },
  build: {
    outDir: process.env.HOMEBOT_UI_OUT ?? resolve(import.meta.dirname, "../src/setup-ui"),
    emptyOutDir: true,
    assetsInlineLimit: 0,
    modulePreload: { polyfill: false },
    reportCompressedSize: false,
    // React, motion and the page: about 550 kB, read once from this Mac.
    chunkSizeWarningLimit: 800,
    // Fixed names: the gateway serves exactly these files (src/server/setup.ts STATIC).
    rolldownOptions: {
      output: {
        entryFileNames: "assets/app.js",
        chunkFileNames: "assets/[name].js",
        assetFileNames: "assets/app[extname]",
      },
    },
  },
});
