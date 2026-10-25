// Link tokens are HMACs, recomputed on every request, so no token is stored in the database.
// A token is `<pid>.<signature>`; `pid` is a random public id, never the row id.

const enc = new TextEncoder();

function b64url(bytes: ArrayBuffer | Uint8Array): string {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let s = "";
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function unb64url(s: string): Uint8Array<ArrayBuffer> | null {
  if (!/^[A-Za-z0-9_-]+$/.test(s)) return null;
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/"));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function key(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}

export function newPid(): string {
  return b64url(crypto.getRandomValues(new Uint8Array(16)));
}

/** HMAC of a lower-cased address, for the per-address throttle (the plain address isn't kept there). */
export async function addrHash(secret: string, email: string): Promise<string> {
  return b64url(await crypto.subtle.sign("HMAC", await key(secret), enc.encode(`addr|${email}`)));
}

/**
 * purpose "confirm" binds created_at, so a re-sent confirmation replaces the old link;
 * purpose "manage" (unsubscribe and manage) binds only pid and address and works until the row is deleted.
 */
function message(purpose: "confirm" | "manage", pid: string, email: string, createdAt: string): Uint8Array<ArrayBuffer> {
  return new Uint8Array(enc.encode(purpose === "confirm" ? `confirm|${pid}|${email}|${createdAt}` : `manage|${pid}|${email}`));
}

export async function makeToken(secret: string, purpose: "confirm" | "manage", pid: string, email: string, createdAt = ""): Promise<string> {
  const sig = await crypto.subtle.sign("HMAC", await key(secret), message(purpose, pid, email, createdAt));
  return `${pid}.${b64url(sig)}`;
}

/** Splits a token into its pid and signature; null when malformed. */
export function splitToken(token: string | null): { pid: string; sig: Uint8Array<ArrayBuffer> } | null {
  if (!token || token.length > 200) return null;
  const [pid, s, extra] = token.split(".");
  if (!pid || !s || extra !== undefined || !/^[A-Za-z0-9_-]{22}$/.test(pid)) return null;
  const sig = unb64url(s);
  return sig ? { pid, sig } : null;
}

/** Constant-time check (crypto.subtle.verify). */
export async function checkToken(secret: string, purpose: "confirm" | "manage", sig: Uint8Array<ArrayBuffer>, pid: string, email: string, createdAt = ""): Promise<boolean> {
  return crypto.subtle.verify("HMAC", await key(secret), sig, message(purpose, pid, email, createdAt));
}
