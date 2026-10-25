// LAN-facing listener (DESIGN §4.1, §11): /v1/health, /v1/ask, one-time /dl/<id> Shortcut
// downloads, and — only when enabled for a device session — /v1/probe-wait and /v1/lab
// (DESIGN §19). JSON request; /v1/ask answers plain text that Siri reads aloud.
import http from "node:http";
import { readFile } from "node:fs/promises";
import { setTimeout as sleep } from "node:timers/promises";
import { messages } from "../core/i18n.ts";
import { replyLang, type ReplyLang } from "../core/lang.ts";
import { isRecord } from "../core/fsutil.ts";
import type { AskService } from "../core/ask.ts";
import type { TokenStore } from "../core/tokens.ts";
import { errorName, type Log } from "../core/log.ts";
import type { Downloads } from "./downloads.ts";
import { labOff, type LabService } from "../core/lab.ts";
import { ConversationService } from "../core/conversation.ts";

/** Delays (s) the wait probe cycles through; restarts at the first on every gateway start. */
export const PROBE_STEPS = [5, 10, 15, 20, 25, 30, 40, 50, 58];
const ruSeconds = (n: number): string => ({ one: "секунду", few: "секунды" })[new Intl.PluralRules("ru").select(n) as "one" | "few"] ?? "секунд";
export const PROBE_TEXT: Record<ReplyLang, (n: number) => string> = {
  en: (n) => `Waited ${n} seconds.`,
  es: (n) => `He esperado ${n} segundos.`,
  fr: (n) => `J’ai attendu ${n} secondes.`,
  de: (n) => `${n} Sekunden gewartet.`,
  it: (n) => `Ho aspettato ${n} secondi.`,
  "pt-BR": (n) => `Esperei ${n} segundos.`,
  ru: (n) => `Подождал ${n} ${ruSeconds(n)}.`,
  ja: (n) => `${n}秒待ちました。`,
  ko: (n) => `${n}초 기다렸습니다.`,
  "zh-CN": (n) => `等了${n}秒，收到。`,
  "zh-TW": (n) => `等了${n}秒，收到。`,
};

/** What the voice listener needs from the config store (ConfigStore satisfies it). */
export interface VoiceConfig {
  readonly settings: { rateLimitPerMin: number };
  bot(key: string): { sessionId: string } | undefined;
  refresh?(): Promise<unknown>;
}

