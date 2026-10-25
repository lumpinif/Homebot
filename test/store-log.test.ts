import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, stat, readdir, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ConfigStore, StateStore, DEFAULT_SETTINGS } from "../src/core/store.ts";
import { createLogger, errorName } from "../src/core/log.ts";
import type { BdkClient } from "../src/core/bdk.ts";
import { must } from "../test-helpers/must.ts";

const tmp = () => mkdtemp(join(tmpdir(), "homebot-test-"));

test("config: defaults merge, bot validation, prototype keys are not bots", async () => {
  const dir = await tmp();
  const c = await new ConfigStore(join(dir, "config.json")).load();
  c.data.settings = { answerBudgetMs: 9000, maxSpokenChars: { en: 100 } };
  assert.equal(c.settings.answerBudgetMs, 9000);
  assert.equal(c.settings.pollMs, DEFAULT_SETTINGS.pollMs);
  assert.deepEqual(c.settings.maxSpokenChars, { ...DEFAULT_SETTINGS.maxSpokenChars, en: 100 });
  await assert.rejects(c.putBot({ key: "../x", name: "x", sessionId: "1", strictEcho: true }), /bot key/);
  await assert.rejects(c.putBot({ key: "ok", name: "x", sessionId: "da83afad-uuid", strictEcho: true }), /numeric/);
  await c.putBot({ key: "chai", name: "拆解师", sessionId: "14752726", strictEcho: true });
  assert.equal(c.bot("constructor"), undefined);
  assert.equal(c.bot("__proto__"), undefined);
  const again = await new ConfigStore(c.file).load();
  assert.equal(must(again.bot("chai")).sessionId, "14752726");
  assert.equal((await stat(c.file)).mode & 0o777, 0o600);
});

test("S3: a key never moves to another session; a session has one key", async () => {
  const c = await new ConfigStore(join(await tmp(), "config.json")).load();
  await c.putBot({ key: "chai", name: "拆解师", sessionId: "100", strictEcho: true });
  await c.putBot({ key: "chai", name: "Renamed", sessionId: "100", strictEcho: false }); // same identity: OK
  assert.throws(() => c.checkBot({ key: "chai", name: "x", sessionId: "200", strictEcho: true }), /already belongs to session 100/);
  await assert.rejects(c.putBot({ key: "alias", name: "x", sessionId: "100", strictEcho: true }), /already configured as bot "chai"/);
  assert.equal(must(c.bot("chai")).sessionId, "100");
  assert.equal(c.bot("alias"), undefined);
});

test("cold sync has a total time cap, not just a page cap", async () => {
  const { coldSync } = await import("../src/core/bots.ts");
  let n = 0;
  const slow: BdkClient = {
    getOrCreateSession: async () => assert.fail("not used"),
    sendMessage: async () => assert.fail("not used"),
    getEntries: async (_sid, _c, o) => {
      const signal = must(o?.signal);
      await new Promise<void>((r, j) => {
        const t = setTimeout(r, 30);
        signal.addEventListener("abort", () => (clearTimeout(t), j(signal.reason)), { once: true });
      });
      n++;
      return { entries: [{ seq: String(n), updatedSeq: String(n), kind: "message" }], latestUpdatedSeq: String(n), turn: {} };
    },
  };
  await assert.rejects(coldSync(slow, "1", { timeoutMs: 120 }), /longer than 0 s|longer than/);
  assert.ok(n < 10);
});

test("state: cursors only move forward", async () => {
  const s = await new StateStore(join(await tmp(), "state.json")).load();
  await s.setCursor("chai", { cursor: "500", maxSeq: "480" });
  await s.setCursor("chai", { cursor: "300", maxSeq: "900" });
  assert.equal(must(s.cursor("chai")).cursor, "500");
  await s.setCursor("chai", { cursor: "600", maxSeq: "100" });
  assert.equal(must(s.cursor("chai")).cursor, "600");
  assert.equal(must(s.cursor("chai")).maxSeq, "480", "maxSeq never decreases");
  assert.equal(s.cursor("hasOwnProperty"), undefined);
});

test("logger: 0600 file, JSON lines, rotation keeps 3 files", async () => {
  const dir = await tmp();
  const { log, file } = createLogger(dir, { maxBytes: 200 });
  for (let i = 0; i < 30; i++) await log({ event: "x", i, pad: "y".repeat(40) });
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  const names = (await readdir(dir)).sort();
  assert.deepEqual(names, ["homebot.jsonl", "homebot.jsonl.1", "homebot.jsonl.2", "homebot.jsonl.3"]);
  const last = (await readFile(file, "utf8")).trim().split("\n").map((l) => JSON.parse(l)).at(-1);
  assert.equal(last.i, 29);
});

test("R2: errorName logs only known error classes", () => {
  assert.equal(errorName(new TypeError("x")), "TypeError");
  assert.equal(errorName(new Error("x")), "Error");
  const custom = new Error("x");
  custom.name = "synthetic_private_error_name";
  assert.equal(errorName(custom), "other");
  assert.equal(errorName("a string"), "non-error");
  assert.equal(errorName(undefined), "non-error");
});
