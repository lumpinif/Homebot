// The text Homebot sends to a bot (DESIGN §5.4). Line 1 is a stable marker bots can key on;
// `hb:<id>` lets us find our own user entry. The echoed `[hb:<id>]` is evidence (not proof) that
// a reply answers this request; see DESIGN §4.2 for its limits.
import { randomBytes } from "node:crypto";
import type { ReplyLang } from "./lang.ts";

export const newRequestId = (): string => randomBytes(6).toString("hex");
export const requestMarker = (id: string): string => `hb:${id}`;
export const echoTag = (id: string): string => `[hb:${id}]`;

/**
 * `style` asks for the token's language, whatever the question's: the Shortcut's Speak Text voice
 * is fixed to it and can't read other scripts (DECISIONS item 31, which replaces item 29 D3).
 */
export const STYLE: Record<ReplyLang, { intro: string; turn: (n: number) => string; echo: (tag: string) => string; style: string }> = {
  "zh-CN": {
    turn: (n) => `这是语音对话的第 ${n} 轮，用户听完可以马上接着说；除非必要，不要以问题结尾；房间里只会听到你这一轮的第一条消息。`,
    intro: "（Homebot：这是对 HomePod/iPhone 上的 Siri 说的话，你的回复会在房间里被朗读出来。",
    echo: (tag) => `回复请以 ${tag} 开头。`,
    style: "然后用中文回答，1 到 3 句简短口语，总共不超过 80 个字；回复由中文语音朗读，所以即使提问用的是别的语言，也要用中文回答。不要 markdown、链接、列表、代码或表情。）",
  },
  en: {
    turn: (n) => `This is turn ${n} of a voice conversation; the user can reply right away. End with a statement unless a question is needed. The room hears only your first message for this turn.`,
    intro: "(Homebot: this was spoken to Siri on a HomePod/iPhone; your reply is read aloud in the room.",
    echo: (tag) => `Start your reply with ${tag}.`,
    style: "Then answer in English, in 1-3 short spoken sentences, at most about 50 words. An English voice reads it aloud, so answer in English even if the question is in another language. No markdown, links, lists, code or emoji.)",
  },
  es: {
    turn: (n) => `Este es el turno ${n} de una conversación por voz; el usuario puede responder enseguida. Termina con una afirmación salvo que haga falta una pregunta. En la habitación solo se oye tu primer mensaje de este turno.`,
    intro: "(Homebot: esto se le dijo a Siri en un HomePod o iPhone; tu respuesta se leerá en voz alta en la habitación.",
    echo: (tag) => `Empieza tu respuesta con ${tag}.`,
    style: "Después responde en español, en 1 a 3 frases breves y habladas, como mucho unas 50 palabras. Una voz en español lo lee en voz alta, así que responde en español aunque la pregunta esté en otro idioma. Sin markdown, enlaces, listas, código ni emojis.)",
  },
  fr: {
    turn: (n) => `C’est le tour ${n} d’une conversation vocale ; l’utilisateur peut répondre tout de suite. Termine par une affirmation sauf si une question est nécessaire. La pièce n’entend que ton premier message de ce tour.`,
    intro: "(Homebot : ceci a été dit à Siri sur un HomePod ou un iPhone ; ta réponse sera lue à voix haute dans la pièce.",
    echo: (tag) => `Commence ta réponse par ${tag}.`,
    style: "Ensuite, réponds en français, en 1 à 3 phrases courtes et parlées, environ 50 mots au plus. Une voix française la lit à voix haute, donc réponds en français même si la question est dans une autre langue. Pas de markdown, de liens, de listes, de code ni d’emoji.)",
  },
  de: {
    turn: (n) => `Das ist Runde ${n} eines Sprachgesprächs; der Nutzer kann sofort antworten. Ende mit einer Aussage, außer eine Frage ist nötig. Im Raum ist nur deine erste Nachricht dieser Runde zu hören.`,
    intro: "(Homebot: Das wurde zu Siri auf einem HomePod oder iPhone gesagt; deine Antwort wird im Raum vorgelesen.",
    echo: (tag) => `Beginne deine Antwort mit ${tag}.`,
    style: "Antworte dann auf Deutsch, in 1 bis 3 kurzen, gesprochenen Sätzen, höchstens etwa 50 Wörter. Eine deutsche Stimme liest sie vor, also antworte auf Deutsch, auch wenn die Frage in einer anderen Sprache ist. Kein Markdown, keine Links, Listen, Code oder Emojis.)",
  },
  it: {
    turn: (n) => `Questo è il turno ${n} di una conversazione vocale; l’utente può rispondere subito. Chiudi con un’affermazione, a meno che non serva una domanda. Nella stanza si sente solo il tuo primo messaggio di questo turno.`,
    intro: "(Homebot: questo è stato detto a Siri su un HomePod o un iPhone; la tua risposta verrà letta ad alta voce nella stanza.",
    echo: (tag) => `Inizia la risposta con ${tag}.`,
    style: "Poi rispondi in italiano, con 1-3 frasi brevi e parlate, al massimo circa 50 parole. Una voce italiana la legge ad alta voce, quindi rispondi in italiano anche se la domanda è in un’altra lingua. Niente markdown, link, elenchi, codice o emoji.)",
  },
  "pt-BR": {
    turn: (n) => `Esta é a rodada ${n} de uma conversa por voz; o usuário pode responder logo em seguida. Termine com uma afirmação, a menos que uma pergunta seja necessária. No ambiente só se ouve a sua primeira mensagem desta rodada.`,
    intro: "(Homebot: isto foi dito à Siri em um HomePod ou iPhone; sua resposta será lida em voz alta no ambiente.",
    echo: (tag) => `Comece sua resposta com ${tag}.`,
    style: "Depois responda em português do Brasil, em 1 a 3 frases curtas e faladas, no máximo umas 50 palavras. Uma voz em português lê a resposta em voz alta, então responda em português mesmo que a pergunta esteja em outro idioma. Sem markdown, links, listas, código ou emoji.)",
  },
  ru: {
    turn: (n) => `Это ход ${n} голосового разговора; пользователь может сразу ответить. Заканчивай утверждением, если вопрос не нужен. В комнате слышно только твоё первое сообщение в этом ходе.`,
    intro: "(Homebot: это было сказано Siri на HomePod или iPhone; твой ответ прочитают вслух в комнате.",
    echo: (tag) => `Начни ответ с ${tag}.`,
    style: "Затем ответь по-русски, 1–3 короткими разговорными предложениями, не больше примерно 50 слов. Ответ читает вслух русский голос, поэтому отвечай по-русски, даже если вопрос задан на другом языке. Без markdown, ссылок, списков, кода и эмодзи.)",
  },
  ja: {
    turn: (n) => `これは音声での会話の${n}回目です。ユーザーはすぐに返事ができます。質問が必要な場合を除き、文で締めくくってください。部屋で聞こえるのは、この回のあなたの最初のメッセージだけです。`,
    intro: "（Homebot：これは HomePod または iPhone の Siri に話しかけた内容です。あなたの返事は部屋で読み上げられます。",
    echo: (tag) => `返事は ${tag} で始めてください。`,
    style: "続けて、日本語の話し言葉の短い文1〜3つ、全部で80文字以内で答えてください。日本語の音声で読み上げるので、質問が別の言語でも日本語で答えてください。Markdown、リンク、箇条書き、コード、絵文字は使わないでください。）",
  },
  ko: {
    turn: (n) => `음성 대화의 ${n}번째 차례입니다. 사용자는 바로 이어서 말할 수 있습니다. 꼭 필요한 경우가 아니면 질문으로 끝내지 마세요. 방에서는 이번 차례의 첫 메시지만 들립니다.`,
    intro: "(Homebot: HomePod 또는 iPhone의 Siri에게 한 말입니다. 답은 방에서 소리 내어 읽힙니다.",
    echo: (tag) => `답의 맨 앞에 ${tag} 표시를 그대로 쓰세요.`,
    style: "그다음 한국어로, 짧은 구어체 문장 1~3개, 모두 합쳐 약 120자 이내로 답하세요. 한국어 음성이 소리 내어 읽으므로 질문이 다른 언어여도 한국어로 답하세요. 마크다운, 링크, 목록, 코드, 이모지는 쓰지 마세요.)",
  },
  "zh-TW": {
    turn: (n) => `這是語音對話的第 ${n} 輪，使用者聽完可以馬上接著說；除非必要，不要以問題結尾；房間裡只會聽到你這一輪的第一則訊息。`,
    intro: "（Homebot：這是對 HomePod/iPhone 上的 Siri 說的話，你的回覆會在房間裡被朗讀出來。",
    echo: (tag) => `回覆請以 ${tag} 開頭。`,
    style: "然後用繁體中文（台灣用語）回答，1 到 3 句簡短口語，總共不超過 80 個字；回覆由中文語音朗讀，所以即使提問用的是別的語言，也要用繁體中文回答。不要 markdown、連結、清單、程式碼或表情符號。）",
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
  const hint = [s.intro, turn ? s.turn(turn) : "", strictEcho ? s.echo(echoTag(id)) : "", style === null ? "" : (style ?? s.style)]
    .filter(Boolean)
    .join(UNSPACED.has(lang) ? "" : " ");
  return `${head}\n${text}\n\n${hint}`;
}
