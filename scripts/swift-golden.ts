// Writes the golden fixtures the Swift port (mac/) is checked against: the TypeScript output for
// the same inputs. Shortcut XML uses deterministic UUIDs (a counter), so the Swift builder must
// produce the same bytes; the JSON holds catalog, envelope, phrase, speech and naming results.
// Usage: node scripts/swift-golden.ts mac/Tests/HomebotCoreTests/Fixtures
import crypto from "node:crypto";
import { syncBuiltinESMExports } from "node:module";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

let counter = 0;
const nextUuid = (): `${string}-${string}-${string}-${string}-${string}` => {
  counter++;
  return `00000000-0000-4000-8000-${counter.toString(16).padStart(12, "0")}`;
};
// build.ts imports randomUUID from node:crypto; make that import see the counter.
crypto.randomUUID = nextUuid;
syncBuiltinESMExports();

const { toXmlPlist } = await import("../src/shortcut/plist.ts");
const { buildAskShortcut, buildProbeShortcut, buildLabShortcut, buildConversationShortcut } = await import("../src/shortcut/build.ts");
const { shortcutProfile, takenPhrases } = await import("../src/shortcut/profile.ts");
const { safeFileName } = await import("../src/shortcut/make.ts");
const { messages, LANGS } = await import("../src/core/i18n.ts");
const { buildEnvelope } = await import("../src/core/envelope.ts");
const { END_WORDS } = await import("../src/core/conversation.ts");
const { PROBE_TEXT, PROBE_STEPS } = await import("../src/server/voice.ts");
const { LANGUAGES, SIRI_OPTIONS, heySiri, langOfSiri, replyLang } = await import("../src/core/lang.ts");
const { sanitize, truncate, speakable } = await import("../src/core/speech.ts");
const { labelKey } = await import("../src/core/tokens.ts");
const { DEFAULT_SETTINGS } = await import("../src/core/store.ts");

const dir = process.argv[2];
if (!dir) throw new Error("usage: node scripts/swift-golden.ts <fixtures dir>");
mkdirSync(dir, { recursive: true });

// --- Shortcuts ------------------------------------------------------------------------------
const shortcuts: Record<string, () => unknown> = {
  "ask-en": () => buildAskShortcut({ baseUrl: "http://felix-mac.local:8787/ignored", botKey: "chai", token: "TOKEN-en", prompt: "What would you like to ask Chai?", speakLang: "en-US" }),
  "ask-zh": () => buildAskShortcut({ baseUrl: "http://felix-mac.local:8787", botKey: "homebot", token: "TOKEN-zh", prompt: "想问拆解师什么？", speakLang: "zh-CN" }),
  "ask-escaping": () => buildAskShortcut({ baseUrl: "https://192.168.1.20:8787", botKey: "kitchen-bot", token: "a&b<c>d\"e'f", prompt: "Q & <A> \"quoted\" 'single' é 😀", speakLang: "fr-FR" }),
  "probe-en": () => buildProbeShortcut({ baseUrl: "http://mac.local:8787", token: "TOKEN-probe", speakLang: "en-GB" }),
  "lab-zh": () => buildLabShortcut({ baseUrl: "http://mac.local:8787/x", token: "TOKEN-lab", speakLang: "zh-CN" }),
  "conversation-zh": () => buildConversationShortcut({ baseUrl: "http://felix-mac.local:8787", botKey: "chai", token: "TOKEN-conv", prompt: "想问拆解师什么？", speakLang: "zh-CN" }),
  "conversation-ja": () => buildConversationShortcut({ baseUrl: "http://mac.local:80", botKey: "b", token: "T", prompt: "何を聞きますか？", speakLang: "ja-JP" }),
};
for (const [name, build] of Object.entries(shortcuts)) {
  counter = 0;
  writeFileSync(join(dir, `${name}.plist`), toXmlPlist(build()));
}

// --- JSON dump ------------------------------------------------------------------------------
const BOTS = ["Chai", "拆解师", "homebot"];
const msg = Object.fromEntries(
  LANGS.map((l) => {
    const m = messages(l);
    const out: Record<string, string> = {};
    for (const [k, f] of Object.entries(m)) out[k] = (f as (b: string) => string)("拆解师");
    out["busy:Chai"] = m.busy("Chai");
    return [l, out];
  }),
);

const envelopes: Record<string, string> = {};
for (const l of LANGS) {
  envelopes[`${l}|strict`] = buildEnvelope({ id: "abc123abc123", text: "今天天气？", lang: l, strictEcho: true });
  envelopes[`${l}|plain|test|custom`] = buildEnvelope({ id: "x", text: "hi", lang: l, strictEcho: false, test: true, style: "Be brief." });
  envelopes[`${l}|nostyle`] = buildEnvelope({ id: "x", text: "hi", lang: l, strictEcho: true, style: null });
  envelopes[`${l}|turn3`] = buildEnvelope({ id: "abc", text: "and after", lang: l, strictEcho: true, turn: 3 });
}

const probe: Record<string, string[]> = {};
const ns = [...PROBE_STEPS, 1, 2, 3, 4, 11, 12, 14, 21, 22, 25, 101, 111, 112];
for (const l of LANGS) probe[l] = ns.map((n) => PROBE_TEXT[l](n));

