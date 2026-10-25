import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, readdir, stat, copyFile, access, utimes } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname, basename } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { startFakeBdk, FAKE_KEY, type FakeBdk } from "../test-helpers/fake-bdk.ts";
import { run } from "../src/cli.ts";
import { ConfigStore } from "../src/core/store.ts";
import type { Server } from "node:http";
import type { RunIO } from "../src/cli.ts";
import type { Signer } from "../src/shortcut/sign.ts";
import { must, group, portOf } from "../test-helpers/must.ts";

const SID = "14752726";
const isMac = process.platform === "darwin";
let fake: FakeBdk; // set by harness(); afterEach closes it
let server: Server | undefined;
afterEach(async () => {
  server?.closeAllConnections();
  await new Promise<void>((r) => (server ? server.close(() => r()) : r()));
  server = undefined;
  await fake?.close();
});

async function harness(io: RunIO = {}) {
  fake = await startFakeBdk();
  fake.add(SID, { kind: "send-message", text: "old" });
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
  const cli = async (argv: string[], extra: { env?: NodeJS.ProcessEnv; io?: RunIO } = {}) => {
    const lines: string[] = [];
    const code = await run(argv, {
      env: { ...env, ...extra.env },
      userHome: dir,
      out: (s) => lines.push(s),
      err: (s) => lines.push(s),
      onListening: (s) => (server = s),
      hostName: async () => "felix-mac",
      probeUnitMs: 2,
      ...io,
      ...extra.io,
    });
    return { code, text: lines.join("\n") };
  };
  assert.equal((await cli(["bot", "add-id", SID, "--key", "chai", "--name", "homebot"])).code, 0);
  return { env, cli, dir };
}

const fileOf = (text: string) => group(/^File: (.+?) \(/m, text);
const tokenIn = (xml: string) => group(/<string>X-Homebot-Token<\/string>[\s\S]*?<key>WFValue<\/key>\s*<dict>\s*<key>Value<\/key>\s*<dict>\s*<key>string<\/key>\s*<string>([^<]+)<\/string>/, xml);

test("default build: English, Bonjour URL, private file named after the Shortcut", async () => {
  const { cli, env } = await harness();
  const r = await cli(["shortcut", "build", "chai"]);
  assert.equal(r.code, 0, r.text);
  assert.match(r.text, /Built "Grok Bot" for bot chai \(Siri en-US, gateway http:\/\/felix-mac\.local:8787\)/);
  assert.match(r.text, /UNSIGNED/);
  assert.match(r.text, /1\. Send the file to your iPhone/);
  const file = fileOf(r.text);
  assert.equal(basename(file), "Grok Bot.unsigned.shortcut");
  assert.equal(dirname(dirname(file)), join(env.HOMEBOT_HOME, "shortcuts"));
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  assert.equal((await stat(dirname(file))).mode & 0o777, 0o700);
  const xml = await readFile(file, "utf8");
  assert.match(xml, /<string>http:\/\/felix-mac\.local:8787\/v1\/ask<\/string>/);
  assert.match(xml, /<string>en-US<\/string>/);
  assert.match(xml, /What would you like to ask Grok Bot\?/);
  assert.match(xml, /<string>listen<\/string>/, "keeps listening after each answer by default (DECISIONS item 36)");
  assert.match((await cli(["token", "list"])).text, /\tchai\tpending\tGrok Bot\ten-US\t/);
  const once = await cli(["shortcut", "build", "chai", "--no-conversation", "--name", "My Grok Bot"]);
  assert.equal(once.code, 0, once.text);
  assert.doesNotMatch(await readFile(fileOf(once.text), "utf8"), /<string>listen<\/string>/, "--no-conversation: one question per run");
  assert.ok(!r.text.includes(tokenIn(xml)), "the token is never printed");
});

test("Felix's setup: iPhone English, Siri Chinese", async () => {
  const { cli } = await harness();
  const r = await cli(["shortcut", "build", "chai", "--siri-lang", "zh-CN", "--phone-lang", "en", "--url", "http://192.168.1.5:8787"]);
  assert.equal(r.code, 0, r.text);
  assert.match(r.text, /Built "Grok Bot"/, "the default in every language (DECISIONS item 33)");
  assert.match(r.text, /Allow Running When Locked/, "steps in the iPhone's language");
  assert.match(r.text, /allow it to connect to 192\.168\.1\.5:8787/);
  const xml = await readFile(fileOf(r.text), "utf8");
  assert.match(xml, /<key>WFSpeakTextLanguage<\/key>\s*<string>zh-CN<\/string>/);
  assert.match(xml, /想问 Grok Bot 什么？/);
});

test("language defaults come from settings (the user's setup answers)", async () => {
  const { cli, env } = await harness();
  const c = await new ConfigStore(join(env.HOMEBOT_HOME, "config.json")).load();
  c.data.settings = { siriLang: "zh-CN", phoneLang: "zh-Hans" };
  await c.save();
  const r = await cli(["shortcut", "build", "chai"]);
  assert.match(r.text, /Built "Grok Bot"/);
  assert.match(r.text, /锁定时允许运行/);
});

// Token-to-HTTP integration: the token is read from the generated XML and the request the
// Shortcut is built to send is made by hand. Real Shortcut execution is M3 acceptance.
test("built Shortcut's token + request shape are accepted over HTTP; the file is deleted on first use", async () => {
  const { cli, env } = await harness();
  const r = await cli(["shortcut", "build", "chai", "--siri-lang", "zh-CN"]);
  const file = fileOf(r.text);
  const token = tokenIn(await readFile(file, "utf8"));
  assert.equal((await cli(["start"])).code, 0);
  fake.autoReply(SID, { text: "现在三点。" });
  const res = await fetch(`http://127.0.0.1:${portOf(server)}/v1/ask`, {
    method: "POST",
    headers: { "X-Homebot-Token": token, "Content-Type": "application/json" },
    body: JSON.stringify({ bot: "chai", text: "几点了", v: "1" }), // exactly what the Shortcut sends
  });
  assert.equal(await res.text(), "现在三点。");
  assert.match(must(fake.posts[0]).text, / · zh-CN\]\n几点了\n/);
  assert.deepEqual(await readdir(join(env.HOMEBOT_HOME, "shortcuts")), []);
});

