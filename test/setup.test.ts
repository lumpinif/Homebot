import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { mkdtemp, readFile, readdir, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { startFakeBdk, FAKE_KEY, type FakeBdk } from "../test-helpers/fake-bdk.ts";
import { must, group, portOf } from "../test-helpers/must.ts";
import { run } from "../src/cli.ts";
import { Downloads, LINK_TTL_MS } from "../src/server/downloads.ts";
import type { SetupServer } from "../src/server/setup.ts";
import type { ApiErrorBody, DownloadLink, SetupState, ShortcutBuild, ShortcutPreview } from "../src/server/setup-api.ts";
import { STRINGS } from "../web/src/i18n/index.ts";
import { LANGUAGES } from "../src/core/lang.ts";
import { messages } from "../src/core/i18n.ts";

const SID = "14752726";
let fake: FakeBdk; // set by harness(); afterEach closes it
let voice: http.Server | undefined;
let setup: SetupServer | undefined;
afterEach(async () => {
  voice?.closeAllConnections();
  await new Promise<void>((r) => (voice ? voice.close(() => r()) : r())); // also closes the setup listener
  voice = undefined;
  setup = undefined;
  await fake?.close();
});

interface Res {
  status: number | undefined;
  headers: http.IncomingHttpHeaders;
  text: string;
  // Views of the body as the documented API shapes (src/server/setup-api.ts). They are parsed
  // without validation: a body of another shape makes the assertions that read it fail.
  state(): SetupState;
  preview(): ShortcutPreview;
  build(): ShortcutBuild;
  link(): DownloadLink;
  error(): ApiErrorBody["error"];
}

/** Start Homebot (voice + setup) against a fake BDK. Every response body is recorded. */
async function harness({ key = FAKE_KEY, env: extraEnv = {}, args = [] }: { key?: string; env?: NodeJS.ProcessEnv; args?: string[] } = {}) {
  fake = await startFakeBdk();
  fake.add(SID, { kind: "send-message", text: "old" });
  const dir = await mkdtemp(join(tmpdir(), "homebot-test-"));
  const env = {
    HOMEBOT_HOME: join(dir, "hb"),
    CURSOR_API_KEY: key,
    HOMEBOT_BDK_BASE_URL: fake.baseUrl,
    HOMEBOT_PORT: "0",
    HOMEBOT_BIND: "127.0.0.1",
    HOMEBOT_SETUP_PORT: "0",
    HOMEBOT_DETECT_CREDENTIALS: "0",
    ...extraEnv,
  };
  const revealed: string[] = [];
  const lines: string[] = [];
  const code = await run(["start", ...args], {
    env,
    userHome: dir,
    out: (s) => lines.push(s),
    err: (s) => lines.push(s),
    onListening: (s) => (voice = s),
    onSetupListening: (s) => (setup = s),
    hostName: async () => "felix-mac",
    reveal: async (f) => revealed.push(f),
  });
  assert.equal(code, 0, lines.join("\n"));
  const port = portOf(setup);
  const voiceUrl = `http://127.0.0.1:${portOf(voice)}`;
  const bodies: string[] = [];
  /** Raw request so Host/Origin can be set freely. */
  const raw = (method: string, path: string, { headers = {}, body }: { headers?: Record<string, string>; body?: string } = {}) =>
    new Promise<Res>((resolve, reject) => {
      const req = http.request({ host: "127.0.0.1", port, method, path, headers: { host: `127.0.0.1:${port}`, ...headers } }, (res) => {
        let data = "";
        res.setEncoding("utf8");
        res.on("data", (c) => (data += c));
        res.on("end", () => {
          bodies.push(data);
          const parse = () => JSON.parse(data);
          resolve({ status: res.statusCode, headers: res.headers, text: data, state: parse, preview: parse, build: parse, link: parse, error: () => parse().error });
        });
      });
      req.on("error", reject);
      req.end(body);
    });
  const secret = must(setup).setupSecret;
  const okHeaders = { "x-homebot-setup": secret, origin: `http://127.0.0.1:${port}`, "content-type": "application/json" };
  const get = (path: string) => raw("GET", path, { headers: { "x-homebot-setup": secret } });
  const post = (path: string, body: unknown = {}) => raw("POST", path, { headers: okHeaders, body: JSON.stringify(body) });
  return { env, dir, port, raw, get, post, secret, okHeaders, bodies, revealed, voiceUrl, lines };
}

const ask = (voiceUrl: string, token: string, text = "hi") =>
  fetch(`${voiceUrl}/v1/ask`, { method: "POST", headers: { "X-Homebot-Token": token, "content-type": "application/json" }, body: JSON.stringify({ text, v: "1" }) });

/** The token inside a built Shortcut file (test-side only; the API never returns it). */
async function tokenOf(env: { HOMEBOT_HOME: string }, tokenId: string) {
  const dir = join(env.HOMEBOT_HOME, "shortcuts", tokenId);
  const xml = await readFile(join(dir, must((await readdir(dir))[0])), "utf8");
  return group(/<string>X-Homebot-Token<\/string>[\s\S]*?<key>string<\/key>\s*<string>([^<]+)<\/string>/, xml);
}

test("setup: loopback only; the page carries the per-launch secret; strict headers", async () => {
  const h = await harness();
  const addr = must(setup).address();
  assert.ok(addr && typeof addr === "object");
  assert.equal(addr.address, "127.0.0.1");
  assert.match(h.lines.join("\n"), new RegExp(`Setup page: http://127\\.0\\.0\\.1:${h.port}/`));
  const page = await h.raw("GET", "/");
  assert.equal(page.status, 200);
  assert.match(page.text, new RegExp(`<meta name="homebot-setup" content="${h.secret}" />`));
  assert.ok(!page.text.includes("__HOMEBOT_SETUP_SECRET__"));
  const csp = String(page.headers["content-security-policy"]);
  assert.match(csp, /default-src 'none'/);
  assert.match(csp, /script-src 'self'/);
  assert.match(csp, /frame-ancestors 'none'/);
  assert.equal(page.headers["x-content-type-options"], "nosniff");
  assert.equal(page.headers["cache-control"], "no-store");
  assert.equal(page.headers["referrer-policy"], "no-referrer");
  // A fresh style nonce per page load, in both the CSP and the page.
  const nonce = group(/'nonce-([A-Za-z0-9+/=]+)'/, csp);
  assert.ok(page.text.includes(`<meta name="homebot-style-nonce" content="${nonce}" />`));
  const again = await h.raw("GET", "/");
  assert.notEqual(group(/'nonce-([A-Za-z0-9+/=]+)'/, String(again.headers["content-security-policy"])), nonce);
  assert.doesNotMatch(csp, /unsafe-inline/);
  for (const p of ["/assets/app.js", "/assets/app.css"]) {
    const r = await h.raw("GET", p);
    assert.equal(r.status, 200, p);
    assert.doesNotMatch(String(r.headers["content-security-policy"]), /nonce/, p);
  }
  assert.equal((await h.raw("GET", "/assets/../index.html")).status, 404);
  assert.equal((await h.raw("GET", "/../package.json")).status, 404);
  assert.equal((await h.raw("GET", "/src/cli.ts")).status, 404);
});

test("setup: Host must be this loopback listener (DNS rebinding)", async () => {
  const h = await harness();
  assert.equal((await h.raw("GET", "/", { headers: { host: `evil.example:${h.port}` } })).status, 421);
  assert.equal((await h.raw("GET", "/api/state", { headers: { host: `evil.example:${h.port}`, "x-homebot-setup": h.secret } })).status, 421);
  assert.equal((await h.raw("GET", "/", { headers: { host: `127.0.0.1:${h.port + 1}` } })).status, 421);
  assert.equal((await h.raw("GET", "/", { headers: { host: `localhost:${h.port}` } })).status, 200);
});

test("setup: API needs the secret header; changes need POST + JSON + same Origin", async () => {
  const h = await harness();
  const body = JSON.stringify({ siriLang: "zh-CN" });
  assert.equal((await h.raw("GET", "/api/state")).status, 403, "no secret");
  assert.equal((await h.raw("GET", "/api/state", { headers: { "x-homebot-setup": "x".repeat(32) } })).status, 403, "wrong secret");
  const { origin: _o, ...noOrigin } = h.okHeaders;
  assert.equal((await h.raw("POST", "/api/settings", { headers: noOrigin, body })).status, 403, "no Origin");
  assert.equal((await h.raw("POST", "/api/settings", { headers: { ...h.okHeaders, origin: "http://evil.example" }, body })).status, 403, "foreign Origin");
  assert.equal((await h.raw("POST", "/api/settings", { headers: { ...h.okHeaders, origin: `http://localhost:${h.port}` }, body })).status, 403, "Origin must match Host");
  assert.equal((await h.raw("POST", "/api/settings", { headers: { ...h.okHeaders, "content-type": "text/plain" }, body })).status, 415, "form-style body");
  assert.equal((await h.raw("POST", "/api/settings", { headers: h.okHeaders, body: "x".repeat(17 * 1024) })).status, 413);
  assert.equal((await h.get("/api/state")).state().settings.siriLang, "en-US", "nothing changed by refused calls");
  assert.equal((await h.post("/api/settings", { siriLang: "zh-CN" })).status, 200);
  assert.equal((await h.get("/api/state")).state().settings.siriLang, "zh-CN");
  assert.equal((await h.post("/api/settings", { siriLang: "fr-FR" })).status, 200, "every page language is a Siri language");
  assert.equal((await h.post("/api/settings", { siriLang: "nl-NL" })).status, 400);
  assert.equal((await h.post("/api/settings", { port: 1 })).status, 400, "only language settings");
});

test("setup: English is the default for a new user", async () => {
  const h = await harness();
  const s = (await h.get("/api/state")).state();
  assert.deepEqual(s.settings, { uiLang: "en", siriLang: "en-US", phoneLang: "en" });
  assert.equal(s.gatewayUrl, `http://felix-mac.local:${portOf(voice)}`);
  assert.deepEqual(s.options.uiLangs.map((l) => l.code), Object.keys(LANGUAGES), "one language list for the page");
  assert.deepEqual(s.options.phoneLangs, s.options.uiLangs, "and the same one for the iPhone");
  assert.deepEqual(s.options.siriLangs.map((l) => l.code), Object.values(LANGUAGES).flatMap((l) => l.siri), "Siri locales grouped under their language");
  assert.ok(s.options.siriLangs.some((l) => l.code === "zh-CN"));
  assert.equal(s.signing.consent, false, "nothing goes to Apple until the user agrees");
  assert.equal(must(s.credential).source, "env:CURSOR_API_KEY");
  assert.equal((await h.post("/api/bots", { sessionId: SID, name: "Chai" })).status, 200);
  const p = (await h.post("/api/shortcuts/preview", { bot: "chai" })).preview();
  assert.equal(p.name, "Grok Bot");
  assert.equal(p.prompt, "What would you like to ask Grok Bot?", "the question names the phrase, never the bot (S25)");
  assert.match(p.steps.join("\n"), /Allow Running When Locked/);
});

test("setup: Felix's mix (iPhone English, Siri Chinese) end to end through the page API", async () => {
  const h = await harness();
  assert.equal((await h.post("/api/bots", { sessionId: SID, name: "homebot" })).status, 200);
  const st = (await h.post("/api/settings", { siriLang: "zh-CN", phoneLang: "en" })).state();
  const bot = must(st.bots[0]);
  assert.deepEqual([bot.key, bot.name], ["homebot", "homebot"]);
  const pre = (await h.post("/api/shortcuts/preview", { bot: bot.key })).preview();
  assert.equal(pre.kind, "ask");
  assert.equal(pre.name, "Grok Bot", "the default in every language; a Chinese Siri ran it (DECISIONS item 33)");
  assert.equal(pre.prompt, "想问Grok Bot什么？", "the question names the phrase, never the bot (S25)");
  assert.deepEqual(pre.alternatives, ["我的 Grok Bot", "家庭助手", "我家助手"], "a bot called homebot is never suggested");
  assert.deepEqual(pre.problems, []);
  const mixed = (await h.post("/api/shortcuts/preview", { bot: bot.key, name: "homebot 你好" })).preview();
  assert.deepEqual([mixed.name, mixed.problems.map((w) => [w.code, w.blocking])], ["homebot 你好", [["wrong-script", false]]], "advice only (DECISIONS item 29)");
  assert.deepEqual(mixed.alternatives, ["Grok Bot", "我的 Grok Bot", "家庭助手", "我家助手"]);
  const refused = await h.post("/api/shortcuts", { bot: bot.key, url: h.voiceUrl, name: "a/b" });
  assert.equal(refused.status, 400, "a name iOS would change is refused");
  assert.equal((await h.get("/api/state")).state().tokens.length, 0, "refused before a token exists");
  const r = await h.post("/api/shortcuts", { bot: bot.key, url: h.voiceUrl });
  assert.equal(r.status, 200, r.text);
  const b = r.build();
  assert.equal(b.name, "Grok Bot");
  assert.equal(b.signed, false);
  assert.equal(b.fileName, "Grok Bot.unsigned.shortcut");
  assert.match(b.steps.join("\n"), /Allow Running When Locked/, "steps in the iPhone's language");
  assert.match(b.steps.join("\n"), /run "Grok Bot" once/);
  const t = must(b.state.tokens.find((x) => x.id === b.tokenId));
  assert.deepEqual([t.state, t.siriLang, t.hasFile], ["pending", "zh-CN", true]);
  const xml = await readFile(join(h.env.HOMEBOT_HOME, "shortcuts", b.tokenId, b.fileName), "utf8");
  assert.match(xml, /<key>WFSpeakTextLanguage<\/key>\s*<string>zh-CN<\/string>/);

  assert.equal((await h.post(`/api/shortcuts/${b.tokenId}/reveal`)).status, 200);
  assert.deepEqual(h.revealed, [join(h.env.HOMEBOT_HOME, "shortcuts", b.tokenId, b.fileName)]);

  // The token works on the voice listener, the reply is Chinese, and the page shows "received".
  const token = await tokenOf(h.env, b.tokenId);
  fake.autoReply(SID, { text: "现在三点。" });
  assert.equal(await (await ask(h.voiceUrl, token, "几点了")).text(), "现在三点。");
  const after = must((await h.get("/api/state")).state().tokens.find((x) => x.id === b.tokenId));
  assert.deepEqual([after.state, after.hasFile], ["active", false]);
  assert.equal((await h.post(`/api/shortcuts/${b.tokenId}/reveal`)).error().code, "gone");
});

test("setup: add a bot by session id (read-only cold sync); safe errors; remove revokes its Shortcuts", async () => {
  const h = await harness();
  fake.add("777", { kind: "send-message", text: "hello" });
  const before = fake.posts.length;
  const unconfirmed = await h.post("/api/bots", { sessionId: "777", name: "Kitchen Bot", strictEcho: false });
  assert.equal(unconfirmed.error().code, "confirm-non-strict", "M4 S6: non-strict needs an explicit confirmation");
  assert.equal(fake.requests.length, 0, "refused before any network call");
  const added = await h.post("/api/bots", { sessionId: "777", name: "Kitchen Bot", strictEcho: false, confirmNonStrict: true });
  assert.equal(added.status, 200, added.text);
  const kb = must(added.state().bots.find((b) => b.sessionId === "777"));
  assert.deepEqual([kb.key, kb.name, kb.strictEcho, kb.synced], ["kitchen-bot", "Kitchen Bot", false, true]);
  assert.equal((await h.post("/api/bots", { sessionId: "777", name: "Again" })).status, 409, "a session has one key");
  assert.equal((await h.post("/api/bots", { sessionId: "abc", name: "X" })).error().message, "The session id is a number.");
  assert.equal((await h.post("/api/bots", { sessionId: "1", name: "" })).status, 400);
  fake.intercept = async () => ({ status: 404 });
  const nf = (await h.post("/api/bots", { sessionId: "888", name: "Ghost" })).error();
  assert.equal(nf.code, "not-found");
  fake.intercept = async () => ({ status: 401 });
  assert.equal((await h.post("/api/bots", { sessionId: "889", name: "Ghost" })).error().code, "auth");
  fake.intercept = undefined;
  assert.ok(!(await h.get("/api/state")).state().bots.some((b) => b.name === "Ghost"), "failed adds leave no bot");
  assert.equal(fake.posts.length, before, "adding never messages a bot");
  assert.ok(fake.requests.every((r) => r.method === "GET"), "only read-only calls");

  const b = (await h.post("/api/shortcuts", { bot: "kitchen-bot", url: h.voiceUrl })).build();
  const token = await tokenOf(h.env, b.tokenId);
  const gone = (await h.post("/api/bots/kitchen-bot/remove")).state();
  assert.ok(!gone.bots.some((x) => x.key === "kitchen-bot"));
  assert.equal(must(gone.tokens.find((t) => t.id === b.tokenId)).state, "retired");
  assert.equal((await ask(h.voiceUrl, token)).status, 401, "its Shortcut stops working");
  assert.deepEqual(await readdir(join(h.env.HOMEBOT_HOME, "shortcuts")), []);
  const state = JSON.parse(await readFile(join(h.env.HOMEBOT_HOME, "state.json"), "utf8"));
  assert.equal(state.cursors["kitchen-bot"], undefined);
  assert.equal((await h.post("/api/bots/kitchen-bot/remove")).status, 404);
});

test("setup: a key saved on the page works without a restart and never appears in any response", async () => {
  const h = await harness({ key: "" });
  assert.equal((await h.get("/api/state")).state().credential, null);
  assert.equal((await h.post("/api/bots", { sessionId: SID, name: "Chai" })).error().code, "no-credentials");
  assert.equal((await h.post("/api/credential", { key: "short" })).status, 400);
  const saved = (await h.post("/api/credential", { key: FAKE_KEY })).state();
  assert.deepEqual(saved.credential, { source: "homebot:secrets", kind: "saved", access: "unchecked" });
  const secrets = join(h.env.HOMEBOT_HOME, "secrets.json");
  assert.equal((await stat(secrets)).mode & 0o777, 0o600);
  assert.equal(JSON.parse(await readFile(secrets, "utf8")).bdkApiKey, FAKE_KEY);

  const withBot = await h.post("/api/bots", { sessionId: SID, name: "Chai" });
  assert.equal(withBot.status, 200);
  assert.equal(must(withBot.state().credential).access, "ok", "access is claimed only after Grok Bot accepted the key");
  const b = (await h.post("/api/shortcuts", { bot: "chai", url: h.voiceUrl })).build();
  const token = await tokenOf(h.env, b.tokenId);
  fake.autoReply(SID, { text: "It's three." });
  assert.equal(await (await ask(h.voiceUrl, token)).text(), "It's three.", "voice uses the new key, no restart");
  await h.post(`/api/shortcuts/${b.tokenId}/link`);

  for (const body of h.bodies) {
    assert.ok(!body.includes(FAKE_KEY), "API key never returned");
    assert.ok(!body.includes(token), "Shortcut token never returned");
    assert.ok(!/"hash"/.test(body), "token hashes never returned");
  }
  const removed = (await h.post("/api/credential/remove")).state();
  assert.equal(removed.credential, null);
  assert.equal(await (await ask(h.voiceUrl, token)).text(), messages("en").authFailed());
});

test("setup: signing needs the user's consent on the page; refused builds issue nothing; consent is remembered", async () => {
  const h = await harness();
  await h.post("/api/bots", { sessionId: SID, name: "Chai" });
  const r = await h.post("/api/shortcuts", { bot: "chai", sign: true });
  assert.equal(r.status, 403);
  assert.equal(r.error().code, "signing-consent");
  assert.deepEqual((await h.get("/api/state")).state().tokens, []);
  assert.equal((await h.post("/api/settings", { appleSigning: "yes" })).status, 400, "only a real boolean counts");
  const on = (await h.post("/api/settings", { appleSigning: true })).state();
  assert.equal(on.signing.consent, true);
  assert.equal((await h.get("/api/state")).state().signing.consent, true, "remembered");
  const off = (await h.post("/api/settings", { appleSigning: false })).state();
  assert.equal(off.signing.consent, false, "and can be withdrawn");
  // Overlapping writes from the page (language menu and the switch) both land.
  await Promise.all([h.post("/api/settings", { uiLang: "fr" }), h.post("/api/settings", { appleSigning: true }), h.post("/api/settings", { phoneLang: "ja" })]);
  const both = (await h.get("/api/state")).state();
  assert.equal(both.signing.consent, true);
  assert.equal(both.settings.uiLang, "fr");
  assert.equal(both.settings.phoneLang, "ja");
});

test("setup: one-time QR link — served once on the LAN listener, then gone; never logged", async () => {
  const h = await harness();
  await h.post("/api/bots", { sessionId: SID, name: "Chai" });
  const b = (await h.post("/api/shortcuts", { bot: "chai", url: h.voiceUrl })).build();
  const l = (await h.post(`/api/shortcuts/${b.tokenId}/link`)).link();
  assert.match(l.url, new RegExp(`^${h.voiceUrl}/dl/[A-Za-z0-9_-]{22}$`));
  assert.ok(l.expiresAt - Date.now() <= LINK_TTL_MS && l.expiresAt > Date.now());
  assert.ok(Array.isArray(l.qr) && l.qr.every((row) => /^[01]+$/.test(row) && row.length === l.qr.length));
  const first = await fetch(l.url);
  assert.equal(first.status, 200);
  assert.equal(first.headers.get("cache-control"), "no-store");
  assert.match(String(first.headers.get("content-disposition")), /filename\*=UTF-8''Grok%20Bot\.shortcut/);
  const file = join(h.env.HOMEBOT_HOME, "shortcuts", b.tokenId, b.fileName);
  assert.equal(await first.text(), await readFile(file, "utf8"));
  assert.equal((await fetch(l.url)).status, 404, "single use");
  const id = must(l.url.split("/dl/")[1]);
  const log = await readFile(join(h.env.HOMEBOT_HOME, "logs", "homebot.jsonl"), "utf8");
  assert.ok(!log.includes(id), "the bearer link is never logged");

  // A revoked Shortcut's links die with it.
  const l2 = (await h.post(`/api/shortcuts/${b.tokenId}/link`)).link();
  await h.post(`/api/tokens/${b.tokenId}/revoke`);
  assert.equal((await fetch(l2.url)).status, 404);
  assert.equal((await h.post(`/api/shortcuts/${b.tokenId}/link`)).error().code, "gone");
  assert.equal((await h.post("/api/tokens/000000000000/revoke")).status, 404);
});

test("setup: replacing a Shortcut from the page keeps the old one until the new one is used", async () => {
  const h = await harness();
  await h.post("/api/bots", { sessionId: SID, name: "Chai" });
  fake.autoReply(SID, { text: "ok" });
  const v1 = (await h.post("/api/shortcuts", { bot: "chai", url: h.voiceUrl })).build();
  const t1 = await tokenOf(h.env, v1.tokenId);
  assert.equal((await ask(h.voiceUrl, t1)).status, 200);
  const v2 = (await h.post("/api/shortcuts", { bot: "chai", url: h.voiceUrl, replaces: v1.tokenId })).build();
  const t2 = await tokenOf(h.env, v2.tokenId);
  assert.equal((await ask(h.voiceUrl, t1)).status, 200, "old still works");
  assert.equal((await ask(h.voiceUrl, t2)).status, 200);
  assert.equal((await ask(h.voiceUrl, t1)).status, 401, "old retired by the new one's first use");
  // A replacement keeps the phrase Siri learned, and the preview says so (review S2).
  const custom = (await h.post("/api/shortcuts", { bot: "chai", url: h.voiceUrl, name: "Kitchen Helper", replaces: v2.tokenId })).build();
  assert.equal(custom.name, "Kitchen Helper");
  const preview = await h.post("/api/shortcuts/preview", { bot: "chai", url: h.voiceUrl, replaces: custom.tokenId });
  const built = (await h.post("/api/shortcuts", { bot: "chai", url: h.voiceUrl, replaces: custom.tokenId })).build();
  assert.equal(preview.preview().name, "Kitchen Helper");
  assert.equal(built.name, preview.preview().name, "preview and build pick the same phrase");
  const bad = await h.post("/api/shortcuts", { bot: "chai", replaces: "ffffffffffff" });
  assert.equal(bad.error().code, "build-failed");
});

test("Q-ADD: add by exact name needs the name typed twice; a just-created bot is detected and not added", async () => {
  const h = await harness();
  fake.addNamed("homebot", SID);
  const mismatch = await h.post("/api/bots/by-name", { name: "homebot", confirmName: "hombot" });
  assert.equal(mismatch.error().code, "confirm-name");
  assert.equal((await h.post("/api/bots/by-name", { name: "homebot" })).error().code, "confirm-name", "confirmation is required");
  assert.equal(fake.requests.length, 0, "nothing sent before the name is confirmed");

  // A typo confirmed twice: get-or-create made a new empty bot; Homebot says so and adds nothing.
  const typo = await h.post("/api/bots/by-name", { name: "hombot", confirmName: "hombot" });
  assert.equal(typo.status, 409);
  assert.equal(typo.error().code, "created-new");
  assert.match(typo.error().message, /just created a new, empty one/);
  assert.deepEqual(fake.created, ["hombot"]);
  assert.deepEqual((await h.get("/api/state")).state().bots, []);

  const ok = await h.post("/api/bots/by-name", { name: "homebot", confirmName: " homebot " });
  assert.equal(ok.status, 200, ok.text);
  const bot = must(ok.state().bots[0]);
  assert.deepEqual([bot.key, bot.name, bot.sessionId, bot.strictEcho, bot.synced], ["homebot", "homebot", SID, true, true]);
  assert.deepEqual(fake.created, ["hombot"], "an existing name creates nothing");
  assert.equal(fake.posts.length, 0, "adding never messages a bot");
  const again = await h.post("/api/bots/by-name", { name: "homebot", confirmName: "homebot" });
  assert.match(again.error().message, /already added as "homebot"/);
  assert.equal((await h.post("/api/bots/by-name", { name: "homebot", confirmName: "homebot", strictEcho: false })).error().code, "confirm-non-strict");

  // An empty bot that is old (not created by this call) is a real bot and can be added.
  fake.addNamed("Empty Old", "4242");
  assert.equal((await h.post("/api/bots/by-name", { name: "Empty Old", confirmName: "Empty Old" })).status, 200);
  fake.intercept = async () => ({ status: 401 });
  assert.equal((await h.post("/api/bots/by-name", { name: "x", confirmName: "x" })).error().code, "auth");
  assert.equal(must((await h.get("/api/state")).state().credential).access, "rejected");
});

test("B1: a token whose bot now points at another conversation is refused by the voice listener", async () => {
  const h = await harness();
  await h.post("/api/bots", { sessionId: SID, name: "homebot" });
  const b = (await h.post("/api/shortcuts", { bot: "homebot", url: h.voiceUrl })).build();
  const token = await tokenOf(h.env, b.tokenId);
  // Bypass every lock (as a hand edit would): same key, another conversation.
  const file = join(h.env.HOMEBOT_HOME, "config.json");
  const cfg = JSON.parse(await readFile(file, "utf8"));
  cfg.bots.homebot.sessionId = "555";
  await writeFile(file, JSON.stringify(cfg));
  fake.autoReply("555", { text: "wrong room" });
  const r = await ask(h.voiceUrl, token);
  assert.equal(r.status, 401);
  assert.equal(fake.posts.length, 0, "nothing sent to the other conversation");
});

test("S2: wait-test builds need --probe-wait, never replace, and never retire the voice Shortcut", async () => {
  const off = await harness();
  await off.post("/api/bots", { sessionId: SID, name: "homebot" });
  assert.equal((await off.get("/api/state")).state().probe.enabled, false);
  const refused = await off.post("/api/shortcuts", { bot: "homebot", probe: true, url: off.voiceUrl });
  assert.equal(refused.error().code, "probe-disabled");
  assert.match(refused.error().message, /homebot start --probe-wait/);
  assert.deepEqual((await off.get("/api/state")).state().tokens, [], "nothing issued");
  const first = must(voice);
  first.closeAllConnections();
  await new Promise<void>((r) => first.close(() => r()));
  voice = undefined;
  await fake.close();

  const h = await harness({ args: ["--probe-wait"] });
  await h.post("/api/bots", { sessionId: SID, name: "homebot" });
  assert.equal((await h.get("/api/state")).state().probe.enabled, true);
  fake.autoReply(SID, { text: "ok" });
  const v = (await h.post("/api/shortcuts", { bot: "homebot", url: h.voiceUrl })).build();
  const vt = await tokenOf(h.env, v.tokenId);
  assert.equal((await ask(h.voiceUrl, vt)).status, 200);
  const pre = (await h.post("/api/shortcuts/preview", { bot: "homebot", probe: true })).preview();
  assert.deepEqual([pre.kind, pre.prompt, pre.alternatives], ["probe", null, []]);
  const bad = await h.post("/api/shortcuts", { bot: "homebot", probe: true, replaces: v.tokenId, url: h.voiceUrl });
  assert.equal(bad.status, 400);
  const p = (await h.post("/api/shortcuts", { bot: "homebot", probe: true, url: h.voiceUrl })).build();
  const pt = await tokenOf(h.env, p.tokenId);
  assert.equal((await ask(h.voiceUrl, pt)).status, 401, "a wait-test token is not a voice token");
  const st = (await h.get("/api/state")).state();
  assert.equal(must(st.tokens.find((t) => t.id === p.tokenId)).kind, "probe");
  assert.equal((await ask(h.voiceUrl, vt)).status, 200, "the voice Shortcut still works");
});

test("S4/S5: credential source and access are shown truthfully; old-language Shortcuts are flagged", async () => {
  const env = await harness();
  const c = (await env.get("/api/state")).state().credential;
  assert.deepEqual(c, { source: "env:CURSOR_API_KEY", kind: "env", access: "unchecked" }, "never claims access before use");
  await env.post("/api/bots", { sessionId: SID, name: "homebot" });
  assert.equal(must((await env.get("/api/state")).state().credential).access, "ok");
  const b = (await env.post("/api/shortcuts", { bot: "homebot", url: env.voiceUrl })).build();
  assert.equal(must(b.state.tokens[0]).languageDiffers, false);
  const st = (await env.post("/api/settings", { siriLang: "zh-CN" })).state();
  const t = must(st.tokens.find((x) => x.id === b.tokenId));
  assert.deepEqual([t.siriLang, t.languageDiffers], ["en-US", true], "built for English Siri; settings now say Chinese");
  await env.post(`/api/tokens/${b.tokenId}/revoke`);
  assert.equal(must((await env.get("/api/state")).state().tokens[0]).languageDiffers, false, "retired ones are not flagged");
});

test("S5: detected login, then a saved key overrides it; rejected and unchecked are shown truthfully", async () => {
  const as = await mkdtemp(join(tmpdir(), "homebot-test-"));
  await writeFile(join(as, "credentials.json"), JSON.stringify({ apiKey: "detected-key-not-a-secret" }));
  const h = await harness({ key: "", env: { HOMEBOT_DETECT_CREDENTIALS: "1", AGENT_SERVE_CONFIG_DIR: as } });
  assert.deepEqual((await h.get("/api/state")).state().credential, { source: "detected:agent-serve", kind: "detected", access: "unchecked" });
  await h.post("/api/credential", { key: FAKE_KEY });
  assert.equal(must((await h.get("/api/state")).state().credential).kind, "saved", "a key saved here overrides the detected login");
  fake.intercept = async () => ({ status: 401 });
  await h.post("/api/bots", { sessionId: SID, name: "homebot" });
  assert.equal(must((await h.get("/api/state")).state().credential).access, "rejected");
  fake.intercept = undefined;
  await h.post("/api/credential", { key: FAKE_KEY });
  assert.equal(must((await h.get("/api/state")).state().credential).access, "unchecked", "a newly saved key starts unchecked");
});

test("downloads: single use, 10-minute expiry, malformed ids, per-token drop", () => {
  let t = 0;
  const d = new Downloads({ now: () => t });
  const a = d.create({ file: "/x", name: "A", tokenId: "aaaaaaaaaaaa" });
  assert.equal(a.expiresAt, LINK_TTL_MS);
  assert.equal(must(d.take(a.id)).file, "/x");
  assert.equal(d.take(a.id), null);
  const b = d.create({ file: "/y", name: "B", tokenId: "aaaaaaaaaaaa" });
  t = LINK_TTL_MS;
  assert.equal(d.take(b.id), null, "expired");
  t = 0;
  const c = d.create({ file: "/z", name: "C", tokenId: "bbbbbbbbbbbb" });
  d.dropToken("bbbbbbbbbbbb");
  assert.equal(d.take(c.id), null);
  assert.equal(d.take("../../etc/passwd"), null);
});

test("setup page: every language has every string; the page never renders HTML", async () => {
  const keys = (o: object, p = ""): string[] => Object.entries(o).flatMap(([k, v]) => (typeof v === "object" ? keys(v, `${p}${k}.`) : [`${p}${k}`])).sort();
  const en = keys(STRINGS.en);
  for (const [lang, s] of Object.entries(STRINGS)) assert.deepEqual(keys(s), en, lang);
  const root = join(dirname(new URL(import.meta.url).pathname), "..");
  // The page's own source (web/src, beUI components included) never renders a string as HTML.
  const web = join(root, "web/src");
  const sources = (await readdir(web, { recursive: true })).filter((f) => /\.(ts|tsx)$/.test(f));
  assert.ok(sources.length > 10, "the page sources are found");
  for (const f of sources) {
    const src = await readFile(join(web, f), "utf8");
    assert.doesNotMatch(src, /dangerouslySetInnerHTML|innerHTML|outerHTML|insertAdjacentHTML|document\.write|\beval\(|new Function/, f);
  }
  const html = await readFile(join(root, "src/setup-ui/index.html"), "utf8");
  assert.doesNotMatch(html, /<script(?![^>]*\bsrc=)/, "no inline scripts (CSP)");
  assert.doesNotMatch(html, /<style/, "no inline style elements (CSP)");
  assert.doesNotMatch(html, /\son[a-z]+=/i, "no inline event handlers");
  assert.doesNotMatch(html, /\sstyle=/i, "no inline styles");
  assert.match(html, /__HOMEBOT_SETUP_SECRET__/);
  assert.match(html, /__HOMEBOT_STYLE_NONCE__/);
  // Every file the page loads is one the gateway serves.
  for (const [, ref] of html.matchAll(/(?:src|href)="([^"]+)"/g)) assert.match(must(ref), /^\/(assets\/app\.(js|css)|favicon\.svg)$/);
  // Every error code the API sends and every phrase warning has page text.
  const server = await readFile(join(root, "src/server/setup.ts"), "utf8");
  const codes = new Set([...server.matchAll(/new ApiError\(\d+, "([a-z-]+)"/g)].map((m) => must(m[1])));
  for (const c of ["invalid", "not-found", "build-failed", "bad-request", "add-failed"]) codes.delete(c); // shown with the server's message
  for (const c of codes) assert.ok(Object.hasOwn(STRINGS.en.errors, c), `errors.${c}`);
  const profile = await readFile(join(root, "src/shortcut/profile.ts"), "utf8");
  // The page shows "<code>" for a blocking problem and "<code>-advice" for advice.
  const found = [...profile.matchAll(/code: "([a-z-]+)", blocking: (true|false)/g)].map(([, c, b]) => (b === "true" ? must(c) : `${c}-advice`));
  assert.ok(found.length >= 5, "every problem is found");
  for (const k of found) assert.ok(Object.hasOwn(STRINGS.en.problems, k), `problems.${k}`);
});
