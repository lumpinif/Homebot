// Conversation mode (DESIGN §18): a looping Shortcut asks, the gateway answers and says whether
// to listen again. One invocation is a run; each listen-and-POST is a step. The Shortcut holds no
// policy: end words, silence and the step cap are decided here. Every bot turn goes through
// AskService unchanged, so strict ownership (§4.2) applies to each answer. Nothing said is
// logged; the log holds run ids, steps, outcomes and lengths.
import { messages } from "./i18n.ts";
import { isRunId, RunStore, type LoopResponse } from "./runs.ts";
import type { AskRequest, AskResult } from "./ask.ts";
import type { ReplyLang } from "./lang.ts";
import type { Log } from "./log.ts";

/** Steps per run, fixed in the Shortcut: the gateway can end a run earlier, never later. */
export const CONVERSATION_STEPS = 10;

/**
 * Whole utterances that end a run (punctuation and spaces ignored; DESIGN §18.2, Q18-2). Every
 * language's list counts on every Shortcut: Siri may write a phrase in the user's language
 * whatever the Shortcut's (S25: "没有了" and "结束" on an English Shortcut). Never a substring:
 * "怎么结束这个项目" is a question. While the entry chooser asks a yes/no question, its own yes/no
 * words win (Conversation.swift).
 */
export const END_WORDS: Record<ReplyLang, string[]> = {
  "zh-CN": ["结束", "退出", "再见", "谢谢", "没事了", "不用了", "没有了", "没了", "没有", "就这样", "就这样吧", "就这些", "没别的了", "不需要了", "拜拜", "不", "不了", "不要了"],
  en: ["stop", "goodbye", "thats all", "thanks", "never mind", "thank you", "thats it", "im done", "done", "bye", "nothing", "nothing else", "no thanks", "no thank you", "end", "exit", "quit", "cancel", "no", "nope"],
  es: ["para", "basta", "adiós", "eso es todo", "gracias", "nada más", "déjalo", "nada", "no gracias", "ya está", "listo", "fin", "terminar", "chao", "no"],
  fr: ["stop", "au revoir", "cest tout", "merci", "laisse tomber", "rien", "non merci", "rien dautre", "cest fini", "fini", "terminé", "arrête", "non"],
  de: ["stopp", "schluss", "tschüss", "das wars", "danke", "schon gut", "nichts mehr", "nein danke", "nichts", "das ist alles", "fertig", "ende", "beenden", "nein"],
  it: ["basta", "stop", "ciao", "arrivederci", "è tutto", "grazie", "non importa", "lascia stare", "niente", "nientaltro", "no grazie", "finito", "ho finito", "no"],
  "pt-BR": ["parar", "chega", "tchau", "é só isso", "era só isso", "obrigado", "obrigada", "deixa pra lá", "nada", "só isso", "não obrigado", "não obrigada", "fim", "terminar", "pronto", "não", "nao"],
  // A recognizer may write ё as е, so both spellings are listed.
  ru: ["стоп", "хватит", "пока", "это всё", "это все", "спасибо", "ничего", "не надо", "нет спасибо", "всё", "больше ничего", "конец", "закончить", "нет"],
  ja: ["終わり", "終了", "やめて", "さようなら", "ありがとう", "バイバイ", "もういい", "大丈夫", "大丈夫です", "以上", "以上です", "ないです", "特にない", "結構です", "おしまい", "いいえ"],
  ko: ["그만", "종료", "끝", "안녕", "고마워", "감사합니다", "됐어", "없어", "없어요", "괜찮아", "괜찮아요", "그만할게", "이제 됐어", "아니", "아니요"],
  "zh-TW": ["結束", "退出", "再見", "謝謝", "沒事了", "不用了", "沒有了", "沒了", "沒有", "就這樣", "就這樣吧", "就這些", "沒別的了", "不需要了", "掰掰", "拜拜", "不", "不了", "不要了"],
};

const norm = (s: string): string => s.normalize("NFKC").toLowerCase().replace(/[\p{P}\p{S}]/gu, "").replace(/\s+/g, " ").trim();
const ALL_END_WORDS = new Set(Object.values(END_WORDS).flat().map(norm));
/** A whole utterance from any language's list ends the run. */
export const isEndWord = (text: string): boolean => ALL_END_WORDS.has(norm(text));

