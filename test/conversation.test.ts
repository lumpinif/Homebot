// Conversation mode (DESIGN §18), offline: runs, end words, the follow-up idle wait, the v2
// HTTP contract and the looping Shortcut.
import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type http from "node:http";
import type { AddressInfo } from "node:net";
import { ConversationService, CONVERSATION_STEPS } from "../src/core/conversation.ts";
import { AskService, type AskRequest, type AskResult } from "../src/core/ask.ts";
import { buildEnvelope, echoTag } from "../src/core/envelope.ts";
import { DEFAULT_SETTINGS, type Bot } from "../src/core/store.ts";
import type { Entry, Turn } from "../src/core/entries.ts";
import type { LoopResponse } from "../src/core/runs.ts";
import { createVoiceServer, type VoiceConfig } from "../src/server/voice.ts";
import type { TokenKind, TokenRecord, VerifyResult } from "../src/core/tokens.ts";
import { buildConversationShortcut, type Action } from "../src/shortcut/build.ts";
import { toXmlPlist } from "../src/shortcut/plist.ts";
import { scriptedBdk, IDLE, type ScriptedPage } from "../test-helpers/scripted-bdk.ts";
import { must } from "../test-helpers/must.ts";

const isMac = process.platform === "darwin";

/** A fake AskService: answers from `outcomes` in order and records each request. */
function fakeAsk(outcomes: string[] = []) {
  const calls: AskRequest[] = [];
  return {
    calls,
    async ask(r: AskRequest): Promise<AskResult> {
      calls.push(r);
      const outcome = outcomes.shift() ?? "answered";
      return { text: outcome === "answered" ? `answer ${calls.length}` : `refusal ${outcome}`, outcome, timings: {} };
    },
  };
}

function conv(outcomes: string[] = [], followupIdleMs = 0) {
  const ask = fakeAsk(outcomes);
  const logs: Record<string, unknown>[] = [];
  const svc = new ConversationService({ ask, log: (e) => logs.push(e), followupIdleMs: () => followupIdleMs });
  const step = (run: string, n: number, text = "", o: { last?: number; botKey?: string; prompt?: string } = {}) =>
    svc.handle({ run, step: n, last: o.last ?? CONVERSATION_STEPS, text, prompt: o.prompt ?? "想问什么？", botKey: o.botKey ?? "chai", tokenId: "tok", lang: "zh-CN" });
  return { svc, ask, logs, step };
}

test("conversation: the first prompt is the Shortcut's question; answers keep listening", async () => {
  const { step, ask } = conv([], 3000);
  const s0 = await step("", 0);
  assert.deepEqual([s0.say, s0.mode, s0.next], ["想问什么？", "v2", "listen"]);
  const r1 = await step(s0.run, 1, "明天天气怎么样");
  assert.deepEqual([r1.say, r1.mode, r1.ask, r1.next], ["answer 1", "v1", "还有吗？", "listen"]);
  const r2 = await step(s0.run, 2, "那后天呢");
  assert.equal(r2.next, "listen");
  assert.deepEqual(ask.calls.map((c) => [c.turn, c.waitIdleMs]), [[1, 0], [2, 3000]], "only a follow-up to an answered turn may wait");
});

test("conversation: a refusal, error or timeout ends the run, and no later step is taken", async () => {
  const { step, ask } = conv(["answered", "refused"], 3000);
  const s0 = await step("", 0);
  await step(s0.run, 1, "一");
  const r2 = await step(s0.run, 2, "二");
  assert.deepEqual([r2.say, r2.next], ["refusal refused", "end"]);
  const r3 = await step(s0.run, 3, "三");
  assert.equal(r3.next, "end");
  assert.match(r3.say, /重新开始/);
  assert.equal(ask.calls.length, 2, "nothing is sent after the run ended");
});

test("conversation: end words and silence end the run without reaching the bot", async () => {
  for (const said of ["谢谢。", " 再见 ", "", "  "]) {
    const { step, ask } = conv();
    const s0 = await step("", 0);
    const r = await step(s0.run, 1, said);
    assert.deepEqual([r.say, r.next], ["好的。", "end"], JSON.stringify(said));
    assert.equal(ask.calls.length, 0);
  }
  const { step, ask } = conv();
  const s0 = await step("", 0);
  assert.equal((await step(s0.run, 1, "谢谢你帮我查天气")).next, "listen", "only the whole utterance is an end word");
  assert.equal(ask.calls.length, 1);
});

