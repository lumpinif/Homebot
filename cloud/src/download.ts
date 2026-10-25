import type { Deps, Env } from "./env";
import { bump, country, empty, json, utcDay, VERSION_RE } from "./util";

/** releases/latest.json in the bucket, written at release time (DEPLOY.md). */
export interface Latest {
  version: string;
  sha256: string;
  notes?: string;
}

const CHANNELS = new Set(["home", "install", "agent", "app", "github"]);
const FILE_RE = /^Homebot-(\d{1,2}\.\d{1,3}\.\d{1,3})\.zip$/;

export async function readLatest(env: Env): Promise<Latest | null> {
  const obj = await env.RELEASES.get("releases/latest.json");
  if (!obj) return null;
  try {
    const l = (await obj.json()) as Latest;
    return typeof l.version === "string" && VERSION_RE.test(l.version) && typeof l.sha256 === "string" ? l : null;
  } catch {
    return null;
  }
}

function channelOf(url: URL): string {
  const from = url.searchParams.get("from");
  if (from === null) return "direct";
  return CHANNELS.has(from) ? from : "other";
}

/**
 * A request that starts a download: a plain GET, or exactly "bytes=0-" (the whole file from the
 * start). Resumes and partial probes such as "bytes=0-0" don't count.
 */
function startsDownload(request: Request): boolean {
  if (request.method !== "GET") return false;
  const range = request.headers.get("range");
  return range === null || range.trim() === "bytes=0-";
}

/**
 * Parses a single "bytes=a-b" / "bytes=a-" / "bytes=-n" range. Anything malformed or backwards is
 * ignored and the file is served whole (RFC 9110 allows that).
 */
function parseRange(header: string | null): R2Range | undefined {
  const m = header?.trim().match(/^bytes=(\d{0,15})-(\d{0,15})$/);
  if (!m || (m[1] === "" && m[2] === "")) return undefined;
  if (m[1] === "") return Number(m[2]) > 0 ? { suffix: Number(m[2]) } : undefined;
  const offset = Number(m[1]);
  if (m[2] === "") return { offset };
  const end = Number(m[2]);
  return end >= offset ? { offset, length: end - offset + 1 } : undefined;
}

export async function handleDownload(request: Request, env: Env, deps: Deps, ctx: ExecutionContext, url: URL): Promise<Response> {
  if (request.method !== "GET" && request.method !== "HEAD") return empty(405);
  const name = url.pathname.slice("/download/".length);

  if (name === "latest") {
    const latest = await readLatest(env);
    if (!latest) return empty(404);
    const to = new URL(`/download/Homebot-${latest.version}.zip`, env.SITE_ORIGIN);
    const from = url.searchParams.get("from");
    if (from !== null) to.searchParams.set("from", from);
    return new Response(null, { status: 302, headers: { location: to.toString(), "cache-control": "no-store" } });
  }

  const m = name.match(FILE_RE);
  if (!m) return empty(404);
  const version = m[1];
  const key = `releases/${name}`;

  if (request.method === "HEAD") {
    const head = await env.RELEASES.head(key);
    if (!head) return empty(404);
    return new Response(null, { headers: fileHeaders(head, name) });
  }

  let range = parseRange(request.headers.get("range"));
  if (range && "offset" in range) {
    // A range starting past the end can't be served: 416 with the size, as RFC 9110 asks.
    const head = await env.RELEASES.head(key);
    if (!head) return empty(404);
    if ((range.offset ?? 0) >= head.size) {
      return new Response(null, { status: 416, headers: { "content-range": `bytes */${head.size}`, "cache-control": "no-store" } });
    }
    if (range.length !== undefined && range.offset! + range.length > head.size) range = { offset: range.offset! };
  }
  let obj: R2ObjectBody | null;
  try {
    obj = await env.RELEASES.get(key, range ? { range } : {});
  } catch {
    obj = await env.RELEASES.get(key);
    range = undefined;
  }
  if (!obj) return empty(404);

  if (startsDownload(request)) {
    const day = utcDay(deps.now());
    ctx.waitUntil(
      env.DB.batch([
        bump(env.DB, "downloads_daily", ["day", "version", "channel"], [day, version, channelOf(url)]),
        bump(env.DB, "downloads_country_daily", ["day", "country"], [day, country(request)]),
      ]).catch(() => {}),
    );
  }

  const headers = fileHeaders(obj, name);
  if (range && obj.range) {
    const r = obj.range as { offset?: number; length?: number; suffix?: number };
    const start = r.suffix !== undefined ? Math.max(0, obj.size - r.suffix) : (r.offset ?? 0);
    const len = r.suffix !== undefined ? obj.size - start : (r.length ?? obj.size - start);
    headers.set("content-range", `bytes ${start}-${start + len - 1}/${obj.size}`);
    headers.set("content-length", String(len));
    return new Response(obj.body, { status: 206, headers });
  }
  return new Response(obj.body, { headers });
}

function fileHeaders(obj: R2Object, name: string): Headers {
  const h = new Headers();
  h.set("content-type", "application/zip");
  h.set("content-length", String(obj.size));
  h.set("content-disposition", `attachment; filename="${name}"`);
  h.set("etag", obj.httpEtag);
  h.set("accept-ranges", "bytes");
  // Not cached at the edge, so every download reaches this Worker and is counted once.
  h.set("cache-control", "no-store");
  return h;
}

/** GET /api/v1/latest — the app's daily update check. It sends nothing; only the number of checks is kept. */
export async function handleLatest(request: Request, env: Env, deps: Deps, ctx: ExecutionContext): Promise<Response> {
  if (request.method !== "GET") return empty(405);
  const latest = await readLatest(env);
  // Counted under the same limiter as pings, so a flood can't inflate the count or the writes.
  const { success } = await env.PING_LIMIT.limit({ key: "latest" });
  if (success) ctx.waitUntil(bump(env.DB, "update_checks_daily", ["day"], [utcDay(deps.now())]).run().catch(() => {}));
  if (!latest) return empty(404);
  return json({
    version: latest.version,
    url: `${env.SITE_ORIGIN}/download/Homebot-${latest.version}.zip?from=app`,
    sha256: latest.sha256,
    ...(latest.notes ? { notes: latest.notes } : {}),
  });
}
