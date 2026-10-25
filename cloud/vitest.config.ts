import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest(async () => ({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        // Test-only values (they win over a local .dev.vars); the real secret is set in Cloudflare (DEPLOY.md).
        bindings: { HMAC_SECRET: "test-secret", SITE_ORIGIN: "https://homebot.fun", TEST_MIGRATIONS: await readD1Migrations(path.join(import.meta.dirname, "migrations")) },
        // The tests make more sign-ups a minute than production allows; the limiter itself isn't under test.
        ratelimits: {
          SUBSCRIBE_LIMIT: { namespace_id: "2002", simple: { limit: 1000, period: 60 as const } },
          PING_LIMIT: { namespace_id: "2001", simple: { limit: 1000, period: 60 as const } },
        },
      },
    })),
  ],
  test: { setupFiles: ["./test/apply-migrations.ts"] },
});
