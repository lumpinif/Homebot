// What a Shortcut says and how it speaks, derived from the two language settings
// (src/core/lang.ts). Siri language -> name, prompt, voice. iPhone language -> setup steps.
import { isSiriLang, isPhoneLang, replyLang, DEFAULT_SIRI_LANG, DEFAULT_PHONE_LANG, type PhoneLang, type ReplyLang, type SiriLang } from "../core/lang.ts";
import { labelKey } from "../core/tokens.ts";
import { safeFileName } from "./make.ts";

/**
 * One row per reply language (DESIGN §16). The script and the leading words are advice
 * (DECISIONS item 29): on a Chinese HomePod "homebot 你好" was not recognized while "家庭助手" was
 * (item 18), but tapping a Shortcut works whatever its name. The default is "Grok Bot" in every
 * language (DECISIONS item 33: Felix's Chinese Siri ran it); the brand never counts against the
 * script. No digits (Siri may say a number in several ways).
 */
interface PhraseRow {
  /** Whole-phrase check: only this language's characters (advice; defaults must pass). */
  script: RegExp;
  /** Words are separated by spaces, so a leading command word matches as a whole word only. */
  spaced: boolean;
  /** Ranked defaults; the first one not in use becomes the default phrase. */
  products: string[];
  /**
   * Leading words Siri may parse as its own intent; all advice. `strong`: a device failure
   * (DECISIONS item 12, "问"), so the advice is worded as a likely failure.
   */
  badStarts: { word: string; strong?: true }[];
  /** Ask for Input question; the bot name only appears when it is in this script. */
  prompt(bot: string | undefined): string;
  probeName: string;
  labName: string;
}

