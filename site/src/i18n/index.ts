// The site's text in the eleven languages the app speaks (src/core/lang.ts). English is the
// source; the others are drafts written for the site and want a native reader before release.
import { createContext, useContext } from "react";
import { en, type Strings } from "./en";
import { es } from "./es";
import { fr } from "./fr";
import { de } from "./de";
import { it } from "./it";
import { ptBR } from "./pt-BR";
import { ru } from "./ru";
import { ja } from "./ja";
import { ko } from "./ko";
import { zhHans } from "./zh-Hans";
import { zhHant } from "./zh-Hant";

export type { Strings };

/** Code and native name, in the app's order. */
export const LANG_OPTIONS = [
  { code: "en", name: "English" },
  { code: "es", name: "Español (España)" },
  { code: "fr", name: "Français" },
  { code: "de", name: "Deutsch" },
  { code: "it", name: "Italiano" },
  { code: "pt-BR", name: "Português (Brasil)" },
  { code: "ru", name: "Русский" },
  { code: "ja", name: "日本語" },
  { code: "ko", name: "한국어" },
  { code: "zh-Hans", name: "简体中文" },
  { code: "zh-Hant", name: "繁體中文" },
] as const;

export type UiLang = (typeof LANG_OPTIONS)[number]["code"];
export const UI_LANGS: readonly UiLang[] = LANG_OPTIONS.map((l) => l.code);

export const STRINGS: Record<UiLang, Strings> = { en, es, fr, de, it, "pt-BR": ptBR, ru, ja, ko, "zh-Hans": zhHans, "zh-Hant": zhHant };

/** The browser's first language the site has, else English. */
export function detectLang(): UiLang {
  for (const raw of navigator.languages?.length ? navigator.languages : [navigator.language]) {
    const tag = raw.toLowerCase();
    if (tag.startsWith("zh")) return /hant|tw|hk|mo/.test(tag) ? "zh-Hant" : "zh-Hans";
    if (tag.startsWith("pt")) return "pt-BR";
    const base = tag.split("-")[0];
    const hit = UI_LANGS.find((c) => c === base);
    if (hit) return hit;
  }
  return "en";
}

export const fmt = (s: string, vars: Record<string, string>) => s.replace(/\{(\w+)\}/g, (m, k: string) => vars[k] ?? m);

export const LangContext = createContext<{ lang: UiLang; t: Strings }>({ lang: "en", t: en });
export const useT = () => useContext(LangContext);