test("without --sign nothing goes to Apple and no signing consent is recorded", async () => {
  const signer: Signer = async () => {
    throw new Error("the signer must not run");
  };
  const { cli, env } = await harness({ signer });
  const r = await cli(["shortcut", "build", "chai"]);
  assert.equal(r.code, 0, r.text);
  const config = JSON.parse(await readFile(join(env.HOMEBOT_HOME, "config.json"), "utf8"));
  assert.notEqual(config.settings.appleSigning, true);
});

test("a refused --sign build records no signing consent", async () => {
  const signer: Signer = async () => {
    throw new Error("the signer must not run");
  };
  const { cli, env } = await harness({ signer });
  const r = await cli(["shortcut", "build", "chai", "--sign", "--siri-lang", "zz-ZZ"]);
  assert.equal(r.code, 1);
  const config = JSON.parse(await readFile(join(env.HOMEBOT_HOME, "config.json"), "utf8"));
  assert.notEqual(config.settings?.appleSigning, true);
  assert.equal((await cli(["token", "list"])).text, "");
});

test("--sign with a fake signer: signed file keeps the name, unsigned removed, reveal called", async () => {
  const revealed: string[] = [];
  const signer: Signer = async ({ input, output, onAttempt }) => {
    must(onAttempt)({ attempt: 1, mode: "people-who-know-me" });
    await copyFile(input, output);
  };
  const { cli, env } = await harness({ signer, reveal: async (f: string) => revealed.push(f) });
  const r = await cli(["shortcut", "build", "chai", "--sign", "--reveal"]);
  assert.equal(r.code, 0, r.text);
  const file = fileOf(r.text);
  assert.equal(basename(file), "Grok Bot.shortcut");
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  assert.deepEqual(await readdir(dirname(file)), ["Grok Bot.shortcut"]);
  assert.deepEqual(revealed, [file]);
  assert.match(r.text, /Signing \(attempt 1, mode people-who-know-me\)/);
  const config = JSON.parse(await readFile(join(env.HOMEBOT_HOME, "config.json"), "utf8"));
  assert.equal(config.settings.appleSigning, true, "--sign records the same consent as the page switch");
});

