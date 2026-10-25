import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startFakeBdk, FAKE_KEY, type FakeBdk } from "../test-helpers/fake-bdk.ts";
import { must } from "../test-helpers/must.ts";
import { createBdkClient } from "../src/core/bdk.ts";
import { ConfigStore, StateStore, type Bot, type Settings } from "../src/core/store.ts";
import { AskService } from "../src/core/ask.ts";
import { coldSync } from "../src/core/bots.ts";
import { messages } from "../src/core/i18n.ts";

const SID = "14752726";
const zh = messages("zh-CN");
const PRIVATE = "这是给桌面的私密回复";
let fake: FakeBdk;
afterEach(() => fake?.close());

async function setup({ settings = {}, bot = {}, history = 5, key = FAKE_KEY }: { settings?: Partial<Settings>; bot?: Partial<Bot>; history?: number; key?: string } = {}) {
  fake = await startFakeBdk();
  for (let i = 0; i < history; i++) fake.add(SID, { kind: i % 2 ? "send-message" : "message", role: i % 2 ? undefined : "user", text: `old ${i}` });
  const dir = await mkdtemp(join(tmpdir(), "homebot-test-"));
  const config = await new ConfigStore(join(dir, "config.json")).load();
  config.data.settings = { answerBudgetMs: 1500, pollMs: 10, ...settings };
  await config.putBot({ key: "chai", name: "拆解师", sessionId: SID, strictEcho: true, ...bot });
  const state = await new StateStore(join(dir, "state.json")).load();
  const setupClient = createBdkClient({ key: FAKE_KEY, baseUrl: fake.baseUrl });
  await state.setCursor("chai", await coldSync(setupClient, SID));
  const logs: Record<string, unknown>[] = [];
  const bdk = createBdkClient({ key, baseUrl: fake.baseUrl });
  const svc = new AskService({ config, state, bdk, log: (e) => logs.push(e) });
  return { svc, state, logs, config };
}

test("happy path: owned, echoed reply is spoken without the tag", async () => {
  const { svc, logs } = await setup();
  fake.autoReply(SID, { text: "现在**三点**。" });
  const r = await svc.ask({ lang: "zh-CN", botKey: "chai", text: "几点了" });
  assert.equal(r.outcome, "answered");
  assert.equal(r.text, "现在三点。");
  assert.equal(fake.posts.length, 1);
  assert.match(must(fake.posts[0]).text, /^\[Homebot voice · hb:[0-9a-f]{12} · zh-CN\]\n几点了\n/);
  assert.equal(must(fake.posts[0]).messageId, r.requestId);
  assert.ok(fake.requests.every((q) => q.client === "agent-serve"));
  assert.ok(!JSON.stringify(logs).includes("几点了"), "question text is not logged by default");
});

test("baseline walks a >200-entry backlog and never speaks old replies", async () => {
  const { svc, state } = await setup({ history: 3 });
  // Backlog that arrived after setup: 450 entries, including old bot replies.
  for (let i = 0; i < 450; i++) fake.add(SID, { kind: "send-message", text: `backlog ${i}` });
  fake.autoReply(SID, { text: "新回答。" });
  const r = await svc.ask({ lang: "zh-CN", botKey: "chai", text: "你好" });
  assert.equal(r.text, "新回答。");
  await svc.flush(); // cursor writes are locked and off the response path
  assert.ok(BigInt(must(state.cursor("chai")).cursor) > 1450n);
});

test("B1: desktop message between the idle check and our send -> refused, private text never returned", async () => {
  const { svc, logs } = await setup();
  let injected = false;
  fake.intercept = async ({ what, method }) => {
    if (what === "messages" && method === "POST" && !injected) {
      injected = true;
      fake.add(SID, { kind: "message", role: "user", text: "桌面上的问题" });
      setTimeout(() => fake.add(SID, { kind: "send-message", text: PRIVATE }), 5);
    }
  };
  fake.autoReply(SID, { ms: 40, text: "语音回答" });
  const r = await svc.ask({ lang: "zh-CN", botKey: "chai", text: "几点了" });
  assert.equal(r.outcome, "refused");
  assert.equal(r.reason, "O2");
  assert.equal(r.text, zh.refused());
  assert.ok(!JSON.stringify({ r, logs }).includes(PRIVATE));
});

