import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, writeFile, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { toXmlPlist } from "../src/shortcut/plist.ts";
import { buildAskShortcut, buildProbeShortcut } from "../src/shortcut/build.ts";
import { keptPhrase, shortcutProfile, takenPhrases } from "../src/shortcut/profile.ts";
import { LANGUAGES, SIRI_OPTIONS, heySiri, langOfSiri, replyLang } from "../src/core/lang.ts";
import { buildEnvelope } from "../src/core/envelope.ts";
import { END_WORDS } from "../src/core/conversation.ts";
import { signShortcut, UMASK_LAUNCHER } from "../src/shortcut/sign.ts";
import { must } from "../test-helpers/must.ts";

// The plist shapes build.ts writes (its text/output/dict helpers). Action parameters are typed
// `unknown` there, so tests view them through these shapes to inspect them.
interface TextToken {
  Value: { string: string; attachmentsByRange?: Record<string, { OutputUUID: string }> };
}
interface DictField {
  Value: { WFDictionaryFieldValueItems: { WFKey: TextToken; WFValue: TextToken }[] };
}
const dictOf = (v: unknown) => Object.fromEntries((v as DictField).Value.WFDictionaryFieldValueItems.map((i) => [i.WFKey.Value.string, i.WFValue]));
const outputUuid = (v: unknown) => must((v as TextToken | undefined)?.Value.attachmentsByRange?.["{0, 1}"]).OutputUUID;

const run = promisify(execFile);
const isMac = process.platform === "darwin";

test("plist: types, escaping, empty containers, rejects what it can't encode", () => {
  const xml = toXmlPlist({ s: "a<b>&c", n: 5, t: true, f: false, a: [], d: {}, nested: [{ k: "v" }], skip: undefined });
  assert.match(xml, /<key>s<\/key>\n\t<string>a&lt;b&gt;&amp;c<\/string>/);
  assert.match(xml, /<integer>5<\/integer>/);
  assert.match(xml, /<true\/>/);
  assert.match(xml, /<false\/>/);
  assert.match(xml, /<array\/>/);
  assert.match(xml, /<dict\/>/);
  assert.ok(!xml.includes("skip"));
  assert.throws(() => toXmlPlist({ x: 1.5 }), /safe integers/);
  assert.throws(() => toXmlPlist({ x: null }), /null/);
  assert.throws(() => toXmlPlist({ x: "bad\u0001" }), /XML cannot represent/);
});

test("profile: English is the default; Siri language drives name, prompt, voice", () => {
  const en = shortcutProfile({ botName: "Chai" });
  assert.equal(en.siriLang, "en-US");
  assert.equal(en.name, "Grok Bot", "a product phrase first (DESIGN §16, Q16-1)");
  assert.deepEqual(en.alternatives, ["My Grok Bot", "Our Grok Bot", "Chai"], "the bot's own name is offered when it fits");
  assert.equal(en.prompt, "What would you like to ask Grok Bot?", "the phrase, never the bot (S25)");
  assert.equal(en.speakLang, "en-US");
  assert.equal(en.replyLang, "en");
  assert.deepEqual(en.problems, []);
  const gb = shortcutProfile({ botName: "Chai", siriLang: "en-GB" });
  assert.equal(gb.speakLang, "en-GB");
});

test("profile: Felix's setup — iPhone English, Siri Chinese", () => {
  const p = shortcutProfile({ botName: "homebot", siriLang: "zh-CN", phoneLang: "en" });
  assert.equal(p.name, "Grok Bot", "the default in every language; Felix's Chinese Siri ran it (DECISIONS item 33)");
  assert.equal(p.prompt, "想问Grok Bot什么？", "the phrase the user says, not the bot \"homebot\" (S25)");
  assert.equal(p.speakLang, "zh-CN");
  assert.equal(p.replyLang, "zh-CN");
  assert.deepEqual(p.alternatives, ["我的 Grok Bot", "家庭助手", "我家助手"], "native names are suggestions; the bot \"homebot\" is not");
  assert.deepEqual(p.problems, []);
  assert.match(p.steps("mac.local").join("\n"), /Allow Running When Locked/, "setup steps in the iPhone's language");
  const zhPhone = shortcutProfile({ botName: "homebot", siriLang: "zh-CN", phoneLang: "zh-Hans" });
  assert.match(zhPhone.steps("mac.local").join("\n"), /锁定时允许运行/);
  assert.match(zhPhone.steps("mac.local", "家庭等待测试").join("\n"), /轻点“家庭等待测试”/, "steps name the Shortcut actually built");
});