test("signing failure: error, token revoked, files removed", async () => {
  const signer = async () => {
    throw new Error("signing failed after 5 attempts (last exit: 1)");
  };
  const { cli, env } = await harness({ signer });
  const r = await cli(["shortcut", "build", "chai", "--sign"]);
  assert.equal(r.code, 1);
  assert.match(r.text, /signing failed/);
  assert.match((await cli(["token", "list"])).text, /\tretired\t/);
  assert.deepEqual(await readdir(join(env.HOMEBOT_HOME, "shortcuts")), []);
});

test("names iOS would change are refused before a token exists; script and leading words are advice (DECISIONS item 29)", async () => {
  const { cli, env } = await harness();
  for (const name of ["../../evil:/name", ".hidden", "back\\slash"]) {
    const r = await cli(["shortcut", "build", "chai", "--name", name]);
    assert.equal(r.code, 1, name);
    assert.match(r.text, /iOS would change/, name);
    assert.match(r.text, /Phrases you can use: "Grok Bot"/, "the refusal offers valid phrases");
  }
  assert.equal((await cli(["token", "list"])).text, "", "no token issued");
  await assert.rejects(access(join(env.HOMEBOT_HOME, "evil")));
  const zh = await cli(["shortcut", "build", "chai", "--siri-lang", "zh-CN", "--name", "homebot 你好"]);
  assert.equal(zh.code, 0, zh.text);
  assert.match(zh.text, /Note: Siri in this language may not hear "homebot 你好"/);
  const ask = await cli(["shortcut", "build", "chai", "--siri-lang", "zh-CN", "--name", "问拆解师"]);
  assert.equal(ask.code, 0, "a leading 问 is strong advice (DECISIONS items 12, 29)");
  assert.match(ask.text, /Note: On a Chinese HomePod, Siri took a phrase starting with "问" as a web search/);
  const advice = await cli(["shortcut", "build", "chai", "--name", "Ask Chai"]);
  assert.equal(advice.code, 0, "other leading command words are advice only (design review v8 S5)");
  assert.match(advice.text, /Note: A phrase starting with "ask" may be taken by Siri/);
});

test("a phrase already used by another Shortcut is refused; a replacement may keep its phrase", async () => {
  const { cli } = await harness();
  const first = await cli(["shortcut", "build", "chai"]);
  assert.match(first.text, /Built "Grok Bot"/);
  const id = group(/Token (\w+) is pending/, first.text);
  const second = await cli(["shortcut", "build", "chai"]);
  assert.match(second.text, /Built "My Grok Bot"/, "the next unused default");
  const dup = await cli(["shortcut", "build", "chai", "--name", "grok  bot"]);
  assert.equal(dup.code, 1);
  assert.match(dup.text, /already uses/);
  const repl = await cli(["shortcut", "build", "chai", "--name", "Grok Bot", "--replaces", id]);
  assert.equal(repl.code, 0, repl.text);
});

test("M2 S3: probe build instructions name the probe Shortcut, never the Ask Shortcut", async () => {
  const { cli } = await harness();
  const r = await cli(["shortcut", "build", "chai", "--probe", "--siri-lang", "zh-CN", "--phone-lang", "zh-Hans"]);
  assert.match(r.text, /Built "家庭等待测试"/);
  assert.match(r.text, /轻点“家庭等待测试”运行一次/);
  assert.match(r.text, /“嘿 Siri，家庭等待测试”/);
  assert.ok(!r.text.includes("家庭助手"), "would invoke the bot instead of measuring the wait");
  assert.ok(!r.text.includes("Note: the name was changed"));
});