export function createVoiceServer({ ask, tokens, config, log = () => {}, maxBodyBytes = 16 * 1024, now = Date.now, probeWait = false, probeUnitMs = 1000, downloads, lab, conversation = new ConversationService({ ask, log }) }: {
  ask: Pick<AskService, "ask">;
  tokens: Pick<TokenStore, "verify">;
  config: VoiceConfig;
  log?: Log;
  maxBodyBytes?: number;
  now?: () => number;
  probeWait?: boolean;
  probeUnitMs?: number | undefined;
  downloads?: Downloads | undefined;
  /** Device-experiment handler; /v1/lab exists only when this is set (`start --lab`). */
  lab?: Pick<LabService, "handle"> | undefined;
  /** Conversation runs for `v: "2"` requests on /v1/ask (DESIGN §18.2). */
  conversation?: Pick<ConversationService, "handle">;
}): http.Server {
  /** token id -> request times in the last minute */
  const recent = new Map<string, number[]>();
  let probeIdx = 0;

  const text = (res: http.ServerResponse, status: number, body: string): void => {
    res.writeHead(status, { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" });
    res.end(body);
  };
  const json = (res: http.ServerResponse, status: number, body: unknown): void => {
    res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
    res.end(JSON.stringify(body));
  };
  const tokenHeader = (req: http.IncomingMessage): string => {
    const tok = req.headers["x-homebot-token"];
    return (Array.isArray(tok) ? tok[0] : tok) ?? "";
  };

  function overLimit(id: string): boolean {
    const t = now();
    const times = (recent.get(id) ?? []).filter((x) => t - x < 60_000);
    times.push(t);
    recent.set(id, times);
    return times.length > config.settings.rateLimitPerMin;
  }

  async function handle(req: http.IncomingMessage, res: http.ServerResponse, ctl: AbortController): Promise<void> {
    const path = (req.url ?? "/").split("?")[0] ?? "/";
    if (req.method === "GET" && path === "/v1/health") return json(res, 200, { ok: true });
    if (probeWait && req.method === "GET" && path === "/v1/probe-wait") return probe(req, res, ctl);
    if (downloads && req.method === "GET" && path.startsWith("/dl/")) return download(res, path.slice(4));
    if (path === "/v1/lab") return labStep(req, res, ctl, lab);
    if (path !== "/v1/ask") return json(res, 404, { error: "not found" });
    if (req.method !== "POST") return json(res, 405, { error: "method not allowed" });
    const body = await readBody(req, res);
    if (body === "too-long") return text(res, 413, messages(undefined).tooLong());
    if (body === "bad-json") return json(res, 400, { error: "bad json" });
    const requested = typeof body.bot === "string" && body.bot ? body.bot : undefined;
    return handleAsk(req, res, ctl, body, requested);
  }

  /** A v2 (conversation) response that ends the run: every refusal and failure is spoken. */
  const endRun = (res: http.ServerResponse, status: number, say: string): void => json(res, status, { say, ask: "", mode: "v1", next: "end", run: "" });

  /** The JSON object body, or why there is none; the caller answers in its own format. */
  async function readBody(req: http.IncomingMessage, res: http.ServerResponse): Promise<Record<string, unknown> | "too-long" | "bad-json"> {
    const chunks: Buffer[] = [];
    let size = 0;
    // No encoding was set on the request, so its chunks are Buffers.
    for await (const chunk of req as AsyncIterable<Buffer>) {
      size += chunk.length;
      if (size > maxBodyBytes) {
        res.setHeader("connection", "close");
        return "too-long";
      }
      chunks.push(chunk);
    }
    try {
      const parsed: unknown = JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}"); // decode once: chunks may split a UTF-8 char
      // Only a JSON object is a request. Anything else (arrays included) is refused before the
      // token is checked, so a malformed body never activates or retires a token (TS review S1).
      if (!isRecord(parsed)) throw new Error();
      return parsed;
    } catch {
      return "bad-json";
    }
  }

  async function handleAsk(req: http.IncomingMessage, res: http.ServerResponse, ctl: AbortController, body: Record<string, unknown>, requested: string | undefined): Promise<void> {
    // v1 Shortcuts get plain text, as always; a v2 (conversation) Shortcut gets JSON in every
    // case, so its loop always has a line to speak and a `next` (DESIGN §18.2).
    const v2 = body.v === "2";
    const fail = (status: number, say: string): void => (v2 ? endRun(res, status, say) : text(res, status, say));
    const int = (v: unknown, d: number): number => (typeof v === "number" ? v : typeof v === "string" && /^\d{1,4}$/.test(v.trim()) ? Number(v) : d);
    try {
      const auth = await tokens.verify(tokenHeader(req), requested);
      if (!auth.ok) {
        // Before authentication we don't know the Shortcut's language: product default (English).
        log({ event: "auth", outcome: auth.reason });
        return auth.reason === "forbidden" ? fail(403, messages("en").forbiddenBot()) : fail(401, messages("en").badToken());
      }
      const botKey = requested ?? auth.record.bot;
      // Tokens are bound to the bot's conversation too: if the key now names another session
      // (removed and re-added), this Shortcut is not valid for it.
      await config.refresh?.();
      if (auth.record.sessionId && config.bot(botKey)?.sessionId !== auth.record.sessionId) {
        log({ event: "auth", outcome: "session-changed" });
        return fail(401, messages("en").badToken());
      }
      const lang = replyLang(auth.record.siriLang); // the Shortcut's Siri language, bound to its token
      // A conversation counts once, at its start: its later steps are bounded by the run's step
      // cap, and a retry must still get its cached answer (conversation review S3).
      if ((!v2 || int(body.step, -1) === 0) && overLimit(auth.record.id)) return fail(200, messages(lang).rateLimited());
      if (ctl.signal.aborted) return; // client left (e.g. during token activation): send nothing to the bot

      if (v2) {
        try {
          const r = await conversation.handle({
            run: typeof body.run === "string" ? body.run : "",
            step: int(body.step, -1),
            last: int(body.last, 0),
            text: typeof body.text === "string" ? body.text : "",
            prompt: typeof body.prompt === "string" ? body.prompt : "",
            botKey,
            tokenId: auth.record.id,
            lang,
            signal: ctl.signal,
          });
          if (!res.destroyed) json(res, 200, r);
        } catch (e) {
          log({ event: "request-error", error: errorName(e), kind: "conversation" });
          if (!res.headersSent && !res.destroyed) endRun(res, 500, messages(lang).internalError());
        }
        return;
      }

      // `test: true` marks the message "[Homebot test]" for the bot (manual curl checks, M3 L3).
      const r = await ask.ask({ botKey, text: typeof body.text === "string" ? body.text : "", lang, signal: ctl.signal, test: body.test === true });
      if (!res.destroyed) text(res, 200, r.text);
    } catch (e) {
      // v1 keeps the outer plain-text 500; a v2 loop always gets a line to speak and `next`.
      if (!v2) throw e;
      log({ event: "request-error", error: errorName(e), kind: "conversation" });
      if (!res.headersSent && !res.destroyed) endRun(res, 500, messages("en").internalError());
    }
  }

  /**
   * One step of the lab Shortcut (DESIGN §19.1). Only lab tokens; nothing reaches a bot. Every
   * answer, refusals and failures included, is JSON with `say` and `next: "end"` where the run
   * stops, so the Shortcut's loop always has a line to speak (milestone review S3). Without
   * `--lab` (no `svc`) a lab token hears that the lab is off; nothing else happens.
   */
  async function labStep(req: http.IncomingMessage, res: http.ServerResponse, ctl: AbortController, svc: Pick<LabService, "handle"> | undefined): Promise<void> {
    const stop = (status: number, say: string): void => json(res, status, { say, ask: "", mode: "v1", next: "end", run: "" });
    try {
      if (req.method !== "POST") return stop(405, messages("en").internalError());
      const body = await readBody(req, res);
      if (body === "too-long") return stop(413, messages(undefined).tooLong());
      if (body === "bad-json") return stop(400, messages("en").internalError());
      const auth = await tokens.verify(tokenHeader(req), undefined, { kind: "lab" });
      if (!auth.ok) {
        log({ event: "auth", outcome: auth.reason, kind: "lab" });
        return stop(401, messages("en").badToken());
      }
      const lang = replyLang(auth.record.siriLang);
      if (!svc) return stop(404, labOff(lang));
      if (overLimit(auth.record.id)) return stop(200, messages(lang).rateLimited());
      const int = (v: unknown, d: number): number => (typeof v === "number" ? v : typeof v === "string" && /^\d{1,4}$/.test(v.trim()) ? Number(v) : d);
      const r = await svc.handle({
        run: typeof body.run === "string" ? body.run : "",
        step: int(body.step, -1),
        last: int(body.last, 10),
        text: typeof body.text === "string" ? body.text : "",
        tokenId: auth.record.id,
        lang,
        signal: ctl.signal,
      });
      if (!res.destroyed) json(res, 200, r);
    } catch (e) {
      log({ event: "request-error", error: errorName(e), kind: "lab" });
      if (!res.headersSent && !res.destroyed) stop(500, messages(undefined).internalError());
    }
  }

  /**
   * Siri wait-limit probe: answer after the next delay in PROBE_STEPS and log whether the
   * client was still there. Talks to no bot.
   */
  async function probe(req: http.IncomingMessage, res: http.ServerResponse, ctl: AbortController): Promise<void> {
    // Only wait-test tokens: a voice Shortcut's token is never activated (or its predecessor
    // retired) by the probe endpoint (M4 review S2).
    const auth = await tokens.verify(tokenHeader(req), undefined, { kind: "probe" });
    if (!auth.ok) return text(res, 401, messages("en").badToken());
    const s = PROBE_STEPS[probeIdx++ % PROBE_STEPS.length] ?? 5;
    const t0 = now();
    log({ event: "probe-start", s });
    await sleep(s * probeUnitMs, undefined, { signal: ctl.signal }).catch(() => {});
    const delivered = !ctl.signal.aborted && !res.destroyed;
    log({ event: "probe-end", s, delivered, ...(delivered ? {} : { client_gave_up_ms: now() - t0 }) });
    if (delivered) text(res, 200, PROBE_TEXT[replyLang(auth.record.siriLang)](s));
  }

  /**
   * One-time Shortcut download (DESIGN §7.8). The id is a bearer secret: never logged; unknown,
   * used and expired links look the same.
   */
  async function download(res: http.ServerResponse, id: string): Promise<void> {
    const link = downloads?.take(id);
    const data = link && (await readFile(link.file).catch(() => null));
    log({ event: "download", outcome: data ? "served" : "gone" });
    if (!link || !data) return text(res, 404, "This link has expired or was already used. Make a new one on the Homebot setup page.");
    res.writeHead(200, {
      "content-type": "application/octet-stream",
      "content-disposition": `attachment; filename="Homebot.shortcut"; filename*=UTF-8''${encodeURIComponent(link.name)}.shortcut`,
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
    });
    res.end(data);
  }

  const server = http.createServer((req, res) => {
    // Installed before any await, so a disconnect at any point is seen by AskService.
    const ctl = new AbortController();
    res.on("close", () => {
      if (!res.writableFinished) ctl.abort();
    });
    handle(req, res, ctl).catch((e: unknown) => {
      log({ event: "request-error", error: errorName(e) });
      if (!res.headersSent && !res.destroyed) text(res, 500, messages(undefined).internalError());
      else if (!res.destroyed) res.destroy();
    });
  });
  server.requestTimeout = 70_000; // above the Shortcut's reported ~60 s client timeout
  server.headersTimeout = 10_000;
  return server;
}
