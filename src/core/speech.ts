// Turn bot text into something Siri can read aloud: no markdown, code, links or emoji,
// and a length cap that cuts at a sentence boundary.

const EMOJI = /[\p{Extended_Pictographic}\p{Emoji_Modifier}\u{FE0F}\u{200D}]/gu;
const BOUNDARY = /[。！？；.!?;]/g;

export function sanitize(s: string): string {
  return s
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/`([^`]*)`/g, "$1")
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/https?:\/\/\S+/g, "")
    .replace(/^\s*(?:[#>]+|[-*+]|\d+\.)\s+/gm, "")
    .replace(/[*_~|]/g, "")
    .replace(EMOJI, "")
    .replace(/\s+/g, " ")
    .trim();
}

/** `s` must already be sanitized. */
export function truncate(s: string, maxChars: number): string {
  const chars = [...s];
  if (chars.length <= maxChars) return s;
  const head = chars.slice(0, maxChars).join("");
  let cut = -1;
  for (const m of head.matchAll(BOUNDARY)) cut = m.index + 1;
  const body = cut >= head.length / 2 ? head.slice(0, cut) : head;
  return body.trimEnd() + "…";
}

export const speakable = (s: string, maxChars: number): string => truncate(sanitize(s), maxChars);

/**
 * Letters each Speak Text voice can read, by script. Common/Inherited letters (e.g. the Japanese
 * long-vowel mark) are always fine, and every voice reads Latin, with an accent. A letter in any
 * other script is read as noise or skipped (an en-US voice read a Chinese answer as noise on a Mac,
 * S25), so such a reply is never spoken.
 */
const READABLE: Record<string, string> = {
  ru: "\\p{Script=Cyrillic}",
  ja: "\\p{Script=Han}\\p{Script=Hiragana}\\p{Script=Katakana}",
  ko: "\\p{Script=Hangul}",
  "zh-CN": "\\p{Script=Han}",
  "zh-TW": "\\p{Script=Han}",
};

export const unreadablePattern = (lang: string): string =>
  `[^\\P{L}\\p{Script=Latin}\\p{Script=Common}\\p{Script=Inherited}${READABLE[lang] ?? ""}]`;

/** True when the voice of `lang` can read every letter of `s`. */
export const readableBy = (s: string, lang: string): boolean => !new RegExp(unreadablePattern(lang), "u").test(s);

/**
 * The most a reply may hold in scripts its voice can't read and still be spoken without them
 * (DECISIONS item 39), as a share of its letters, each Han, kana or Hangul letter weighing 3: an
 * English word is about 5 letters and a Chinese word about 1.7 characters, so one such letter
 * carries about as much as 3 Latin ones, and the share is one of the reply's words, not its
 * characters. Felix's reply that quoted "家庭助手" in English is 6%.
 */
export const MAX_FOREIGN_SHARE = 0.2;
const DENSE = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u;

/** What a run drop leaves behind: empty quotes and brackets, doubled spaces and punctuation. */
export function tidy(s: string): string {
  let t = s;
  for (let prev = ""; prev !== t; ) {
    prev = t;
    t = t.replace(/(?:"\s*"|“\s*”|'\s*'|‘\s*’|「\s*」|『\s*』|\(\s*\)|（\s*）|\[\s*\]|《\s*》|«\s*»)/g, "");
  }
  return t
    .replace(/\s+([,.;:!?，。！？；：、])/g, "$1")
    .replace(/([,，、;；:：])(?:\s*[,，、;；:：])+/g, "$1")
    .replace(/[,，、;；:：]\s*([.。!！?？])/g, "$1")
    .replace(/^[\s,，、;；:：.。]+/, "")
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * The text the voice of `lang` reads: `s` itself when it can read every letter; without the runs
 * it can't read, tidied, when they are a small share (`partial`); undefined when they are not, or
 * nothing readable is left.
 */
export function forVoice(s: string, lang: string): { text: string; partial: boolean } | undefined {
  const foreign = new RegExp(unreadablePattern(lang), "u");
  let total = 0;
  let other = 0;
  for (const c of s.match(/\p{L}/gu) ?? []) {
    const w = DENSE.test(c) ? 3 : 1;
    total += w;
    if (foreign.test(c)) other += w;
  }
  if (other === 0) return { text: s, partial: false };
  if (other / total > MAX_FOREIGN_SHARE) return undefined;
  const text = tidy(s.replace(new RegExp(`(?:${unreadablePattern(lang)}\\p{M}*)+`, "gu"), ""));
  return /[\p{L}\p{N}]/u.test(text) ? { text, partial: true } : undefined;
}
