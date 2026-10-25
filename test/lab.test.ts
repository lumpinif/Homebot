// Runs and the device-experiment lab (DESIGN §18.2, §19.1), offline.
import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type http from "node:http";
import type { AddressInfo } from "node:net";
import { RunStore } from "../src/core/runs.ts";
import { LabService, matchSentence, readLabState, writeLabState, type LabResponse } from "../src/core/lab.ts";
import { createVoiceServer, type VoiceConfig } from "../src/server/voice.ts";
import type { TokenKind, TokenRecord, VerifyResult } from "../src/core/tokens.ts";
import { buildLabShortcut, LAB_STEPS, type Action } from "../src/shortcut/build.ts";
import { toXmlPlist } from "../src/shortcut/plist.ts";
import { must } from "../test-helpers/must.ts";

const run = promisify(execFile);
const isMac = process.platform === "darwin";

test("runs: ordered steps, repeats share one response, anything else is unknown", async () => {
  let t = 0;
  const runs = new RunStore<{ n: number }>({ ttlMs: 1000, now: () => t });
  let made = 0;
  const a = runs.start("tok", { n: 1 }, async (id) => (made++, `start:${id}`));
  assert.equal(await a.response, `start:${a.id}`);
  assert.equal(runs.check(a.id, "tok", 1).kind, "next");
  assert.equal(runs.check(a.id, "tok", 2).kind, "unknown", "a skipped step");
  assert.equal(runs.check(a.id, "other", 1).kind, "unknown", "another token's run");
  assert.equal(runs.check("nope", "tok", 1).kind, "unknown");
  const r1 = runs.take(a.id, 1, async () => (made++, "one"));
  const again = runs.check(a.id, "tok", 1);
  assert.equal(again.kind, "repeat");
  assert.equal(await (again.kind === "repeat" ? again.response : null), "one");
  assert.equal(await r1, "one");
  assert.equal(made, 2, "a repeated step never runs its work again");
  assert.equal(runs.check(a.id, "tok", 0).kind, "unknown", "an old step");
  const b = runs.start("tok", { n: 2 }, async () => "b");
  assert.notEqual(a.id, b.id, "overlapping runs of one Shortcut have their own state");
  t = 999;
  assert.equal(runs.check(a.id, "tok", 2).kind, "next", "each step renews the run");
  t = 2100;
  assert.equal(runs.check(a.id, "tok", 2).kind, "unknown", "expired");
  assert.equal(runs.size, 0);
});

test("runs: an ended run keeps its last response for retries and takes no later step (review S4)", async () => {
  const runs = new RunStore<null>();
  const a = runs.start("tok", null, async () => "start");
  assert.equal(runs.check(a.id, "tok", 1).kind, "early", "the start response is not ready yet");
  await a.response;
  let release = (): void => {};
  const slow = runs.take(a.id, 1, () => new Promise<string>((r) => (release = () => r("one"))));
  assert.equal(runs.check(a.id, "tok", 2).kind, "early", "step 1 is still being made");
  runs.finish(a.id);
  release();
  assert.equal(await slow, "one");
  const again = runs.check(a.id, "tok", 1);
  assert.equal(again.kind, "repeat");
  assert.equal(await (again.kind === "repeat" ? again.response : null), "one", "a retry of the final step gets the final response");
  assert.equal(runs.check(a.id, "tok", 2).kind, "ended");
});

test("lab: sentence matching tells full, cut, other and empty apart", () => {
  const e = { whole: "明天我想去公园散步，然后去超市买菜", head: "明天我想去公园散步", tail: "然后去超市买菜" };
  assert.equal(matchSentence("明天我想去公园散步，然后去超市买菜。", e), "full");
  assert.equal(matchSentence("明天我想去公园散步", e), "cut");
  assert.equal(matchSentence("今天天气怎么样", e), "other");
  assert.equal(matchSentence("明天我想去公园，然后去超市买菜", e), "partial", "a missing middle is never full");
  assert.equal(matchSentence("  ", e), "empty");
  assert.equal(matchSentence("随便", undefined), "n/a");
  const en = { whole: "tomorrow I want to walk in the park and then buy some groceries", head: "tomorrow I want to walk in the park", tail: "buy some groceries" };
  assert.equal(matchSentence("Tomorrow I want to walk in the park, and then buy some groceries.", en), "full");
  assert.equal(matchSentence("Tomorrow I want to walk in the park.", en), "cut");
  assert.equal(matchSentence("tom buy some groceries", en), "partial", "review S7: only the end arrived");
});

