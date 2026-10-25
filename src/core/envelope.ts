// The text Homebot sends to a bot (DESIGN §5.4). Line 1 is a stable marker bots can key on;
// `hb:<id>` lets us find our own user entry. The echoed `[hb:<id>]` is evidence (not proof) that
// a reply answers this request; see DESIGN §4.2 for its limits.
import { randomBytes } from "node:crypto";
import type { ReplyLang } from "./lang.ts";

export const newRequestId = (): string => randomBytes(6).toString("hex");
export const requestMarker = (id: string): string => `hb:${id}`;
export const echoTag = (id: string): string => `[hb:${id}]`;
/** Written by the bot right after its echo tag when the user is ending a conversation (S25). */
export const END_MARK = "[end]";

/**
 * The hint keeps only what Homebot relies on (DECISIONS item 35): where the words came from, the
 * echo tag, the answer language (the Shortcut's Speak Text voice is fixed to it and can't read
 * other scripts, DECISIONS item 31), no markdown or emoji, and how a reply ends. The rest of the
 * voice is the bot's own. `end` is for conversation turns, `statement` for one-shot questions,
 * where the user can't answer back. `close` ends the parenthesis `intro` opens.
 */
export const STYLE: Record<ReplyLang, { intro: string; echo: (tag: string) => string; style: string; end: (tag: string) => string; statement: string; close: string }> = {
  "zh-CN": {
    intro: "（Homebot：用户在 HomePod/iPhone 上对 Siri 说了这句话，你的回复会由 Siri 用中文朗读出来。",
    echo: (tag) => `回复请以 ${tag} 开头。`,
    style: "用中文简短口语回答，不用 markdown 和表情。",
    end: (tag) => `如果用户想结束对话，就以 ${tag} [end] 开头，再简短道别。`,
    statement: "用陈述句结尾，不要以问题结尾。",
    close: "）",
  },
  en: {
    intro: "(Homebot: the user said this to Siri on a HomePod or iPhone, and Siri reads your reply aloud in English.",
    echo: (tag) => `Start your reply with ${tag}.`,
    style: "Answer in English, short and spoken. No markdown or emoji.",
    end: (tag) => `If the user wants to end the conversation, start with ${tag} [end], then say a short goodbye.`,
    statement: "End with a statement, not a question.",
    close: ")",
  },
  es: {
    intro: "(Homebot: el usuario le dijo esto a Siri en un HomePod o iPhone, y Siri lee tu respuesta en voz alta en español.",
    echo: (tag) => `Empieza tu respuesta con ${tag}.`,
    style: "Responde en español, breve y hablado. Sin markdown ni emojis.",
    end: (tag) => `Si el usuario quiere terminar la conversación, empieza con ${tag} [end] y despídete brevemente.`,
    statement: "Termina con una afirmación, no con una pregunta.",
    close: ")",
  },
  fr: {
    intro: "(Homebot : l’utilisateur a dit ceci à Siri sur un HomePod ou un iPhone, et Siri lit ta réponse à voix haute en français.",
    echo: (tag) => `Commence ta réponse par ${tag}.`,
    style: "Réponds en français, de façon brève et parlée. Pas de markdown ni d’emoji.",
    end: (tag) => `Si l’utilisateur veut terminer la conversation, commence par ${tag} [end], puis dis au revoir brièvement.`,
    statement: "Termine par une affirmation, pas par une question.",
    close: ")",
  },
  de: {
    intro: "(Homebot: Der Nutzer hat das zu Siri auf einem HomePod oder iPhone gesagt, und Siri liest deine Antwort auf Deutsch vor.",
    echo: (tag) => `Beginne deine Antwort mit ${tag}.`,
    style: "Antworte auf Deutsch, kurz und gesprochen. Kein Markdown, keine Emojis.",
    end: (tag) => `Wenn der Nutzer das Gespräch beenden will, beginne mit ${tag} [end] und verabschiede dich kurz.`,
    statement: "Ende mit einer Aussage, nicht mit einer Frage.",
    close: ")",
  },
  it: {
    intro: "(Homebot: l’utente ha detto questo a Siri su un HomePod o un iPhone, e Siri legge la tua risposta ad alta voce in italiano.",
    echo: (tag) => `Inizia la risposta con ${tag}.`,
    style: "Rispondi in italiano, in modo breve e parlato. Niente markdown né emoji.",
    end: (tag) => `Se l’utente vuole chiudere la conversazione, inizia con ${tag} [end], poi saluta brevemente.`,
    statement: "Chiudi con un’affermazione, non con una domanda.",
    close: ")",
  },
  "pt-BR": {
    intro: "(Homebot: o usuário disse isto à Siri em um HomePod ou iPhone, e a Siri lê sua resposta em voz alta em português.",
    echo: (tag) => `Comece sua resposta com ${tag}.`,
    style: "Responda em português do Brasil, de forma curta e falada. Sem markdown nem emoji.",
    end: (tag) => `Se o usuário quiser encerrar a conversa, comece com ${tag} [end] e depois se despeça em poucas palavras.`,
    statement: "Termine com uma afirmação, não com uma pergunta.",
    close: ")",
  },
  ru: {
    intro: "(Homebot: пользователь сказал это Siri на HomePod или iPhone, и Siri прочитает твой ответ вслух по-русски.",
    echo: (tag) => `Начни ответ с ${tag}.`,
    style: "Отвечай по-русски, коротко и разговорно. Без markdown и эмодзи.",
    end: (tag) => `Если пользователь хочет закончить разговор, начни с ${tag} [end], а затем коротко попрощайся.`,
    statement: "Закончи утверждением, а не вопросом.",
    close: ")",
  },
  ja: {
    intro: "（Homebot：ユーザーが HomePod または iPhone の Siri にこう話しかけました。あなたの返事は Siri が日本語で読み上げます。",
    echo: (tag) => `返事は ${tag} で始めてください。`,
    style: "日本語の短い話し言葉で答えてください。Markdown と絵文字は使わないでください。",
    end: (tag) => `ユーザーが会話を終えたい場合は、${tag} [end] で始め、短く別れのあいさつをしてください。`,
    statement: "質問ではなく、文で締めくくってください。",
    close: "）",
  },
  ko: {
    intro: "(Homebot: 사용자가 HomePod 또는 iPhone의 Siri에게 한 말입니다. 답은 Siri가 한국어로 소리 내어 읽습니다.",
    echo: (tag) => `답의 맨 앞에 ${tag} 표시를 그대로 쓰세요.`,
    style: "한국어로 짧게, 말하듯이 답하세요. 마크다운과 이모지는 쓰지 마세요.",
    end: (tag) => `사용자가 대화를 끝내려고 하면 ${tag} [end]로 시작하고 짧게 작별 인사를 하세요.`,
    statement: "질문이 아니라 평서문으로 끝내세요.",
    close: ")",
  },
  "zh-TW": {
    intro: "（Homebot：使用者在 HomePod/iPhone 上對 Siri 說了這句話，你的回覆會由 Siri 用中文朗讀出來。",
    echo: (tag) => `回覆請以 ${tag} 開頭。`,
    style: "用繁體中文（台灣用語）簡短口語回答，不用 markdown 和表情符號。",
    end: (tag) => `如果使用者想結束對話，就以 ${tag} [end] 開頭，再簡短道別。`,
    statement: "用陳述句結尾，不要以問題結尾。",
    close: "）",
  },
};

