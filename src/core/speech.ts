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