async function lab(scenario: Parameters<typeof writeLabState>[1]["scenario"], delays?: number[]) {
  const dir = await mkdtemp(join(tmpdir(), "homebot-lab-"));
  const file = join(dir, "lab.json");
  await writeLabState(file, { scenario, delays });
  const logs: Record<string, unknown>[] = [];
  const svc = new LabService({ file, log: (e) => logs.push(e), delayUnit: 0.001 });
  const step = (run: string, n: number, text = "", extra: { last?: number; signal?: AbortSignal } = {}) =>
    svc.handle({ run, step: n, last: extra.last ?? LAB_STEPS, text, tokenId: "tok", lang: "zh-CN", signal: extra.signal });
  return { svc, file, logs, step };
}

test("lab E2: matches each try, logs no text, ends after the last try", async () => {
  const { step, logs } = await lab("E2");
  const s0 = await step("", 0);
  assert.equal(s0.next, "listen");
  assert.match(s0.say, /实验二/);
  const said = ["明天我想去公园散步然后去超市买菜", "明天我想去公园散步", "明天我想去公园散步然后去超市买菜", "我的银行卡密码"];
  const out: LabResponse[] = [];
  for (const [i, text] of said.entries()) out.push(await step(s0.run, i + 1, text));
  assert.deepEqual(out.map((r) => r.next), ["listen", "listen", "listen", "end"]);
  assert.match(must(out[3]).say, /实验二结束/);
  const steps = logs.filter((e) => e.event === "lab" && typeof e.step === "number" && e.step > 0);
  assert.deepEqual(steps.map((e) => e.match), ["full", "cut", "full", "other"]);
  assert.deepEqual(steps.map((e) => e.recv_len), [16, 9, 16, 7]);
  const all = JSON.stringify(logs);
  for (const text of said) assert.ok(!all.includes(text), "what was said never reaches the log");
});

test("lab: the last step always ends the run, so its answer is spoken (review B2)", async () => {
  const { step } = await lab("E5");
  const s0 = await step("", 0, "", { last: 2 });
  const r1 = await step(s0.run, 1, "一", { last: 2 });
  assert.equal(r1.next, "listen");
  const r2 = await step(s0.run, 2, "二", { last: 2 });
  assert.equal(r2.next, "end");
  assert.match(r2.say, /第2轮/, "the answer to the last step is the one spoken");
});

test("lab: the cap is the one sent at the start; an ended run takes no later step (review S4)", async () => {
  const { step } = await lab("E5");
  const s0 = await step("", 0, "", { last: 1 });
  assert.equal((await step(s0.run, 1, "一", { last: 10 })).next, "end");
  const after = await step(s0.run, 2, "二", { last: 10 });
  assert.equal(after.next, "end");
  assert.match(after.say, /重新说/);
});

test("lab: a run id the gateway did not issue is never logged (review S6)", async () => {
  const { step, logs } = await lab("E1");
  const r = await step("SECRET_FROM_REQUEST", 1, "x");
  assert.equal(r.next, "end");
  assert.equal(r.run, "");
  assert.ok(!JSON.stringify(logs).includes("SECRET"));
  assert.equal(must(logs.at(-1)).run, "invalid");
});

test("lab E1 / E1b: silence first, and silence after an answer, are separate runs (review S5)", async () => {
  {
    const { step } = await lab("E1");
    const s0 = await step("", 0);
    const r1 = await step(s0.run, 1, "");
    assert.equal(r1.next, "end");
    assert.match(r1.say, /实验一结束/);
  }
  const { step, logs } = await lab("E1b");
  const s0 = await step("", 0);
  assert.match(s0.say, /请说“好”/);
  const r1 = await step(s0.run, 1, "好");
  assert.equal(r1.next, "listen");
  const r2 = await step(s0.run, 2, "");
  assert.equal(r2.next, "end");
  assert.match(r2.say, /实验一乙结束/);
  assert.deepEqual(logs.filter((e) => typeof e.match === "string").map((e) => e.match), ["full", "empty"]);
});

test("lab: unknown runs end with a restart hint; a repeated step is answered once", async () => {
  const { step, logs } = await lab("E1");
  const lost = await step("deadbeefdeadbeef", 3, "x");
  assert.equal(lost.next, "end");
  assert.match(lost.say, /重新说“家庭实验”/);
  const s0 = await step("", 0);
  const [a, b] = await Promise.all([step(s0.run, 1, ""), step(s0.run, 1, "")]);
  assert.deepEqual(a, b);
  assert.equal(logs.filter((e) => e.step === 1 && e.match).length, 1, "one result for a retried step");
  assert.equal(logs.filter((e) => e.repeat).length, 1);
});

