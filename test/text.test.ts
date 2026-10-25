import { test } from "node:test";
import assert from "node:assert/strict";
import { buildEnvelope, newRequestId, echoTag, requestMarker } from "../src/core/envelope.ts";
import { sanitize, truncate, speakable } from "../src/core/speech.ts";

test("request ids are 12 hex chars and unique", () => {
  const a = newRequestId();
  assert.match(a, /^[0-9a-f]{12}$/);
  assert.notEqual(a, newRequestId());
});

test("envelope: marker line, question, echo instruction", () => {
  const e = buildEnvelope({ id: "abc123abc123", text: "今天天气？", lang: "zh-CN", strictEcho: true });
  const lines = e.split("\n");
  assert.equal(lines[0], "[Homebot voice · hb:abc123abc123 · zh-CN]");
  assert.equal(lines[1], "今天天气？");
  assert.ok(e.includes(echoTag("abc123abc123")));
  assert.ok(e.includes(requestMarker("abc123abc123")));
});

test("envelope: test mode, english, no echo, custom and disabled style", () => {
  const e = buildEnvelope({ id: "x", text: "hi", lang: "en", strictEcho: false, test: true, style: "Be brief." });
  assert.ok(e.startsWith("[Homebot test · hb:x · en]\nhi\n"));
  assert.ok(!e.includes("[hb:x]"));
  assert.ok(e.includes("Be brief."));
  const n = buildEnvelope({ id: "x", text: "hi", lang: "en", strictEcho: false, style: null });
  assert.ok(!n.includes("1-3 short"));
});

test("sanitize strips markdown, code, links, emoji and list markers", () => {
  const s = sanitize("# 标题\n- 第一点 **重要**\n1. 第二点 [链接](https://x.y)\n```js\ncode()\n```\n看 `ls` 和 https://a.b/c 😀👍🏽");
  assert.equal(s, "标题 第一点 重要 第二点 链接 看 ls 和");
});

test("truncate cuts at a sentence boundary and adds an ellipsis", () => {
  assert.equal(truncate("短句。", 10), "短句。");
  assert.equal(truncate("第一句话很长。第二句话也很长。第三句", 16), "第一句话很长。第二句话也很长。…");
  assert.equal(truncate("没有标点的一段很长的文字内容", 6), "没有标点的一…");
});

test("truncate counts code points, not UTF-16 units", () => {
  assert.equal(truncate("𠀀𠀀𠀀", 3), "𠀀𠀀𠀀");
});

test("speakable combines both; an early boundary is not used", () => {
  assert.equal(speakable("**Hi.** There is more text here.", 10), "Hi. There…");
  assert.equal(speakable("**Hello there.** More text here.", 16), "Hello there.…");
});
