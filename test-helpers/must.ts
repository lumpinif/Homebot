import assert from "node:assert/strict";
import type { Server } from "node:net";

/** The value, asserted to exist: a failing test then says what was missing, not "cannot read
 * properties of undefined". Used instead of non-null assertions (`!`) in tests. */
export function must<T>(v: T | null | undefined, what = "value"): T {
  assert.ok(v !== null && v !== undefined, `expected ${what} to exist`);
  return v;
}

/** Capture group 1 of `re` in `s`, asserted to match. */
export function group(re: RegExp, s: string): string {
  return must(re.exec(s)?.[1], `a match for ${re}`);
}

/** The TCP port of a listening server. */
export function portOf(server: Server | undefined): number {
  const a = must(server, "a listening server").address();
  assert.ok(a && typeof a === "object", "server listens on TCP");
  return a.port;
}
