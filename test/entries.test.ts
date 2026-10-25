import { test } from "node:test";
import assert from "node:assert/strict";
import { syncToEnd, decideReply, HistoryTooLongError, type Decision, type Entry, type Page } from "../src/core/entries.ts";
import { buildEnvelope, echoTag } from "../src/core/envelope.ts";

// --- syncToEnd ---------------------------------------------------------------

interface SeqEntry extends Entry {
  updatedSeq: string;
}

/** Fake paged store: entries ordered by updatedSeq, 200 per page, like the real API. */
function pagedStore(entries: SeqEntry[], pageSize = 200) {
  const calls: string[] = [];
  const fetchPage = async (cursor: string): Promise<Page> => {
    calls.push(cursor);
    const after = entries.filter((e) => BigInt(e.updatedSeq) > BigInt(cursor)).slice(0, pageSize);
    return {
      entries: after,
      latestUpdatedSeq: after.at(-1)?.updatedSeq ?? cursor,
      turn: { idle: true },
    };
  };
  return { fetchPage, calls };
}
const mk = (n: number): SeqEntry[] => Array.from({ length: n }, (_, i) => ({ seq: String(i + 1), updatedSeq: String(i + 1), kind: "message", role: "user", text: `m${i + 1}` }));

test("syncToEnd walks past the first 200-entry page to the real end", async () => {
  const { fetchPage, calls } = pagedStore(mk(450));
  const r = await syncToEnd(fetchPage, { cursor: "-1" });
  assert.equal(r.cursor, "450");
  assert.equal(r.maxSeq, "450");
  assert.equal(r.entries.length, 450);
  assert.deepEqual(calls, ["-1", "200", "400", "450"]);
});

test("syncToEnd handles exactly 200 entries and an empty session", async () => {
  const a = await syncToEnd(pagedStore(mk(200)).fetchPage, { cursor: "-1" });
  assert.equal(a.cursor, "200");
  const b = await syncToEnd(pagedStore([]).fetchPage, { cursor: "-1" });
  assert.equal(b.cursor, "-1");
  assert.equal(b.maxSeq, "-1");
});

test("syncToEnd keeps the cursor on an empty page and resumes from a warm cursor", async () => {
  const { fetchPage, calls } = pagedStore(mk(10));
  const r = await syncToEnd(fetchPage, { cursor: "10", maxSeq: "10" });
  assert.equal(r.cursor, "10");
  assert.equal(r.maxSeq, "10");
  assert.deepEqual(calls, ["10"]);
});

test("syncToEnd tracks max creation seq even when old entries are re-updated", async () => {
  const entries = [...mk(5), { seq: "2", updatedSeq: "6", kind: "send-message" }];
  const r = await syncToEnd(pagedStore(entries).fetchPage, { cursor: "5", maxSeq: "5" });
  assert.equal(r.cursor, "6");
  assert.equal(r.maxSeq, "5");
});

test("syncToEnd fails clearly when the history exceeds the page cap", async () => {
  await assert.rejects(syncToEnd(pagedStore(mk(450)).fetchPage, { cursor: "-1", maxPages: 2 }), HistoryTooLongError);
});

// --- decideReply ---------------------------------------------------------------

const ID = "a1b2c3d4e5f6";
const base = { baseMaxSeq: "100", requestId: ID, strictEcho: true };
const ours = (seq: number): Entry => ({ seq: String(seq), kind: "message", role: "user", text: buildEnvelope({ id: ID, text: "几点了", lang: "zh-CN", strictEcho: true }) });
const desktop = (seq: number, text = "桌面消息"): Entry => ({ seq: String(seq), kind: "message", role: "user", text });
const bot = (seq: number, text: string): Entry => ({ seq: String(seq), kind: "send-message", text });
const PRIVATE = "这是给桌面的私密回复";
const reasonOf = (d: Decision) => (d.status === "refuse" ? d.reason : undefined);
const textOf = (d: Decision) => (d.status === "accept" ? d.text : undefined);

test("accepts the first echoed reply after our message and strips the tag", () => {
  const d = decideReply([ours(101), bot(102, `${echoTag(ID)} 现在三点。`)], base);
  assert.deepEqual(d, { status: "accept", text: "现在三点。", userSeq: "101", replySeq: "102" });
});

test("waits until our entry and a text reply exist", () => {
  assert.equal(decideReply([], base).status, "waiting");
  assert.equal(decideReply([ours(101)], base).status, "waiting");
  assert.equal(decideReply([ours(101), { seq: "102", kind: "send-message" }], base).status, "waiting"); // attachment-only
});