test("M2 N1: invalid input fails before a token exists; a later failure revokes and cleans up", async () => {
  const signer: Signer = async () => {
    throw new Error("signing failed after 5 attempts (last exit: 1)");
  };
  const { cli, env } = await harness({ signer });
  const bad = await cli(["shortcut", "build", "chai", "--url", "file:///invalid"]);
  assert.equal(bad.code, 1);
  assert.match(bad.text, /gateway URL must be http/);
  assert.equal((await cli(["token", "list"])).text, "", "no token issued");

  // An old working Shortcut, then a rebuild that fails after its token was issued (signing).
  const ok = await cli(["shortcut", "build", "chai"]);
  const oldToken = tokenIn(await readFile(fileOf(ok.text), "utf8"));
  const oldId = group(/Token (\w+) is pending/, ok.text);
  const failed = await cli(["shortcut", "build", "chai", "--name", "Chai Voice", "--replaces", oldId, "--sign"]);
  assert.equal(failed.code, 1);
  assert.match(failed.text, /signing failed/);
  const list = (await cli(["token", "list"])).text.trim().split("\n");
  assert.equal(list.length, 2);
  assert.match(must(list[0]), new RegExp(`^${oldId}\\tchai\\tpending\\t`), "the old token is untouched");
  assert.match(must(list[1]), /\tretired\t/, "the failed build's token is not usable");
  assert.deepEqual(await readdir(join(env.HOMEBOT_HOME, "shortcuts")), [oldId], "only the old Shortcut's files remain");
  assert.equal((await cli(["start"])).code, 0);
  fake.autoReply(SID, { text: "ok" });
  const res = await fetch(`http://127.0.0.1:${portOf(server)}/v1/ask`, {
    method: "POST",
    headers: { "X-Homebot-Token": oldToken, "Content-Type": "application/json" },
    body: JSON.stringify({ bot: "chai", text: "hi", v: "1" }),
  });
  assert.equal(res.status, 200, "the old Shortcut still works");
});

test("M2 S4: --replaces with another bot's token is refused and issues nothing", async () => {
  const { cli } = await harness();
  fake.add("999", { kind: "send-message", text: "x" });
  assert.equal((await cli(["bot", "add-id", "999", "--key", "other", "--name", "Other"])).code, 0);
  const a = await cli(["shortcut", "build", "other"]);
  const otherId = group(/Token (\w+) is pending/, a.text);
  const r = await cli(["shortcut", "build", "chai", "--replaces", otherId]);
  assert.equal(r.code, 1);
  assert.match(r.text, /belongs to bot "other", not "chai"/);
  assert.equal((await cli(["token", "list"])).text.trim().split("\n").length, 1);
});

test("M2 S2: every CLI run removes artifacts older than 24 h", async () => {
  const { cli, env } = await harness();
  const r = await cli(["shortcut", "build", "chai"]);
  const dir = dirname(fileOf(r.text));
  await cli(["bot", "list"]);
  await access(dir); // fresh: kept
  const old = new Date(Date.now() - 25 * 3600 * 1000);
  await utimes(dir, old, old);
  await cli(["bot", "list"]); // any command, not only token commands
  assert.deepEqual(await readdir(join(env.HOMEBOT_HOME, "shortcuts")), []);
  assert.match((await cli(["token", "list"])).text, /\tpending\t/, "the token itself just stays pending until its own expiry");
});

test("M2 S2: a running gateway removes artifacts once they are 24 h old, without any request", async () => {
  const { cli, env } = await harness({ cleanupMs: 20 });
  const r = await cli(["shortcut", "build", "chai"]);
  const dir = dirname(fileOf(r.text));
  assert.equal((await cli(["start"])).code, 0);
  await new Promise((res) => setTimeout(res, 80));
  await access(dir); // still fresh
  const old = new Date(Date.now() - 25 * 3600 * 1000);
  await utimes(dir, old, old);
  const deadline = Date.now() + 2000;
  while ((await readdir(join(env.HOMEBOT_HOME, "shortcuts"))).length && Date.now() < deadline) await new Promise((res) => setTimeout(res, 20));
  assert.deepEqual(await readdir(join(env.HOMEBOT_HOME, "shortcuts")), []);
});

