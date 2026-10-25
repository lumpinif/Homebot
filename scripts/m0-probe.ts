// M0-b: the two read-only GET probes Felix approved (docs/DECISIONS.md item 1). Kept in the repo
// as the exact record of what ran. Prints only HTTP status, response SHAPE (key names, types,
// array lengths) and a few non-secret scalars. Never prints the key or any message text.
// Credentials come from Homebot's own resolver (env, then ~/.homebot, then detected login).
import { homedir } from "node:os";
import { join } from "node:path";
import { resolveCredential } from "../src/core/credentials.ts";
import { isRecord } from "../src/core/fsutil.ts";

const BASE = "https://api.cursor.com/v0/grokbot/sessions";
const SESSION = "14752726"; // 拆解师, numeric id from BRIEF §2.1
const PROBES = [
  { name: "P1 empty entries page", path: `/${SESSION}/entries?afterUpdatedSeq=999999999999999999` },
  { name: "P2 list sessions", path: "" },
];

type Shape = string | null | { array: number; item: Shape } | { [key: string]: Shape };

function shape(v: unknown, depth = 0): Shape {
  if (Array.isArray(v)) return depth > 1 ? `array(${v.length})` : { array: v.length, item: v.length ? shape(v[0], depth + 1) : null };
  if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, shape(x, depth + 1)]));
  return typeof v === "string" ? `string(${v.length})` : typeof v;
}

const cred = await resolveCredential({ env: process.env, secretsFile: join(homedir(), ".homebot", "secrets.json") });
if (!cred) {
  console.log("no credential found; nothing sent");
  process.exit(1);
}
console.log(`credential source: ${cred.source}`);
for (const p of PROBES) {
  const res = await fetch(BASE + p.path, {
    method: "GET",
    headers: { authorization: `Bearer ${cred.key}`, "x-cursor-client-type": "agent-serve" },
    redirect: "error",
    signal: AbortSignal.timeout(15_000),
  });
  const body: unknown = await res.json().catch(() => null);
  const out: Record<string, unknown> = { probe: p.name, status: res.status, contentType: res.headers.get("content-type"), shape: shape(body) };
  if (p.name.startsWith("P1") && isRecord(body) && res.ok) {
    // Non-secret scalars that answer open questions: cursor value on an empty page, turn status.
    out.latestUpdatedSeq = body.latestUpdatedSeq;
    out.entriesLength = Array.isArray(body.entries) ? body.entries.length : undefined;
    out.turn = body.turn;
  }
  console.log(JSON.stringify(out, null, 2));
}
