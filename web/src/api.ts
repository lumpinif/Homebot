// The setup page API client. Every call carries the per-launch secret the gateway writes into
// the page's <meta>; the server is this page's own origin. Response shapes are documented in
// src/server/setup-api.ts.
export type {
  BotView,
  DownloadLink,
  Option,
  PhraseProblemView,
  SetupState,
  ShortcutBuild,
  ShortcutPreview,
  TokenView,
} from "../../src/server/setup-api.ts";

const meta = (name: string): string => document.querySelector(`meta[name="${name}"]`)?.getAttribute("content") ?? "";
const SECRET = meta("homebot-setup");
/** CSP nonce for the few <style> elements motion inserts (AnimatePresence popLayout). */
export const STYLE_NONCE = meta("homebot-style-nonce");

export class ApiFailure extends Error {
  code: string | undefined;
  constructor(message: string, code: string | undefined) {
    super(message);
    this.code = code;
  }
}

/** GET without a body, POST with one. The caller names the documented response shape. */
export async function api<R>(path: string, body?: unknown): Promise<R> {
  const init: RequestInit =
    body === undefined
      ? { headers: { "x-homebot-setup": SECRET } }
      : { method: "POST", headers: { "x-homebot-setup": SECRET, "content-type": "application/json" }, body: JSON.stringify(body) };
  const res = await fetch(path, init);
  const data: unknown = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = typeof data === "object" && data !== null && "error" in data && typeof data.error === "object" && data.error !== null ? data.error : {};
    const message = "message" in err && typeof err.message === "string" ? err.message : `HTTP ${res.status}`;
    throw new ApiFailure(message, "code" in err && typeof err.code === "string" ? err.code : undefined);
  }
  // JSON boundary: the server's documented shape for this path.
  return data as R;
}
