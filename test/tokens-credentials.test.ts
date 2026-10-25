import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, mkdir, readFile, readdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TokenStore, PENDING_TTL_MS } from "../src/core/tokens.ts";
import { resolveCredential } from "../src/core/credentials.ts";
import { writeJson } from "../src/core/fsutil.ts";
import { messages, LANGS } from "../src/core/i18n.ts";
import { must } from "../test-helpers/must.ts";

const tmp = () => mkdtemp(join(tmpdir(), "homebot-test-"));

async function store(now = () => 1_000) {
  return new TokenStore(join(await tmp(), "tokens.json"), { now }).load();
}

test("tokens: issued plaintext is never stored, only its hash", async () => {
  const s = await store();
  const { token } = await s.issue({ bot: "chai", label: "问拆解师" });
  const raw = await readFile(s.file, "utf8");
  assert.ok(!raw.includes(token));
  assert.ok(!JSON.stringify(s.list()).includes("hash"));
});

test("tokens: verify accepts own bot or omitted bot, rejects others and garbage", async () => {
  const s = await store();
  const { token } = await s.issue({ bot: "chai", label: "a" });
  assert.equal((await s.verify(token, "chai")).ok, true);
  assert.equal((await s.verify(token, undefined)).ok, true);
  assert.deepEqual(await s.verify(token, "other"), { ok: false, reason: "forbidden" });
  assert.deepEqual(await s.verify("nope", "chai"), { ok: false, reason: "invalid" });
  assert.deepEqual(await s.verify(undefined, "chai"), { ok: false, reason: "invalid" });
});

test("tokens: replacement keeps the old token working until the new one is used", async () => {
  const s = await store();
  const old = await s.issue({ bot: "chai", label: "v1" });
  await s.verify(old.token, "chai"); // v1 active
  const next = await s.issue({ bot: "chai", label: "v2", replaces: old.id });
  assert.equal((await s.verify(old.token, "chai")).ok, true, "old still valid while v2 is pending");
  assert.equal((await s.verify(next.token, "chai")).ok, true);
  assert.deepEqual(await s.verify(old.token, "chai"), { ok: false, reason: "invalid" }, "old retired after v2's first use");
  const reloaded = await new TokenStore(s.file).load();
  assert.equal(must(reloaded.records.find((r) => r.id === old.id)).state, "retired");
});

test("tokens: an abandoned pending token never breaks the active one and expires", async () => {
  let t = 1_000;
  const s = await store(() => t);
  const old = await s.issue({ bot: "chai", label: "v1" });
  await s.verify(old.token);
  const abandoned = await s.issue({ bot: "chai", label: "v2", replaces: old.id });
  t += PENDING_TTL_MS;
  assert.deepEqual(await s.verify(abandoned.token), { ok: false, reason: "invalid" });
  assert.deepEqual(await s.expirePending(), [abandoned.id]);
  assert.equal((await s.verify(old.token)).ok, true);
});

test("tokens: revoke", async () => {
  const s = await store();
  const a = await s.issue({ bot: "chai", label: "a" });
  assert.equal(await s.revoke(a.id), true);
  assert.equal((await s.verify(a.token)).ok, false);
  assert.equal(await s.revoke("missing"), false);
});

test("B1: two stores on one file (gateway + CLI) always agree", async () => {
  const file = join(await tmp(), "tokens.json");
  const gateway = await new TokenStore(file).load();
  const cli = await new TokenStore(file).load();
  const a = await cli.issue({ bot: "chai", label: "a" }); // issued after the gateway loaded
  assert.equal((await gateway.verify(a.token, "chai")).ok, true, "gateway sees new tokens");
  assert.equal(await cli.revoke(a.id), true);
  assert.deepEqual(await gateway.verify(a.token, "chai"), { ok: false, reason: "invalid" }, "revocation reaches the gateway");
});

test("B1: activation in a stale store never overwrites a newer revoke", async () => {
  const file = join(await tmp(), "tokens.json");
  const cli = await new TokenStore(file).load();
  const keep = await cli.issue({ bot: "chai", label: "keep" });
  const kill = await cli.issue({ bot: "chai", label: "kill" });
  const gateway = await new TokenStore(file).load(); // snapshot with both pending
  await cli.revoke(kill.id);
  assert.equal((await gateway.verify(keep.token)).ok, true); // activation = locked RMW
  const fresh = await new TokenStore(file).load();
  assert.equal(must(fresh.records.find((r) => r.id === kill.id)).state, "retired");
  assert.equal(must(fresh.records.find((r) => r.id === keep.id)).state, "active");
});