test("lab E4: the response names how to speak each answer (V1 / V2)", async () => {
  const { step } = await lab("E4");
  const s0 = await step("", 0);
  const modes = [s0.mode];
  for (let i = 1; i <= 4; i++) modes.push((await step(s0.run, i, i < 3 ? "好" : "西瓜")).mode);
  assert.deepEqual(modes, ["v1", "v2", "v1", "v2", "v2"]);
  assert.equal(s0.ask, "请说。");
});

test("lab E7: one delay per run, from the list; a client that leaves is logged; `lab use` restarts the list", async () => {
  const { step, logs, file } = await lab("E7", [3, 5]);
  const waits: string[] = [];
  for (let i = 0; i < 3; i++) {
    const s0 = await step("", 0);
    waits.push((await step(s0.run, 1, "随便")).say);
  }
  assert.deepEqual(waits, ["等了3秒。", "等了5秒。", "等了3秒。"]);
  const ctl = new AbortController();
  const s0 = await step("", 0);
  const p = step(s0.run, 1, "随便", { signal: ctl.signal });
  ctl.abort();
  await p;
  assert.equal(typeof must(logs.at(-1)).client_gave_up_ms, "number");
  await writeLabState(file, { scenario: "E7", delays: [9] }, Date.now() + 1);
  const n0 = await step("", 0);
  assert.equal((await step(n0.run, 1, "x")).say, "等了9秒。");
});

test("lab state: bad files fall back to E1 with the default delays", async () => {
  const dir = await mkdtemp(join(tmpdir(), "homebot-lab-"));
  const file = join(dir, "lab.json");
  await writeFile(file, JSON.stringify({ scenario: "E9", delays: [0, "x"] }));
  const st = await readLabState(file);
  assert.equal(st.scenario, "E1");
  assert.deepEqual(st.delays, [8, 12, 16, 20, 25, 30]);
});

// HTTP: /v1/lab exists only with a lab service, and only lab tokens work there.
let server: http.Server | undefined;
afterEach(async () => {
  server?.closeAllConnections();
  await new Promise<void>((r) => (server ? server.close(() => r()) : r()));
  server = undefined;
});

const config: VoiceConfig = { settings: { rateLimitPerMin: 100 }, bot: () => undefined };
const record = (kind?: "lab"): TokenRecord => ({ id: "aaaaaaaaaaaa", hash: "", bot: "chai", label: "t", state: "active", createdAt: 0, siriLang: "zh-CN", ...(kind ? { kind } : {}) });
// Like TokenStore.verify: a token only works at the endpoint of its kind.
const verify = async (token: unknown, _bot?: string, o: { kind?: TokenKind } = {}): Promise<VerifyResult> =>
  token === `${o.kind ?? "ask"}-token` ? { ok: true, record: record(o.kind === "lab" ? "lab" : undefined) } : { ok: false, reason: "invalid" };

async function startServer(withLab: boolean | "failing") {
  const asked: unknown[] = [];
  const ask = { ask: async (q: unknown) => (asked.push(q), { text: "answer", outcome: "answered", timings: {} }) };
  const failing = {
    handle: async (): Promise<LabResponse> => {
      throw new Error("lab failed");
    },
  };
  const svc = withLab === "failing" ? failing : withLab ? (await lab("E1b")).svc : undefined;
  const s = createVoiceServer({ ask, tokens: { verify }, config, lab: svc, maxBodyBytes: 1024 });
  server = s;
  await new Promise<void>((r) => s.listen(0, "127.0.0.1", r));
  const port = (s.address() as AddressInfo).port; // listening on TCP
  const post = (path: string, token: string, body: unknown) =>
    fetch(`http://127.0.0.1:${port}${path}`, { method: "POST", headers: { "X-Homebot-Token": token, "Content-Type": "application/json" }, body: JSON.stringify(body) });
  return { post, asked };
}

