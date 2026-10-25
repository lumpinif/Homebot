// Thin HTTP client for the (undocumented) Grok Bot sessions API (DESIGN §5.1).
// All BDK HTTP goes through here. Errors never include the key or response bodies.
import type { Page } from "./entries.ts";
import { errorName } from "./log.ts";

export const DEFAULT_BASE_URL = "https://api.cursor.com/v0/grokbot/sessions";

export type BdkErrorKind = "auth" | "upstream" | "network" | "request";

export class BdkError extends Error {
  kind: BdkErrorKind;
  status: number | undefined;
  constructor(message: string, { kind, status }: { kind: BdkErrorKind; status?: number }) {
    super(message);
    this.kind = kind;
    this.status = status;
  }
}

/** Get-or-create response (DESIGN §5.1). */
export interface NamedSession {
  id: string | number;
  name?: string;
  createdAtMs?: number;
  latestUpdatedSeq?: string;
}

export interface BdkClient {
  /**
   * Get-or-create a bot by its EXACT name (DESIGN §5.1). Creates a new empty bot on a typo,
   * so callers must confirm the name first and check `justCreated` (resolveBotByName).
   */
  getOrCreateSession(name: string, o?: { signal?: AbortSignal }): Promise<NamedSession>;
  /** `sessionId`: numeric session id. */
  getEntries(sessionId: string, afterUpdatedSeq: string, o?: { signal?: AbortSignal }): Promise<Page>;
  sendMessage(sessionId: string, msg: { messageId: string; text: string }, o?: { signal?: AbortSignal }): Promise<{ delivery?: string }>;
}

export function createBdkClient({ key, baseUrl = DEFAULT_BASE_URL, fetch = globalThis.fetch, callTimeoutMs = 10_000 }: {
  key: string;
  baseUrl?: string;
  fetch?: typeof globalThis.fetch;
  callTimeoutMs?: number;
}): BdkClient {
  // The API's JSON is trusted to have the shapes in DESIGN §5.1 (observed in the spike and M0);
  // each method states the type it returns. Callers handle missing fields defensively.
  async function call<T>(method: "GET" | "POST", path: string, body: unknown, signal: AbortSignal | undefined): Promise<T> {
    const signals = [AbortSignal.timeout(callTimeoutMs)];
    if (signal) signals.push(signal);
    let res: Response;
    try {
      res = await fetch(baseUrl + path, {
        method,
        headers: { authorization: `Bearer ${key}`, "content-type": "application/json", "x-cursor-client-type": "agent-serve" },
        body: body === undefined ? null : JSON.stringify(body),
        redirect: "error",
        signal: AbortSignal.any(signals),
      });
    } catch (e) {
      if (signal?.aborted) throw signal.reason;
      throw new BdkError(`BDK ${method} ${redact(path)} failed: ${errorName(e)}`, { kind: "network" });
    }
    const json: unknown = await res.json().catch(() => null);
    if (res.ok) return json as T;
    const kind = res.status === 401 || res.status === 403 ? "auth" : res.status >= 500 || res.status === 429 ? "upstream" : "request";
    throw new BdkError(`BDK ${method} ${redact(path)} -> ${res.status}`, { kind, status: res.status });
  }

  return {
    getOrCreateSession(name, { signal } = {}) {
      return call("POST", "", { name }, signal);
    },
    getEntries(sessionId, afterUpdatedSeq, { signal } = {}) {
      return call("GET", `/${encodeURIComponent(sessionId)}/entries?afterUpdatedSeq=${encodeURIComponent(afterUpdatedSeq)}`, undefined, signal);
    },
    sendMessage(sessionId, msg, { signal } = {}) {
      return call("POST", `/${encodeURIComponent(sessionId)}/messages`, msg, signal);
    },
  };
}

/** Keep only the shape of a path in error messages (no query values). */
const redact = (p: string): string => p.replace(/\?.*$/, "");
