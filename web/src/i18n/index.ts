// Setup page text, one catalog per language in src/core/lang.ts (DECISIONS item 22). Plain typed
// objects and the browser's Intl APIs, no i18n library: every catalog is checked against English
// at compile time, all of them ship in the one app.js the gateway serves, and the lists and
// code tables in them stay plain data.
import type { Lang } from "../../../src/core/lang.ts";
import { en, type Strings } from "./en.ts";
import { es } from "./es.ts";
import { fr } from "./fr.ts";
import { de } from "./de.ts";
import { it } from "./it.ts";
import { ptBR } from "./pt-BR.ts";
import { ru } from "./ru.ts";
import { ja } from "./ja.ts";
import { ko } from "./ko.ts";
import { zhHans } from "./zh-Hans.ts";
import { zhHant } from "./zh-Hant.ts";

export type { Strings };
export type UiLang = Lang;

export const STRINGS: Record<UiLang, Strings> = {
  en,
  es,
  fr,
  de,
  it,
  "pt-BR": ptBR,
  ru,
  ja,
  ko,
  "zh-Hans": zhHans,
  "zh-Hant": zhHant,
};

/** Fill {placeholders}. Values are plain text. */
export function fmt(s: string, vars: Record<string, string | number> = {}): string {
  return s.replace(/\{(\w+)\}/g, (m, k: string) => String(Object.hasOwn(vars, k) ? vars[k] : m));
}