test("B1: concurrent mutations from two stores are all kept", async () => {
  const file = join(await tmp(), "tokens.json");
  const s1 = await new TokenStore(file).load();
  const s2 = await new TokenStore(file).load();
  await Promise.all([...Array(5)].flatMap((_, i) => [s1.issue({ bot: "a", label: `x${i}` }), s2.issue({ bot: "b", label: `y${i}` })]));
  assert.equal((await new TokenStore(file).load()).records.length, 10);
});

test("S1: a Shortcut's phrase is unique under the issuance lock, across stores and kinds", async () => {
  const file = join(await tmp(), "tokens.json");
  const s1 = await new TokenStore(file).load();
  const s2 = await new TokenStore(file).load();
  const tries = await Promise.allSettled([s1.issue({ bot: "a", label: "家庭助手", uniqueLabel: true }), s2.issue({ bot: "b", label: "家庭助手", uniqueLabel: true, kind: "lab" })]);
  assert.deepEqual(tries.map((t) => t.status).sort(), ["fulfilled", "rejected"], "two concurrent builds never share a phrase");
  const won = await new TokenStore(file).load();
  const first = must(won.records[0]);
  await assert.rejects(won.issue({ bot: "a", label: " House  BUTLER ", uniqueLabel: true }).then(() => won.issue({ bot: "a", label: "house butler", uniqueLabel: true })), /already uses/);
  const again = await won.issue({ bot: first.bot, label: "家庭助手", replaces: first.id, uniqueLabel: true, ...(first.kind ? { kind: first.kind } : {}) });
  assert.ok(again.id, "a replacement keeps its predecessor's phrase");
  await won.revoke(first.id);
  await won.revoke(again.id);
  assert.ok((await won.issue({ bot: "a", label: "家庭助手", uniqueLabel: true })).id, "retired tokens free their phrase");
});

test("S5: token artifacts are removed on use, revoke, expiry, or after 24 h", async () => {
  const dir = await tmp();
  const { mkdir: mk, writeFile: wf, readdir: rd } = await import("node:fs/promises");
  const art = join(dir, "shortcuts");
  await mk(art);
  let t = 1_000;
  const s = await new TokenStore(join(dir, "tokens.json"), { now: () => t, artifactsDir: art }).load();
  const used = await s.issue({ bot: "chai", label: "used" });
  const revoked = await s.issue({ bot: "chai", label: "revoked" });
  const idle = await s.issue({ bot: "chai", label: "idle" });
  for (const x of [used, revoked, idle]) await wf(s.artifactPath(x.id, "token"), "synthetic");
  await wf(join(art, "ffffffffffff.token"), "orphan");
  await s.verify(used.token);
  await s.revoke(revoked.id);
  assert.deepEqual((await rd(art)).sort(), [`${idle.id}.token`]);
  t = Date.now() + 25 * 3600 * 1000; // pending but artifact older than 24 h
  await s.cleanupArtifacts();
  assert.deepEqual(await rd(art), []);
});

test("M2 S1: cleanup in a stale store never deletes an artifact another process just built", async () => {
  const dir = await tmp();
  const art = join(dir, "shortcuts");
  await mkdir(art);
  const file = join(dir, "tokens.json");
  const gateway = await new TokenStore(file, { artifactsDir: art }).load(); // snapshot before the build
  const cli = await new TokenStore(file, { artifactsDir: art }).load();
  const built = await cli.issue({ bot: "chai", label: "Ask Chai" });
  await mkdir(cli.artifactDir(built.id));
  await writeFile(join(cli.artifactDir(built.id), "Ask Chai.shortcut"), "synthetic");
  assert.deepEqual(await gateway.cleanupArtifacts(), [], "decided against the current file, not the snapshot");
  const other = await gateway.issue({ bot: "chai", label: "x" }); // mutation path sweeps too
  await gateway.revoke(other.id);
  assert.deepEqual(await readdir(art), [built.id]);
});

test("M2 S1: concurrent builds and sweeps from two stores keep every live artifact", async () => {
  const dir = await tmp();
  const art = join(dir, "shortcuts");
  await mkdir(art);
  const file = join(dir, "tokens.json");
  const a = await new TokenStore(file, { artifactsDir: art }).load();
  const b = await new TokenStore(file, { artifactsDir: art }).load();
  const build = async (s: TokenStore, i: number) => {
    const { id } = await s.issue({ bot: "chai", label: `t${i}` });
    await writeFile(s.artifactPath(id, "token"), "synthetic");
    return `${id}.token`;
  };
  const sweeps = [...Array(6)].map(() => a.cleanupArtifacts());
  const files = await Promise.all([...Array(6)].map((_, i) => build(i % 2 ? a : b, i)));
  await Promise.all(sweeps);
  await a.cleanupArtifacts();
  assert.deepEqual((await readdir(art)).sort(), files.sort());
});

