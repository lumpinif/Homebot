// AskService ownership over exact page sequences (BDK review B1, B2, S3), without sockets.
import { test } from "node:test";
import assert from "node:assert/strict";
import { AskService, turnCode } from "../src/core/ask.ts";
import { echoTag } from "../src/core/envelope.ts";
import { DEFAULT_SETTINGS, type Bot } from "../src/core/store.ts";
import type { Entry, Turn } from "../src/core/entries.ts";
import { scriptedBdk, IDLE, type ScriptedPage } from "../test-helpers/scripted-bdk.ts";
import { must } from "../test-helpers/must.ts";

const BOT: Bot = { key: "chai", name: "拆解师", sessionId: "1", strictEcho: true };
const PRIVATE = "a separate task's private output";
const BUSY: Turn = { idle: false, inFlight: true, queued: 0 };

type Sent = { messageId: string; text: string };
const ours = (seq: number, sent: Sent): Entry => ({ seq: String(seq), kind: "message", role: "user", text: sent.text });
const reply = (seq: number, text: string): Entry => ({ seq: String(seq), kind: "send-message", text });
// An explicit `undefined` turn means "no turn field", so no default parameters here.
const page = (entries: Entry[], ...turn: [Turn | undefined] | []): ScriptedPage => ({ entries, turn: turn.length ? turn[0] : IDLE });
const end = (...turn: [Turn | undefined] | []): ScriptedPage => ({ entries: [], turn: turn.length ? turn[0] : IDLE });

function service(script: (sent: Sent) => ScriptedPage[]) {
  const bdk = scriptedBdk(script);
  const logs: Record<string, unknown>[] = [];
  const config = { settings: { ...DEFAULT_SETTINGS, pollMs: 5, answerBudgetMs: 1000 }, bot: (k: string) => (k === BOT.key ? BOT : undefined) };
  const state = { cursor: () => ({ cursor: "100", maxSeq: "100", syncedAt: 0 }), setCursor: async () => {} };
  const svc = new AskService({ config, state, bdk, log: (e) => logs.push(e) });
  const ask = () => svc.ask({ botKey: "chai", text: "hi" });
  const log = () => must(logs.find((e) => e.event === "ask"));
  return { bdk, ask, log, logs };
}

test("B1: a replacement of the accepted reply in a later poll is never fetched or spoken", async () => {
  const { bdk, ask } = service((s) => [
    page([ours(101, s), reply(102, `${echoTag(s.messageId)} OWNED`)]),
    end(),
    page([reply(102, PRIVATE)]), // same seq, tag removed, text replaced
    end(),
  ]);
  const r = await ask();
  assert.equal(r.outcome, "answered");
  assert.equal(r.text, "OWNED");
  assert.equal(bdk.remaining(), 2, "the answer is returned at once; nothing after it is read");
});

test("B1: a replacement seen before answering is checked again and refused (O5)", async () => {
  const { ask } = service((s) => [page([ours(101, s), reply(102, `${echoTag(s.messageId)} OWNED`), reply(102, PRIVATE)]), end()]);
  const r = await ask();
  assert.equal(r.reason, "O5");
  assert.ok(!r.text.includes(PRIVATE));
});

test("B1: late O2/O3 evidence in the same observation refuses", async () => {
  {
    const { ask } = service((s) => [
      page([{ seq: "101", kind: "status" }, ours(102, s), reply(103, `${echoTag(s.messageId)} ${PRIVATE}`), { seq: "101", kind: "status", role: "user" }]),
      end(),
    ]);
    assert.equal((await ask()).reason, "O2");
  }
  {
    const { ask } = service((s) => [
      page([{ seq: "101", kind: "status" }, ours(102, s), reply(103, `${echoTag(s.messageId)} ${PRIVATE}`), { seq: "101", kind: "send-message" }]),
      end(),
    ]);
    assert.equal((await ask()).reason, "O3");
  }
});

test("B2: untagged output after the proved reply is never spoken, in the same poll or later", async () => {
  for (const split of [false, true]) {
    const { ask, logs } = service((s) => [
      page([ours(101, s), reply(102, `${echoTag(s.messageId)} OWNED`), ...(split ? [] : [reply(103, PRIVATE)])]),
      end(),
      ...(split ? [page([reply(103, PRIVATE)]), end()] : []),
    ]);
    const r = await ask();
    assert.equal(r.text, "OWNED");
    assert.ok(!JSON.stringify({ r, logs }).includes(PRIVATE));
  }
});