test("B1: desktop message after ours, before the reply -> refused", async () => {
  const { svc } = await setup();
  fake.onMessage = (_sid, msg) => {
    const id = must(/hb:([0-9a-f]{12})/.exec(msg.text))[1];
    fake.add(SID, { kind: "message", role: "user", text: "桌面插话" });
    setTimeout(() => fake.add(SID, { kind: "send-message", text: `[hb:${id}] ${PRIVATE}` }), 10);
  };
  const r = await svc.ask({ lang: "zh-CN", botKey: "chai", text: "几点了" });
  assert.equal(r.outcome, "refused");
  assert.ok(!r.text.includes(PRIVATE));
});

test("B4: foreign output re-updated without text before we poll -> refused", async () => {
  const { svc } = await setup();
  fake.intercept = async ({ what, method }) => {
    if (what === "messages" && method === "POST" && !fake.posts.length) {
      const e = fake.add(SID, { kind: "send-message", text: PRIVATE });
      fake.touch(SID, e.seq, { text: undefined });
    }
  };
  fake.autoReply(SID, { text: PRIVATE });
  const r = await svc.ask({ lang: "zh-CN", botKey: "chai", text: "几点了" });
  assert.equal(r.outcome, "refused");
  assert.equal(r.reason, "O3");
  assert.ok(!r.text.includes(PRIVATE));
});

test("B1: reply without the echo tag is refused in strict mode", async () => {
  const { svc } = await setup();
  fake.autoReply(SID, { text: PRIVATE, echo: false });
  const r = await svc.ask({ lang: "zh-CN", botKey: "chai", text: "几点了" });
  assert.equal(r.reason, "O5");
  assert.ok(!r.text.includes(PRIVATE));
});

test("non-strict bot accepts an untagged reply", async () => {
  const { svc } = await setup({ bot: { strictEcho: false } });
  fake.autoReply(SID, { text: "好的。", echo: false });
  const r = await svc.ask({ lang: "zh-CN", botKey: "chai", text: "你好" });
  assert.equal(r.text, "好的。");
  assert.ok(!must(fake.posts[0]).text.includes("[hb:"), "no echo instruction when strict is off");
});

test("busy bot: nothing is sent", async () => {
  const { svc } = await setup();
  fake.setIdle(SID, false);
  const r = await svc.ask({ lang: "zh-CN", botKey: "chai", text: "你好" });
  assert.equal(r.outcome, "busy");
  assert.equal(r.text, zh.busy("拆解师"));
  assert.equal(fake.posts.length, 0);
});

test("S1: deadline before send -> nothing sent, 'not sent' message", async () => {
  const { svc } = await setup({ settings: { answerBudgetMs: 100 } });
  fake.intercept = async ({ what }) => {
    if (what === "entries") await new Promise((r) => setTimeout(r, 300));
  };
  const r = await svc.ask({ lang: "zh-CN", botKey: "chai", text: "你好" });
  assert.equal(r.outcome, "not-sent:deadline");
  assert.equal(r.text, zh.notSent());
  await new Promise((r) => setTimeout(r, 300));
  assert.equal(fake.posts.length, 0);
});

test("S1: client disconnect before send aborts without sending", async () => {
  const { svc } = await setup();
  const ctl = new AbortController();
  fake.intercept = async ({ what }) => {
    if (what === "entries") {
      ctl.abort();
      await new Promise((r) => setTimeout(r, 50));
    }
  };
  const r = await svc.ask({ lang: "zh-CN", botKey: "chai", text: "你好", signal: ctl.signal });
  assert.equal(r.outcome, "not-sent:disconnect");
  await new Promise((r) => setTimeout(r, 100));
  assert.equal(fake.posts.length, 0);
});

test("S1: uncertain send is retried with the same messageId and the answer still arrives", async () => {
  const { svc } = await setup();
  fake.intercept = async ({ what, method, attempt }) => (what === "messages" && method === "POST" && attempt === 1 ? "accept-then-destroy" : undefined);
  fake.autoReply(SID, { text: "到了。" });
  const r = await svc.ask({ lang: "zh-CN", botKey: "chai", text: "你好" });
  assert.equal(r.outcome, "answered");
  assert.equal(fake.posts.length, 1, "server stored the message once");
  const sends = fake.requests.filter((q) => q.method === "POST");
  assert.equal(sends.length, 2, "client retried");
});

