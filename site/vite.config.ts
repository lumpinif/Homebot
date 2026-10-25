import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

const VERSION_FILE = resolve(import.meta.dirname, "../mac/VERSION");

// The public website: a static build in site/dist, hosted anywhere. Relative asset paths, so it
// also works from a subfolder (for example GitHub Pages under /Homebot/).
export default defineConfig({
  base: "./",
  // One source for the version shown on the Install page: the app's own mac/VERSION.
  define: {
    __HOMEBOT_VERSION__: JSON.stringify(readFileSync(VERSION_FILE, "utf8").trim()),
  },
  plugins: [
    react(),
    tailwindcss(),
    {
      // The version is baked in at start, so a new mac/VERSION restarts the dev server.
      name: "homebot-version",
      configureServer(server) {
        server.watcher.add(VERSION_FILE);
        server.watcher.on("change", (file) => file === VERSION_FILE && server.restart());
      },
    },
  ],
  resolve: {
    alias: {
      "@": resolve(import.meta.dirname, "./src"),
    },
  },
  server: { port: 5181 },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    reportCompressedSize: false,
  },
});
