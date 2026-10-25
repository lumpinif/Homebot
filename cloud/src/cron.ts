import type { Env } from "./env";
import { utcDay } from "./util";

/**
 * In a published month, any value counted fewer than K times (a country, a macOS version, a
 * language…) is merged into "other", and "other" itself is left out when it is under K too.
 * These are counts of requests, not of people: the threshold keeps small cells out of the public
 * file; it is not a promise of anonymity among K people.
 */
export const K = 10;

/** Daily detail (by country, macOS, language…) is kept for about 13 months, then only monthly files remain. */
const KEEP_DAYS = 400;

/**
 * Daily: drop unconfirmed sign-ups after 7 days, throttle rows after a day, old mail counts after
 * 30 days, and daily counter rows after KEEP_DAYS.
 */
export async function cleanup(env: Env, now: Date): Promise<void> {
  const ago = (days: number) => new Date(now.getTime() - days * 86400_000).toISOString();
  await env.DB.batch([
    env.DB.prepare("DELETE FROM subscribers WHERE confirmed_at IS NULL AND created_at < ?").bind(ago(7)),
    env.DB.prepare("DELETE FROM signup_throttle WHERE window_start < ?").bind(ago(1)),
    env.DB.prepare("DELETE FROM mail_daily WHERE day < ?").bind(utcDay(new Date(ago(30)))),
    ...["active_daily", "active_version_os", "downloads_country_daily"].map((t) =>
      env.DB.prepare(`DELETE FROM ${t} WHERE day < ?`).bind(utcDay(new Date(ago(KEEP_DAYS))))),
  ]);
}

function previousMonth(now: Date): { month: string; from: string; to: string } {
  const start = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 1, 1));
  const end = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
  return { month: start.toISOString().slice(0, 7), from: utcDay(start), to: utcDay(end) };
}

/** Merges rare countries into "other"; "other" is left out when it is rare too. */
export function kAnon(rows: { country: string; n: number }[]): Record<string, number> {
  const out: Record<string, number> = {};
  let other = 0;
  for (const r of rows) {
    if (r.country === "ZZ" || r.n < K) other += r.n;
    else out[r.country] = r.n;
  }
  if (other >= K) out.other = other;
  return out;
}

type KindRow = { kind: string; dim: string; value: string; n: number };

/** The same rule for every (kind, dimension): rare values become "other". Totals ("all") stay. */
export function kAnonRows(rows: KindRow[]): KindRow[] {
  const out: KindRow[] = [];
  const other = new Map<string, KindRow>();
  for (const r of rows) {
    if (r.dim === "all" || r.n >= K) {
      out.push(r);
      continue;
    }
    const k = `${r.kind}|${r.dim}`;
    const o = other.get(k) ?? { kind: r.kind, dim: r.dim, value: "other", n: 0 };
    o.n += r.n;
    other.set(k, o);
  }
  for (const o of other.values()) if (o.n >= K) out.push(o);
  return out;
}

async function sha256(text: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Monthly: write last month's totals to R2 as stats/YYYY-MM.json and append its hash to
 * stats/ledger.txt, each line chained to the previous one, so the history can't be rewritten quietly.
 * Only monthly totals with rare countries merged leave D1; daily country rows never do.
 */
export async function snapshot(env: Env, now: Date): Promise<string | null> {
  const { month, from, to } = previousMonth(now);
  const key = `stats/${month}.json`;
  const ledgerObj = await env.RELEASES.get("stats/ledger.txt");
  const prior = ledgerObj ? await ledgerObj.text() : "";
  const lines = prior.trim().split("\n").filter(Boolean);
  if (lines.some((l) => l.startsWith(`${month} `))) return null; // already done (cron retried)
  const written = await env.RELEASES.get(key);
  if (written) {
    // The file was written but the ledger line wasn't (a failure in between): add the line for it.
    await appendLedger(env, prior, lines, month, await written.text());
    return key;
  }
  const q = <T>(sql: string) => env.DB.prepare(sql).bind(from, to).all<T>().then((r) => r.results);

  const downloads = await q<{ version: string; channel: string; n: number }>(
    "SELECT version, channel, SUM(n) AS n FROM downloads_daily WHERE day >= ? AND day < ? GROUP BY version, channel ORDER BY version, channel");
  const dlCountry = await q<{ country: string; n: number }>(
    "SELECT country, SUM(n) AS n FROM downloads_country_daily WHERE day >= ? AND day < ? GROUP BY country ORDER BY country");
  const checks = await q<{ day: string; n: number }>("SELECT day, n FROM update_checks_daily WHERE day >= ? AND day < ? ORDER BY day");
  const daily = await q<{ day: string; n: number }>(
    "SELECT day, n FROM active_daily WHERE day >= ? AND day < ? AND kind = 'day' AND dim = 'all' ORDER BY day");
  const byKind = await q<{ kind: string; dim: string; value: string; n: number }>(
    "SELECT kind, dim, value, SUM(n) AS n FROM active_daily WHERE day >= ? AND day < ? AND dim <> 'country' GROUP BY kind, dim, value ORDER BY kind, dim, value");
  const activeCountry = await q<{ country: string; n: number }>(
    "SELECT value AS country, SUM(n) AS n FROM active_daily WHERE day >= ? AND day < ? AND kind = 'month' AND dim = 'country' GROUP BY value");
  const subs = await env.DB.prepare(
    "SELECT COUNT(*) AS confirmed FROM subscribers WHERE confirmed_at IS NOT NULL",
  ).first<{ confirmed: number }>();

  const body = JSON.stringify({
    month,
    method: "https://homebot.fun/privacy",
    downloads,
    downloadsByCountry: kAnon(dlCountry),
    updateChecksPerDay: checks,
    activePerDay: daily,
    active: kAnonRows(byKind),
    activeByCountry: kAnon(activeCountry),
    subscribers: { confirmed: subs?.confirmed ?? 0 },
  }, null, 1);

  await env.RELEASES.put(key, body, { httpMetadata: { contentType: "application/json" } });
  await appendLedger(env, prior, lines, month, body);
  return key;
}

async function appendLedger(env: Env, prior: string, lines: string[], month: string, body: string): Promise<void> {
  const last = lines[lines.length - 1];
  const prevChain = last ? last.split(" ")[2] : "0".repeat(64);
  const fileHash = await sha256(body);
  const chain = await sha256(`${prevChain} ${month} ${fileHash}`);
  const base = prior && !prior.endsWith("\n") ? `${prior}\n` : prior;
  await env.RELEASES.put("stats/ledger.txt", `${base}${month} ${fileHash} ${chain}\n`, { httpMetadata: { contentType: "text/plain" } });
}