test("probe Shortcut + start --probe-wait: token works, no bot is contacted", async () => {
  const { cli } = await harness();
  const r = await cli(["shortcut", "build", "chai", "--probe"]);
  assert.match(r.text, /Built "Homebot Wait Test"/);
  assert.match(r.text, /run "Homebot Wait Test" once/);
  const token = tokenIn(await readFile(fileOf(r.text), "utf8"));
  assert.match((await cli(["start", "--probe-wait"])).text, /Wait-limit probe enabled/);
  const res = await fetch(`http://127.0.0.1:${portOf(server)}/v1/probe-wait`, { headers: { "X-Homebot-Token": token } });
  assert.equal(await res.text(), "Waited 5 seconds.");
  assert.equal(fake.posts.length, 0);
});

test("built file passes plutil -lint (macOS only)", { skip: !isMac && "macOS only" }, async () => {
  const { cli } = await harness();
  const r = await cli(["shortcut", "build", "chai", "--siri-lang", "zh-CN"]);
  const { stdout } = await promisify(execFile)("plutil", ["-lint", fileOf(r.text)]);
  assert.match(stdout, /OK$/m);
});

test("conversation: build a looping voice Shortcut from the CLI (DESIGN §18)", async () => {
  const { cli } = await harness();
  assert.equal((await cli(["shortcut", "build", "chai", "--conversation", "--lab"])).code, 1);
  const b = await cli(["shortcut", "build", "chai", "--conversation", "--siri-lang", "zh-CN", "--name", "我家助手"]);
  assert.equal(b.code, 0, b.text);
  assert.match(b.text, /Built "我家助手"/);
  const xml = await readFile(fileOf(b.text), "utf8");
  assert.match(xml, /\/v1\/ask<\/string>/);
  assert.match(xml, /is\.workflow\.actions\.repeat\.count/);
});

test("lab: build the lab Shortcut, choose an experiment, run it over HTTP, read the report", async () => {
  const { cli } = await harness({ labUnit: 0.001 });
  const b = await cli(["shortcut", "build", "chai", "--lab", "--siri-lang", "zh-CN"]);
  assert.equal(b.code, 0, b.text);
  assert.match(b.text, /Built "家庭实验"/);
  const xml = await readFile(fileOf(b.text), "utf8");
  assert.match(xml, /\/v1\/lab<\/string>/);
  const token = tokenIn(xml);
  assert.equal((await cli(["shortcut", "build", "chai", "--lab", "--probe"])).code, 1);
  const twice = await cli(["shortcut", "build", "chai", "--lab", "--siri-lang", "zh-CN"]);
  assert.equal(twice.code, 1, "a second lab Shortcut would share its phrase (review S1)");
  assert.match(twice.text, /already uses "家庭实验"/);
  assert.equal((await cli(["lab", "use", "E9"])).code, 1);
  assert.equal((await cli(["lab", "use", "E7", "--delays", "0"])).code, 1);
  assert.match((await cli(["lab", "use", "E2"])).text, /now runs E2/);
  const started = await cli(["start", "--lab"]);
  assert.equal(started.code, 0, started.text);
  assert.match(started.text, /Lab enabled at \/v1\/lab, experiment E2/);
  const post = async (body: unknown) =>
    (await (
      await fetch(`http://127.0.0.1:${portOf(server)}/v1/lab`, { method: "POST", headers: { "X-Homebot-Token": token, "Content-Type": "application/json" }, body: JSON.stringify(body) })
    ).json()) as { run: string; next: string };
  const s0 = await post({ v: "2", step: "0", run: "", last: "10", text: "" });
  await post({ v: "2", step: "1", run: s0.run, last: "10", text: "明天我想去公园散步" });
  // The log is appended off the response path; wait for the line instead of racing it.
  let report = "";
  for (let i = 0; i < 50 && !/\tcut\t/.test(report); i++) {
    report = (await cli(["lab", "report"])).text;
    await new Promise((r) => setTimeout(r, 10));
  }
  assert.match(report, /\tE2\t[0-9a-f]{6}\t1\tv1\t9\tcut\t/);
  assert.ok(!report.includes("公园"), "no speech text in the report");
});
