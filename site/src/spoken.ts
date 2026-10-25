// What Siri says in each language a Shortcut can be made for. Copied from the app's spoken
// catalogs (src/core/lang.ts, mac/Sources/HomebotCore/Catalogs.generated.swift): the wake
// words, the suggested phrases, the question Siri asks, "Anything else?" in conversation mode,
// the first end word and the "which bot?" menu (mac/Sources/HomebotCore/Chooser.swift). Keep
// in step with those files.
export type SiriLang = {
  code: string;
  name: string;
  hey: string;
  phrases: string[];
  prompt: (bot: string) => string;
  more: string;
  end: string;
  /** The "which bot?" menu of an All-my-bots Shortcut: question, separator, final stop (Chooser.swift). */
  which: [string, string, string];
};

/** Chinese spaces Han from Latin letters and digits around a name (spaceMixed in src/core/lang.ts). */
const spaceMixed = (text: string): string => text.replace(/(\p{Script=Han})(?=[A-Za-z0-9])|([A-Za-z0-9])(?=\p{Script=Han})/gu, "$1$2 ");

export const SIRI_LANGS: SiriLang[] = [
  { code: "en", which: ["Which bot?", ", ", "."], name: "English", hey: "Hey Siri, {name}", phrases: ["Grok Bot", "My Grok Bot", "Our Grok Bot"], prompt: (b) => `What would you like to ask ${b}?`, more: "Anything else?", end: "stop" },
  { code: "es", which: ["¿Qué bot?", ", ", "."], name: "Español (España)", hey: "Oye Siri, {name}", phrases: ["Grok Bot", "mi Grok Bot", "mayordomo", "ama de llaves"], prompt: (b) => `¿Qué quieres preguntarle a ${b}?`, more: "¿Algo más?", end: "para" },
  { code: "fr", which: ["Quel bot ?", ", ", "."], name: "Français", hey: "Dis Siri, {name}", phrases: ["Grok Bot", "mon Grok Bot", "majordome", "intendant"], prompt: (b) => `Que voulez-vous demander à ${b} ?`, more: "Autre chose ?", end: "stop" },
  { code: "de", which: ["Welcher Bot?", ", ", "."], name: "Deutsch", hey: "Hey Siri, {name}", phrases: ["Grok Bot", "mein Grok Bot", "Hausgeist", "Haushelfer"], prompt: (b) => `Was möchtest du ${b} fragen?`, more: "Sonst noch etwas?", end: "stopp" },
  { code: "it", which: ["Quale bot?", ", ", "."], name: "Italiano", hey: "Ehi Siri, {name}", phrases: ["Grok Bot", "il mio Grok Bot", "maggiordomo", "factotum"], prompt: (b) => `Cosa vuoi chiedere a ${b}?`, more: "Altro?", end: "basta" },
  { code: "pt-BR", which: ["Qual bot?", ", ", "."], name: "Português (Brasil)", hey: "E aí Siri, {name}", phrases: ["Grok Bot", "meu Grok Bot", "mordomo", "assistente do lar"], prompt: (b) => `O que você quer perguntar para ${b}?`, more: "Mais alguma coisa?", end: "parar" },
  { code: "ru", which: ["Какой бот?", ", ", "."], name: "Русский", hey: "Привет, Siri, {name}", phrases: ["Grok Bot", "мой Grok Bot", "домовой", "дворецкий"], prompt: (b) => `${b} слушает. Что вы хотите спросить?`, more: "Что-нибудь ещё?", end: "стоп" },
  { code: "ja", which: ["どのボットですか？", "、", "。"], name: "日本語", hey: "Hey Siri、{name}", phrases: ["Grok Bot", "うちの Grok Bot", "うち助手", "家事助手"], prompt: (b) => `${b}に何を聞きますか？`, more: "ほかにありますか？", end: "終わり" },
  { code: "ko", which: ["어느 봇인가요?", ", ", "."], name: "한국어", hey: "Siri야, {name}", phrases: ["Grok Bot", "우리 Grok Bot", "집비서", "집도우미"], prompt: (b) => `${b}에게 무엇을 물어볼까요?`, more: "더 필요한 게 있으세요?", end: "그만" },
  { code: "zh-Hans", which: ["问哪个机器人？", "，", "。"], name: "简体中文", hey: "嘿 Siri，{name}", phrases: ["Grok Bot", "我的 Grok Bot", "家庭助手", "我家助手"], prompt: (b) => spaceMixed(`想问${b}什么？`), more: "还有吗？", end: "结束" },
  { code: "zh-Hant", which: ["問哪個機器人？", "，", "。"], name: "繁體中文", hey: "嘿 Siri，{name}", phrases: ["Grok Bot", "我的 Grok Bot", "居家助理", "我家助理"], prompt: (b) => spaceMixed(`想問${b}什麼？`), more: "還有嗎？", end: "結束" },
];

export const siriLang = (code: string) => SIRI_LANGS.find((l) => l.code === code) ?? SIRI_LANGS[0];
export const hey = (l: SiriLang, name: string) => l.hey.replace("{name}", name);
