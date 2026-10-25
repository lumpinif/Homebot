import type { Deps, Env, Mail } from "./env";
import { esc, invalidLink, LIST_TEXT, page } from "./pages";
import { LANGS } from "./ping";
import { addrHash, checkToken, makeToken, newPid, splitToken } from "./token";
import { empty, json, readBody, utcDay } from "./util";

/** Id of the sign-up wording the app and site show; change it whenever that wording changes. */
export const CONSENT_VERSION = "email-2026-10";
const CONFIRM_HOURS = 48;
const PER_ADDRESS_PER_DAY = 3;
const PER_ADDRESS_GAP_MIN = 10;

interface Row {
  id: number;
  pid: string;
  email: string;
  created_at: string;
  confirmed_at: string | null;
}

/** Deliberately plain: one @, a dotted domain, no spaces or angle brackets, at most 254 characters. */
export function normalizeEmail(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const e = raw.trim().toLowerCase();
  if (e.length < 6 || e.length > 254) return null;
  if (!/^[a-z0-9._%+'-]+@[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(e)) return null;
  if (e.includes("..") || e.startsWith(".") || e.split("@")[0].endsWith(".")) return null;
  return e;
}

/** The answer to every accepted sign-up, whatever happened, so nobody can learn whether an address is on the list. */
const ACCEPTED = () => json({ status: "check-inbox" }, 202);

/** POST /api/v1/subscribe {email, lang, source}. There is one list (product updates); other fields are ignored. */
export async function handleSubscribe(request: Request, env: Env, deps: Deps, ctx: ExecutionContext): Promise<Response> {
  if (request.method !== "POST") return empty(405);
  // Admission first: a flood is turned away before any body is read.
  const { success } = await env.SUBSCRIBE_LIMIT.limit({ key: "subscribe" });
  if (!success) return json({ error: "rate-limited" }, 429);
  const text = await readBody(request, 2048);
  let o: Record<string, unknown> | null = null;
  try {
    o = text === null ? null : JSON.parse(text);
  } catch {}
  if (!o || typeof o !== "object") return json({ error: "bad-request" }, 400);
  const email = normalizeEmail(o.email);
  const lang = typeof o.lang === "string" && LANGS.has(o.lang) ? o.lang : "en";
  const source = o.source === "site" ? "site" : "app";
  if (!email) return json({ error: "email" }, 400);
  // The work runs after the response, so the answer and its timing are the same for new,
  // pending and confirmed addresses.
  ctx.waitUntil(subscribe(env, deps, { email, lang, source }).catch(() => {}));
  return ACCEPTED();
}

async function subscribe(env: Env, deps: Deps, s: { email: string; lang: string; source: string }): Promise<void> {
  const now = deps.now();
  // Check the throttle before touching the row: a throttled re-submit must not replace a pending link.
  if (!(await takeSendSlot(env, now, s.email))) return;
  const iso = now.toISOString();
  const row = await env.DB.prepare("SELECT * FROM subscribers WHERE email = ?").bind(s.email).first<Row>();
  if (row?.confirmed_at) {
    // Already subscribed: changes go through the manage link, never through this form.
    await sendSafely(deps, await alreadyMail(env, row));
    return;
  }
  let pid: string;
  if (row) {
    pid = row.pid;
    await env.DB.prepare("UPDATE subscribers SET lang = ?, source = ?, consent_version = ?, created_at = ? WHERE id = ? AND confirmed_at IS NULL")
      .bind(s.lang, s.source, CONSENT_VERSION, iso, row.id).run();
  } else {
    pid = newPid();
    const r = await env.DB.prepare("INSERT OR IGNORE INTO subscribers (pid, email, lang, source, consent_version, created_at) VALUES (?, ?, ?, ?, ?, ?)")
      .bind(pid, s.email, s.lang, s.source, CONSENT_VERSION, iso).run();
    if (!r.meta.changes) return; // lost a race with a parallel sign-up for the same address
  }
  await sendSafely(deps, await confirmMail(env, pid, s.email, iso));
}

/**
 * Per-address limit (one mail per 10 minutes, three a day) and the global daily cap, each taken by
 * one conditional upsert, so parallel sign-ups can't all pass a check made before either write.
 * The address goes first: a throttled address never uses up the global cap (a full cap may cost
 * an address one of its slots, which only delays its own mail).
 */
async function takeSendSlot(env: Env, now: Date, email: string): Promise<boolean> {
  const h = await addrHash(env.HMAC_SECRET, email);
  const iso = now.toISOString();
  const dayAgo = new Date(now.getTime() - 24 * 3600_000).toISOString();
  const gapAgo = new Date(now.getTime() - PER_ADDRESS_GAP_MIN * 60_000).toISOString();
  const cap = Number(env.MAIL_DAILY_CAP || "500");
  try {
    const address = await env.DB.prepare(
      `INSERT INTO signup_throttle (addr_hash, window_start, last_sent_at, sends) VALUES (?1, ?2, ?2, 1)
       ON CONFLICT (addr_hash) DO UPDATE SET
         window_start = CASE WHEN window_start <= ?3 THEN ?2 ELSE window_start END,
         sends = CASE WHEN window_start <= ?3 THEN 1 ELSE sends + 1 END,
         last_sent_at = ?2
       WHERE window_start <= ?3 OR (sends < ?4 AND last_sent_at <= ?5)
       RETURNING sends`,
    ).bind(h, iso, dayAgo, PER_ADDRESS_PER_DAY, gapAgo).all();
    if (!address.results.length) return false;
    const global = await env.DB.prepare(
      "INSERT INTO mail_daily (day, n) SELECT ?1, 1 WHERE ?2 > 0 ON CONFLICT (day) DO UPDATE SET n = n + 1 WHERE n < ?2 RETURNING n",
    ).bind(utcDay(now), cap).all();
    return global.results.length > 0;
  } catch {
    return false;
  }
}

async function sendSafely(deps: Deps, mail: Mail): Promise<void> {
  try {
    await deps.send(mail);
  } catch {
    // A failed send leaves the row as it is; the person can sign up again later.
  }
}

async function confirmMail(env: Env, pid: string, email: string, createdAt: string): Promise<Mail> {
  const link = `${env.SITE_ORIGIN}/confirm?token=${await makeToken(env.HMAC_SECRET, "confirm", pid, email, createdAt)}`;
  return {
    to: email,
    subject: "Confirm your Homebot emails",
    text: `Confirm that you'd like ${LIST_TEXT}:\n\n${link}\n\nThe link works for ${CONFIRM_HOURS} hours. Didn't sign up? Ignore this email and we'll delete your address in 7 days.\n`,
    html: `<p>Confirm that you'd like ${esc(LIST_TEXT)}:</p><p><a href="${esc(link)}">Confirm</a></p><p>The link works for ${CONFIRM_HOURS} hours. Didn't sign up? Ignore this email and we'll delete your address in 7 days.</p>`,
  };
}

async function alreadyMail(env: Env, row: Row): Promise<Mail> {
  const token = await makeToken(env.HMAC_SECRET, "manage", row.pid, row.email);
  const manage = `${env.SITE_ORIGIN}/manage?token=${token}`;
  return {
    to: row.email,
    subject: "You're already on the Homebot list",
    text: `Someone (probably you) asked to sign this address up again. You're already subscribed to ${LIST_TEXT}.\n\nStop your emails: ${manage}\n`,
    html: `<p>Someone (probably you) asked to sign this address up again. You're already subscribed to ${esc(LIST_TEXT)}.</p><p><a href="${esc(manage)}">Stop your emails</a></p>`,
    headers: listHeaders(env, token),
  };
}

/** Headers every list email carries (RFC 2369 / RFC 8058 one-click unsubscribe). */
export function listHeaders(env: Env, manageToken: string): Record<string, string> {
  return {
    "List-Unsubscribe": `<${env.SITE_ORIGIN}/unsubscribe?token=${manageToken}>`,
    "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
  };
}

/** The row a token is for; "missing" when its pid isn't on the list (any more), null when the token is bad. */
async function rowByToken(env: Env, purpose: "confirm" | "manage", token: string | null): Promise<Row | "missing" | null> {
  const t = splitToken(token);
  if (!t) return null;
  const row = await env.DB.prepare("SELECT * FROM subscribers WHERE pid = ?").bind(t.pid).first<Row>();
  if (!row) return "missing";
  const ok = await checkToken(env.HMAC_SECRET, purpose, t.sig, row.pid, row.email, purpose === "confirm" ? row.created_at : "");
  return ok ? row : null;
}

/** A manage/unsubscribe token for an address that's gone is answered as "unsubscribed", which is true. */
async function manageRow(env: Env, token: string | null): Promise<Row | Response> {
  const r = await rowByToken(env, "manage", token);
  if (r === "missing") return gone();
  return r ?? invalidLink();
}

async function formToken(request: Request): Promise<URLSearchParams | null> {
  const text = await readBody(request, 2048);
  return text === null ? null : new URLSearchParams(text);
}

/** GET shows a button; only the POST confirms, so a mail scanner opening the link changes nothing. */
export async function handleConfirm(request: Request, env: Env, deps: Deps, url: URL): Promise<Response> {
  if (request.method === "GET") {
    const token = url.searchParams.get("token");
    const row = await rowByToken(env, "confirm", token);
    if (!row || row === "missing") return invalidLink();
    if (row.confirmed_at) return page("Subscribed", `<h1>You're already subscribed</h1><p>Nothing else to do.</p>`);
    if (expired(row, deps.now())) return invalidLink();
    return page("Confirm", `<h1>Confirm your Homebot emails</h1><p>You'll get ${esc(LIST_TEXT)}. Unsubscribe from any email.</p>
<form method="post" action="/confirm"><input type="hidden" name="token" value="${esc(token!)}"><button type="submit">Confirm</button></form>`);
  }
  if (request.method !== "POST") return empty(405);
  const token = (await formToken(request))?.get("token") ?? null;
  const row = await rowByToken(env, "confirm", token);
  if (!row || row === "missing") return invalidLink();
  // An old confirmation link never turns into a manage link, confirmed or not.
  if (expired(row, deps.now())) return invalidLink();
  if (!row.confirmed_at) {
    // Only the revision this token signed: a re-sign-up in between (a new created_at) isn't confirmed by an older link.
    const r = await env.DB.prepare("UPDATE subscribers SET confirmed_at = ? WHERE id = ? AND pid = ? AND email = ? AND created_at = ? AND confirmed_at IS NULL")
      .bind(deps.now().toISOString(), row.id, row.pid, row.email, row.created_at).run();
    if (!r.meta.changes) return invalidLink();
  }
  const manage = await makeToken(env.HMAC_SECRET, "manage", row.pid, row.email);
  return page("Subscribed", `<h1>You're subscribed</h1><p>Thanks. Every email has a link to unsubscribe.</p><p><a href="/manage?token=${esc(manage)}">Your email settings</a></p>`);
}

function expired(row: Row, now: Date): boolean {
  return now.getTime() - Date.parse(row.created_at) > CONFIRM_HOURS * 3600_000;
}

/**
 * GET shows a button that posts back to the same URL. POST deletes the address; it is also the
 * one-click target mail apps call with "List-Unsubscribe=One-Click" (the token stays in the query).
 */
export async function handleUnsubscribe(request: Request, env: Env, url: URL): Promise<Response> {
  const token = url.searchParams.get("token");
  if (request.method === "GET") {
    const row = await manageRow(env, token);
    if (row instanceof Response) return row;
    return page("Unsubscribe", `<h1>Unsubscribe from Homebot emails?</h1><p>We'll delete ${esc(row.email)} from our list.</p>
<form method="post" action="/unsubscribe?token=${esc(token!)}"><button type="submit">Unsubscribe</button></form>`);
  }
  if (request.method !== "POST") return empty(405);
  const row = await manageRow(env, token);
  if (row instanceof Response) return row;
  await env.DB.prepare("DELETE FROM subscribers WHERE id = ? AND pid = ? AND email = ?").bind(row.id, row.pid, row.email).run();
  return gone();
}

function gone(): Response {
  return page("Unsubscribed", `<h1>You're unsubscribed</h1><p>We deleted your email address. You won't get any more emails from us.</p>`);
}

/** What this address gets, and a button to stop it. Read-only: the button posts to /unsubscribe. */
export async function handleManage(request: Request, env: Env, url: URL): Promise<Response> {
  if (request.method !== "GET") return empty(405);
  const token = url.searchParams.get("token");
  const row = await manageRow(env, token);
  if (row instanceof Response) return row;
  return page("Your emails", `<h1>Your Homebot emails</h1><p>${esc(row.email)} gets ${esc(LIST_TEXT)}.</p>
<form method="post" action="/unsubscribe?token=${esc(token!)}"><button type="submit">Unsubscribe</button></form>`);
}
