// AskService: one voice question -> one owned bot reply, within one hard deadline (DESIGN §4).
// Authentication/authorization happen in the server before this is called.
import { setTimeout as sleep } from "node:timers/promises";
import { syncToEnd, decideReply, HistoryTooLongError, type Entry, type Turn } from "./entries.ts";
import { buildEnvelope, newRequestId } from "./envelope.ts";
import { speakable } from "./speech.ts";
import { messages } from "./i18n.ts";
import { BdkError, type BdkClient } from "./bdk.ts";
import type { Bot, Cursor, Settings } from "./store.ts";
import { errorName, type Log } from "./log.ts";
import type { ReplyLang } from "./lang.ts";

/** `POST /messages` delivery values that mean the message was taken (as in @cursor/bdk). */
const ACCEPTED = new Set(["accepted_temporal", "duplicate"]);

class Deadline extends Error {}
class Disconnected extends Error {}

export interface AskResult {
  text: string;
  outcome: string;
  requestId?: string;
  reason?: string;
  timings: Record<string, number>;
}

/** What AskService needs from the config store (ConfigStore satisfies it). */
export interface AskConfig {
  readonly settings: Settings;
  bot(key: string): Bot | undefined;
  refresh?(): Promise<unknown>;
}

/** What AskService needs from the state store (StateStore satisfies it). */
export interface AskState {
  cursor(bot: string): Cursor | undefined;
  setCursor(bot: string, c: { cursor: string; maxSeq: string }, o?: { sessionId?: string }): Promise<unknown>;
  refresh?(): Promise<unknown>;
}

export interface AskRequest {
  botKey: string;
  text: string;
  /** Reply language from the Shortcut's Siri language (default English). */
  lang?: ReplyLang;
  /** Aborted when the HTTP client disconnects. */
  signal?: AbortSignal;
  test?: boolean;
  /** The bot turn within a conversation run (DESIGN §18.4); absent for one-shot questions. */
  turn?: number | undefined;
  /**
   * Follow-up inside a run whose previous turn was answered (DESIGN §18.3): wait up to this long
   * for the session to go idle instead of answering "busy" at once. Any user entry seen during
   * the wait answers "busy" and nothing is sent. 0 or absent: no wait.
   */
  waitIdleMs?: number | undefined;
}

export class AskService {
  config: AskConfig;
  state: AskState;
  bdk: BdkClient;
  log: Log;
  warmMaxPages: number;
  inFlight = new Set<string>();
  persisting: Promise<unknown> = Promise.resolve();
  /** Turn-tail tracing (DESIGN §18.3): off when `maxMs` is 0. */
  traceIdle: { maxMs: number; everyMs: number };
  #tails = new Map<string, AbortController>();

  constructor({ config, state, bdk, log = () => {}, warmMaxPages = 20, traceIdle = { maxMs: 0, everyMs: 1000 } }: {
    config: AskConfig;
    state: AskState;
    bdk: BdkClient;
    log?: Log;
    warmMaxPages?: number;
    traceIdle?: { maxMs: number; everyMs: number };
  }) {
    this.config = config;
    this.state = state;
    this.bdk = bdk;
    this.log = log;
    this.warmMaxPages = warmMaxPages;
    this.traceIdle = traceIdle;
  }

