// Wrapper around macOS `shortcuts sign` (DESIGN D7). Apple's signing service is often slow or
// failing (spike: minutes of 502/503/504), so retry with backoff and alternate modes;
// `people-who-know-me` sometimes worked when `anyone` failed.
// Called only after the user agreed to signing, on the setup page or with --sign (DESIGN §7.5).
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { setTimeout as sleep } from "node:timers/promises";

const MODES = ["people-who-know-me", "anyone"] as const;
export type SignMode = (typeof MODES)[number];
export const BACKOFF_MS = [2000, 4000, 8000, 16000, 30000];

// The signer writes the token-bearing output itself, with the process umask. Node can't set a
// umask for one child, so a fixed /bin/sh launcher sets 077 and then execs the signer: the output
// is 0600 from creation, also if signing is interrupted. The script is a constant; the signer
// and all paths are passed as separate arguments ("$0" "$@"), never interpolated into it.
export const UMASK_LAUNCHER = ["-c", 'umask 077 && exec "$0" "$@"'];

export type RunCommand = (cmd: string, args: string[]) => Promise<unknown>;

export interface SignOptions {
  input: string;
  output: string;
  attempts?: number;
  /** The signer binary (tests pass a fake; default Apple's `shortcuts`). */
  command?: string;
  run?: RunCommand;
  wait?: (ms: number) => Promise<unknown>;
  onAttempt?: ((info: { attempt: number; mode: SignMode }) => void) | undefined;
}

/** What callers need from a signer (signShortcut, or a fake in tests). */
export type Signer = (o: Pick<SignOptions, "input" | "output" | "onAttempt">) => Promise<unknown>;

const execFileAsync = promisify(execFile);

export async function signShortcut({ input, output, attempts = BACKOFF_MS.length, command = "shortcuts", run = (cmd, args) => execFileAsync(cmd, args), wait = sleep, onAttempt }: SignOptions): Promise<{ mode: SignMode; attempts: number }> {
  let last: unknown;
  for (let i = 0; i < attempts; i++) {
    const mode = MODES[i % MODES.length] ?? "anyone";
    onAttempt?.({ attempt: i + 1, mode });
    try {
      await run("/bin/sh", [...UMASK_LAUNCHER, command, "sign", "--mode", mode, "--input", input, "--output", output]);
      return { mode, attempts: i + 1 };
    } catch (e) {
      last = e;
      if (i + 1 < attempts) await wait(BACKOFF_MS[Math.min(i, BACKOFF_MS.length - 1)] ?? 30000);
    }
  }
  const code = typeof last === "object" && last !== null && "code" in last ? last.code : undefined;
  throw new Error(`signing failed after ${attempts} attempts (last exit: ${code ?? "unknown"}); Apple's signing service may be down, try again later`);
}
