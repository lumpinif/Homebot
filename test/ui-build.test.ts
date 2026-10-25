// The committed setup page must be what web/ builds to (DECISIONS item 16).
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { staleUiFiles } from "../scripts/build-ui.ts";

const hasVite = existsSync(new URL("../web/node_modules/vite/bin/vite.js", import.meta.url));

test("setup page: the committed build in src/setup-ui matches a fresh build of web/", { skip: !hasVite && "web dev dependencies not installed (npm --prefix web install)" }, async () => {
  assert.deepEqual(await staleUiFiles(), [], "run: npm run build:ui");
});