  async ask({ botKey, text, lang = "en", signal, test = false, turn, waitIdleMs = 0 }: AskRequest): Promise<AskResult> {
    const t0 = Date.now();
    const timings: Record<string, number> = {};
    const mark = (k: string): number => (timings[k] = Date.now() - t0);
    // Bots may have been added/removed by the setup page or another CLI process.
    await this.config.refresh?.();
    await this.state.refresh?.();
    const settings = this.config.settings;
    const bot = this.config.bot(botKey);
    const m = messages(lang);
    const question = String(text ?? "").trim();
    /**
     * Turn state per poll after sending (turnCode). Diagnostics for the live check of turn
     * values; never used to decide ownership. No content.
     */
    let turns = "";
    const done = (outcome: string, say: string, extra: { requestId?: string; reason?: string; [k: string]: unknown } = {}): AskResult => {
      const r = { text: say, outcome, timings, ...extra };
      mark("total_ms");
      this.log({ event: "ask", bot: botKey, outcome, ...extra, q_len: question.length, ...(settings.logText ? { q: question } : {}), ...(turns ? { turns } : {}), ...timings });
      return r;
    };

    const cur = bot && this.state.cursor(bot.key);
    // A cursor tagged with another conversation is not this bot's position.
    if (!bot || !cur || (cur.sessionId && cur.sessionId !== bot.sessionId)) return done("not-configured", m.botNotConfigured());
    // A new request ends the previous answer's tail trace: from here on the session is ours again.
    this.#tails.get(bot.sessionId)?.abort("superseded");
    if (!question) return done("empty", m.emptyQuestion());
    if ([...question].length > settings.maxQuestionChars) return done("too-long", m.tooLong());
    // Guard per session (not per key), so no two Homebot requests ever share one conversation.
    if (this.inFlight.has(bot.sessionId)) return done("in-flight", m.inFlight(bot.name));

    this.inFlight.add(bot.sessionId);
    const requestId = newRequestId();
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(new Deadline()), settings.answerBudgetMs);
    const onDisconnect = (): void => ctl.abort(new Disconnected());
    signal?.addEventListener("abort", onDisconnect, { once: true });
    if (signal?.aborted) onDisconnect();
    const sig = ctl.signal;
    const fetchPage = (c: string) => this.bdk.getEntries(bot.sessionId, c, { signal: sig });
    let phase = "before-send";
    let pos = { cursor: cur.cursor, maxSeq: cur.maxSeq };