test("conversation: the last step's answer ends the run, so it is spoken (DESIGN §18.2)", async () => {
  const { step } = conv();
  const s0 = await step("", 0, "", { last: 2 });
  assert.equal((await step(s0.run, 1, "一", { last: 2 })).next, "listen");
  const r2 = await step(s0.run, 2, "二", { last: 99 });
  assert.deepEqual([r2.say, r2.next], ["answer 2", "end"], "the cap sent at the start holds, and never above the Shortcut's");
});

test("conversation: retries are answered once; foreign runs and other bots restart; run ids are never logged raw", async () => {
  const { step, ask, logs } = conv();
  const s0 = await step("", 0);
  const [a, b] = await Promise.all([step(s0.run, 1, "一"), step(s0.run, 1, "一")]);
  assert.deepEqual(a, b);
  assert.equal(ask.calls.length, 1, "a retried step never asks the bot twice");
  const other = await step(s0.run, 2, "二", { botKey: "kitchen" });
  assert.equal(other.next, "end");
  assert.equal(ask.calls.length, 1, "a run belongs to one bot");
  const forged = await step("SECRET_FROM_REQUEST", 1, "x");
  assert.deepEqual([forged.next, forged.run], ["end", ""]);
  assert.ok(!JSON.stringify(logs).includes("SECRET"));
  assert.ok(!JSON.stringify(logs).includes("一"), "what was said is never logged");
});

test("conversation: a step that throws ends the run; its retry gets the same answer (review S2)", async () => {
  let calls = 0;
  const svc = new ConversationService({
    ask: {
      async ask(): Promise<AskResult> {
        calls++;
        throw new Error("state refresh failed");
      },
    },
  });
  const step = (run: string, n: number, text = "") => svc.handle({ run, step: n, last: 10, text, prompt: "", botKey: "chai", tokenId: "tok", lang: "en" });
  const s0 = await step("", 0);
  const r1 = await step(s0.run, 1, "hello");
  assert.equal(r1.next, "end");
  assert.deepEqual(await step(s0.run, 1, "hello"), r1);
  assert.equal((await step(s0.run, 2, "again")).next, "end");
  assert.equal(calls, 1, "nothing more reaches the bot after the failed step");
});

test("conversation: a retry for another bot is not answered from the cache (review N1)", async () => {
  const { step } = conv();
  const s0 = await step("", 0);
  const r1 = await step(s0.run, 1, "一");
  const other = await step(s0.run, 1, "一", { botKey: "kitchen" });
  assert.notDeepEqual(other, r1);
  assert.equal(other.next, "end");
});

// The follow-up idle wait inside AskService (DESIGN §18.3).
const BOT: Bot = { key: "chai", name: "拆解师", sessionId: "1", strictEcho: true };
const BUSY: Turn = { idle: false, inFlight: true, queued: 0 };
type Sent = { messageId: string; text: string };
const ours = (seq: number, sent: Sent): Entry => ({ seq: String(seq), kind: "message", role: "user", text: sent.text });
const reply = (seq: number, text: string): Entry => ({ seq: String(seq), kind: "send-message", text });
const page = (entries: Entry[], turn: Turn = IDLE): ScriptedPage => ({ entries, turn });

function waiting(before: ScriptedPage[], script: (s: Sent) => ScriptedPage[] = (s) => [page([ours(110, s), reply(111, `${echoTag(s.messageId)} OWNED`)]), page([])]) {
  const bdk = scriptedBdk(script, { before });
  const logs: Record<string, unknown>[] = [];
  const config = { settings: { ...DEFAULT_SETTINGS, pollMs: 5, answerBudgetMs: 2000 }, bot: (k: string) => (k === BOT.key ? BOT : undefined) };
  const state = { cursor: () => ({ cursor: "100", maxSeq: "100", syncedAt: 0 }), setCursor: async () => {} };
  const svc = new AskService({ config, state, bdk, log: (e) => logs.push(e) });
  return { bdk, logs, ask: (waitIdleMs: number) => svc.ask({ botKey: "chai", text: "那后天呢", lang: "zh-CN", turn: 2, waitIdleMs }) };
}