test("profile: script, digits and first words are advice; unsafe names and phrases in use block (DESIGN §16.2)", () => {
  const han = shortcutProfile({ botName: "拆解师", siriLang: "zh-CN" });
  assert.equal(han.name, "Grok Bot");
  assert.equal(han.prompt, "想问Grok Bot什么？", "the phrase, not the bot");
  assert.equal(shortcutProfile({ botName: "拆解师", siriLang: "zh-CN", name: "homebot 你好" }).prompt, "想问什么？", "a phrase with advice is left out of the question");
  assert.deepEqual(han.alternatives, ["我的 Grok Bot", "家庭助手", "我家助手", "拆解师"]);
  const codes = (name: string, siriLang = "zh-CN", taken: string[] = []) => shortcutProfile({ botName: "homebot", siriLang, name, taken }).problems.map((p) => (p.blocking ? p.code : `${p.code}?`));
  assert.deepEqual(codes("家庭助手"), []);
  assert.deepEqual(codes("homebot 你好"), ["wrong-script?"]);
  assert.deepEqual(codes("家庭助手2"), ["wrong-script?"], "digits are advice");
  assert.deepEqual(codes("家庭助手！"), ["wrong-script?"], "symbols are advice");
  assert.deepEqual(codes("问拆解师"), ["search-start?"], "strong advice: a device failure (DECISIONS item 12)");
  assert.deepEqual(codes("问问homebot"), ["wrong-script?", "search-start?"]);
  assert.deepEqual(codes("Grok Bot"), [], "the brand is fine in every language (DECISIONS item 33)");
  for (const siriLang of ["zh-CN", "zh-TW", "ja-JP", "ko-KR", "ru-RU", "de-DE", "fr-FR", "es-ES", "it-IT", "pt-BR", "en-US"]) {
    assert.deepEqual(codes("Grok Bot", siriLang), [], siriLang);
    assert.deepEqual(codes("grok bot", siriLang), [], `${siriLang}: any case`);
  }
  assert.deepEqual(codes("我的 Grok Bot"), []);
  assert.deepEqual(codes("Grok Bot助手"), [], "a native word next to the brand is fine");
  assert.deepEqual(codes("うちの Grok Bot", "ja-JP"), []);
  assert.deepEqual(codes("мой Grok Bot", "ru-RU"), []);
  assert.deepEqual(codes("问 Grok Bot"), ["search-start?"], "a leading 问 is still a device failure (DECISIONS item 12)");
  assert.deepEqual(codes("Grok Bot 2", "en-US"), ["wrong-script?"], "digits are still advice");
  assert.deepEqual(codes("Grok Bot homebot"), ["wrong-script?"], "other Latin words still are, in Chinese");
  assert.deepEqual(codes("a/b", "en-US"), ["wrong-script?", "unsafe-chars"], "a name iOS would change blocks");
  assert.deepEqual(codes(".hidden", "en-US"), ["wrong-script?", "unsafe-chars"]);
  assert.deepEqual(codes("问问Grok Bot", "zh-CN", ["问问grok bot"]), ["search-start?", "in-use"], "uniqueness stays hard");
  assert.deepEqual(codes("Homebot", "en-US"), []);
  assert.deepEqual(codes("Kitchen Bot", "en-US"), []);
  assert.deepEqual(codes("Ask Chai", "en-US"), ["bad-start?"], "advice only: no device evidence yet");
  assert.deepEqual(codes("打开助手"), ["bad-start?"]);
  assert.deepEqual(codes("Asking Chai", "en-US"), [], "only whole first words count in English");
  assert.deepEqual(codes("家庭助手 bot", "en-US"), ["wrong-script?"]);
  assert.deepEqual(codes("Home Bot 2", "en-US"), ["wrong-script?"]);
  assert.deepEqual(codes("house butler", "en-US", ["House  Butler"]), ["in-use"], "case and spaces don't make a phrase different");
  assert.deepEqual(codes("家庭助手", "zh-CN", ["家庭助手".normalize("NFD")]), ["in-use"], "Unicode forms are compared normalized");
  const taken = shortcutProfile({ botName: "homebot", siriLang: "zh-CN", taken: ["Grok Bot"] });
  assert.equal(taken.name, "我的 Grok Bot", "the default skips phrases in use, in any language");
  assert.deepEqual(taken.alternatives, ["家庭助手", "我家助手"]);
  assert.deepEqual(shortcutProfile({ botName: "Home Bot", siriLang: "en-US" }).alternatives, ["My Grok Bot", "Our Grok Bot"], "a bot named like the app is never suggested");
  assert.deepEqual(shortcutProfile({ botName: "Chai", siriLang: "en-US" }).alternatives, ["My Grok Bot", "Our Grok Bot", "Chai"]);
});