    try {
      // Baseline: warm sync from the persisted cursor to the real end; transient errors retry
      // within the same deadline.
      // A follow-up that may wait judges user entries from its arrival on, the first sync
      // included: a desktop message that lands there must not slip below the new baseline
      // (conversation review B1).
      let sawUser = false;
      const watchUsers = waitIdleMs > 0 ? { onEntries: (es: Entry[]) => (sawUser ||= es.some((e) => e.role === "user")) } : {};
      let base = await syncToEnd((c) => retrying(() => fetchPage(c), sig, 3), { ...pos, maxPages: this.warmMaxPages, ...watchUsers });
      pos = { cursor: base.cursor, maxSeq: base.maxSeq };
      mark("baseline_ms");
      if (isBusy(base.turn) && waitIdleMs > 0) {
        // A scheduling allowance, never evidence of ownership: each poll is a full sync to the
        // end, so the baseline is taken only after the wait, and any user entry that arrived
        // meanwhile (someone else's message, in any version) refuses the follow-up. Deliveries
        // seen here fall below the baseline and are never spoken (DESIGN §18.3).
        const until = Date.now() + waitIdleMs;
        if (sawUser) return done("busy", m.busy(bot.name), { requestId, wait: "user" });
        while (isBusy(base.turn) && Date.now() < until) {
          // Never sleep past the allowance (conversation review S4).
          await sleep(Math.max(0, Math.min(settings.pollMs, until - Date.now())), undefined, { signal: sig });
          base = await syncToEnd((c) => retrying(() => fetchPage(c), sig, 3), { ...pos, maxPages: this.warmMaxPages, ...watchUsers });
          pos = { cursor: base.cursor, maxSeq: base.maxSeq };
          if (sawUser) return done("busy", m.busy(bot.name), { requestId, wait: "user" });
        }
        mark("idle_wait_ms");
      }
      if (isBusy(base.turn)) return done("busy", m.busy(bot.name), { requestId });
      if (sig.aborted) throw sig.reason; // last point where nothing has been sent

      phase = "sent";
      const envelope = buildEnvelope({ id: requestId, text: question, lang, strictEcho: bot.strictEcho, style: bot.style, test, turn });
      // Same messageId on every attempt: the API answers `duplicate` if one already arrived.
      const { delivery } = await retrying(() => this.bdk.sendMessage(bot.sessionId, { messageId: requestId, text: envelope }, { signal: sig }), sig, 4);
      mark("sent_ms");
      // The official client treats any other delivery as "not accepted". We can't be sure nothing
      // arrived, so we say it may have been delivered, but stop waiting. A missing field keeps
      // the old behavior (wait for an owned reply). The value itself is never logged: an
      // unexpected string could carry anything (BDK review S2).
      if (delivery !== undefined && !ACCEPTED.has(delivery)) {
        return done("not-accepted", m.noReplyInTime(bot.name), { requestId, delivery: "unknown" });
      }

      const seen: Entry[] = [];
      // True only when the last poll read every page to the end. A failed poll keeps its partial
      // evidence, which may justify a refusal, but never an acceptance: the unread pages could
      // hold a foreign turn (O2) (milestone review B1).
      let complete = true;
      for (;;) {
        // One ownership decision over every version seen so far; the spoken text is the one
        // this decision checked. Only the first proved delivery is spoken: activity flags never
        // prove that a later delivery belongs to this request (BDK review B1, B2).
        const d = decideReply(seen, { baseMaxSeq: base.maxSeq, requestId, strictEcho: bot.strictEcho });
        if (d.status === "refuse") return done("refused", m.refused(), { requestId, reason: d.reason });
        if (d.status === "accept" && complete) {
          mark("reply_ms");
          const say = speakable(d.text, settings.maxSpokenChars[lang] ?? 600);
          if (!say) return done("unspeakable", m.unspeakable(), { requestId });
          if (this.traceIdle.maxMs > 0) this.#traceTail(bot, requestId, pos);
          return done("answered", say, { requestId, a_len: say.length });
        }
        await sleep(Date.now() - t0 > 10_000 ? settings.pollMs * 2 : settings.pollMs, undefined, { signal: sig });
        try {
          // Entries go into `seen` page by page: if a later page fails, the evidence already
          // fetched still counts. The cursor stays put, so the retry fetches them again; extra
          // versions only add evidence (BDK re-review R1).
          const page = await syncToEnd(fetchPage, { ...pos, maxPages: 5, onEntries: (es) => seen.push(...es) });
          pos = { cursor: page.cursor, maxSeq: page.maxSeq };
          complete = true;
          if (turns.length < 80) turns += turnCode(page.turn);
        } catch (e) {
          complete = false;
          if (sig.aborted) throw sig.reason;
          if (e instanceof BdkError && e.kind === "auth") throw e;
          timings.poll_errors = (timings.poll_errors ?? 0) + 1; // transient; keep polling until the deadline
        }
      }
    } catch (e) {
      const err: unknown = sig.aborted ? sig.reason : e;
      if (err instanceof Deadline || err instanceof Disconnected) {
        const why = err instanceof Deadline ? "deadline" : "disconnect";
        return phase === "before-send"
          ? done(`not-sent:${why}`, m.notSent(), { requestId })
          : done(`no-reply:${why}`, m.noReplyInTime(bot.name), { requestId });
      }
      if (err instanceof BdkError && err.kind === "auth") return done("auth-failed", m.authFailed(), { requestId, phase });
      if (err instanceof HistoryTooLongError) return done("history-too-long", m.botNotConfigured(), { requestId });
      if (err instanceof BdkError) {
        // A 4xx rejection means nothing was accepted. Network/5xx after sending started is uncertain.
        const uncertain = phase === "sent" && err.kind !== "request";
        return uncertain
          ? done("no-reply:upstream", m.noReplyInTime(bot.name), { requestId, status: err.status ?? 0 })
          : done("upstream", m.upstreamDown(), { requestId, phase, status: err.status ?? 0 });
      }
      return done("error", m.internalError(), { requestId, phase, error: errorName(err) });
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener("abort", onDisconnect);
      this.inFlight.delete(bot.sessionId);
      this.#persistCursor(bot, pos); // not awaited: never delays the spoken response
    }
  }

  /**
   * Diagnostics only (DESIGN §18.3): after an answer was returned, poll the session (GET only)
   * until its turn is fully idle, and log how long that took (`turn-tail`). This measures the
   * SESSION, not our turn: `user_entries`/`deliveries` count other activity seen meanwhile, and
   * "timeout" means idle was not observed. It holds no guard, moves no persisted cursor and
   * decides nothing; at most one runs per session, and a new request for the session stops it.
   */
  #traceTail(bot: Bot, requestId: string, from: { cursor: string; maxSeq: string }): void {
    const ctl = new AbortController();
    this.#tails.set(bot.sessionId, ctl);
    const t0 = Date.now();
    const timer = setTimeout(() => ctl.abort("timeout"), this.traceIdle.maxMs);
    timer.unref();
    const sig = ctl.signal;
    void (async () => {
      let polls = 0;
      let outcome = "timeout";
      let userEntries = 0;
      let deliveries = 0;
      let pos = from;
      try {
        for (;;) {
          await sleep(this.traceIdle.everyMs, undefined, { signal: sig, ref: false });
          const page = await syncToEnd((c) => this.bdk.getEntries(bot.sessionId, c, { signal: sig }), {
            ...pos,
            maxPages: 5,
            onEntries: (es) => {
              for (const e of es) {
                if (e.role === "user") userEntries++;
                else if (e.kind === "send-message") deliveries++;
              }
            },
          });
          pos = { cursor: page.cursor, maxSeq: page.maxSeq };
          polls++;
          if (turnCode(page.turn) === "I") {
            outcome = "idle";
            break;
          }
        }
      } catch (e) {
        outcome = sig.aborted ? (sig.reason === "superseded" ? "superseded" : "timeout") : `error:${errorName(e)}`;
      } finally {
        clearTimeout(timer);
        if (this.#tails.get(bot.sessionId) === ctl) this.#tails.delete(bot.sessionId);
        this.log({ event: "turn-tail", bot: bot.key, requestId, outcome, polls, user_entries: userEntries, deliveries, ...(outcome === "idle" ? { idle_after_ms: Date.now() - t0 } : {}) });
      }
    })();
  }

  /** Stop all tail traces (shutdown, tests). */
  stop(): void {
    for (const c of this.#tails.values()) c.abort("superseded");
  }

  /**
   * Ordered, forward-only cursor writes off the response path; failures are logged, not thrown.
   * Tagged with the session, and skipped if the bot was removed or re-added meanwhile (S1).
   */
  #persistCursor(bot: Bot, pos: { cursor: string; maxSeq: string }): void {
    this.persisting = this.persisting.then(async () => {
      try {
        await this.config.refresh?.();
        if (this.config.bot(bot.key)?.sessionId !== bot.sessionId) return;
        await this.state.setCursor(bot.key, pos, { sessionId: bot.sessionId });
      } catch (e) {
        this.log({ event: "persist-error", bot: bot.key, error: errorName(e) });
      }
    });
  }

  /** Wait for pending cursor writes (shutdown, tests). */
  flush(): Promise<unknown> {
    return this.persisting;
  }
}

