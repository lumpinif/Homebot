import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, readdir, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startFakeBdk, FAKE_KEY, type FakeBdk } from "../test-helpers/fake-bdk.ts";
import { run } from "../src/cli.ts";
import { ConfigStore } from "../src/core/store.ts";
import { messages } from "../src/core/i18n.ts";
import type { Settings } from "../src/core/store.ts";
import type { Server } from "node:http";
import { must, group, portOf } from "../test-helpers/must.ts";

const SID = "14752726";
const zh = messages("zh-CN");
let fake: FakeBdk; // set by harness(); afterEach closes it
let server: Server | undefined;
afterEach(async () => {
  server?.closeAllConnections();
  await new Promise<void>((r) => (server ? server.close(() => r()) : r()));
  server = undefined;
  await fake?.close();
});

async function harness({ settings }: { settings?: Partial<Settings> } = {}) {
  fake = await startFakeBdk();
  for (let i = 0; i < 3; i++) fake.add(SID, { kind: "send-message", text: `old ${i}` });
  const dir = await mkdtemp(join(tmpdir(), "homebot-test-"));
  const env = {
    HOMEBOT_HOME: join(dir, "hb"),
    CURSOR_API_KEY: FAKE_KEY,
    HOMEBOT_BDK_BASE_URL: fake.baseUrl,
    HOMEBOT_PORT: "0",
    HOMEBOT_BIND: "127.0.0.1",
    HOMEBOT_SETUP_PORT: "0",
    HOMEBOT_DETECT_CREDENTIALS: "0",
  };
  const output: string[] = [];
  const cli = async (...argv: string[]) => {
    const lines: string[] = [];
    const code = await run(argv, { env, userHome: dir, out: (s) => lines.push(s), err: (s) => lines.push(s), onListening: (s) => (server = s) });
    output.push(...lines);
    return { code, text: lines.join("\n") };
  };
  assert.equal((await cli("bot", "add-id", SID, "--key", "chai", "--name", "拆解师")).code, 0);
  if (settings) {
    const c = await new ConfigStore(join(env.HOMEBOT_HOME, "config.json")).load();
    c.data.settings = settings;
    await c.save();
  }
  // Felix's setup: Siri in Chinese (the product default would be en-US).
  const issued = await cli("token", "issue", "chai", "--siri-lang", "zh-CN");
  const tokenFile = group(/written to (\S+) /, issued.text);
  const token = (await readFile(tokenFile, "utf8")).trim();
  return { env, cli, token, output, dir };
}

async function startServer(cli: (...argv: string[]) => Promise<{ code: number; text: string }>) {
  const r = await cli("start");
  assert.equal(r.code, 0, r.text);
  return `http://127.0.0.1:${portOf(server)}`;
}

const post = (url: string, body: unknown, headers: Record<string, string> = {}) =>
  fetch(`${url}/v1/ask`, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: typeof body === "string" ? body : JSON.stringify(body) });

test("end to end over HTTP: token -> /v1/ask -> owned reply as text/plain", async () => {
  const { cli, token, output, env } = await harness({ settings: { answerBudgetMs: 2000, pollMs: 10 } });
  const url = await startServer(cli);
  fake.autoReply(SID, { text: "现在三点。" });
  const res = await post(url, { bot: "chai", text: "几点了", v: 1 }, { "X-Homebot-Token": token });
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("content-type"), "text/plain; charset=utf-8");
  assert.equal(await res.text(), "现在三点。");

  // Bot omitted -> the token's own bot.
  const res2 = await post(url, { text: "再问一次" }, { "X-Homebot-Token": token });
  assert.equal(await res2.text(), "现在三点。");

  const list = await cli("token", "list");
  assert.match(list.text, /\tchai\tactive\t/);

  // Secret hygiene: neither the BDK key nor the client token appear in output or logs.
  const logs = await readFile(join(env.HOMEBOT_HOME, "logs", "homebot.jsonl"), "utf8");
  for (const secret of [FAKE_KEY, token]) {
    assert.ok(!output.join("\n").includes(secret));
    assert.ok(!logs.includes(secret));
  }
  assert.ok(!logs.includes("几点了"), "question text not logged by default");
});