test("takenPhrases: every usable Homebot Shortcut on the phone, minus the one replaced", () => {
  const t = (id: string, label: string, state: string) => ({ id, label, state });
  const list = [t("a", "家庭助手", "active"), t("b", "我家助手", "pending"), t("c", "居家助手", "retired"), t("d", "家庭等待测试", "pending"), t("e", "Homebot", "active")];
  assert.deepEqual(takenPhrases(list), ["家庭助手", "我家助手", "家庭等待测试", "Homebot"], "test Shortcuts and other languages count too");
  assert.deepEqual(takenPhrases(list, "a"), ["我家助手", "家庭等待测试", "Homebot"]);
});

test("every Siri language: same options as the iPhone menu, a valid default phrase, a prompt, its own envelope", () => {
  assert.deepEqual(SIRI_OPTIONS.map((o) => o.label), Object.values(LANGUAGES).map((l) => l.name), "same names, same order");
  for (const { code } of SIRI_OPTIONS) {
    const p = shortcutProfile({ botName: "Chai", siriLang: code });
    assert.deepEqual(p.problems, [], `${code}: default phrase "${p.name}" passes its own rules`);
    assert.ok(p.alternatives.length >= 1, `${code}: has alternatives`);
    assert.equal(p.speakLang, code, `${code}: Speak Text voice`);
    assert.ok(p.prompt.includes(p.name) && !p.prompt.includes("Chai"), `${code}: prompt names the phrase, never the bot (S25)`);
    assert.equal(p.name, "Grok Bot", `${code}: the default in every language (DECISIONS item 33)`);
    assert.ok(p.alternatives.some((a) => a !== "Grok Bot" && /Grok Bot/.test(a)), `${code}: a "my Grok Bot" form`);
    assert.ok(p.alternatives.some((a) => !/Grok/.test(a)) || code.startsWith("en"), `${code}: a native name`);
    assert.ok(heySiri(code, p.name).includes(p.name));
    const env = buildEnvelope({ id: "abc", text: "q", lang: replyLang(code), strictEcho: true });
    assert.ok(env.includes("[hb:abc]"), `${code}: echo tag requested`);
    assert.ok(END_WORDS[replyLang(code)].length >= 4, `${code}: end words`);
  }
  assert.equal(langOfSiri("en-GB"), "en", "older English variants still map to English");
  assert.equal(shortcutProfile({ botName: "Chai", siriLang: "en-GB" }).speakLang, "en-GB", "and keep their voice");
});