/** Languages written without spaces between sentences. */
const UNSPACED = new Set<ReplyLang>(["zh-CN", "zh-TW", "ja"]);

/**
 * `style`: custom style text; `null` disables the style hint; undefined uses the default.
 * `turn`: the bot turn within a conversation run (DESIGN §18.4); absent for one-shot questions.
 */
export function buildEnvelope({ id, text, lang, strictEcho, style, test = false, turn }: {
  id: string;
  text: string;
  lang: ReplyLang;
  strictEcho: boolean;
  style?: string | null | undefined;
  test?: boolean;
  turn?: number | undefined;
}): string {
  const s = Object.hasOwn(STYLE, lang) ? STYLE[lang] : STYLE.en;
  // `lang` in the head is the fallback reply language (and the Speak Text voice).
  const head = `[Homebot ${test ? "test" : "voice"} · ${requestMarker(id)} · ${lang}]`;
  // A conversation turn may end the run: `[end]` counts only right after the echo tag (S25). A
  // one-shot question can't be answered back, so it ends on a statement.
  const ending = turn ? (strictEcho ? s.end(echoTag(id)) : "") : s.statement;
  const hint = [s.intro, strictEcho ? s.echo(echoTag(id)) : "", style === null ? "" : (style ?? s.style), ending]
    .filter(Boolean)
    .join(UNSPACED.has(lang) ? "" : " ");
  return `${head}\n${text}\n\n${hint}${s.close}`;
}
