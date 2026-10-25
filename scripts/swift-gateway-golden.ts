// Writes the gateway parity fixtures for the Swift port (mac/): a TypeScript Homebot folder made
// by the TypeScript CLI against the fake Grok Bot API, and the TypeScript gateway's answers to
// Shortcut-shaped requests on the same fake transcripts. The Swift test imports the folder, loads
// the same transcripts into its fake, replays the requests and compares status, content type and
// body. Every token and key in the output is a test value for the fake API only.
// Usage: node scripts/swift-gateway-golden.ts mac/Tests/HomebotGatewayTests/Fixtures
import { mkdtemp, readFile, writeFile, mkdir, rm, copyFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Server } from "node:http";
import { startFakeBdk, FAKE_KEY } from "../test-helpers/fake-bdk.ts";
import { run } from "../src/cli.ts";
import { ConfigStore } from "../src/core/store.ts";

const out = process.argv[2];
if (!out) throw new Error("usage: node scripts/swift-gateway-golden.ts <fixtures dir>");

const CHAI = "14752726";
const KITCHEN = "555";
const fake = await startFakeBdk();
for (let i = 0; i < 3; i++) fake.add(CHAI, { kind: "send-message", text: `old ${i}` });
fake.add(KITCHEN, { kind: "message", role: "user", text: "old question" });
fake.add(KITCHEN, { kind: "send-message", text: "old answer" });

const dir = await mkdtemp(join(tmpdir(), "homebot-golden-"));
const home = join(dir, "hb");
const env = { HOMEBOT_HOME: home, CURSOR_API_KEY: FAKE_KEY, HOMEBOT_BDK_BASE_URL: fake.baseUrl, HOMEBOT_PORT: "0", HOMEBOT_BIND: "127.0.0.1", HOMEBOT_SETUP_PORT: "0", HOMEBOT_DETECT_CREDENTIALS: "0" };
let server: Server | undefined;
const cli = async (...argv: string[]) => {
  const lines: string[] = [];
  const code = await run(argv, { env, userHome: dir, out: (s) => lines.push(s), err: (s) => lines.push(s), onListening: (s) => (server = s), onSetupListening: (s) => s.close() });
  if (code !== 0) throw new Error(`${argv.join(" ")} failed: ${lines.join("\n")}`);
  return lines.join("\n");
};
const issue = async (...argv: string[]) => {
  const text = await cli("token", "issue", ...argv);
  const file = /written to (\S+) /.exec(text)?.[1];
  const id = /token (\w+) for/.exec(text)?.[1];
  if (!file || !id) throw new Error(text);
  return { id, token: (await readFile(file, "utf8")).trim() };
};

await cli("bot", "add-id", CHAI, "--key", "chai", "--name", "拆解师");
await cli("bot", "add-id", KITCHEN, "--key", "kitchen", "--name", "厨房", "--no-strict");
const c = await new ConfigStore(join(home, "config.json")).load();
c.data.settings = { ...c.data.settings, answerBudgetMs: 2000, pollMs: 10, rateLimitPerMin: 100, siriLang: "zh-CN" };
await c.save();
const tokens = {
  zh: await issue("chai", "--siri-lang", "zh-CN", "--label", "问拆解师"),
  en: await issue("chai", "--siri-lang", "en-US", "--label", "Ask Chai"),
  kitchen: await issue("kitchen", "--siri-lang", "zh-CN", "--label", "问厨房"),
  revoked: await issue("chai", "--label", "Old one"),
  pending: await issue("kitchen", "--label", "Never used"),
};
await cli("token", "revoke", tokens.revoked.id);

// Activate three tokens with one question each (a pending token would expire before the Swift
// test runs), then snapshot the folder and the fake's transcripts.
await cli("start");
const port = () => {
  const a = server?.address();
  if (!a || typeof a !== "object") throw new Error("not listening");
  return a.port;
};
const ask = (token: string, body: unknown) =>
  fetch(`http://127.0.0.1:${port()}/v1/ask`, { method: "POST", headers: { "X-Homebot-Token": token, "Content-Type": "application/json" }, body: JSON.stringify(body) });
