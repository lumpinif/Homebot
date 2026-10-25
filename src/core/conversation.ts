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

/** Whole utterances that end a run (punctuation and spaces ignored; DESIGN §18.2, Q18-2). */
export const END_WORDS: Record<ReplyLang, string[]> = {
  "zh-CN": ["结束", "退出", "再见", "谢谢", "没事了", "不用了"],
  en: ["stop", "goodbye", "thats all", "thanks", "never mind"],
  es: ["para", "basta", "adiós", "eso es todo", "gracias", "nada más", "déjalo"],
  fr: ["stop", "au revoir", "cest tout", "merci", "laisse tomber", "rien"],
  de: ["stopp", "schluss", "tschüss", "das wars", "danke", "schon gut", "nichts mehr"],
  it: ["basta", "stop", "ciao", "arrivederci", "è tutto", "grazie", "non importa", "lascia stare"],
  "pt-BR": ["parar", "chega", "tchau", "é só isso", "era só isso", "obrigado", "obrigada", "deixa pra lá"],
  // A recognizer may write ё as е, so both spellings are listed.
  ru: ["стоп", "хватит", "пока", "это всё", "это все", "спасибо", "ничего", "не надо"],
  ja: ["終わり", "終了", "やめて", "さようなら", "ありがとう", "バイバイ", "もういい"],
  ko: ["그만", "종료", "끝", "안녕", "고마워", "감사합니다", "됐어"],
  "zh-TW": ["結束", "退出", "再見", "謝謝", "沒事了", "不用了"],
};

const norm = (s: string): string => s.normalize("NFKC").toLowerCase().replace(/[\p{P}\p{S}]/gu, "").replace(/\s+/g, " ").trim();
const isEndWord = (text: string, lang: ReplyLang): boolean => END_WORDS[lang].includes(norm(text));

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
      if (isEndWord(text, lang)) return stop(m.goodbye(), "end-word");
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
      // Only a proved answer keeps listening; every refusal, error or timeout ends the run.
      const end = !s.answered || step >= s.last;
      if (end) this.runs.finish(run);
      this.log({ event: "conversation", run: run.slice(0, 6), step, turn: s.turns, outcome: r.outcome, next: end ? "end" : "listen" });
      return { say: r.text, ask: m.more(), mode: "v1", next: end ? "end" : "listen", run };
    });
  }
}