test("profile: custom name, validation", () => {
  assert.equal(shortcutProfile({ botName: "Chai", name: "  Chai Voice " }).name, "Chai Voice");
  assert.throws(() => shortcutProfile({ botName: "x", siriLang: "nl-NL" }), /Siri language/);
  assert.throws(() => shortcutProfile({ botName: "x", phoneLang: "xx" }), /iPhone language/);
  assert.throws(() => shortcutProfile({ botName: "x", name: "  " }), /1-60/);
});

test("profile: every iPhone language has the five steps, naming the Shortcut and the gateway", () => {
  for (const phoneLang of Object.keys(LANGUAGES)) {
    const steps = shortcutProfile({ botName: "homebot", phoneLang }).steps("mac.local", "Test Phrase");
    assert.equal(steps.length, 5, phoneLang);
    assert.ok(steps[1]?.includes("Test Phrase") && steps[1].includes("mac.local"), `${phoneLang}: step 2 names the Shortcut and host`);
    assert.ok(steps[4]?.includes("Test Phrase"), `${phoneLang}: step 5 says the phrase`);
    assert.ok(!steps.join("").includes("${"), `${phoneLang}: no unfilled placeholder`);
  }
});

test("ask Shortcut: three actions wired by UUID, token header, JSON body, speech language", () => {
  const w = buildAskShortcut({ baseUrl: "http://mac.local:8787/ignored/path", botKey: "chai", token: "TOKEN", prompt: "Q?", speakLang: "zh-CN" });
  const [ask, dl, speak] = w.WFWorkflowActions.map((a) => a.WFWorkflowActionParameters);
  assert.deepEqual(w.WFWorkflowActions.map((a) => a.WFWorkflowActionIdentifier), [
    "is.workflow.actions.ask",
    "is.workflow.actions.downloadurl",
    "is.workflow.actions.speaktext",
  ]);
  const p = must(dl);
  assert.equal(p.WFURL, "http://mac.local:8787/v1/ask");
  assert.equal(p.WFHTTPMethod, "POST");
  assert.equal(p.WFHTTPBodyType, "JSON");
  const headers = dictOf(p.WFHTTPHeaders);
  assert.equal(must(headers["X-Homebot-Token"]).Value.string, "TOKEN");
  const body = dictOf(p.WFJSONValues);
  assert.equal(must(body.bot).Value.string, "chai");
  assert.equal(outputUuid(body.text), must(ask).UUID);
  assert.equal(outputUuid(must(speak).WFText), p.UUID);
  assert.equal(must(speak).WFSpeakTextLanguage, "zh-CN");
  assert.equal(must(speak).WFSpeakTextWait, true);
  assert.equal(must(ask).WFInputType, "Text");
  assert.throws(() => buildAskShortcut({ baseUrl: "file:///x", botKey: "b", token: "t", prompt: "q", speakLang: "en-US" }), /http/);
});

test("probe Shortcut: GET /v1/probe-wait with token, then speak", () => {
  const w = buildProbeShortcut({ baseUrl: "http://mac.local:8787", token: "T", speakLang: "en-US" });
  const [dl, speak] = w.WFWorkflowActions;
  assert.equal(must(dl).WFWorkflowActionParameters.WFURL, "http://mac.local:8787/v1/probe-wait");
  assert.equal(must(dl).WFWorkflowActionParameters.WFHTTPMethod, "GET");
  assert.equal(must(speak).WFWorkflowActionIdentifier, "is.workflow.actions.speaktext");
});

test("generated Shortcut XML passes plutil -lint (macOS only)", { skip: !isMac && "plutil is macOS-only" }, async () => {
  const dir = await mkdtemp(join(tmpdir(), "homebot-test-"));
  const file = join(dir, "x.shortcut");
  const p = shortcutProfile({ botName: "拆解师 & <Co>", siriLang: "zh-CN" });
  await writeFile(file, toXmlPlist(buildAskShortcut({ baseUrl: "http://mac.local:8787", botKey: "chai", token: "t", prompt: p.prompt, speakLang: p.speakLang })));
  const { stdout } = await run("plutil", ["-lint", file]);
  assert.match(stdout, /OK/);
});