test("S1: deadline after send -> 'may have been delivered', no interrupt, guard released", async () => {
  const { svc } = await setup({ settings: { answerBudgetMs: 200 } });
  const r = await svc.ask({ lang: "zh-CN", botKey: "chai", text: "你好" });
  assert.equal(r.outcome, "no-reply:deadline");
  assert.equal(r.text, zh.noReplyInTime("拆解师"));
  assert.ok(!fake.requests.some((q) => q.path.endsWith("/interrupt")));
  assert.equal(svc.inFlight.size, 0);
});

test("second concurrent request to the same bot is rejected immediately", async () => {
  const { svc } = await setup();
  fake.autoReply(SID, { ms: 100 });
  const first = svc.ask({ lang: "zh-CN", botKey: "chai", text: "一" });
  await new Promise((r) => setTimeout(r, 10));
  const second = await svc.ask({ lang: "zh-CN", botKey: "chai", text: "二" });
  assert.equal(second.outcome, "in-flight");
  assert.equal((await first).outcome, "answered");
  assert.equal(fake.posts.length, 1);
});

test("auth failure, 4xx send rejection, transient poll errors", async () => {
  {
    const { svc } = await setup({ key: "wrong" });
    const r = await svc.ask({ lang: "zh-CN", botKey: "chai", text: "你好" });
    assert.equal(r.outcome, "auth-failed");
    assert.equal(r.text, zh.authFailed());
  }
  await fake.close();
  {
    const { svc } = await setup();
    fake.intercept = async ({ what, method }) => (what === "messages" && method === "POST" ? { status: 400 } : undefined);
    const r = await svc.ask({ lang: "zh-CN", botKey: "chai", text: "你好" });
    assert.equal(r.outcome, "upstream");
    assert.equal(r.text, zh.upstreamDown());
  }
  await fake.close();
  {
    const { svc } = await setup();
    let gets = 0;
    fake.intercept = async ({ what, method }) => (what === "entries" && method === "GET" && ++gets === 2 ? { status: 503 } : undefined);
    fake.autoReply(SID, { ms: 50 });
    const r = await svc.ask({ lang: "zh-CN", botKey: "chai", text: "你好" });
    assert.equal(r.outcome, "answered");
    assert.equal(r.timings.poll_errors, 1);
  }
});

test("BDK delivery: an unknown value stops waiting at once; a missing field still waits for the reply", async () => {
  {
    const { svc, logs } = await setup({ settings: { answerBudgetMs: 5000 } });
    fake.delivery = "rejected_by_harness";
    fake.autoReply(SID);
    const t0 = Date.now();
    const r = await svc.ask({ lang: "zh-CN", botKey: "chai", text: "你好" });
    assert.equal(r.outcome, "not-accepted");
    assert.equal(r.text, zh.noReplyInTime("拆解师"), "never claims it was not delivered");
    assert.ok(Date.now() - t0 < 1000, "no wait until the deadline");
    assert.equal(must(logs.find((e) => e.event === "ask")).delivery, "unknown");
    assert.ok(!JSON.stringify(logs).includes("rejected_by_harness"));
  }
  // BDK review S2: an unexpected value is never logged, whatever its shape.
  for (const value of ["synthetic_private_value", "sk-live: not/allowed!", "x".repeat(500)]) {
    await fake.close();
    const { svc, logs } = await setup();
    fake.delivery = value;
    assert.equal((await svc.ask({ lang: "zh-CN", botKey: "chai", text: "你好" })).outcome, "not-accepted");
    assert.equal(must(logs.find((e) => e.event === "ask")).delivery, "unknown");
    assert.ok(!JSON.stringify(logs).includes(value));
  }
  await fake.close();
  {
    const { svc } = await setup();
    fake.delivery = undefined;
    fake.autoReply(SID, { text: "到了。" });
    assert.equal((await svc.ask({ lang: "zh-CN", botKey: "chai", text: "你好" })).outcome, "answered");
  }
  await fake.close();
  {
    const { svc } = await setup();
    fake.delivery = "duplicate";
    fake.autoReply(SID, { text: "到了。" });
    assert.equal((await svc.ask({ lang: "zh-CN", botKey: "chai", text: "你好" })).outcome, "answered");
  }
});

const askLog = (logs: Record<string, unknown>[]) => must(logs.find((e) => e.event === "ask"));