/**
 * Turn shape verified by probe P1 (2026-10-21): { idle: boolean, inFlight: boolean, queued: number }.
 * Busy rule as in @cursor/bdk's grokbot-agents extension, plus `idle === false`.
 */
export function isBusy(turn: Turn | undefined): boolean {
  return turn?.idle === false || turn?.inFlight === true || (typeof turn?.queued === "number" && turn.queued > 0);
}

/**
 * One character per poll for the log: `B` busy (isBusy), `I` a fully valid idle state
 * (`idle: true, inFlight: false, queued: 0`), `?` anything else (missing or malformed).
 */
export function turnCode(turn: Turn | undefined): "B" | "I" | "?" {
  if (isBusy(turn)) return "B";
  return turn?.idle === true && turn.inFlight === false && turn.queued === 0 ? "I" : "?";
}

/**
 * Run `fn`, retrying network/5xx BDK errors with a short backoff while `sig` allows.
 * Auth and 4xx errors are not retried.
 */
async function retrying<T>(fn: () => Promise<T>, sig: AbortSignal, retries: number): Promise<T> {
  for (let attempt = 0; ; attempt++) {
    try {
      return await fn();
    } catch (e) {
      if (sig.aborted) throw sig.reason;
      const retryable = e instanceof BdkError && (e.kind === "network" || e.kind === "upstream");
      if (!retryable || attempt >= retries) throw e;
      await sleep(200 * (attempt + 1), undefined, { signal: sig });
    }
  }
}