const NAMES = ["家庭助手", "homebot 你好", "家庭助手2", "家庭助手！", "问拆解师", "问问homebot", "Homebot", "Kitchen Bot", "Ask Chai", "打开助手", "Asking Chai", "家庭助手 bot", "Home Bot 2",
  "house butler", "Grok Bot", "问问Grok Bot", "Grok Bot助手", "a/b", ".hidden", "back\\slash", "mayordomo", "pregunta algo", "majordome", "Demande X", "Hausgeist", "frag mal", "maggiordomo", "mordomo", "o que é", "домовой", "спроси бота", "うち助手", "聞いてみて", "집비서", "물어봐 봐", "居家助理", "問拆解師", "Ünïcödé Name", "l'assistant", "half-way", "  spaced   out  "];
const profiles: unknown[] = [];
for (const { code } of [...SIRI_OPTIONS, { code: "en-GB" }]) {
  for (const botName of BOTS) {
    for (const phoneLang of botName === "Chai" ? Object.keys(LANGUAGES) : ["en"]) {
      const p = shortcutProfile({ botName, siriLang: code, phoneLang });
      profiles.push({ siriLang: code, botName, phoneLang, name: p.name, prompt: p.prompt, speakLang: p.speakLang, replyLang: p.replyLang, probeName: p.probeName, labName: p.labName, alternatives: p.alternatives, problems: p.problems, steps: p.steps("mac.local"), stepsNamed: p.steps("mac.local", "Test Phrase") });
    }
  }
  for (const name of NAMES) {
    const p = shortcutProfile({ botName: "homebot", siriLang: code, name: name.trim() ? name : "x" });
    profiles.push({ siriLang: code, botName: "homebot", name: p.name, given: name, problems: p.problems, alternatives: p.alternatives });
  }
  const taken = shortcutProfile({ botName: "homebot", siriLang: code, taken: ["家庭助手", "Grok Bot", "My Grok Bot", "mayordomo"] });
  profiles.push({ siriLang: code, botName: "homebot", taken: true, name: taken.name, alternatives: taken.alternatives, problems: taken.problems });
  for (const keep of ["Call Butler", "homebot 你好", "家庭助手", "Hausgeist", "  "]) {
    const k = shortcutProfile({ botName: "homebot", siriLang: code, keep });
    profiles.push({ siriLang: code, botName: "homebot", keep, name: k.name, alternatives: k.alternatives, problems: k.problems });
  }
}

const SPEECH = ["# 标题\n- 第一点 **重要**\n1. 第二点 [链接](https://x.y)\n```js\ncode()\n```\n看 `ls` 和 https://a.b/c 😀👍🏽", "**Hi.** There is more text here.", "**Hello there.** More text here.",
  "![img](http://x/y.png) caption > quote\n> block\n  12. item\n+ plus", "a b c﻿d\u000be", "第一句话很长。第二句话也很长。第三句", "没有标点的一段很长的文字内容", "𠀀𠀀𠀀𠀀", "Hi 👨‍👩‍👧 family ❤️ love", "x|y~z_w*v", "Short."];
const speech = SPEECH.map((s) => ({ input: s, sanitized: sanitize(s), t6: truncate(sanitize(s), 6), t10: speakable(s, 10), t16: speakable(s, 16), t3: truncate(s, 3) }));

const labels = ["  House  BUTLER ", "家庭助手".normalize("NFD"), "Ünïcödé\tName", "ÉCOLE", "İstanbul", "ß"].map((s) => ({ input: s, key: labelKey(s) }));
const fileNames = ["家庭助手", "a/b\\c:d", "..hidden", " . lead", "\u0001ctl\u007f", "x".repeat(70), "😀".repeat(61), "", "   ", "Ask Chai's \"bot\""].map((s) => ({ input: s, safe: safeFileName(s) }));
const lang = {
  siriOptions: SIRI_OPTIONS,
  langOfSiri: Object.fromEntries(["en-US", "en-GB", "zh-CN", "zh-TW", "nl-NL", "", "ja-JP"].map((s) => [s, langOfSiri(s)])),
  replyLang: Object.fromEntries(["en-US", "en-ZA", "zh-CN", "pt-BR", "ko-KR", "xx"].map((s) => [s, replyLang(s)])),
  hey: Object.fromEntries(SIRI_OPTIONS.map((o) => [o.code, heySiri(o.code, "NAME")])),
};
const taken = takenPhrases([{ id: "a", label: "家庭助手", state: "active" }, { id: "b", label: "我家助手", state: "pending" }, { id: "c", label: "居家助手", state: "retired" }, { id: "d", label: "家庭等待测试", state: "pending" }, { id: "e", label: "Homebot", state: "active" }]);

writeFileSync(join(dir, "ts-golden.json"), JSON.stringify({ messages: msg, envelopes, endWords: END_WORDS, probe: { ns, text: probe }, profiles, speech, labels, fileNames, lang, taken, maxSpokenChars: DEFAULT_SETTINGS.maxSpokenChars }) + "\n");
console.log(`wrote ${Object.keys(shortcuts).length} Shortcuts and ts-golden.json to ${dir}`);