fake.autoReply(CHAI, { text: "好。" });
fake.autoReply(KITCHEN, { text: "好。" });
for (const t of [tokens.zh, tokens.en]) await (await ask(t.token, { bot: "chai", text: "你好", v: "1" })).text();
await (await ask(tokens.kitchen.token, { bot: "kitchen", text: "你好", v: "1" })).text();
const stopServer = async () => {
  server?.closeAllConnections();
  await new Promise<void>((r) => (server ? server.close(() => r()) : r()));
  server = undefined;
};
await stopServer();
await new Promise((r) => setTimeout(r, 100)); // the turns settle

// A pre-M4 token (made without a session): the importer retires it unless the user keeps it.
const tj = JSON.parse(await readFile(join(home, "tokens.json"), "utf8"));
const pre = tj.tokens.find((t: { id: string }) => t.id === tokens.pending.id);
delete pre.sessionId;
await writeFile(join(home, "tokens.json"), JSON.stringify(tj, null, 2) + "\n");
// The key as the TypeScript setup page stored it.
await writeFile(join(home, "secrets.json"), JSON.stringify({ bdkApiKey: FAKE_KEY }) + "\n", { mode: 0o600 });

const fixture = join(out, "ts-home");
await rm(fixture, { recursive: true, force: true });
await mkdir(fixture, { recursive: true });
for (const f of ["config.json", "state.json", "tokens.json", "secrets.json"]) await copyFile(join(home, f), join(fixture, f));
const transcripts = Object.fromEntries([CHAI, KITCHEN].map((sid) => [sid, fake.session(sid).entries]));

// Scenarios: Shortcut-shaped requests and the fake's behaviour for each. "$run" is the run id
// of the previous answer.
type Req = { token: keyof typeof tokens | "bad"; method?: string; path?: string; body?: unknown; raw?: string };
type Scenario = { name: string; bot?: { sid: string; text?: string; echo?: boolean; more?: string[]; busy?: boolean }; req: Req };
const long = "这是一个很长的回答。".repeat(80);
const scenarios: Scenario[] = [
  { name: "v1 answer, markdown removed", bot: { sid: CHAI, text: "现在**三点**。" }, req: { token: "zh", body: { bot: "chai", text: "几点了", v: "1" } } },
  { name: "v1 long answer is cut", bot: { sid: CHAI, text: long }, req: { token: "zh", body: { bot: "chai", text: "讲个故事", v: "1" } } },
  { name: "v1 English token", bot: { sid: CHAI, text: "It is **three**." }, req: { token: "en", body: { bot: "chai", text: "what time is it", v: "1" } } },
  { name: "strict bot, untagged reply refused", bot: { sid: CHAI, text: "我没有标签", echo: false }, req: { token: "zh", body: { bot: "chai", text: "几点了", v: "1" } } },
  { name: "non-strict bot, untagged reply spoken", bot: { sid: KITCHEN, text: "冰箱里有牛奶。", echo: false }, req: { token: "kitchen", body: { bot: "kitchen", text: "冰箱里有什么", v: "1" } } },
  { name: "multi-part turn speaks the first delivery", bot: { sid: CHAI, text: "第一部分。", more: ["第二部分。"] }, req: { token: "zh", body: { bot: "chai", text: "分两段说", v: "1" } } },
  { name: "busy bot", bot: { sid: CHAI, busy: true }, req: { token: "zh", body: { bot: "chai", text: "几点了", v: "1" } } },
  { name: "empty question", req: { token: "zh", body: { bot: "chai", text: "  ", v: "1" } } },
  { name: "too long question", req: { token: "zh", body: { bot: "chai", text: "长".repeat(1200), v: "1" } } },
  { name: "bad token", req: { token: "bad", body: { bot: "chai", text: "几点了", v: "1" } } },
  { name: "revoked token", req: { token: "revoked", body: { bot: "chai", text: "几点了", v: "1" } } },
  { name: "another bot's token", req: { token: "kitchen", body: { bot: "chai", text: "几点了", v: "1" } } },
  { name: "unknown bot", req: { token: "zh", body: { bot: "nobody", text: "几点了", v: "1" } } },
  { name: "body is not JSON", req: { token: "zh", raw: "{" } },
  { name: "body is not an object", req: { token: "zh", raw: "[1]" } },
  { name: "health", req: { token: "zh", method: "GET", path: "/v1/health" } },
  { name: "GET /v1/ask", req: { token: "zh", method: "GET", path: "/v1/ask" } },
  { name: "unknown path", req: { token: "zh", method: "POST", path: "/v1/nope", body: {} } },
  { name: "v2 first step", bot: { sid: CHAI, text: "我在听。" }, req: { token: "zh", body: { bot: "chai", text: "我们聊聊", v: "2", step: "0", run: "", last: "5" } } },
  { name: "v2 next step", bot: { sid: CHAI, text: "好的，**继续**。" }, req: { token: "zh", body: { bot: "chai", text: "再说一点", v: "2", step: "1", run: "$run", last: "5" } } },
  { name: "v2 end word", req: { token: "zh", body: { bot: "chai", text: "谢谢", v: "2", step: "2", run: "$run", last: "5" } } },
  { name: "v2 empty first step", req: { token: "zh", body: { bot: "chai", text: "", v: "2", step: "0", run: "", last: "5" } } },
  { name: "v2 unknown run", req: { token: "zh", body: { bot: "chai", text: "还在吗", v: "2", step: "3", run: "zzzzzz", last: "5" } } },
  { name: "v2 bad token", req: { token: "bad", body: { bot: "chai", text: "你好", v: "2", step: "0", run: "", last: "5" } } },
];

