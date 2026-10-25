// M4 review B1/S1/S2: one owner for a bot's identity, its cursor and its tokens.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ConfigStore, StateStore } from "../src/core/store.ts";
import { TokenStore } from "../src/core/tokens.ts";
import { BotLifecycle } from "../src/core/lifecycle.ts";
import { makeShortcut } from "../src/shortcut/make.ts";
import { shortcutProfile } from "../src/shortcut/profile.ts";
import { must } from "../test-helpers/must.ts";
import type { Bot } from "../src/core/store.ts";

const A: Bot = { key: "homebot", name: "homebot", sessionId: "14752726", strictEcho: true };
const B: Bot = { key: "homebot", name: "homebot", sessionId: "555", strictEcho: true };
const sync = (n: number) => ({ cursor: String(n), maxSeq: String(n) });

async function stores() {
  const dir = await mkdtemp(join(tmpdir(), "homebot-test-"));
  const config = await new ConfigStore(join(dir, "config.json")).load();
  const state = await new StateStore(join(dir, "state.json")).load();
  const tokens = await new TokenStore(join(dir, "tokens.json"), { artifactsDir: join(dir, "shortcuts") }).load();
  return { dir, config, state, tokens, lifecycle: new BotLifecycle({ config, state, tokens }) };
}

/** Fresh store objects on the same files, as another process (CLI vs gateway) would have. */
async function otherProcess(dir: string) {
  const config = await new ConfigStore(join(dir, "config.json")).load();
  const state = await new StateStore(join(dir, "state.json")).load();
  const tokens = await new TokenStore(join(dir, "tokens.json"), { artifactsDir: join(dir, "shortcuts") }).load();
  return { config, state, tokens, lifecycle: new BotLifecycle({ config, state, tokens }) };
}

const usable = (tokens: TokenStore, bot: string) => tokens.list().filter((t) => t.bot === bot && t.state !== "retired");

test("B1: a build that captured the bot before remove + re-add under the same key issues nothing", async () => {
  const s = await stores();
  await s.lifecycle.add(A, sync(10));
  const captured = must(s.config.bot("homebot")); // the build read the bot here...
  const other = await otherProcess(s.dir);
  assert.deepEqual(await other.lifecycle.remove("homebot"), []); // ...then another process removed it
  await other.lifecycle.add(B, sync(20)); // ...and re-added the key for another conversation
  const profile = shortcutProfile({ botName: captured.name });
  await assert.rejects(
    makeShortcut({ tokens: s.tokens, lifecycle: s.lifecycle, bot: captured, profile, baseUrl: "http://mac.local:8787" }),
    /removed or changed meanwhile; nothing was issued/,
  );
  await s.tokens.load();
  assert.deepEqual(s.tokens.list(), [], "no token exists for the old conversation");
  assert.deepEqual(await readdir(join(s.dir, "shortcuts")).catch(() => []), [], "no file was written");
});

test("B1: removal racing a build never leaves a usable token behind", async () => {
  for (let i = 0; i < 10; i++) {
    const s = await stores();
    await s.lifecycle.add(A, sync(10));
    const other = await otherProcess(s.dir);
    const issue = (b: Bot) => s.tokens.issue({ bot: b.key, label: "x", sessionId: b.sessionId });
    const [built] = await Promise.allSettled([s.lifecycle.issueFor(A, issue), other.lifecycle.remove("homebot")]);
    await s.tokens.load();
    assert.deepEqual(usable(s.tokens, "homebot"), [], `round ${i}: ${built.status}`);
  }
});

test("B1: tokens record the conversation; removal retires all of a bot's tokens", async () => {
  const s = await stores();
  await s.lifecycle.add(A, sync(10));
  const issue = (b: Bot) => s.tokens.issue({ bot: b.key, label: "x", sessionId: b.sessionId });
  const t1 = await s.lifecycle.issueFor(A, issue);
  const t2 = await s.lifecycle.issueFor(A, issue);
  assert.equal(must(s.tokens.list().find((t) => t.id === t1.id)).sessionId, A.sessionId);
  assert.deepEqual(must(await s.lifecycle.remove("homebot")).sort(), [t1.id, t2.id].sort());
  assert.equal(s.config.bot("homebot"), undefined);
  assert.equal(s.state.cursor("homebot"), undefined);
  assert.equal((await s.tokens.verify(t1.token, "homebot")).ok, false);
  assert.equal(await s.lifecycle.remove("homebot"), null, "unknown bot");
});

test("S1: a rejected concurrent add changes neither the config nor the other bot's cursor", async () => {
  const s = await stores();
  const other = await otherProcess(s.dir);
  // Both validated the key as free before their (slow) cold syncs; A finishes first.
  s.config.checkBot(A);
  other.config.checkBot(B);
  await s.lifecycle.add(A, sync(10));
  await assert.rejects(other.lifecycle.add(B, sync(99)), /already belongs to session 14752726/);
  const fresh = await otherProcess(s.dir);
  assert.equal(must(fresh.config.bot("homebot")).sessionId, A.sessionId);
  assert.deepEqual(
    { cursor: must(fresh.state.cursor("homebot")).cursor, sessionId: must(fresh.state.cursor("homebot")).sessionId },
    { cursor: "10", sessionId: A.sessionId },
  );
});

test("S1: a cursor tagged for another conversation is never advanced by a stale writer", async () => {
  const s = await stores();
  await s.lifecycle.add(B, sync(20));
  await s.state.setCursor("homebot", sync(500), { sessionId: A.sessionId }); // a request for the old bot finishing late
  assert.deepEqual([must(s.state.cursor("homebot")).cursor, must(s.state.cursor("homebot")).sessionId], ["20", B.sessionId]);
  await s.state.setCursor("homebot", sync(30), { sessionId: B.sessionId });
  assert.equal(must(s.state.cursor("homebot")).cursor, "30");
});

test("S2: a wait-test token never works for /v1/ask, and using it leaves the voice token alone", async () => {
  const s = await stores();
  const voice = await s.tokens.issue({ bot: "homebot", label: "voice" });
  assert.equal((await s.tokens.verify(voice.token, "homebot")).ok, true);
  await assert.rejects(s.tokens.issue({ bot: "homebot", label: "probe", kind: "probe", replaces: voice.id }), /never replace each other/);
  const probe = await s.tokens.issue({ bot: "homebot", label: "probe", kind: "probe" });
  assert.deepEqual(await s.tokens.verify(probe.token, "homebot"), { ok: false, reason: "invalid" }, "not a voice token");
  assert.equal(must(s.tokens.list().find((t) => t.id === probe.id)).state, "pending", "a refused use does not activate it");
  assert.equal((await s.tokens.verify(probe.token, "homebot", { kind: "probe" })).ok, true);
  assert.deepEqual(await s.tokens.verify(voice.token, "homebot", { kind: "probe" }), { ok: false, reason: "invalid" });
  assert.equal((await s.tokens.verify(voice.token, "homebot")).ok, true, "the voice Shortcut still works");
  await assert.rejects(s.tokens.issue({ bot: "homebot", label: "v2", replaces: probe.id }), /never replace each other/);
});