test("signer: retries with backoff and alternates modes; argument array only", async () => {
  const calls: string[][] = [];
  const waits: number[] = [];
  let n = 0;
  const r = await signShortcut({
    input: "/tmp/in",
    output: "/tmp/out",
    run: async (cmd, args) => {
      calls.push([cmd, ...args]);
      if (++n < 3) throw Object.assign(new Error("HTTP 503"), { code: 1 });
    },
    wait: async (ms) => waits.push(ms),
  });
  assert.deepEqual(r, { mode: "people-who-know-me", attempts: 3 });
  assert.deepEqual(calls.map((c) => c[6]), ["people-who-know-me", "anyone", "people-who-know-me"]);
  assert.deepEqual(calls[0], ["/bin/sh", ...UMASK_LAUNCHER, "shortcuts", "sign", "--mode", "people-who-know-me", "--input", "/tmp/in", "--output", "/tmp/out"]);
  assert.deepEqual(waits, [2000, 4000]);
});

test("S5: the signer's output is 0600 from creation, also when signing fails midway (fake signer)", async () => {
  const dir = await mkdtemp(join(tmpdir(), "homebot-test-"));
  // Fake `shortcuts`: creates the output with default permissions, then succeeds or fails.
  // argv: sign --mode <m> --input <in> --output <out>  ($7 = out)
  const fake = join(dir, "fake-shortcuts");
  await writeFile(fake, '#!/bin/sh\nprintf signed > "$7"\n[ "$3" = "anyone" ] && exit 0\nexit 1\n', { mode: 0o700 });
  const prev = process.umask(0o022); // a normal, permissive parent umask
  try {
    const failed = join(dir, "failed out.shortcut");
    await assert.rejects(signShortcut({ input: "in", output: failed, attempts: 1, command: fake, wait: async () => {} }), /signing failed/);
    assert.equal((await stat(failed)).mode & 0o777, 0o600, "partial output left by a failing signer is private");
    const ok = join(dir, "it's \"ok\"; $(x).shortcut"); // hostile path stays one argument
    const r = await signShortcut({ input: "in", output: ok, attempts: 2, command: fake, wait: async () => {} });
    assert.equal(r.mode, "anyone");
    assert.equal((await stat(ok)).mode & 0o777, 0o600);
  } finally {
    process.umask(prev);
  }
});

test("signer: gives up with a clear error", async () => {
  await assert.rejects(
    signShortcut({ input: "a", output: "b", attempts: 2, run: async () => Promise.reject(Object.assign(new Error("x"), { code: 1 })), wait: async () => {} }),
    /signing failed after 2 attempts \(last exit: 1\)/,
  );
});

test("replacement: the old phrase is kept unless a blocking rule refuses it (re-review S2)", () => {
  const advice = shortcutProfile({ botName: "homebot", siriLang: "en-US", keep: "Call Butler" });
  assert.equal(advice.name, "Call Butler", "advice alone never changes a learned phrase");
  assert.ok(advice.problems.every((p) => !p.blocking));
  const mixed = shortcutProfile({ botName: "homebot", siriLang: "zh-CN", keep: "homebot 你好" });
  assert.equal(mixed.name, "homebot 你好", "the script rule is advice, so the phrase is kept");
  const unsafe = shortcutProfile({ botName: "homebot", siriLang: "zh-CN", keep: "a/b" });
  assert.equal(unsafe.name, "Grok Bot", "a name iOS would change is not kept");
  assert.equal(keptPhrase({ label: "Grok Bot", siriLang: "en-US" }, "zh-CN"), "Grok Bot", "a language change never renames a Shortcut (DECISIONS item 33)");
  assert.equal(keptPhrase({ label: "家庭助手", siriLang: "zh-CN" }, "en-US"), "家庭助手");
});