test("auth: 401 for bad token, 403 for another bot, nothing sent", async () => {
  const { cli, token } = await harness();
  fake.add("999", { kind: "send-message", text: "x" });
  assert.equal((await cli("bot", "add-id", "999", "--key", "other", "--name", "Other")).code, 0);
  const url = await startServer(cli);
  const bad = await post(url, { bot: "chai", text: "hi" }, { "X-Homebot-Token": "wrong" });
  assert.equal(bad.status, 401);
  assert.equal(await bad.text(), messages("en").badToken(), "unauthenticated: product default English");
  const none = await post(url, { bot: "chai", text: "hi" });
  assert.equal(none.status, 401);
  const cross = await post(url, { bot: "other", text: "hi" }, { "X-Homebot-Token": token });
  assert.equal(cross.status, 403);
  assert.equal(await cross.text(), messages("en").forbiddenBot());
  assert.equal(fake.posts.length, 0);
});

test("S4: a token issued without --siri-lang speaks English; bad languages are rejected", async () => {
  const { cli } = await harness({ settings: { answerBudgetMs: 2000, pollMs: 10 } });
  const issued = await cli("token", "issue", "chai");
  const enToken = (await readFile(group(/written to (\S+) /, issued.text), "utf8")).trim();
  assert.match((await cli("token", "list")).text, /\ten-US\t/);
  assert.equal((await cli("token", "issue", "chai", "--siri-lang", "xx")).code, 1);
  const url = await startServer(cli);
  fake.autoReply(SID, { text: "Three o'clock." });
  assert.equal(await (await post(url, { text: "What time is it?" }, { "X-Homebot-Token": enToken })).text(), "Three o'clock.");
  assert.match(must(fake.posts[0]).text, / · en\]\n/);
});

test("S3: add-id refuses remapping a key or reusing a session, before any network call", async () => {
  const { cli } = await harness();
  const before = fake.requests.length;
  assert.match((await cli("bot", "add-id", "888", "--key", "chai", "--name", "X")).text, /already belongs to session 14752726/);
  assert.match((await cli("bot", "add-id", SID, "--key", "alias", "--name", "X")).text, /already configured as bot "chai"/);
  assert.equal(fake.requests.length, before);
});

test("transport limits: 413, 400, 404, 405, health, rate limit", async () => {
  const { cli, token } = await harness({ settings: { rateLimitPerMin: 1, answerBudgetMs: 1000, pollMs: 10 } });
  const url = await startServer(cli);
  assert.equal((await post(url, "x".repeat(17 * 1024), { "X-Homebot-Token": token })).status, 413);
  assert.equal((await post(url, "{not json", { "X-Homebot-Token": token })).status, 400);
  assert.equal((await fetch(`${url}/nope`)).status, 404);
  assert.equal((await fetch(`${url}/v1/ask`)).status, 405);
  const h = await fetch(`${url}/v1/health`);
  assert.deepEqual(await h.json(), { ok: true });
  fake.autoReply(SID);
  assert.equal((await post(url, { text: "一" }, { "X-Homebot-Token": token })).status, 200);
  const limited = await post(url, { text: "二" }, { "X-Homebot-Token": token });
  assert.equal(await limited.text(), zh.rateLimited());
  assert.equal(fake.posts.length, 1);
});

test("client disconnect before send: nothing is sent", async () => {
  const { cli, token } = await harness({ settings: { answerBudgetMs: 3000, pollMs: 10 } });
  const url = await startServer(cli);
  const ctl = new AbortController();
  fake.intercept = async ({ what }) => {
    if (what === "entries") {
      ctl.abort();
      await new Promise((r) => setTimeout(r, 100));
    }
  };
  const p = fetch(`${url}/v1/ask`, { method: "POST", headers: { "X-Homebot-Token": token }, body: JSON.stringify({ text: "hi" }), signal: ctl.signal });
  await assert.rejects(p);
  await new Promise((r) => setTimeout(r, 300));
  assert.equal(fake.posts.length, 0);
});

test("CLI: add-id validates before any network call; no credentials is a clear error", async () => {
  const { cli, env, dir } = await harness();
  const before = fake.requests.length;
  const r = await cli("bot", "add-id", "da83afad-uuid", "--key", "x", "--name", "X");
  assert.equal(r.code, 1);
  assert.match(r.text, /numeric/);
  assert.equal(fake.requests.length, before);
  const noKey = await run(["bot", "add-id", "777", "--key", "x", "--name", "X"], { env: { ...env, CURSOR_API_KEY: "" }, userHome: dir, out: () => {}, err: (s) => assert.match(s, /No Grok Bot credentials found/) });
  assert.equal(noKey, 1);
});