test("M2 S4: --replaces must name a usable token of the same bot", async () => {
  const s = await store();
  const a = await s.issue({ bot: "a", label: "a" });
  await s.verify(a.token); // bot a's working Shortcut
  await assert.rejects(s.issue({ bot: "b", label: "b", replaces: a.id }), /belongs to bot "a", not "b"/);
  await assert.rejects(s.issue({ bot: "a", label: "x", replaces: "000000000000" }), /no such usable token/);
  await s.revoke(a.id);
  await assert.rejects(s.issue({ bot: "a", label: "x", replaces: a.id }), /no such usable token/);
  assert.equal(s.records.length, 1, "rejected replacements issue nothing");
  const c = await s.issue({ bot: "c", label: "c" });
  await s.verify(c.token);
  await assert.rejects(s.issue({ bot: "b", label: "b", replaces: c.id }));
  assert.equal((await s.verify(c.token)).ok, true, "a rejected cross-bot replacement leaves the old token usable");
});

test("credentials: resolution order and source names", async () => {
  const dir = await tmp();
  const secretsFile = join(dir, "secrets.json");
  const userHome = join(dir, "home");
  const keyFile = join(dir, "key.txt");
  await writeFile(keyFile, "file-key\n");
  await writeJson(secretsFile, { bdkApiKey: "secrets-key" });
  const asDir = join(userHome, ".config/agent-serve");
  await mkdir(asDir, { recursive: true });
  await writeJson(join(asDir, "credentials.json"), { apiKey: "detected-key" });

  const r = (env: NodeJS.ProcessEnv, extra: { detect?: boolean } = {}) => resolveCredential({ env, secretsFile, userHome, ...extra });
  assert.deepEqual(await r({ CURSOR_API_KEY: "env-key", CURSOR_API_KEY_FILE: keyFile }), { key: "env-key", source: "env:CURSOR_API_KEY" });
  assert.deepEqual(await r({ CURSOR_API_KEY_FILE: keyFile }), { key: "file-key", source: "env:CURSOR_API_KEY_FILE" });
  assert.deepEqual(await r({ CURSOR_SERVICE_ACCOUNT_KEY: "sa" }), { key: "sa", source: "env:CURSOR_SERVICE_ACCOUNT_KEY" });
  assert.deepEqual(await r({}), { key: "secrets-key", source: "homebot:secrets" });
  await writeJson(secretsFile, {});
  assert.deepEqual(await r({}), { key: "detected-key", source: "detected:agent-serve" });
  assert.equal(await r({ HOMEBOT_DETECT_CREDENTIALS: "0" }), null, "detection off = clean new-user start");
  assert.equal(await r({}, { detect: false }), null);
});

test("credentials: AGENT_SERVE_CONFIG_DIR is preferred over the default agent-serve folder", async () => {
  const dir = await tmp();
  await writeJson(join(dir, "as", "credentials.json"), { apiKey: "as-key" });
  const c = await resolveCredential({ env: { AGENT_SERVE_CONFIG_DIR: join(dir, "as") }, secretsFile: join(dir, "none.json"), userHome: dir });
  assert.deepEqual(c, { key: "as-key", source: "detected:agent-serve" });
});

test("credentials: malformed secrets JSON fails with a fixed message, never the content", async () => {
  const dir = await tmp();
  const secretsFile = join(dir, "secrets.json");
  const dummy = "dummy-secret-value-123";
  await writeFile(secretsFile, `{"bdkApiKey": ${dummy}}`);
  const e = await resolveCredential({ env: {}, secretsFile, userHome: dir }).catch((x) => x);
  assert.ok(e instanceof Error);
  assert.match(e.message, /secrets\.json is not valid JSON/);
  assert.ok(!e.message.includes("dummy") && !String(e.stack).includes("dummy"));
});

test("i18n: every language has every message", () => {
  const keys = Object.keys(messages("zh-CN")).sort();
  for (const l of LANGS) assert.deepEqual(Object.keys(messages(l)).sort(), keys);
  assert.equal(LANGS.length, 11, "one catalog per language in src/core/lang.ts");
  assert.equal(messages("nl"), messages("en"), "unknown language falls back to English");
  assert.equal(messages(undefined), messages("en"));
  assert.match(messages("zh-CN").busy("拆解师"), /正在忙/);
  assert.match(messages("en").busy("Chai"), /^Chai is busy/);
});