test("S3: missing, malformed or stuck-busy turn flags change neither ownership nor timing", async () => {
  const malformed = { idle: "yes", inFlight: "no" } as unknown as Turn; // wrong types on purpose
  for (const [turn, code] of [[undefined, "?"], [malformed, "?"], [{}, "?"], [BUSY, "B"]] as const) {
    const { ask, log } = service((s) => [end(turn), page([ours(101, s)], turn), end(turn), page([reply(102, `${echoTag(s.messageId)} OWNED`), reply(103, PRIVATE)], turn), end(turn)]);
    const t0 = Date.now();
    const r = await ask();
    assert.equal(r.text, "OWNED");
    assert.ok(Date.now() - t0 < 300, "answered as soon as the reply was proved");
    assert.equal(log().turns, code.repeat(String(log().turns).length), `trace for ${JSON.stringify(turn)}`);
    assert.ok(String(log().turns).length > 0);
  }
});

test("N1: the trace marks only a fully valid idle state as idle", () => {
  assert.equal(turnCode(IDLE), "I");
  assert.equal(turnCode(BUSY), "B");
  assert.equal(turnCode({ idle: false, inFlight: false, queued: 0 }), "B");
  assert.equal(turnCode({ idle: true, inFlight: false, queued: 3 }), "B");
  assert.equal(turnCode(undefined), "?");
  assert.equal(turnCode({}), "?");
  assert.equal(turnCode({ idle: true }), "?");
  assert.equal(turnCode({ idle: true, inFlight: "false", queued: 0 }), "?");
});

// BDK re-review R1: a page that fails after an earlier page of the same poll arrived must not
// erase what that earlier page showed.
const FAIL: ScriptedPage = { fail: true, entries: [], turn: IDLE };

test("R1: foreign input seen before a failed page still refuses (O2)", async () => {
  const { ask, log } = service((s) => [
    page([{ seq: "101", kind: "message", role: "user", text: "desktop message" }]),
    FAIL,
    page([{ seq: "101", kind: "message", text: "desktop message" }, ours(102, s), reply(103, `${echoTag(s.messageId)} ${PRIVATE}`)]),
    end(),
  ]);
  const r = await ask();
  assert.equal(r.outcome, "refused");
  assert.equal(r.reason, "O2");
  assert.ok(!r.text.includes(PRIVATE));
  assert.equal(log().poll_errors, 1);
});

test("R1: foreign output seen before a failed page still refuses (O3)", async () => {
  const { ask } = service((s) => [
    page([{ seq: "101", kind: "send-message" }]),
    FAIL,
    page([{ seq: "101", kind: "status" }, ours(102, s), reply(103, `${echoTag(s.messageId)} ${PRIVATE}`)]),
    end(),
  ]);
  const r = await ask();
  assert.equal(r.reason, "O3");
  assert.ok(!r.text.includes(PRIVATE));
});

test("R1: an untagged candidate seen before a failed page still refuses (O5)", async () => {
  const { ask } = service((s) => [
    page([ours(101, s), reply(102, PRIVATE)]),
    FAIL,
    page([ours(101, s), reply(102, `${echoTag(s.messageId)} OWNED`)]),
    end(),
  ]);
  const r = await ask();
  assert.equal(r.reason, "O5");
  assert.ok(!r.text.includes(PRIVATE) && !r.text.includes("OWNED"));
});

test("B1: a proved candidate from an incomplete poll waits for a complete one", async () => {
  // Page two fails; the unread rest holds a foreign turn. Accepting the partial poll would speak
  // a reply O2 must refuse (milestone review B1).
  const { ask } = service((s) => [
    page([ours(101, s), reply(102, `${echoTag(s.messageId)} OWNED`)]),
    FAIL,
    page([ours(101, s), reply(102, `${echoTag(s.messageId)} OWNED`), { seq: "103", kind: "message", role: "user", text: "desktop" }]),
    end(),
  ]);
  const r = await ask();
  assert.equal(r.outcome, "refused");
  assert.ok(!r.text.includes("OWNED"));
});