test("O2: refuses when a desktop message lands between the idle check and our send", () => {
  const d = decideReply([desktop(101), ours(102), bot(103, PRIVATE), bot(104, `${echoTag(ID)} 三点`)], base);
  assert.equal(d.status, "refuse");
  assert.equal(reasonOf(d), "O2");
  assert.ok(!("text" in d));
});

test("O2: refuses when a desktop message lands after ours, before the reply", () => {
  const d = decideReply([ours(101), desktop(102), bot(103, `${echoTag(ID)} ${PRIVATE}`)], base);
  assert.equal(reasonOf(d), "O2");
  assert.ok(!JSON.stringify(d).includes(PRIVATE));
});

test("O2: a foreign user entry refuses even before our own entry shows up", () => {
  assert.equal(reasonOf(decideReply([desktop(101)], base)), "O2");
});

test("O2: unknown kinds with role user count as foreign input", () => {
  assert.equal(reasonOf(decideReply([ours(101), { seq: "102", kind: "voice-note", role: "user" }, bot(103, `${echoTag(ID)} x`)], base)), "O2");
});

test("O3: refuses bot output between the baseline and our message", () => {
  const d = decideReply([bot(101, PRIVATE), ours(102), bot(103, `${echoTag(ID)} 三点`)], base);
  assert.equal(reasonOf(d), "O3");
});

test("O5: strict mode refuses a reply without the echo tag; non-strict accepts it", () => {
  const seen = [ours(101), bot(102, PRIVATE)];
  const d = decideReply(seen, base);
  assert.equal(reasonOf(d), "O5");
  assert.ok(!JSON.stringify(d).includes(PRIVATE));
  assert.equal(decideReply(seen, { ...base, strictEcho: false }).status, "accept");
});

test("O5: an echo tag buried deep in the text does not count", () => {
  const d = decideReply([ours(101), bot(102, `${"x".repeat(60)} ${echoTag(ID)}`)], base);
  assert.equal(reasonOf(d), "O5");
});

test("O5: another request's tag does not count", () => {
  assert.equal(reasonOf(decideReply([ours(101), bot(102, "[hb:ffffffffffff] hi")], base)), "O5");
});

test("ignores re-updated old entries at or below the baseline", () => {
  const d = decideReply([desktop(50), bot(99, PRIVATE), ours(101), bot(102, `${echoTag(ID)} 好`)], base);
  assert.equal(d.status, "accept");
  assert.equal(textOf(d), "好");
});

test("answer text comes from the latest non-empty version", () => {
  const d = decideReply([ours(101), bot(102, ""), bot(102, `${echoTag(ID)} 完整回答`)], base);
  assert.equal(textOf(d), "完整回答");
  const e = decideReply([ours(101), bot(102, `${echoTag(ID)} 第一版`), bot(102, "")], base);
  assert.equal(textOf(e), "第一版", "a later textless re-update does not hide the answer");
});

test("BDK review B1: an untagged re-update of the accepted reply is refused, not spoken", () => {
  const d = decideReply([ours(101), bot(102, `${echoTag(ID)} OWNED`), bot(102, PRIVATE)], base);
  assert.equal(reasonOf(d), "O5");
  assert.ok(!JSON.stringify(d).includes(PRIVATE));
});

test("BDK review B2: only the first proved delivery is the answer; later untagged output is not", () => {
  const d = decideReply([ours(101), bot(102, `${echoTag(ID)} OWNED`), bot(103, PRIVATE)], base);
  assert.equal(textOf(d), "OWNED");
});

test("B4: a textless re-update never erases foreign-output evidence (O3)", () => {
  // baseline 100, foreign output 101, ours 102, tagged reply 103, then 101 re-updated without text
  const seen = [bot(101, PRIVATE), ours(102), bot(103, `${echoTag(ID)} ${PRIVATE}`), { seq: "101", kind: "send-message" }];
  const d = decideReply(seen, base);
  assert.equal(d.status, "refuse");
  assert.equal(reasonOf(d), "O3");
  assert.ok(!JSON.stringify(d).includes(PRIVATE));
});

test("B4: foreign output already textless when first seen is still foreign output (O3)", () => {
  const seen = [{ seq: "101", kind: "send-message" }, ours(102), bot(103, `${echoTag(ID)} 好`)];
  assert.equal(reasonOf(decideReply(seen, base)), "O3");
});

test("B4: a re-update that drops role:user never erases foreign-input evidence (O2)", () => {
  const seen = [desktop(101), ours(102), bot(103, `${echoTag(ID)} 好`), { seq: "101", kind: "message" }];
  assert.equal(reasonOf(decideReply(seen, base)), "O2");
});

test("compares seqs numerically, not as strings", () => {
  const d = decideReply([ours(1000), bot(999, PRIVATE)], { ...base, baseMaxSeq: "998" });
  assert.equal(reasonOf(d), "O3");
});