/** Latin letters (accents included), words joined by a space, apostrophe or hyphen. */
const LATIN = /^\p{Script=Latin}+(?:[ '’-]\p{Script=Latin}+)*$/u;

export const PHRASES: Record<ReplyLang, PhraseRow> = {
  en: {
    script: /^[A-Za-z]+(?:[ '-][A-Za-z]+)*$/,
    spaced: true,
    // Q16-1 (decided 2026-10-24, DECISIONS item 28): the phrase names the real target, the
    // user's Grok Bot. "Ask Grok Bot" is left out: "ask" is a leading command word (advice), and
    // a default never carries advice. "Homebot" stays out: it can be heard as "HomePod". Every
    // row starts with "Grok Bot" (DECISIONS item 33).
    products: ["Grok Bot", "My Grok Bot", "Our Grok Bot"],
    badStarts: ["ask", "call", "play", "set", "open", "turn", "text", "what", "tell", "search"].map((word) => ({ word })),
    prompt: (bot) => (bot ? `What would you like to ask ${bot}?` : "What would you like to ask?"),
    probeName: "Homebot Wait Test",
    labName: "Homebot Lab",
  },
  "zh-CN": {
    script: /^\p{Script=Han}+$/u,
    spaced: false,
    products: ["Grok Bot", "我的 Grok Bot", "家庭助手", "我家助手"],
    badStarts: [{ word: "问", strong: true }, ...["查", "播放", "打开", "设置", "什么", "呼叫", "打电话"].map((word) => ({ word }))],
    prompt: (bot) => (bot ? `想问${bot}什么？` : "想问什么？"),
    probeName: "家庭等待测试",
    labName: "家庭实验",
  },
  // The rows below follow the candidates in DESIGN §16.3. None has been tried on a HomePod yet
  // (STATUS); each avoids the local name of Apple's Home app (Casa, Maison, Дом, ホーム, 홈...).
  es: {
    script: LATIN,
    spaced: true,
    products: ["Grok Bot", "mi Grok Bot", "mayordomo", "ama de llaves"],
    badStarts: ["pregunta", "pregúntale", "llama", "pon", "reproduce", "abre", "busca", "envía", "qué", "activa", "enciende", "apaga", "dime"].map((word) => ({ word })),
    prompt: (bot) => (bot ? `¿Qué quieres preguntarle a ${bot}?` : "¿Qué quieres preguntar?"),
    probeName: "prueba de espera",
    labName: "Homebot Lab",
  },
  fr: {
    script: LATIN,
    spaced: true,
    products: ["Grok Bot", "mon Grok Bot", "majordome", "intendant"],
    badStarts: ["demande", "appelle", "joue", "mets", "ouvre", "cherche", "envoie", "quel", "quelle", "allume", "éteins"].map((word) => ({ word })),
    prompt: (bot) => (bot ? `Que voulez-vous demander à ${bot} ?` : "Que voulez-vous demander ?"),
    probeName: "test d'attente",
    labName: "Homebot Lab",
  },
  de: {
    script: LATIN,
    spaced: true,
    products: ["Grok Bot", "mein Grok Bot", "Hausgeist", "Haushelfer"],
    badStarts: ["frag", "frage", "ruf", "spiel", "öffne", "such", "suche", "schick", "was", "schalte", "stell"].map((word) => ({ word })),
    prompt: (bot) => (bot ? `Was möchtest du ${bot} fragen?` : "Was möchtest du fragen?"),
    probeName: "Wartetest",
    labName: "Homebot Lab",
  },
  it: {
    script: LATIN,
    spaced: true,
    products: ["Grok Bot", "il mio Grok Bot", "maggiordomo", "factotum"],
    badStarts: ["chiedi", "chiama", "riproduci", "metti", "apri", "cerca", "invia", "che", "cosa", "accendi", "spegni", "imposta", "dimmi"].map((word) => ({ word })),
    prompt: (bot) => (bot ? `Cosa vuoi chiedere a ${bot}?` : "Cosa vuoi chiedere?"),
    probeName: "prova di attesa",
    labName: "Homebot Lab",
  },
  "pt-BR": {
    script: LATIN,
    spaced: true,
    products: ["Grok Bot", "meu Grok Bot", "mordomo", "assistente do lar"],
    badStarts: ["pergunte", "ligue", "toque", "abra", "procure", "busque", "envie", "mande", "qual", "o que", "desligue", "defina", "diga"].map((word) => ({ word })),
    prompt: (bot) => (bot ? `O que você quer perguntar para ${bot}?` : "O que você quer perguntar?"),
    probeName: "teste de espera",
    labName: "Homebot Lab",
  },
  ru: {
    script: /^\p{Script=Cyrillic}+(?:[ -]\p{Script=Cyrillic}+)*$/u,
    spaced: true,
    products: ["Grok Bot", "мой Grok Bot", "домовой", "дворецкий"],
    badStarts: ["спроси", "позвони", "включи", "выключи", "открой", "найди", "отправь", "напиши", "что", "поставь", "скажи"].map((word) => ({ word })),
    // The bot's name leads, so it is never declined (Russian would inflect it after "у").
    prompt: (bot) => (bot ? `${bot} слушает. Что вы хотите спросить?` : "Что вы хотите спросить?"),
    probeName: "проверка ожидания",
    labName: "домашняя лаборатория",
  },
  ja: {
    // Hiragana, katakana, kanji and the long-vowel mark ー (which Unicode files as Common).
    script: /^[\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Han}ー]+$/u,
    spaced: false,
    products: ["Grok Bot", "うちの Grok Bot", "うち助手", "家事助手"],
    badStarts: ["聞いて", "電話", "再生", "開いて", "検索", "送って", "何", "つけて", "消して", "教えて", "設定"].map((word) => ({ word })),
    prompt: (bot) => (bot ? `${bot}に何を聞きますか？` : "何を聞きますか？"),
    probeName: "待ち時間テスト",
    labName: "うち実験",
  },
  ko: {
    script: /^\p{Script=Hangul}+(?: \p{Script=Hangul}+)*$/u,
    spaced: true,
    products: ["Grok Bot", "우리 Grok Bot", "집비서", "집도우미"],
    badStarts: ["물어봐", "전화", "재생", "열어", "검색", "보내", "뭐", "켜", "꺼", "틀어", "찾아", "문자", "설정"].map((word) => ({ word })),
    prompt: (bot) => (bot ? `${bot}에게 무엇을 물어볼까요?` : "무엇을 물어볼까요?"),
    probeName: "대기 테스트",
    labName: "집 실험",
  },
  "zh-TW": {
    script: /^\p{Script=Han}+$/u,
    spaced: false,
    products: ["Grok Bot", "我的 Grok Bot", "居家助理", "我家助理"],
    // 問 is 问: the same strong advice (DECISIONS item 12), though only 问 was tried.
    badStarts: [{ word: "問", strong: true }, ...["查", "播放", "打開", "設定", "什麼", "打電話", "撥打", "呼叫", "傳訊息"].map((word) => ({ word }))],
    prompt: (bot) => (bot ? `想問${bot}什麼？` : "想問什麼？"),
    probeName: "居家等待測試",
    labName: "居家實驗",
  },
};

/**
 * Phrases of the user's usable Homebot Shortcuts, except the one being replaced (a replacement
 * normally keeps its phrase). Pending ones count: they may be on the phone. All languages count:
 * every Shortcut lives on the same iPhone (design review v8, Grok S1).
 */
export function takenPhrases(tokens: { id: string; label: string; state: string }[], replaces?: string): string[] {
  return tokens.filter((t) => t.state !== "retired" && t.id !== replaces).map((t) => t.label);
}

/**
 * The phrase a replacement keeps: the old Shortcut's, in any language. The default is the same
 * in every language (DECISIONS item 33), so a language change never renames a Shortcut.
 */
export function keptPhrase(old: { label: string; siriLang?: string | undefined } | undefined, siriLang: string = DEFAULT_SIRI_LANG): string | undefined {
  if (!old || !isSiriLang(siriLang)) return undefined; // an unknown language fails later, in shortcutProfile
  return old.label;
}

export interface PhraseProblem {
  code: "wrong-script" | "bad-start" | "search-start" | "unsafe-chars" | "in-use";
  message: string;
  /** Refused (true) or advice only (false). */
  blocking: boolean;
}

/** Comparison form: Unicode NFC, trimmed, single spaces, lower case. */
const norm = labelKey;

/** The brand every language's default carries (DECISIONS item 33). */
export const BRAND = "Grok Bot";

/** The phrase without the brand, for the script check: "我的 Grok Bot" is judged as "我的". */
const withoutBrand = (name: string): string => name.replace(/grok bot/giu, " ").replace(/\s+/gu, " ").trim();

/** A bot named like the app ("homebot") reads as Homebot itself, so it is never suggested (S25). */
const soundsLikeApp = (bot: string): boolean => norm(bot).replace(/[\s-]+/gu, "") === "homebot";

/**
 * Only correctness blocks (DECISIONS item 29): a name iOS would change on import, and a name
 * another Homebot Shortcut uses. How likely Siri is to hear the name is advice: tapping the
 * Shortcut works whatever its name.
 */
function phraseProblems(name: string, row: PhraseRow, taken: string[]): PhraseProblem[] {
  const p: PhraseProblem[] = [];
  const rest = withoutBrand(name.normalize("NFC"));
  if (rest && !row.script.test(rest)) {
    p.push({ code: "wrong-script", blocking: false, message: `Siri in this language may not hear "${name}" (other scripts, digits or symbols), so saying it may not start the Shortcut. Tapping it always works.` });
  }
  const lower = norm(name);
  // Spaced languages match whole words only ("Asking" is fine); Chinese and Japanese have no
  // word spaces.
  const bad = row.badStarts.find(({ word }) => lower === word || lower.startsWith(row.spaced ? `${word} ` : word));
  if (bad) {
    p.push(
      bad.strong
        ? { code: "search-start", blocking: false, message: `On a Chinese HomePod, Siri took a phrase starting with "${bad.word}" as a web search, so saying it will likely fail. Tapping it always works. Pick another if you can.` }
        : { code: "bad-start", blocking: false, message: `A phrase starting with "${bad.word}" may be taken by Siri as its own command. If Siri does that, pick another.` },
    );
  }
  // iOS names an imported Shortcut after its file name, so a name the file name would change
  // is not the name the user chose, nor the one the setup steps quote.
  if (safeFileName(name) !== name) p.push({ code: "unsafe-chars", blocking: true, message: `iOS would change "${name}" when it imports the Shortcut. Leave out / \\ : and control characters, and don't start with a dot.` });
  if (taken.some((t) => norm(t) === lower)) p.push({ code: "in-use", blocking: true, message: `Another of your Homebot Shortcuts already uses "${name}". Siri can't tell them apart.` });
  return p;
}

/**
 * Setup steps shown after building, in the iPhone's system language, because they name iOS
 * settings as the user sees them. Each quoted label is the string in the iOS 26 localization
 * tables shipped with macOS 26.6 (WorkflowUI, Home's HULocalizable, AssistantServices
 * UIUtterances, each app's display name). iOS 26 renamed Home's "Personal Requests" to
 * "Personal Content". None of the non-English steps has been followed on a phone yet (STATUS).
 */
export const PHONE_STEPS: Record<PhoneLang, (name: string, host: string) => string[]> = {
  en: (name, host) => [
    `Send the file to your iPhone (AirDrop) and tap "Add Shortcut".`,
    `In the Shortcuts app, run "${name}" once by tapping it, and allow it to connect to ${host}.`,
    `Open the shortcut's details (ⓘ) and turn on "Allow Running When Locked" if you see it.`,
    `For HomePod: in the Home app, turn on Recognize My Voice and Personal Content (Personal Requests before iOS 26), and make this iPhone your location device in Find My.`,
    `Test on the iPhone first, with its Siri set to the same language as the HomePod's: "Hey Siri, ${name}". A new name can take minutes to a day to work on HomePod.`,
  ],
  "zh-Hans": (name, host) => [
    `把文件发送到 iPhone（隔空投送），然后轻点“添加快捷指令”。`,
    `在“快捷指令” App 中轻点“${name}”运行一次，并允许它连接 ${host}。`,
    `打开该快捷指令的详细信息（ⓘ），如果看到“锁定时允许运行”，请打开。`,
    `HomePod：在“家庭” App 中打开“识别我的声音”和“个人内容”（iOS 26 之前叫“个人请求”），并在“查找”中把这台 iPhone 设为定位设备。`,
    `先在 iPhone 上测试（iPhone 的 Siri 语言要和 HomePod 的一致）：“嘿Siri，${name}”。新名字在 HomePod 上可能要几分钟到一天才生效。`,
  ],
  "zh-Hant": (name, host) => [
    `把檔案傳到 iPhone（AirDrop），然後點一下「加入捷徑」。`,
    `在「捷徑」App 中點一下「${name}」執行一次，並允許它連接 ${host}。`,
    `打開該捷徑的詳細資訊（ⓘ），如果看到「鎖定時允許執行」，請將它打開。`,
    `HomePod：在「家庭」App 中打開「辨識我的聲音」和「個人化內容」，並在「尋找」中把這台 iPhone 設為定位裝置。`,
    `先在 iPhone 上測試（iPhone 的 Siri 語言要和 HomePod 的一致）：「嘿Siri，${name}」。新名字在 HomePod 上可能要幾分鐘到一天才生效。`,
  ],
  ja: (name, host) => [
    `ファイルを iPhone に送信し（AirDrop）、「ショートカットを追加」をタップします。`,
    `「ショートカット」App で「${name}」をタップして 1 回実行し、${host} への接続を許可します。`,
    `ショートカットの詳細（ⓘ）を開き、「ロック中に実行を許可」が表示されていればオンにします。`,
    `HomePod：「ホーム」App で「自分の声を識別」と「個人的なコンテンツ」をオンにし、「探す」でこの iPhone を位置情報のデバイスに設定します。`,
    `まず iPhone でテストします（iPhone の Siri の言語を HomePod と同じにします）：「Hey Siri、${name}」。新しい名前が HomePod で使えるようになるまで、数分から 1 日かかることがあります。`,
  ],
  ko: (name, host) => [
    `파일을 iPhone으로 보낸 다음(AirDrop) “단축어 추가”를 탭합니다.`,
    `“단축어” 앱에서 “${name}”을(를) 탭하여 한 번 실행하고, ${host}에 연결하도록 허용합니다.`,
    `단축어의 세부사항(ⓘ)을 열고, “잠겨 있는 동안 실행 허용”이 보이면 켭니다.`,
    `HomePod: “홈” 앱에서 “나의 음성 인식”과 “개인용 콘텐츠”를 켜고, “나의\u00A0찾기”에서 이 iPhone을 위치 기기로 설정합니다.`,
    `먼저 iPhone에서 테스트합니다(iPhone의 Siri 언어를 HomePod과 같게): “Siri야, ${name}”. 새 이름은 HomePod에서 작동하기까지 몇 분에서 하루가 걸릴 수 있습니다.`,
  ],
  fr: (name, host) => [
    `Envoyez le fichier sur votre iPhone (AirDrop) et touchez « Ajouter ce raccourci ».`,
    `Dans l’app Raccourcis, exécutez « ${name} » une fois en le touchant, et autorisez-le à se connecter à ${host}.`,
    `Ouvrez les détails du raccourci (ⓘ) et activez « Autoriser l’exécution en mode verrouillé » si vous le voyez.`,
    `Pour le HomePod : dans l’app Maison, activez « Reconnaître ma voix » et « Contenu personnel », et faites de cet iPhone l’appareil de localisation dans Localiser.`,
    `Testez d’abord sur l’iPhone, avec Siri dans la même langue que le HomePod : « Dis Siri, ${name} ». Un nouveau nom peut mettre de quelques minutes à un jour à fonctionner sur le HomePod.`,
  ],
  de: (name, host) => [
    `Sende die Datei an dein iPhone (AirDrop) und tippe auf „Kurzbefehl hinzufügen“.`,
    `Führe in der Kurzbefehle-App „${name}“ einmal aus, indem du darauf tippst, und erlaube die Verbindung mit ${host}.`,
    `Öffne die Details des Kurzbefehls (ⓘ) und aktiviere „Ausführung im Sperrzustand erlauben“, falls du es siehst.`,
    `Für den HomePod: Aktiviere in der Home-App „Meine Stimme erkennen“ und „Persönliche Inhalte“, und lege dieses iPhone in „Wo ist?“ als Standortgerät fest.`,
    `Teste zuerst auf dem iPhone, mit Siri in derselben Sprache wie auf dem HomePod: „Hey Siri, ${name}“. Ein neuer Name kann auf dem HomePod einige Minuten bis einen Tag brauchen.`,
  ],
  es: (name, host) => [
    `Envía el archivo a tu iPhone (AirDrop) y toca «Añadir atajo».`,
    `En la app Atajos, ejecuta «${name}» una vez tocándolo y permite que se conecte a ${host}.`,
    `Abre los detalles del atajo (ⓘ) y activa «Permitir ejecución con el dispositivo bloqueado» si lo ves.`,
    `Para el HomePod: en la app Casa, activa «Reconocer mi voz» y «Contenido personal», y establece este iPhone como dispositivo de ubicación en Buscar.`,
    `Prueba primero en el iPhone, con Siri en el mismo idioma que el HomePod: «Oye Siri, ${name}». Un nombre nuevo puede tardar desde unos minutos hasta un día en funcionar en el HomePod.`,
  ],
  it: (name, host) => [
    `Invia il file al tuo iPhone (AirDrop) e tocca «Aggiungi comando rapido».`,
    `Nell’app Comandi Rapidi, esegui «${name}» una volta toccandolo e consenti la connessione a ${host}.`,
    `Apri i dettagli del comando rapido (ⓘ) e attiva «Consenti esecuzione quando bloccato» se lo vedi.`,
    `Per HomePod: nell’app Casa, attiva «Riconosci la mia voce» e «Contenuti personali», e imposta questo iPhone come dispositivo di localizzazione in Dov’è.`,
    `Prova prima sull’iPhone, con Siri nella stessa lingua dell’HomePod: «Ehi Siri, ${name}». Un nome nuovo può impiegare da qualche minuto a un giorno per funzionare su HomePod.`,
  ],
  "pt-BR": (name, host) => [
    `Envie o arquivo para o iPhone (AirDrop) e toque em “Adicionar Atalho”.`,
    `No app Atalhos, execute “${name}” uma vez tocando nele e permita a conexão com ${host}.`,
    `Abra os detalhes do atalho (ⓘ) e ative “Permitir Execução Quando Bloqueado”, se aparecer.`,
    `Para o HomePod: no app Casa, ative “Reconhecer Minha Voz” e “Conteúdo Pessoal”, e defina este iPhone como dispositivo de localização no Buscar.`,
    `Teste primeiro no iPhone, com a Siri no mesmo idioma do HomePod: “E aí Siri, ${name}”. Um nome novo pode levar de alguns minutos a um dia para funcionar no HomePod.`,
  ],
  ru: (name, host) => [
    `Отправьте файл на iPhone (AirDrop) и нажмите «Добавить».`,
    `В приложении «Команды» запустите «${name}» один раз, нажав на него, и разрешите подключение к ${host}.`,
    `Откройте сведения о команде (ⓘ) и включите «Запуск при\u00A0заблокированном экране», если этот пункт есть.`,
    `Для HomePod: в приложении «Дом» включите «Узнавание моего голоса» и «Личный контент», а в «Локаторе» сделайте этот iPhone устройством геопозиции.`,
    `Сначала проверьте на iPhone (язык Siri должен совпадать с языком HomePod): «Привет, Siri, ${name}». Новое имя на HomePod может заработать через несколько минут или в течение суток.`,
  ],
};

export interface ShortcutProfile {
  siriLang: SiriLang;
  phoneLang: PhoneLang;
  replyLang: ReplyLang;
  name: string;
  prompt: string;
  speakLang: string;
  probeName: string;
  labName: string;
  /** Other valid, unused phrases for this Siri language (none equal to `name`). */
  alternatives: string[];
  /** Problems with `name`; a Shortcut is only built when none is `blocking`. */
  problems: PhraseProblem[];
  /** Pass the name of the Shortcut actually built (probe, or sanitized). */
  steps: (host: string, name?: string) => string[];
}

export function shortcutProfile({ botName, siriLang = DEFAULT_SIRI_LANG, phoneLang = DEFAULT_PHONE_LANG, name, keep, taken = [] }: {
  botName: string;
  siriLang?: string | undefined;
  phoneLang?: string | undefined;
  name?: string | undefined;
  /**
   * The phrase of the Shortcut being replaced: the default when `name` is not given and it still
   * passes every rule for this Siri language, so a replacement keeps the phrase Siri learned.
   */
  keep?: string | undefined;
  /** Phrases of the user's other usable voice Shortcuts in this Siri language. */
  taken?: string[];
}): ShortcutProfile {
  if (!isSiriLang(siriLang)) throw new Error(`unsupported Siri language: ${siriLang}`);
  if (!isPhoneLang(phoneLang)) throw new Error(`unsupported iPhone language: ${phoneLang}`);
  const reply = replyLang(siriLang);
  const row = PHRASES[reply];
  const bot = botName.trim();
  const botFits = !soundsLikeApp(bot) && phraseProblems(bot, row, []).length === 0;
  // Product phrases first (one is proved on a device), then the bot's own name if it fits.
  const usable = [...row.products, ...(botFits ? [bot] : [])].filter((c, i, all) => all.indexOf(c) === i && !phraseProblems(c, row, taken).length);
  // Only blocking problems disqualify the old phrase; advice alone never changes a phrase Siri
  // already learned (milestone re-review S2).
  const kept = keep?.trim() && !phraseProblems(keep.trim(), row, taken).some((p) => p.blocking) ? keep.trim() : undefined;
  const finalName = (name ?? kept ?? usable[0] ?? row.products[0] ?? "").trim();
  if (!finalName || finalName.length > 60) throw new Error("Shortcut name must be 1-60 characters");
  return {
    siriLang,
    phoneLang,
    replyLang: reply,
    name: finalName,
    // The question names the phrase the user said, never the bot: a bot called "homebot" read as
    // the app's name (S25). An entry Shortcut (no bot) asks without a name.
    prompt: row.prompt(bot && !phraseProblems(finalName, row, []).length ? finalName : undefined),
    speakLang: siriLang, // Speak Text voice follows Siri's language, not the iPhone's
    probeName: row.probeName,
    labName: row.labName,
    alternatives: usable.filter((a) => norm(a) !== norm(finalName)),
    problems: phraseProblems(finalName, row, taken),
    steps: (host, name = finalName) => PHONE_STEPS[phoneLang](name, host),
  };
}