interface RunState {
  botKey: string;
  lang: ReplyLang;
  /** The Shortcut's step cap, as sent at the start. */
  last: number;
  /** Bot turns taken in this run. */
  turns: number;
  /** Whether the previous bot turn of this run was answered (enables the follow-up wait). */
  answered: boolean;
}

export interface ConversationStep {
  run: string;
  step: number;
  last: number;
  text: string;
  /** The Shortcut's own first question, spoken at the start of a run. */
  prompt: string;
  botKey: string;
  tokenId: string;
  lang: ReplyLang;
  signal?: AbortSignal | undefined;
}

export class ConversationService {
  runs: RunStore<RunState>;
  ask: { ask(r: AskRequest): Promise<AskResult> };
  log: Log;
  /** Current follow-up idle wait (DESIGN §18.3); read per step so a config change applies. */
  followupIdleMs: () => number;

  constructor({ ask, log = () => {}, now = Date.now, followupIdleMs = () => 0 }: {
    ask: { ask(r: AskRequest): Promise<AskResult> };
    log?: Log;
    now?: () => number;
    followupIdleMs?: () => number;
  }) {
    this.ask = ask;
    this.log = log;
    this.followupIdleMs = followupIdleMs;
    this.runs = new RunStore<RunState>({ now });
  }

  async handle({ run, step, last, text, prompt, botKey, tokenId, lang, signal }: ConversationStep): Promise<LoopResponse> {
    const m = messages(lang);
    if (step === 0) {
      const cap = Math.min(Math.max(last, 0), CONVERSATION_STEPS);
      const end = cap <= 0;
      const first = prompt.trim().slice(0, 200) || m.more();
      const started = this.runs.start(tokenId, { botKey, lang, last: cap, turns: 0, answered: false }, async (id): Promise<LoopResponse> => ({ say: first, ask: m.more(), mode: "v2", next: end ? "end" : "listen", run: id }));
      if (end) this.runs.finish(started.id);
      this.log({ event: "conversation", run: started.id.slice(0, 6), step: 0 });
      return started.response;
    }
    const restart = (r: string): LoopResponse => ({ say: m.restart(), ask: m.more(), mode: "v1", next: "end", run: r });
    if (!isRunId(run)) {
      this.log({ event: "conversation", run: "invalid", step, outcome: "unknown" });
      return restart("");
    }
    const c = this.runs.check(run, tokenId, step);
    // A retry is answered only for the bot its run belongs to (conversation review N1).
    if (c.kind === "repeat" && c.state.botKey === botKey) {
      this.log({ event: "conversation", run: run.slice(0, 6), step, repeat: true });
      return c.response as Promise<LoopResponse>; // the stored response of this run's own step
    }
    if (c.kind !== "next" || c.state.botKey !== botKey) {
      this.log({ event: "conversation", run: run.slice(0, 6), step, outcome: c.kind === "next" || c.kind === "repeat" ? "other-bot" : c.kind });
      return restart(run);
    }
    const s = c.state;
    return this.runs.take(run, step, async (): Promise<LoopResponse> => {
      const stop = (say: string, outcome: string): LoopResponse => {
        this.runs.finish(run);
        this.log({ event: "conversation", run: run.slice(0, 6), step, outcome });
        return { say, ask: m.more(), mode: "v1", next: "end", run };
      };
      // Silence and end words end the run; nothing reaches the bot.
      if (!norm(text)) return stop(m.goodbye(), "empty");
      if (isEndWord(text)) return stop(m.goodbye(), "end-word");
      const wait = s.answered ? Math.min(Math.max(this.followupIdleMs() || 0, 0), 10_000) : 0;
      s.turns++;
      let r: AskResult;
      try {
        r = await this.ask.ask({ botKey, text, lang, turn: s.turns, waitIdleMs: wait, ...(signal ? { signal } : {}) });
      } catch {
        // A step that fails ends its run, and retries get this same answer (conversation review S2).
        return stop(m.internalError(), "error");
      }
      s.answered = r.outcome === "answered";
      // Only a proved answer keeps listening; every refusal, error or timeout ends the run, and so
      // does a bot that marked the user's turn as the end (S25).
      const end = !s.answered || r.ended === true || step >= s.last;
      if (end) this.runs.finish(run);
      this.log({ event: "conversation", run: run.slice(0, 6), step, turn: s.turns, outcome: r.outcome, next: end ? "end" : "listen" });
      return { say: r.text, ask: m.more(), mode: "v1", next: end ? "end" : "listen", run };
    });
  }
}