test("CLI: start without credentials still runs and points the user to the setup page", async () => {
  const { env, dir, token } = await harness();
  const lines: string[] = [];
  const code = await run(["start"], { env: { ...env, CURSOR_API_KEY: "" }, userHome: dir, out: (s) => lines.push(s), err: (s) => lines.push(s), onListening: (s) => (server = s) });
  assert.equal(code, 0, lines.join("\n"));
  assert.match(lines.join("\n"), /credentials: none yet/);
  assert.match(lines.join("\n"), /Setup page: http:\/\/127\.0\.0\.1:\d+\//);
  assert.match(lines.join("\n"), /add your API key on the setup page/);
  // A Shortcut request without a key gets the spoken sign-in message, not a crash.
  const res = await post(`http://127.0.0.1:${portOf(server)}`, { text: "hi" }, { "X-Homebot-Token": token });
  assert.equal(await res.text(), zh.authFailed());
});

test("B3: malformed secrets.json never leaks its content through CLI output", async () => {
  const { env, dir } = await harness();
  const { writeFile } = await import("node:fs/promises");
  await writeFile(join(env.HOMEBOT_HOME, "secrets.json"), '{"bdkApiKey": dummy-secret-value-123}');
  for (const cmd of [["start"], ["doctor"]]) {
    const lines: string[] = [];
    const code = await run(cmd, { env: { ...env, CURSOR_API_KEY: "" }, userHome: dir, out: (s) => lines.push(s), err: (s) => lines.push(s) });
    assert.equal(code, 1);
    assert.match(lines.join("\n"), /not valid JSON/);
    assert.ok(!lines.join("\n").includes("dummy"));
  }
});

test("CLI: doctor reports readable bots without printing secrets; failed add-id leaves no bot", async () => {
  const { cli, token } = await harness();
  const d = await cli("doctor");
  assert.equal(d.code, 0, d.text);
  assert.match(d.text, /Credentials: env:CURSOR_API_KEY/);
  assert.match(d.text, /Bot chai \(拆解师\): readable, idle/);
  assert.ok(!d.text.includes(FAKE_KEY) && !d.text.includes(token));

  fake.intercept = async () => ({ status: 401 });
  const bad = await cli("bot", "add-id", "555", "--key", "ghost", "--name", "Ghost");
  assert.equal(bad.code, 1);
  assert.match(bad.text, /rejected the credentials \(401\)/);
  assert.doesNotMatch((await cli("bot", "list")).text, /ghost/);
});

test("CLI: preview shows the true latest bot message (not the first page)", async () => {
  const { cli } = await harness();
  for (let i = 0; i < 250; i++) fake.add("777", { kind: "send-message", text: `msg ${i}` });
  const r = await cli("bot", "add-id", "777", "--key", "big", "--name", "Big", "--preview");
  assert.equal(r.code, 0, r.text);
  assert.match(r.text, /250 entries in 3 page/);
  assert.match(r.text, /msg 249$/m);
});

test("CLI: token export file is 0600 and removed on revoke", async () => {
  const { cli, env } = await harness();
  const dir = join(env.HOMEBOT_HOME, "shortcuts");
  const files = await readdir(dir);
  assert.equal(files.length, 1);
  assert.equal((await stat(join(dir, must(files[0])))).mode & 0o777, 0o600);
  const id = must(files[0]).replace(/\.token$/, "");
  assert.equal((await cli("token", "revoke", id)).code, 0);
  assert.match((await cli("token", "list")).text, /\tretired\t/);
  assert.deepEqual(await readdir(dir), []);
  assert.equal((await cli("token", "revoke", "nope")).code, 1);
});

// The CLI commands run in this process through run(), with their own TokenStore instance on the
// same tokens.json: this proves the separate-store path, not a separate OS process.
test("B1: running gateway honours issue/revoke from separate CLI store instances and survives a restart", async () => {
  const { cli, token, env } = await harness({ settings: { answerBudgetMs: 2000, pollMs: 10 } });
  let url = await startServer(cli);
  fake.autoReply(SID, { text: "好。" });
  const ask = (t: string) => post(url, { text: "hi" }, { "X-Homebot-Token": t });
  assert.equal((await ask(token)).status, 200); // v1 active
  assert.deepEqual(await readdir(join(env.HOMEBOT_HOME, "shortcuts")), [], "export deleted on first use");
  const v1 = group(/^(\w+)\tchai\tactive/m, (await cli("token", "list")).text);

  // Replacement issued by a separate CLI store instance while the gateway runs.
  const issued = await cli("token", "issue", "chai", "--replaces", v1);
  const v2token = (await readFile(group(/written to (\S+) /, issued.text), "utf8")).trim();
  assert.equal((await ask(token)).status, 200, "v1 still works while v2 is pending");
  assert.equal((await ask(v2token)).status, 200, "gateway knows the token issued after it started");
  assert.equal((await ask(token)).status, 401, "v1 retired by v2's first use");

  // Revoke via CLI reaches the running gateway.
  const v2 = group(/^(\w+)\tchai\tactive/m, (await cli("token", "list")).text);
  assert.equal((await cli("token", "revoke", v2)).code, 0);
  assert.equal((await ask(v2token)).status, 401);

  // Restart: state persists.
  must(server).closeAllConnections();
  await new Promise<void>((r) => must(server).close(() => r()));
  url = await startServer(cli);
  assert.equal((await ask(v2token)).status, 401);
  assert.equal((await ask(token)).status, 401);
});

test("Q-ADD CLI: bot add-name needs --confirm with the exact name; a just-created bot is not added", async () => {
  const { cli } = await harness();
  fake.addNamed("homebot", "4242");
  fake.add("4242", { kind: "send-message", text: "hi" });
  const before = fake.requests.length;
  const noConfirm = await cli("bot", "add-name", "homebot", "--key", "homebot");
  assert.equal(noConfirm.code, 1);
  assert.match(noConfirm.text, /creates a new empty bot if no bot is named exactly "homebot"/);
  assert.equal((await cli("bot", "add-name", "homebot", "--key", "homebot", "--confirm", "Homebot")).code, 1, "case matters");
  assert.equal(fake.requests.length, before, "nothing sent before confirmation");

  const typo = await cli("bot", "add-name", "hombot", "--key", "x", "--confirm", "hombot");
  assert.equal(typo.code, 1);
  assert.match(typo.text, /just created an empty one .* It was not added/);
  assert.doesNotMatch((await cli("bot", "list")).text, /hombot/);

  const ok = await cli("bot", "add-name", "homebot", "--key", "homebot", "--confirm", "homebot");
  assert.equal(ok.code, 0, ok.text);
  assert.match(ok.text, /Added homebot -> "homebot" \(session 4242\)/);
  assert.match((await cli("bot", "list")).text, /^homebot\thomebot\t4242\tstrict=true\tsynced=yes$/m);
  assert.equal(fake.posts.length, 0, "adding never messages a bot");
});

test("bot remove retires its tokens; token issue --curl-header writes a header file for curl -H @file", async () => {
  const { cli, token, env } = await harness({ settings: { answerBudgetMs: 2000, pollMs: 10 } });
  const issued = await cli("token", "issue", "chai", "--siri-lang", "zh-CN", "--label", "M3 curl test", "--curl-header");
  const file = group(/written to (\S+) /, issued.text);
  assert.match(file, /\.header$/);
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  const line = (await readFile(file, "utf8")).trim();
  assert.match(line, /^X-Homebot-Token: \S+$/);
  assert.ok(!issued.text.includes(must(line.split(": ")[1])), "the token is never printed");

  // What the M3 kit's curl does: header from the file, test marker in the body.
  const url = await startServer(cli);
  fake.autoReply(SID, { text: "现在三点。" });
  const res = await post(url, { text: "几点了", test: true }, { "X-Homebot-Token": must(line.split(": ")[1]) });
  assert.equal(await res.text(), "现在三点。");
  assert.match(must(fake.posts.at(-1)).text, /^\[Homebot test · hb:[0-9a-f]{12} · zh-CN\]/, "marked as a test, not a voice request");
  assert.ok(!(await readdir(join(env.HOMEBOT_HOME, "shortcuts"))).some((n) => n.endsWith(".header")), "header file deleted on first use");

  const removed = await cli("bot", "remove", "chai");
  assert.equal(removed.code, 0);
  assert.match(removed.text, /Removed chai; 2 Shortcut token\(s\) retired\./);
  assert.equal((await post(url, { text: "x" }, { "X-Homebot-Token": token })).status, 401);
  assert.equal((await cli("bot", "remove", "chai")).code, 1);
  assert.equal((await cli("bot", "list")).text, "");
});

test("a folder the Homebot app imported (MOVED) is refused by every command, start included", async () => {
  const { env, dir } = await harness();
  const { writeFile } = await import("node:fs/promises");
  await writeFile(join(env.HOMEBOT_HOME, "MOVED"), JSON.stringify({ movedTo: "/elsewhere", at: "2026-10-23T00:00:00Z" }));
  for (const cmd of [["start"], ["doctor"], ["bot", "list"], ["token", "issue", "chai"]]) {
    const lines: string[] = [];
    const code = await run(cmd, { env, userHome: dir, out: (s) => lines.push(s), err: (s) => lines.push(s), onListening: (s) => (server = s) });
    assert.equal(code, 1, cmd.join(" "));
    assert.match(lines.join("\n"), /was moved to the Homebot app/);
  }
  assert.equal(server, undefined, "no gateway was started");
});
