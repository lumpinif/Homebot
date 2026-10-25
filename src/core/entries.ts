// Pure logic over BDK session entries: paging to the real end, and deciding whether a bot
// reply provably belongs to our voice question (DESIGN §4.2, §5.3). No I/O here.
import { END_MARK, echoTag, requestMarker } from "./envelope.ts";

export interface Entry {
  seq: string | number;
  updatedSeq?: string | number;
  kind: string;
  role?: string;
  text?: string;
  createdAtMs?: number;
}

export interface Turn {
  idle?: boolean;
  inFlight?: unknown;
  queued?: unknown;
}

export interface Page {
  entries: Entry[];
  latestUpdatedSeq: string | number;
  turn?: Turn | undefined;
}

export interface SyncResult {
  cursor: string;
  maxSeq: string;
  entries: Entry[];
  turn: Turn | undefined;
  pages: number;
}

export class HistoryTooLongError extends Error {}

const big = (v: string | number): bigint => BigInt(v);

/**
 * Page `afterUpdatedSeq` from `cursor` until a page is empty or the cursor stops moving.
 * The cursor only advances on non-empty pages (a page's latestUpdatedSeq is that page's end,
 * not the session's latest — the spike's 200-per-page bug).
 * `onEntries` receives each page's entries as soon as that page arrives, so evidence from
 * earlier pages survives when a later page fails (BDK re-review R1).
 */
export async function syncToEnd(
  fetchPage: (cursor: string) => Promise<Page>,
  { cursor, maxSeq = "-1", maxPages = 500, onEntries }: { cursor: string; maxSeq?: string; maxPages?: number; onEntries?: (entries: Entry[]) => void },
): Promise<SyncResult> {
  let max = big(maxSeq);
  const entries: Entry[] = [];
  let turn: Turn | undefined;
  let pages = 0;
  for (;;) {
    if (pages >= maxPages) {
      throw new HistoryTooLongError(`session history exceeds ${maxPages} pages; raise the page cap`);
    }
    const page = await fetchPage(cursor);
    pages++;
    turn = page.turn;
    onEntries?.(page.entries);
    for (const e of page.entries) {
      entries.push(e);
      if (big(e.seq) > max) max = big(e.seq);
    }
    const next = String(page.latestUpdatedSeq);
    if (!page.entries.length || next === cursor) break;
    cursor = next;
  }
  return { cursor, maxSeq: String(max), entries, turn, pages };
}

export type Decision =
  | { status: "waiting" }
  | { status: "accept"; text: string; userSeq: string; replySeq: string; ended?: boolean }
  | { status: "refuse"; reason: "O2" | "O3" | "O5"; userSeq?: string; replySeq?: string };

/**
 * Decide reply ownership over everything seen since the baseline (DESIGN §4.2).
 * Evidence is judged over EVERY observed version of an entry: a later re-update (e.g. text
 * removed) never erases a version that disqualifies the request. Only the answer text itself
 * comes from the latest non-empty version.
 * `seen`: all entries fetched after the baseline, all versions, in fetch order.
 */
export function decideReply(seen: Entry[], { baseMaxSeq, requestId, strictEcho }: { baseMaxSeq: string; requestId: string; strictEcho: boolean }): Decision {
  const base = big(baseMaxSeq);
  /** seq -> versions in fetch order */
  const versions = new Map<string, Entry[]>();
  for (const e of seen) {
    if (big(e.seq) <= base) continue;
    const k = String(e.seq);
    versions.set(k, [...(versions.get(k) ?? []), e]);
  }
  const seqs = [...versions.keys()].sort((a, b) => (big(a) < big(b) ? -1 : 1));
  const vs = (s: string): Entry[] => versions.get(s) ?? [];

  const marker = requestMarker(requestId);
  const isOurs = (e: Entry): boolean => e.role === "user" && e.kind === "message" && typeof e.text === "string" && e.text.includes(marker);
  const userSeqs = seqs.filter((s) => vs(s).some((e) => e.role === "user"));
  const ourSeqs = userSeqs.filter((s) => vs(s).some(isOurs));
  // O2: any user-role entry that is not exactly our one message makes the conversation ambiguous.
  if (userSeqs.length > ourSeqs.length || ourSeqs.length > 1) return { status: "refuse", reason: "O2" };
  const [ours] = ourSeqs;
  if (ours === undefined) return { status: "waiting" };
  const userSeq = big(ours);

  const hasText = (e: Entry): boolean => e.kind === "send-message" && !!e.text?.trim();
  // O3: any bot output (text or not — its text may already have been re-updated away before we
  // saw it) between the baseline and our message came from something else.
  if (seqs.some((s) => big(s) < userSeq && vs(s).some((e) => e.kind === "send-message"))) {
    return { status: "refuse", reason: "O3", userSeq: String(userSeq) };
  }

  const replySeq = seqs.find((s) => big(s) > userSeq && vs(s).some(hasText));
  if (!replySeq) return { status: "waiting" };
  // replySeq has a version with text (hasText), so this is that latest non-empty text.
  const text = vs(replySeq).filter(hasText).at(-1)?.text ?? "";
  const ids = { userSeq: String(userSeq), replySeq };
  if (strictEcho) {
    const i = text.indexOf(echoTag(requestId));
    if (i < 0 || i > 40) return { status: "refuse", reason: "O5", ...ids };
  }
  const ended = strictEcho && endMarked(text, echoTag(requestId));
  return { status: "accept", text: text.split(echoTag(requestId)).join(" ").trim(), ...ids, ...(ended ? { ended } : {}) };
}

/**
 * The bot ends a conversation (S25): the text starts with our echo tag and `[end]` comes right
 * after it. `[end]` anywhere else, or after another tag, ends nothing.
 */
export function endMarked(text: string, tag: string): boolean {
  const t = text.trimStart();
  return t.startsWith(tag) && t.slice(tag.length).trimStart().startsWith(END_MARK);
}
