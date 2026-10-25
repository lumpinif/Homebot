// Runs of a looping Shortcut (DESIGN §18.2): one invocation = one run; each listen-and-POST
// inside it is a step. The gateway issues the run id, so two overlapping invocations of the same
// Shortcut never share state. Steps are ordered; a repeated step (an HTTP retry) gets the same
// response and never runs its work twice. A run that ended stays known until it expires, so a
// retry of its last step still gets the final response while any later step is refused.
// Memory only: a restart forgets every run.
import { randomBytes } from "node:crypto";

export const RUN_TTL_MS = 5 * 60_000;

/**
 * The answer to every step of a looping Shortcut (lab and conversation). V1: Speak Text `say`,
 * then Ask for Input with `ask`. V2: Ask for Input with `say` as the question. The Shortcut stops
 * after speaking `say` unless `next` is "listen".
 */
export interface LoopResponse {
  say: string;
  ask: string;
  mode: "v1" | "v2";
  next: "listen" | "end";
  run: string;
}

interface Run<S> {
  id: string;
  tokenId: string;
  /** The last step taken (0 = the run's start). */
  step: number;
  /** The response to `step`, shared by retries of that step while it is still being made. */
  response: Promise<unknown>;
  /** False while the response to `step` is still being made. */
  settled: boolean;
  /** The run ended: no step after `step` is taken. */
  ended: boolean;
  expiresAt: number;
  state: S;
}

export type StepCheck<S> =
  | { kind: "next"; state: S }
  | { kind: "repeat"; response: Promise<unknown>; state: S }
  /** The run ended, or the previous step's response is not ready: nothing is taken. */
  | { kind: "ended" }
  | { kind: "early" }
  | { kind: "unknown" };

/** A run id as issued by `start`; anything else is never looked up or logged. */
export const isRunId = (v: string): boolean => /^[0-9a-f]{16}$/.test(v);

export class RunStore<S> {
  #runs = new Map<string, Run<S>>();
  ttlMs: number;
  now: () => number;

  constructor({ ttlMs = RUN_TTL_MS, now = Date.now }: { ttlMs?: number; now?: () => number } = {}) {
    this.ttlMs = ttlMs;
    this.now = now;
  }

  #sweep(): void {
    const t = this.now();
    for (const [id, r] of this.#runs) if (r.expiresAt <= t) this.#runs.delete(id);
  }

  /** Start a run (step 0) for a token; `make` builds the start response. */
  start<R>(tokenId: string, state: S, make: (id: string) => Promise<R>): { id: string; response: Promise<R> } {
    this.#sweep();
    const id = randomBytes(8).toString("hex");
    const response = make(id);
    const r: Run<S> = { id, tokenId, step: 0, response, settled: false, ended: false, expiresAt: this.now() + this.ttlMs, state };
    this.#runs.set(id, r);
    this.#settle(r, response);
    return { id, response };
  }

  /**
   * Classify a step: the next one (`run.step + 1`), a repeat of the last one, or anything else
   * (unknown or expired run, another token's run, a skipped or old step). A next step is
   * refused once the run ended, or while the last step's response is still being made.
   */
  check(runId: string, tokenId: string, step: number): StepCheck<S> {
    this.#sweep();
    const r = this.#runs.get(runId);
    if (!r || r.tokenId !== tokenId || !Number.isInteger(step)) return { kind: "unknown" };
    if (step === r.step) return { kind: "repeat", response: r.response, state: r.state };
    if (step === r.step + 1) {
      if (r.ended) return { kind: "ended" };
      if (!r.settled) return { kind: "early" };
      return { kind: "next", state: r.state };
    }
    return { kind: "unknown" };
  }

  /** Take step `step` (after `check` said "next"); `make` builds its response. */
  take<R>(runId: string, step: number, make: () => Promise<R>): Promise<R> {
    const r = this.#runs.get(runId);
    if (!r || step !== r.step + 1 || r.ended || !r.settled) throw new Error("step not checked");
    const response = make();
    r.step = step;
    r.response = response;
    r.expiresAt = this.now() + this.ttlMs;
    this.#settle(r, response);
    return response;
  }

  /** Mark a run ended after its current step: retries of that step still get its response. */
  finish(runId: string): void {
    const r = this.#runs.get(runId);
    if (r) r.ended = true;
  }

  #settle(r: Run<S>, response: Promise<unknown>): void {
    r.settled = false;
    const done = (): void => {
      if (r.response === response) r.settled = true;
    };
    response.then(done, done);
  }

  get size(): number {
    this.#sweep();
    return this.#runs.size;
  }
}