test("BDK review B2: a multi-part turn speaks only the proved first delivery; the trace is logged", async () => {
  const { svc, logs } = await setup();
  fake.autoReply(SID, { text: "第一段。", more: [PRIVATE], gapMs: 5 });
  const r = await svc.ask({ lang: "zh-CN", botKey: "chai", text: "讲讲" });
  assert.equal(r.text, "第一段。");
  assert.ok(!JSON.stringify({ r, logs }).includes(PRIVATE));
  assert.match(String(askLog(logs).turns), /^[BI?]+$/);
});

test("input validation and unknown bots", async () => {
  const { svc, config } = await setup({ settings: { maxQuestionChars: 5 } });
  assert.equal((await svc.ask({ lang: "zh-CN", botKey: "nope", text: "x" })).outcome, "not-configured");
  assert.equal((await svc.ask({ lang: "zh-CN", botKey: "chai", text: "   " })).outcome, "empty");
  assert.equal((await svc.ask({ lang: "zh-CN", botKey: "chai", text: "一二三四五六" })).outcome, "too-long");
  await config.putBot({ key: "fresh", name: "新", sessionId: "1", strictEcho: true });
  const r = await svc.ask({ botKey: "fresh", text: "hi" });
  assert.equal(r.outcome, "not-configured", "no cold sync in the voice path");
  assert.equal(r.text, messages("en").botNotConfigured(), "English when no language is given");
  assert.equal(fake.posts.length, 0);
});

test("S4: English Shortcut -> English envelope and messages; Chinese stays Chinese", async () => {
  const { svc } = await setup();
  fake.setIdle(SID, false);
  assert.equal((await svc.ask({ botKey: "chai", text: "hi" })).text, messages("en").busy("拆解师"));
  fake.setIdle(SID, true);
  fake.autoReply(SID, { text: "It is three." });
  const r = await svc.ask({ botKey: "chai", text: "What time is it?", lang: "en" });
  assert.equal(r.text, "It is three.");
  assert.match(must(fake.posts[0]).text, /^\[Homebot voice · hb:[0-9a-f]{12} · en\]\nWhat time is it\?\n/);
  assert.match(must(fake.posts[0]).text, /Then answer in English, .* answer in English even if the question is in another language\./);
});

test("every envelope asks for the token's language, whatever the question's: its voice reads the answer (DECISIONS item 31)", async () => {
  const { STYLE } = await import("../src/core/envelope.ts");
  const ask: Record<string, RegExp> = {
    en: /answer in English even if/, es: /responde en español aunque/, fr: /réponds en français même si/, de: /antworte auf Deutsch, auch wenn/, it: /rispondi in italiano anche se/,
    "pt-BR": /responda em português mesmo que/, ru: /отвечай по-русски, даже если/, ja: /質問が別の言語でも日本語で/, ko: /다른 언어여도 한국어로/, "zh-CN": /也要用中文回答/, "zh-TW": /也要用繁體中文回答/,
  };
  assert.deepEqual(Object.keys(STYLE).sort(), Object.keys(ask).sort());
  for (const [lang, s] of Object.entries(STYLE)) assert.match(s.style, must(ask[lang]), lang);
});

test("S25: a reply its voice can't read is never spoken; the token's language says so instead", async () => {
  const { svc } = await setup();
  fake.setIdle(SID, true);
  fake.autoReply(SID, { text: "我是 homebot，陪你琢磨软件点子的工程师朋友。" });
  const en = await svc.ask({ botKey: "chai", text: "你是谁", lang: "en" });
  assert.equal(en.outcome, "unspeakable");
  assert.equal(en.reason, "script");
  assert.equal(en.text, messages("en").unspeakable());
  fake.autoReply(SID, { text: "我是 homebot。" });
  assert.equal((await svc.ask({ botKey: "chai", text: "你是谁", lang: "zh-CN" })).text, "我是 homebot。", "a Chinese voice reads it, Latin words included");
});

test("S25: which letters each voice can read", async () => {
  const { readableBy } = await import("../src/core/speech.ts");
  const cases: [string, string, boolean][] = [
    ["我是 homebot。", "en", false], ["我是 homebot。", "zh-CN", true], ["It is three.", "zh-TW", true], ["Café crème, 3 €", "fr", true],
    ["コーヒーを飲む", "ja", true], ["コーヒー", "zh-CN", false], ["안녕하세요 OK", "ko", true], ["안녕", "ja", false],
    ["Привет, OK", "ru", true], ["Привет", "de", false], ["", "en", true],
  ];
  for (const [s, lang, ok] of cases) assert.equal(readableBy(s, lang), ok, `${lang}: ${s}`);
});

