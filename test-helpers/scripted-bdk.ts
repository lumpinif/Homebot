// Socket-free BDK for AskService tests whose page responses must be exact: missing or
// malformed turn fields, re-updated entries, output from unrelated tasks. The HTTP fake
// (fake-bdk.ts) stays the transport test double.
import { BdkError, type BdkClient } from "../src/core/bdk.ts";
import type { Entry, Page, Turn } from "../src/core/entries.ts";

export const IDLE: Turn = { idle: true, inFlight: false, queued: 0 };

export interface ScriptedPage {
  /** Serve a transient failure (HTTP 503) instead of a page. */
  fail?: true;
  entries: Entry[];
  /** Exactly what the page carries; `undefined` = no turn field at all. */
  turn: Turn | undefined;
}

export interface ScriptedBdk extends BdkClient {
  /** Messages sent. */
  sent: number;
  /** Entry pages fetched after the send (including empty ones). */
  fetchedAfterSend: number;
  /** Scripted pages not yet served. */
  remaining(): number;
}

/**
 * The baseline sees an empty, idle session at cursor `tail`. After the send, each GET serves the
 * next page from `script(sent)` (sent = the posted message, so pages can contain our entry); once
 * the script is used up, GETs return empty pages with the last page's turn. One poll pages until
 * an empty page (syncToEnd), so an empty scripted page marks the end of a poll.
 * `before`: pages served before the send (the baseline and any follow-up idle wait); once used
 * up, the session looks empty and idle at `tail` again.
 */
export function scriptedBdk(script: (sent: { messageId: string; text: string }) => ScriptedPage[], { tail = "100", before = [] }: { tail?: string; before?: ScriptedPage[] } = {}): ScriptedBdk {
  let pages: ScriptedPage[] | undefined;
  let lastTurn: Turn | undefined = IDLE;
  let counter = 1000;
  const pre = [...before];
  const serve = (next: ScriptedPage, cursor: string): Page => {
    if (next.fail) throw new BdkError("scripted BDK: transient failure", { kind: "upstream", status: 503 });
    lastTurn = next.turn;
    const entries = next.entries.map((e) => ({ ...e, updatedSeq: String(++counter) }));
    return { entries, latestUpdatedSeq: entries.at(-1)?.updatedSeq ?? cursor, turn: next.turn };
  };
  const bdk: ScriptedBdk = {
    sent: 0,
    fetchedAfterSend: 0,
    remaining: () => pages?.length ?? 0,
    async getOrCreateSession() {
      throw new Error("scripted BDK: getOrCreateSession is not part of these tests");
    },
    async getEntries(_sid, cursor): Promise<Page> {
      if (!pages) {
        const early = pre.shift();
        return early ? serve(early, cursor) : { entries: [], latestUpdatedSeq: cursor === "-1" ? tail : cursor, turn: IDLE };
      }
      bdk.fetchedAfterSend++;
      const next = pages.shift();
      if (!next) return { entries: [], latestUpdatedSeq: cursor, turn: lastTurn };
      return serve(next, cursor);
    },
    async sendMessage(_sid, msg) {
      bdk.sent++;
      pages = script(msg);
      return { delivery: "accepted_temporal" };
    },
  };
  return bdk;
}