test("follow-up wait: the previous turn's tail goes below the new baseline and is never spoken", async () => {
  const { ask, bdk } = waiting([page([], BUSY), page([reply(101, "the rest of the previous answer")], BUSY), page([], BUSY), page([], IDLE)]);
  const r = await ask(1000);
  assert.equal(r.outcome, "answered");
  assert.equal(r.text, "OWNED");
  assert.equal(bdk.sent, 1);
});

test("follow-up wait: a user entry during the wait answers busy and sends nothing", async () => {
  const { ask, bdk, logs } = waiting([page([], BUSY), page([{ seq: "101", kind: "message", role: "user", text: "desktop" }], BUSY), page([], BUSY)]);
  const r = await ask(1000);
  assert.equal(r.outcome, "busy");
  assert.equal(bdk.sent, 0);
  assert.equal(must(logs.find((e) => e.event === "ask")).wait, "user");
});

test("follow-up wait: a user entry in the first sync counts too (conversation review B1)", async () => {
  const { ask, bdk } = waiting([page([{ seq: "101", kind: "message", role: "user", text: "desktop" }], BUSY), page([], BUSY), page([], IDLE)]);
  assert.equal((await ask(1000)).outcome, "busy");
  assert.equal(bdk.sent, 0);
});

test("follow-up wait: no wait (0) or a turn that stays busy answers busy and sends nothing", async () => {
  {
    const { ask, bdk } = waiting([page([], BUSY), page([], IDLE)]);
    assert.equal((await ask(0)).outcome, "busy", "0 keeps today's immediate busy");
    assert.equal(bdk.sent, 0);
  }
  const { ask, bdk } = waiting(Array.from({ length: 200 }, () => page([], BUSY)));
  assert.equal((await ask(30)).outcome, "busy");
  assert.equal(bdk.sent, 0);
});

test("envelope: a conversation turn tells the bot the turn and that only its first message is heard", () => {
  const zh = buildEnvelope({ id: "abc", text: "那后天呢", lang: "zh-CN", strictEcho: true, turn: 2 });
  assert.match(zh, /第 2 轮/);
  assert.match(zh, /只会听到你这一轮的第一条消息/);
  const en = buildEnvelope({ id: "abc", text: "and after", lang: "en", strictEcho: true, turn: 3 });
  assert.match(en, /turn 3 of a voice conversation/);
  assert.doesNotMatch(buildEnvelope({ id: "abc", text: "x", lang: "en", strictEcho: true }), /conversation/);
});

// HTTP: v2 on /v1/ask answers JSON in every case; v1 is unchanged.
let server: http.Server | undefined;
afterEach(async () => {
  server?.closeAllConnections();
  await new Promise<void>((r) => (server ? server.close(() => r()) : r()));
  server = undefined;
});

const config: VoiceConfig = { settings: { rateLimitPerMin: 100 }, bot: (k) => (k === "chai" ? { sessionId: "1" } : undefined) };
const record = (): TokenRecord => ({ id: "aaaaaaaaaaaa", hash: "", bot: "chai", label: "t", state: "active", createdAt: 0, siriLang: "zh-CN", sessionId: "1" });
const verify = async (token: unknown, bot?: string, o: { kind?: TokenKind } = {}): Promise<VerifyResult> =>
  token === "ask-token" && (o.kind ?? "ask") === "ask" ? (bot === undefined || bot === "chai" ? { ok: true, record: record() } : { ok: false, reason: "forbidden" }) : { ok: false, reason: "invalid" };

async function start() {
  const ask = fakeAsk();
  const s = createVoiceServer({ ask, tokens: { verify }, config });
  server = s;
  await new Promise<void>((r) => s.listen(0, "127.0.0.1", r));
  const port = (s.address() as AddressInfo).port; // listening on TCP
  const post = (token: string, body: unknown) =>
    fetch(`http://127.0.0.1:${port}/v1/ask`, { method: "POST", headers: { "X-Homebot-Token": token, "Content-Type": "application/json" }, body: JSON.stringify(body) });
  return { post, ask };
}