test("R1: a failed page alone does not stop a proved answer", async () => {
  const { ask, log } = service((s) => [page([ours(101, s)]), FAIL, page([ours(101, s), reply(102, `${echoTag(s.messageId)} OWNED`)]), end()]);
  const r = await ask();
  assert.equal(r.outcome, "answered");
  assert.equal(r.text, "OWNED");
  assert.equal(log().poll_errors, 1);
});

test("R2: an unknown error name never reaches the ask log", async () => {
  const bdk = scriptedBdk(() => []);
  const odd = new Error("x");
  odd.name = "synthetic_private_error_name";
  bdk.getEntries = async () => {
    throw odd;
  };
  const logs: Record<string, unknown>[] = [];
  const config = { settings: { ...DEFAULT_SETTINGS, pollMs: 5, answerBudgetMs: 1000 }, bot: (k: string) => (k === BOT.key ? BOT : undefined) };
  const state = { cursor: () => ({ cursor: "100", maxSeq: "100", syncedAt: 0 }), setCursor: async () => {} };
  const svc = new AskService({ config, state, bdk, log: (e) => logs.push(e) });
  const r = await svc.ask({ botKey: "chai", text: "hi" });
  assert.equal(r.outcome, "error");
  assert.ok(!JSON.stringify(logs).includes("synthetic_private_error_name"));
  assert.equal(must(logs.find((e) => e.event === "ask")).error, "other");
});

// DESIGN §18.3: diagnostics of how long a turn stays busy after its answer was returned.
function tracedService(script: (sent: Sent) => ScriptedPage[]) {
  const bdk = scriptedBdk(script);
  const logs: Record<string, unknown>[] = [];
  const config = { settings: { ...DEFAULT_SETTINGS, pollMs: 5, answerBudgetMs: 1000 }, bot: (k: string) => (k === BOT.key ? BOT : undefined) };
  const state = { cursor: () => ({ cursor: "100", maxSeq: "100", syncedAt: 0 }), setCursor: async () => {} };
  const svc = new AskService({ config, state, bdk, log: (e) => logs.push(e), traceIdle: { maxMs: 500, everyMs: 5 } });
  const tail = async () => {
    for (let i = 0; i < 200 && !logs.some((e) => e.event === "turn-tail"); i++) await new Promise((r) => setTimeout(r, 5));
    return must(logs.find((e) => e.event === "turn-tail"));
  };
  return { svc, bdk, logs, tail };
}

test("turn tail: the answer returns at once; the tail is traced until idle", async () => {
  const { svc, tail } = tracedService((s) => [
    page([ours(101, s), reply(102, `${echoTag(s.messageId)} OWNED`)], BUSY),
    end(BUSY),
    page([reply(103, "a second part")], BUSY),
    end(BUSY),
    page([{ seq: "104", kind: "message", role: "user", text: "desktop" }], BUSY),
    end(IDLE),
  ]);
  const r = await svc.ask({ botKey: "chai", text: "hi" });
  assert.equal(r.outcome, "answered");
  const t = await tail();
  assert.equal(t.outcome, "idle");
  assert.equal(t.requestId, r.requestId);
  assert.equal(typeof t.idle_after_ms, "number");
  assert.equal(t.polls, 2, "one poll per sync until the first idle sync");
  assert.deepEqual([t.deliveries, t.user_entries], [1, 1], "other activity during the tail is counted, never spoken");
});

test("turn tail: a turn that never goes idle is logged as timeout", async () => {
  const { svc, tail } = tracedService((s) => [page([ours(101, s), reply(102, `${echoTag(s.messageId)} OWNED`)], BUSY), end(BUSY)]);
  await svc.ask({ botKey: "chai", text: "hi" });
  const t = await tail();
  assert.equal(t.outcome, "timeout");
  assert.equal(t.idle_after_ms, undefined);
});

test("turn tail: a new request for the session stops the trace", async () => {
  const { svc, tail } = tracedService((s) => [page([ours(101, s), reply(102, `${echoTag(s.messageId)} OWNED`)], BUSY), end(BUSY)]);
  await svc.ask({ botKey: "chai", text: "hi" });
  void svc.ask({ botKey: "chai", text: "again" });
  assert.equal((await tail()).outcome, "superseded");
  svc.stop();
});