test("busy rule: idle=false, inFlight=true or queued>0 each count as busy", async () => {
  const { isBusy } = await import("../src/core/ask.ts");
  assert.equal(isBusy({ idle: true, inFlight: false, queued: 0 }), false);
  assert.equal(isBusy({ idle: false, inFlight: false, queued: 0 }), true);
  assert.equal(isBusy({ idle: true, inFlight: true, queued: 0 }), true);
  assert.equal(isBusy({ idle: true, inFlight: false, queued: 2 }), true);
  const { svc } = await setup();
  fake.session(SID).queued = 1;
  assert.equal((await svc.ask({ botKey: "chai", text: "hi" })).outcome, "busy");
  assert.equal(fake.posts.length, 0);
});

test("S6: a transient baseline failure is retried within the deadline", async () => {
  const { svc } = await setup();
  let gets = 0;
  fake.intercept = async ({ what, method }) => (what === "entries" && method === "GET" && ++gets === 1 ? { status: 503 } : undefined);
  fake.autoReply(SID);
  const r = await svc.ask({ lang: "zh-CN", botKey: "chai", text: "你好" });
  assert.equal(r.outcome, "answered");
  assert.equal(fake.posts.length, 1);
});

test("S6: baseline auth errors are not retried", async () => {
  const { svc } = await setup();
  let gets = 0;
  fake.intercept = async ({ what }) => (what === "entries" && ++gets ? { status: 401 } : undefined);
  const r = await svc.ask({ botKey: "chai", text: "hi" });
  assert.equal(r.outcome, "auth-failed");
  assert.equal(gets, 1);
});

test("S2: slow cursor persistence never delays the response", async () => {
  const { svc, state } = await setup({ settings: { answerBudgetMs: 100, pollMs: 10 } });
  const real = state.setCursor.bind(state);
  state.setCursor = async (...a) => {
    await new Promise((r) => setTimeout(r, 400));
    return real(...a);
  };
  const t0 = Date.now();
  const r = await svc.ask({ botKey: "chai", text: "hi" });
  assert.equal(r.outcome, "no-reply:deadline");
  assert.ok(Date.now() - t0 < 300, `responded in ${Date.now() - t0} ms despite a 400 ms write`);
  await svc.flush();
  assert.ok(BigInt(must(state.cursor("chai")).cursor) > 1000n);
});

test("S2: cursor writes from two requests never overlap or reorder, even when the first is slowest", async () => {
  const { svc, state } = await setup({ settings: { answerBudgetMs: 100, pollMs: 10 } });
  const real = state.setCursor.bind(state);
  const events: [string, number, string?][] = [];
  let n = 0;
  state.setCursor = async (bot, c) => {
    const i = ++n;
    events.push(["start", i, c.cursor]);
    await new Promise((r) => setTimeout(r, i === 1 ? 300 : 5));
    await real(bot, c);
    events.push(["end", i]);
  };
  await svc.ask({ botKey: "chai", text: "one" });
  fake.add(SID, { kind: "send-message", text: "desktop activity between requests" });
  await svc.ask({ botKey: "chai", text: "two" });
  await svc.flush();
  assert.ok(n >= 2, `expected writes from both requests, got ${n}`);
  for (let i = 0; i < n; i++) {
    assert.deepEqual(must(events[2 * i]).slice(0, 2), ["start", i + 1]);
    assert.deepEqual(events[2 * i + 1], ["end", i + 1], "each write finishes before the next starts");
  }
  const cursors = events.filter((e) => e[0] === "start").map((e) => BigInt(must(e[2])));
  assert.ok(cursors.every((c, i) => i === 0 || c >= must(cursors[i - 1])), "cursors are written in non-decreasing order");
  assert.equal(BigInt(must(state.cursor("chai")).cursor), cursors.at(-1));
});

test("S2: a failing cursor write is logged, not thrown", async () => {
  const { svc, state, logs } = await setup({ settings: { answerBudgetMs: 50, pollMs: 10 } });
  state.setCursor = async () => {
    throw new Error("EACCES synthetic");
  };
  await svc.ask({ botKey: "chai", text: "hi" });
  await svc.flush();
  assert.ok(logs.some((e) => e.event === "persist-error"));
});