test("conversation over HTTP: JSON for every v2 answer, refusals included; v1 stays plain text", async () => {
  const { post, ask } = await start();
  const bad = await post("nope", { v: "2", bot: "chai", step: "0" });
  assert.equal(bad.status, 401);
  assert.equal(((await bad.json()) as LoopResponse).next, "end");
  const other = await post("ask-token", { v: "2", bot: "kitchen", step: "0" });
  assert.equal(other.status, 403);
  assert.equal(((await other.json()) as LoopResponse).next, "end");
  // Shortcuts sends numbers as text.
  const s0 = (await (await post("ask-token", { v: "2", bot: "chai", step: "0", run: "", last: "10", text: "", prompt: "想问拆解师什么？" })).json()) as LoopResponse;
  assert.deepEqual([s0.say, s0.next], ["想问拆解师什么？", "listen"]);
  const s1 = (await (await post("ask-token", { v: "2", bot: "chai", step: "1", run: s0.run, last: "10", text: "几点了" })).json()) as LoopResponse;
  assert.deepEqual([s1.say, s1.next], ["answer 1", "listen"]);
  const v1 = await post("ask-token", { v: "1", bot: "chai", text: "几点了" });
  assert.match(must(v1.headers.get("content-type")), /text\/plain/);
  assert.equal(await v1.text(), "answer 2");
  assert.deepEqual(ask.calls.map((c) => c.turn), [1, undefined], "only v2 requests carry a turn");
});

test("conversation over HTTP: only a run's start counts toward the rate limit; failures stay JSON (review S1, S3)", async () => {
  const ask = fakeAsk();
  const throwing = { verify: async (): Promise<VerifyResult> => { throw new Error("token file unreadable"); } };
  {
    const s = createVoiceServer({ ask, tokens: throwing, config });
    server = s;
    await new Promise<void>((r) => s.listen(0, "127.0.0.1", r));
    const port = (s.address() as AddressInfo).port; // listening on TCP
    const r = await fetch(`http://127.0.0.1:${port}/v1/ask`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ v: "2", step: "0" }) });
    assert.equal(r.status, 500);
    assert.equal(((await r.json()) as LoopResponse).next, "end");
    server.closeAllConnections();
    server.close();
  }
  const tight: VoiceConfig = { settings: { rateLimitPerMin: 2 }, bot: config.bot };
  const s = createVoiceServer({ ask, tokens: { verify }, config: tight });
  server = s;
  await new Promise<void>((r) => s.listen(0, "127.0.0.1", r));
  const port = (s.address() as AddressInfo).port; // listening on TCP
  const post = async (body: unknown) =>
    (await (await fetch(`http://127.0.0.1:${port}/v1/ask`, { method: "POST", headers: { "X-Homebot-Token": "ask-token", "Content-Type": "application/json" }, body: JSON.stringify(body) })).json()) as LoopResponse;
  const s0 = await post({ v: "2", bot: "chai", step: "0", last: "10" });
  for (let i = 1; i <= 4; i++) assert.equal((await post({ v: "2", bot: "chai", step: String(i), run: s0.run, last: "10", text: `q${i}` })).next, "listen", `step ${i}`);
  await post({ v: "2", bot: "chai", step: "0", last: "10" });
  assert.match((await post({ v: "2", bot: "chai", step: "0", last: "10" })).say, /Too many|太频繁/, "new runs are still limited");
});

test("conversation Shortcut: the loop posts to /v1/ask with v 2, the bot and the first question", async () => {
  const wf = buildConversationShortcut({ baseUrl: "http://felix-mac.local:8787", botKey: "chai", token: "TOKEN", prompt: "想问拆解师什么？", speakLang: "zh-CN" });
  const xml = toXmlPlist(wf);
  const posts = wf.WFWorkflowActions.filter((a: Action) => a.WFWorkflowActionIdentifier === "is.workflow.actions.downloadurl");
  assert.equal(posts.length, 2, "the start step and the loop step");
  for (const p of posts) assert.equal(p.WFWorkflowActionParameters.WFURL, "http://felix-mac.local:8787/v1/ask");
  assert.match(xml, /想问拆解师什么？/);
  const repeat = wf.WFWorkflowActions.find((a: Action) => a.WFWorkflowActionIdentifier === "is.workflow.actions.repeat.count");
  assert.equal(must(repeat).WFWorkflowActionParameters.WFRepeatCount, CONVERSATION_STEPS);
  if (isMac) {
    const dir = await mkdtemp(join(tmpdir(), "homebot-conv-"));
    const file = join(dir, "c.plist");
    await writeFile(file, xml);
    const { stdout } = await promisify(execFile)("plutil", ["-lint", file]);
    assert.match(stdout, /OK$/m);
  }
});
