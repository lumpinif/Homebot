/** UTC day as YYYY-MM-DD. All counters use the server's clock, never the client's. */
export function utcDay(d: Date): string {
  return d.toISOString().slice(0, 10);
}

export function utcMonth(d: Date): string {
  return d.toISOString().slice(0, 7);
}

/**
 * Coarse country from Cloudflare's edge (request.cf.country). The IP address itself is never read.
 * Unknown, Tor ("T1") and anything malformed become "ZZ".
 */
export function country(request: Request): string {
  const c = (request as { cf?: { country?: unknown } }).cf?.country;
  if (typeof c !== "string" || !/^[A-Z]{2}$/.test(c) || c === "XX" || c === "T1") return "ZZ";
  return c;
}

/**
 * Reads at most `limit` bytes of the body; null when it's bigger or unreadable. The stream is
 * read chunk by chunk and cancelled as soon as it passes the limit, so a huge upload is never
 * buffered (with or without Content-Length).
 */
export async function readBody(request: Request, limit: number): Promise<string | null> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (!(declared <= limit)) return null;
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) {
        await reader.cancel().catch(() => {});
        return null;
      }
      chunks.push(value);
    }
  } catch {
    return null;
  }
  const all = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) {
    all.set(c, at);
    at += c.byteLength;
  }
  try {
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(all);
  } catch {
    return null;
  }
}

/** Whether a release zip of this version is in the bucket (cached per isolate). */
const knownVersions = new Map<string, boolean>();
export async function isReleased(bucket: R2Bucket, version: string): Promise<boolean> {
  const hit = knownVersions.get(version);
  if (hit !== undefined) return hit;
  const ok = (await bucket.head(`releases/Homebot-${version}.zip`)) !== null;
  // Unknown versions are remembered only briefly: a release uploaded later must start counting.
  if (ok) knownVersions.set(version, true);
  return ok;
}

export function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers },
  });
}

export function empty(status: number): Response {
  return new Response(null, { status, headers: { "cache-control": "no-store" } });
}

/** Adds 1 to a counter row. `table` and `cols` are constants from this codebase, never user input. */
export function bump(db: D1Database, table: string, cols: string[], values: string[]): D1PreparedStatement {
  const marks = cols.map(() => "?").join(", ");
  return db
    .prepare(`INSERT INTO ${table} (${cols.join(", ")}, n) VALUES (${marks}, 1) ON CONFLICT DO UPDATE SET n = n + 1`)
    .bind(...values);
}

export const VERSION_RE = /^\d{1,2}\.\d{1,3}\.\d{1,3}$/;