test("lab over HTTP: off by default; lab tokens only; JSON every time; never reaches a bot", async () => {
  {
    const { post } = await startServer(false);
    const off = await post("/v1/lab", "lab-token", { step: "0" });
    assert.equal(off.status, 404);
    const body = (await off.json()) as LabResponse;
    assert.equal(body.next, "end", "without --lab, the lab Shortcut hears why and stops (re-review S3)");
    assert.match(body.say, /homebot start --lab/);
    server?.closeAllConnections();
    server?.close();
  }
  const { post, asked } = await startServer(true);
  const wrong = await post("/v1/lab", "ask-token", { step: "0" });
  assert.equal(wrong.status, 401);
  assert.equal(((await wrong.json()) as LabResponse).next, "end", "a refusal still ends the Shortcut's loop");
  assert.equal((await post("/v1/ask", "lab-token", { text: "hi" })).status, 401, "/v1/ask refuses lab tokens");
  const s0 = (await (await post("/v1/lab", "lab-token", { v: "2", step: "0", run: "", last: "10", text: "" })).json()) as LabResponse;
  assert.equal(s0.next, "listen");
  // Shortcuts sends Repeat Index as text.
  const s1 = (await (await post("/v1/lab", "lab-token", { v: "2", step: "1", run: s0.run, last: "10", text: "" })).json()) as LabResponse;
  assert.equal(s1.next, "listen");
  assert.deepEqual(asked, [], "no bot request");
  // Every refusal and failure still carries a line to speak and ends the loop (review S3).
  const ends = async (r: Response, status: number) => {
    assert.equal(r.status, status);
    const body = (await r.json()) as LabResponse;
    assert.equal(body.next, "end");
    assert.ok(body.say.length > 0);
  };
  await ends(await post("/v1/lab", "lab-token", []), 400);
  await ends(await post("/v1/lab", "lab-token", { text: "x".repeat(2000) }), 413);
  server?.closeAllConnections();
  server?.close();
  const failing = await startServer("failing");
  await ends(await failing.post("/v1/lab", "lab-token", { step: "0" }), 500);
});

/** The actions between a block's start and end share its GroupingIdentifier; count opens/closes. */
function blocks(actions: Action[], id: string): { open: number; close: number } {
  const ps = actions.filter((a) => a.WFWorkflowActionIdentifier === id).map((a) => a.WFWorkflowActionParameters);
  return { open: ps.filter((p) => p.WFControlFlowMode === 0).length, close: ps.filter((p) => p.WFControlFlowMode === 2).length };
}

test("lab Shortcut: balanced loop and conditions, posts to /v1/lab, speaks in the Siri language", () => {
  const w = buildLabShortcut({ baseUrl: "http://mac.local:8787/x", token: "secret-token", speakLang: "zh-CN" });
  const a = w.WFWorkflowActions;
  assert.deepEqual(blocks(a, "is.workflow.actions.repeat.count"), { open: 1, close: 1 });
  const ifs = blocks(a, "is.workflow.actions.conditional");
  assert.equal(ifs.open, ifs.close);
  assert.equal(ifs.open, 3, "start check, V1/V2 choice, end check");
  const posts = a.filter((x) => x.WFWorkflowActionIdentifier === "is.workflow.actions.downloadurl");
  assert.deepEqual(posts.map((p) => p.WFWorkflowActionParameters.WFURL), ["http://mac.local:8787/v1/lab", "http://mac.local:8787/v1/lab"]);
  const speaks = a.filter((x) => x.WFWorkflowActionIdentifier === "is.workflow.actions.speaktext");
  assert.ok(speaks.length >= 3 && speaks.every((s) => s.WFWorkflowActionParameters.WFSpeakTextLanguage === "zh-CN"));
  const repeatStart = must(a.find((x) => x.WFWorkflowActionIdentifier === "is.workflow.actions.repeat.count"));
  assert.equal(repeatStart.WFWorkflowActionParameters.WFRepeatCount, LAB_STEPS);
  // Every Get Dictionary Value reads a POST response, and every variable read is set somewhere.
  const xml = toXmlPlist(w);
  const read = new Set([...xml.matchAll(/<key>VariableName<\/key>\s*<string>([^<]+)<\/string>/g)].map((m) => must(m[1])));
  const set = new Set(a.filter((x) => x.WFWorkflowActionIdentifier === "is.workflow.actions.setvariable").map((x) => String(x.WFWorkflowActionParameters.WFVariableName)));
  for (const v of read) assert.ok(set.has(v) || v === "Repeat Index", `variable ${v} is set before use`);
  assert.equal(xml.split("secret-token").length - 1, 2, "the token is in both requests and nowhere else");
});

test("lab Shortcut XML passes plutil -lint (macOS only)", { skip: !isMac && "plutil is macOS-only" }, async () => {
  const dir = await mkdtemp(join(tmpdir(), "homebot-test-"));
  const file = join(dir, "lab.shortcut");
  await writeFile(file, toXmlPlist(buildLabShortcut({ baseUrl: "http://mac.local:8787", token: "t", speakLang: "en-US" })));
  const { stdout } = await run("plutil", ["-lint", file]);
  assert.match(stdout, /OK/);
});
