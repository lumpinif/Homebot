import type { Deps, Env } from "./env";
import { bump, country, empty, isReleased, readBody, utcDay, utcMonth, VERSION_RE } from "./util";

/**
 * The opt-in daily usage ping. Every field is a closed set or a strict format, so no free text
 * (and nothing personal) can be stored. There is no identifier: the app itself says whether this
 * is its first ping of the week/month, which is how weekly and monthly actives are counted.
 * `day` is the UTC day the app computed those flags for; the ping is counted on that day, so the
 * app and the server never disagree about a week or month at a boundary.
 */
export interface Ping {
  v: 1;
  day: string;
  app: string;
  build: "direct" | "mas";
  os: string;
  arch: "arm64" | "x86_64";
  lang: string;
  cohort: string;
  age: string;
  use7d: string;
  newWeek: boolean;
  newMonth: boolean;
  first: boolean;
}

export const LANGS = new Set(["en", "es", "fr", "de", "it", "pt-BR", "ru", "ja", "ko", "zh-Hans", "zh-Hant"]);
export const AGES = new Set(["0-1d", "2-7d", "8-30d", "31-90d", "91-365d", "1y+"]);
export const USE7D = new Set(["0", "1-5", "6-20", "21+"]);
const KEYS = ["v", "day", "app", "build", "os", "arch", "lang", "cohort", "age", "use7d", "newWeek", "newMonth", "first"];
/** First month Homebot existed; older cohorts are impossible. */
const FIRST_COHORT = "2026-10";

export function parsePing(text: string, now: Date): Ping | null {
  let o: unknown;
  try {
    o = JSON.parse(text);
  } catch {
    return null;
  }
  if (typeof o !== "object" || o === null || Array.isArray(o)) return null;
  const p = o as Record<string, unknown>;
  const keys = Object.keys(p);
  if (keys.length !== KEYS.length || !KEYS.every((k) => k in p)) return null;
  const ok =
    p.v === 1 &&
    typeof p.day === "string" && /^20\d\d-\d\d-\d\d$/.test(p.day) && nearToday(p.day, now) &&
    typeof p.app === "string" && VERSION_RE.test(p.app) &&
    (p.build === "direct" || p.build === "mas") &&
    typeof p.os === "string" && /^(1[5-9]|2\d|30)$/.test(p.os) &&
    (p.arch === "arm64" || p.arch === "x86_64") &&
    typeof p.lang === "string" && LANGS.has(p.lang) &&
    typeof p.cohort === "string" && /^20\d\d-(0[1-9]|1[0-2])$/.test(p.cohort) &&
    p.cohort >= FIRST_COHORT && p.cohort <= utcMonth(now) &&
    typeof p.age === "string" && AGES.has(p.age) &&
    typeof p.use7d === "string" && USE7D.has(p.use7d) &&
    typeof p.newWeek === "boolean" && typeof p.newMonth === "boolean" && typeof p.first === "boolean";
  return ok ? (p as unknown as Ping) : null;
}

/** Within a day of the server's UTC day (the app's clock or a slow request may straddle midnight). */
function nearToday(day: string, now: Date): boolean {
  const t = Date.parse(`${day}T00:00:00Z`);
  return Number.isFinite(t) && utcDay(new Date(t)) === day && Math.abs(t - Date.parse(`${utcDay(now)}T00:00:00Z`)) <= 86400_000;
}

/** The counter rows one ping adds 1 to. Exported for tests. */
export function rowsFor(p: Ping, c: string): [kind: string, dim: string, value: string][] {
  const rows: [string, string, string][] = [
    ["day", "all", "-"],
    ["day", "app", p.app],
    ["day", "build", p.build],
    ["day", "os", p.os],
    ["day", "arch", p.arch],
    ["day", "lang", p.lang],
    ["day", "use7d", p.use7d],
    ["day", "country", c],
  ];
  if (p.newWeek) rows.push(["week", "all", "-"], ["week", "app", p.app]);
  if (p.newMonth) rows.push(["month", "all", "-"], ["month", "app", p.app], ["month", "cohort", p.cohort], ["month", "country", c]);
  if (p.first) rows.push(["first", "cohort", p.cohort], ["first", "age", p.age]);
  return rows;
}

/**
 * POST /api/v1/ping. 204 only once the counters are written, so the app marks its day, week and
 * month done only for a ping that counted. Busy (429) and a failed write (503) are tried again
 * later. A malformed ping or an unreleased version also gets 204: retrying can't fix it.
 */
export async function handlePing(request: Request, env: Env, deps: Deps, _ctx: ExecutionContext): Promise<Response> {
  if (request.method !== "POST") return empty(405);
  const { success } = await env.PING_LIMIT.limit({ key: "ping" });
  if (!success) return empty(429);
  const text = await readBody(request, 1024);
  const now = deps.now();
  const p = text === null ? null : parsePing(text, now);
  if (!p) return empty(204);
  // Only versions that were released count, so nobody can invent rows such as "12.345.678".
  if (!(await isReleased(env.RELEASES, p.app))) return empty(204);
  const day = p.day;
  const stmts = rowsFor(p, country(request)).map(([kind, dim, value]) =>
    bump(env.DB, "active_daily", ["day", "kind", "dim", "value"], [day, kind, dim, value]),
  );
  stmts.push(bump(env.DB, "active_version_os", ["day", "app", "os"], [day, p.app, p.os]));
  try {
    await env.DB.batch(stmts);
  } catch {
    return empty(503);
  }
  return empty(204);
}
