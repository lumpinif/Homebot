// JSONL logger: one line per event, file 0600, rotated at 5 MB x 3.
// Callers pass only ids, timings, outcomes and lengths — never secrets or (by default) text.
import { appendFile, stat, rename } from "node:fs/promises";
import { join } from "node:path";

export const MAX_BYTES = 5 * 1024 * 1024;
export const KEEP = 3;

export type Log = (event: Record<string, unknown>) => unknown;

const KNOWN_ERRORS = new Set(["Error", "TypeError", "RangeError", "SyntaxError", "AbortError", "TimeoutError", "BdkError"]);

/**
 * An error's class for the log, from a fixed list. `Error.name` is free text set by whoever
 * threw, so any other value is logged as "other" (BDK re-review R2).
 */
export function errorName(e: unknown): string {
  if (!(e instanceof Error)) return "non-error";
  return KNOWN_ERRORS.has(e.name) ? e.name : "other";
}

export function createLogger(dir: string, { maxBytes = MAX_BYTES }: { maxBytes?: number } = {}): { log: (event: Record<string, unknown>) => Promise<void>; file: string } {
  const file = join(dir, "homebot.jsonl");
  let chain: Promise<void> = Promise.resolve();
  async function rotate(): Promise<void> {
    const size = await stat(file).then((s) => s.size, () => 0);
    if (size < maxBytes) return;
    for (let i = KEEP - 1; i >= 1; i--) await rename(`${file}.${i}`, `${file}.${i + 1}`).catch(() => {});
    await rename(file, `${file}.1`);
  }
  function log(event: Record<string, unknown>): Promise<void> {
    const line = JSON.stringify({ ts: new Date().toISOString(), ...event }) + "\n";
    chain = chain.then(rotate).then(() => appendFile(file, line, { mode: 0o600 })).catch(() => {});
    return chain;
  }
  return { log, file };
}
