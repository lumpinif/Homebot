// Language model (DECISIONS item 3). English is the product default.
//
// Two independent user settings:
// - Siri language: what the user speaks and hears. It drives the Shortcut name (spoken to
//   Siri), the Ask for Input prompt, the Speak Text voice, the bot's reply language and the
//   spoken system messages. It is chosen per Shortcut and bound to that Shortcut's token.
// - iPhone system language: the language of the Shortcuts/Settings UI on the phone. It only
//   drives the setup instructions (e.g. the name of the "Allow Running When Locked" switch).
// Example: Felix = iPhone English, Siri Chinese (Mandarin, China mainland).

/**
 * Every language Homebot speaks, in menu order, named in itself (DECISIONS item 22). This one
 * table drives all three language menus, which offer the same options:
 * - the setup page's own language (web/src/i18n has a catalog for each code),
 * - the iPhone's system language (src/shortcut/profile.ts has setup steps for each code),
 * - the HomePod's Siri language. `siri` is the Siri locale a Shortcut is made for (its Speak
 *   Text voice); `reply` keys the spoken catalogs (phrases, system messages, the bot's reply
 *   language); `hey` is how Siri is woken in that language, as in the phone steps.
 * Spanish and Portuguese follow the iOS tables they were checked against (Spain, Brazil); Chinese
 * (Traditional) is Mandarin as spoken in Taiwan. `reply` codes "en" and "zh-CN" predate the table
 * and are kept: tokens, settings and the request line bots see already use them.
 */
export const LANGUAGES = {
  en: { name: "English", siri: "en-US", reply: "en", hey: "Hey Siri, {name}" },
  es: { name: "Español (España)", siri: "es-ES", reply: "es", hey: "Oye Siri, {name}" },
  fr: { name: "Français", siri: "fr-FR", reply: "fr", hey: "Dis Siri, {name}" },
  de: { name: "Deutsch", siri: "de-DE", reply: "de", hey: "Hey Siri, {name}" },
  it: { name: "Italiano", siri: "it-IT", reply: "it", hey: "Ehi Siri, {name}" },
  "pt-BR": { name: "Português (Brasil)", siri: "pt-BR", reply: "pt-BR", hey: "E aí Siri, {name}" },
  ru: { name: "Русский", siri: "ru-RU", reply: "ru", hey: "Привет, Siri, {name}" },
  ja: { name: "日本語", siri: "ja-JP", reply: "ja", hey: "Hey Siri、{name}" },
  ko: { name: "한국어", siri: "ko-KR", reply: "ko", hey: "Siri야, {name}" },
  "zh-Hans": { name: "简体中文", siri: "zh-CN", reply: "zh-CN", hey: "嘿 Siri，{name}" },
  "zh-Hant": { name: "繁體中文", siri: "zh-TW", reply: "zh-TW", hey: "嘿 Siri，{name}" },
} as const satisfies Record<string, { name: string; siri: string; reply: string; hey: string }>;

export type Lang = keyof typeof LANGUAGES;
export const isLang = (l: unknown): l is Lang => typeof l === "string" && Object.hasOwn(LANGUAGES, l);
/** The menu: code and native name, in order. */
export const LANG_OPTIONS = Object.entries(LANGUAGES).map(([code, l]) => ({ code: code as Lang, label: l.name }));

/** Keys of the spoken catalogs: one per language. */
export type ReplyLang = (typeof LANGUAGES)[Lang]["reply"];
export const REPLY_LANGS = Object.values(LANGUAGES).map((l) => l.reply) as ReplyLang[];

/**
 * English Siri locales a Shortcut could be made for before the table had one Siri locale per
 * language. Their Shortcuts keep working (and keep their Speak Text accent); the menu no longer
 * offers them.
 */
const LEGACY_SIRI = ["en-GB", "en-AU", "en-CA", "en-IN", "en-IE", "en-NZ", "en-ZA"] as const;

/** Siri locale -> the language it belongs to. */
const SIRI_TO_LANG: Record<string, Lang> = {
  ...Object.fromEntries(Object.entries(LANGUAGES).map(([code, l]) => [l.siri, code as Lang])),
  ...Object.fromEntries(LEGACY_SIRI.map((s) => [s, "en" as Lang])),
};

export type SiriLang = (typeof LANGUAGES)[Lang]["siri"] | (typeof LEGACY_SIRI)[number];
export const isSiriLang = (l: unknown): l is SiriLang => typeof l === "string" && Object.hasOwn(SIRI_TO_LANG, l);
/** The Siri menu: the same options as the other two menus, valued by Siri locale. */
export const SIRI_OPTIONS = LANG_OPTIONS.map((o) => ({ code: LANGUAGES[o.code].siri as SiriLang, label: o.label }));

/** The language a Siri locale belongs to; English for unknown or missing ones. */
export const langOfSiri = (siriLang: string | undefined): Lang => (siriLang && isSiriLang(siriLang) ? (SIRI_TO_LANG[siriLang] ?? "en") : "en");

/** The iPhone and the setup page use the same languages. */
export type PhoneLang = Lang;
export const isPhoneLang = isLang;

export const DEFAULT_SIRI_LANG: SiriLang = "en-US";
export const DEFAULT_PHONE_LANG: PhoneLang = "en";

export function replyLang(siriLang: string | undefined): ReplyLang {
  return LANGUAGES[langOfSiri(siriLang)].reply;
}

/**
 * Chinese text that embeds a name puts a space between Han and Latin letters or digits
 * ("想问我的 Grok Bot 什么？"). Other languages (Japanese and Korean too) pass through unchanged.
 */
export const spaceMixed = (text: string, lang: string): string =>
  lang.startsWith("zh") ? text.replace(/(\p{Script=Han})(?=[A-Za-z0-9])|([A-Za-z0-9])(?=\p{Script=Han})/gu, "$1$2 ") : text;

/** What the user says to run a Shortcut, in its Siri language: "Hey Siri, <name>". */
export const heySiri = (siriLang: string | undefined, name: string): string =>
  spaceMixed(LANGUAGES[langOfSiri(siriLang)].hey.replace("{name}", name), LANGUAGES[langOfSiri(siriLang)].reply);