await cli("start");
const results: unknown[] = [];
let lastRun = "";
for (const s of scenarios) {
  if (s.bot) {
    if (s.bot.busy) fake.setIdle(s.bot.sid, false);
    else fake.autoReply(s.bot.sid, { text: s.bot.text ?? "", echo: s.bot.echo ?? true, more: s.bot.more ?? [] });
  }
  const r = s.req;
  const token = r.token === "bad" ? "not-a-token" : tokens[r.token].token;
  const raw = r.raw ?? (r.body === undefined ? undefined : JSON.stringify(r.body).replaceAll('"$run"', JSON.stringify(lastRun)));
  const res = await fetch(`http://127.0.0.1:${port()}${r.path ?? "/v1/ask"}`, {
    method: r.method ?? "POST",
    headers: { "X-Homebot-Token": token, ...(raw === undefined ? {} : { "Content-Type": "application/json" }) },
    ...(raw === undefined ? {} : { body: raw }),
  });
  let body = await res.text();
  const runId = /"run":"([^"]*)"/.exec(body)?.[1];
  if (runId) {
    lastRun = runId;
    body = body.replace(`"run":"${runId}"`, '"run":"$run"');
  }
  results.push({ ...s, status: res.status, contentType: res.headers.get("content-type"), answer: body });
  if (s.bot?.busy) fake.setIdle(s.bot.sid, true);
  await new Promise((r) => setTimeout(r, 80)); // the turn settles before the next scenario
}
await stopServer();
await fake.close();

const tokenOut = Object.fromEntries(Object.entries(tokens).map(([k, v]) => [k, v]));
await writeFile(
  join(out, "gateway-golden.json"),
  JSON.stringify({ note: "Test values for the fake Grok Bot API only.", key: FAKE_KEY, tokens: tokenOut, transcripts, scenarios: results }, null, 2) + "\n",
);
await rm(dir, { recursive: true, force: true });
console.log(`wrote ${fixture} and ${join(out, "gateway-golden.json")} (${results.length} scenarios)`);
