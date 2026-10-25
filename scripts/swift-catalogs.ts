// Generates mac/Sources/HomebotCore/Catalogs.generated.swift from the TypeScript catalogs.
// Usage: node scripts/swift-catalogs.ts mac/Sources/HomebotCore/Catalogs.generated.swift
// Functions are called with sentinel arguments and the sentinels become Swift interpolations.
import { writeFileSync } from "node:fs";
import { messages, LANGS } from "../src/core/i18n.ts";
import { STYLE } from "../src/core/envelope.ts";
import { END_WORDS } from "../src/core/conversation.ts";
import { PHRASES, PHONE_STEPS } from "../src/shortcut/profile.ts";
import { PROBE_TEXT } from "../src/server/voice.ts";
import { LANGUAGES } from "../src/core/lang.ts";

const out = process.argv[2];
if (!out) throw new Error("usage: node scripts/swift-catalogs.ts <output .swift file>");
const S1 = "\u{E000}A\u{E000}";
const S2 = "\u{E000}B\u{E000}";
const N = 987654321;

function esc(s: string): string {
  let r = "";
  for (const ch of s) {
    const cp = ch.codePointAt(0)!;
    if (ch === "\\") r += "\\\\";
    else if (ch === '"') r += '\\"';
    else if (ch === "\n") r += "\\n";
    else if (cp < 0x20 || cp === 0x7f || cp === 0xa0 || (cp >= 0xe000 && cp <= 0xf8ff)) r += `\\u{${cp.toString(16).toUpperCase()}}`;
    else r += ch;
  }
  return r;
}

function lit(s: string, subs: [string, string][] = []): string {
  let r = esc(s);
  for (const [from, to] of subs) r = r.split(esc(from)).join(`\\(${to})`);
  return `"${r}"`;
}

const L: string[] = [];
L.push("// GENERATED from the TypeScript catalogs (src/core/i18n.ts, envelope.ts, conversation.ts,");
L.push("// src/shortcut/profile.ts, src/server/voice.ts) by scripts/swift-catalogs.ts. Do not edit by hand:");
L.push("// change the TypeScript source while it is the reference, then regenerate. GoldenTests compares");
L.push("// every entry with a dump of the TypeScript output.");
L.push("// swiftlint:disable all");
L.push("import Foundation");
L.push("");

// Spoken system messages
const keys = Object.keys(messages("en")) as (keyof ReturnType<typeof messages>)[];
const withBot = new Set(["busy", "inFlight", "noReplyInTime"]);
L.push("extension Messages {");
L.push("  static let catalog: [ReplyLang: Messages] = [");
for (const lang of LANGS) {
  const m = messages(lang);
  L.push(`    .${caseName(lang)}: Messages(`);
  const parts = keys.map((k) => {
    if (withBot.has(k)) return `      ${k}: { bot in ${lit((m[k] as (b: string) => string)(S1), [[S1, "bot"]])} }`;
    return `      ${k}: ${lit((m[k] as () => string)())}`;
  });
  L.push(parts.join(",\n"));
  L.push("    ),");
}
L.push("  ]");
L.push("}");
L.push("");

// Envelope style
L.push("extension Envelope {");
L.push("  static let styles: [ReplyLang: Style] = [");
for (const lang of LANGS) {
  const s = STYLE[lang];
  L.push(`    .${caseName(lang)}: Style(`);
  L.push(`      intro: ${lit(s.intro)},`);
  L.push(`      turn: { n in ${lit(s.turn(N), [[String(N), "n"]])} },`);
  L.push(`      echo: { tag in ${lit(s.echo(S1), [[S1, "tag"]])} },`);
  L.push(`      end: { tag in ${lit(s.end(S1), [[S1, "tag"]])} },`);
  L.push(`      style: ${lit(s.style)}`);
  L.push("    ),");
}
L.push("  ]");
L.push("}");
L.push("");

// End words
L.push("extension Conversation {");
L.push("  static let endWords: [ReplyLang: [String]] = [");
for (const lang of LANGS) L.push(`    .${caseName(lang)}: [${END_WORDS[lang].map((w) => lit(w)).join(", ")}],`);
L.push("  ]");
L.push("}");
L.push("");

// Probe text (ru plural is hand-written in Catalogs.swift)
L.push("extension Catalogs {");
L.push("  static let probeTextTemplates: [ReplyLang: @Sendable (Int) -> String] = [");
for (const lang of LANGS) {
  if (lang === "ru") continue;
  L.push(`    .${caseName(lang)}: { n in ${lit(PROBE_TEXT[lang](N), [[String(N), "n"]])} },`);
}
L.push("  ]");
L.push("}");
L.push("");

// Phrase rows
L.push("extension PhraseRow {");
L.push("  static let rows: [ReplyLang: PhraseRow] = [");
for (const lang of LANGS) {
  const r = PHRASES[lang];
  L.push(`    .${caseName(lang)}: PhraseRow(`);
  L.push(`      script: ${lit(r.script.source)},`);
  L.push(`      spaced: ${r.spaced},`);
  L.push(`      products: [${r.products.map((p) => lit(p)).join(", ")}],`);
  L.push(`      badStarts: [${r.badStarts.map((b) => `.init(${lit(b.word)}${b.strong ? ", strong: true" : ""})`).join(", ")}],`);
  L.push(`      promptWithBot: { bot in ${lit(r.prompt(S1), [[S1, "bot"]])} },`);
  L.push(`      promptWithoutBot: ${lit(r.prompt(undefined))},`);
  L.push(`      probeName: ${lit(r.probeName)},`);
  L.push(`      labName: ${lit(r.labName)}`);
  L.push("    ),");
}
L.push("  ]");
L.push("}");
L.push("");

// Phone steps
L.push("extension Profile {");
L.push("  static let phoneSteps: [Lang: @Sendable (_ name: String, _ host: String) -> [String]] = [");
for (const code of Object.keys(LANGUAGES) as (keyof typeof LANGUAGES)[]) {
  const steps = PHONE_STEPS[code](S1, S2);
  L.push(`    .${caseName(code)}: { name, host in [`);
  for (const s of steps) L.push(`      ${lit(s, [[S1, "name"], [S2, "host"]])},`);
  L.push("    ] },");
}
L.push("  ]");
L.push("}");

function caseName(code: string): string {
  return ({ "zh-CN": "zhCN", "zh-TW": "zhTW", "pt-BR": "ptBR", "zh-Hans": "zhHans", "zh-Hant": "zhHant" } as Record<string, string>)[code] ?? code;
}

writeFileSync(out, L.join("\n") + "\n");
console.log("wrote", out);
