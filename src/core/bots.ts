// Bot setup helpers. Cold sync walks a session's whole history once (at setup, never in the
// voice path) so later requests can start from a warm cursor (DESIGN §5.3, §6.3).
import type { BdkClient } from "./bdk.ts";
import { syncToEnd, type SyncResult, type Turn } from "./entries.ts";

export const JUST_CREATED_MS = 60_000;

export interface ColdSync {
  cursor: string;
  maxSeq: string;
  pages: number;
  entryCount: number;
  turn: Turn | undefined;
  latestBotText: string | undefined;
}

/**
 * Add-by-name (DECISIONS item 13): resolve an EXACT bot name with get-or-create. Detects the
 * typo case the way the official extension does: an empty session (latestUpdatedSeq "-1")
 * created in the last 60 s was most likely created by this very call. Callers must have
 * confirmed the exact name with the user first, and must not add a just-created bot.
 */
export async function resolveBotByName(bdk: BdkClient, name: string, { now = Date.now }: { now?: () => number } = {}): Promise<{ sessionId: string; justCreated: boolean }> {
  const r = await bdk.getOrCreateSession(name);
  const sessionId = String(r?.id ?? "");
  if (!/^\d+$/.test(sessionId)) throw new Error("Grok Bot returned an unexpected bot id");
  const justCreated = r.latestUpdatedSeq === "-1" && typeof r.createdAtMs === "number" && now() - r.createdAtMs < JUST_CREATED_MS;
  return { sessionId, justCreated };
}

/**
 * Read-only: proves the session id exists and the key can read it, and returns the cursor.
 * Bounded by a page cap AND a total time cap.
 */
export async function coldSync(bdk: BdkClient, sessionId: string, { maxPages = 500, timeoutMs = 120_000 }: { maxPages?: number; timeoutMs?: number } = {}): Promise<ColdSync> {
  const signal = AbortSignal.timeout(timeoutMs);
  let r: SyncResult;
  try {
    r = await syncToEnd((c) => bdk.getEntries(sessionId, c, { signal }), { cursor: "-1", maxPages });
  } catch (e) {
    if (signal.aborted) throw new Error(`reading the session history took longer than ${Math.round(timeoutMs / 1000)} s; try again later`);
    throw e;
  }
  const latestBotText = [...r.entries]
    .filter((e) => e.kind === "send-message" && e.text?.trim())
    .sort((a, b) => (BigInt(a.seq) < BigInt(b.seq) ? -1 : 1))
    .at(-1)?.text;
  return { cursor: r.cursor, maxSeq: r.maxSeq, pages: r.pages, entryCount: r.entries.length, turn: r.turn, latestBotText };
}
