// Plain HTML pages for the email links. No scripts, no external requests, so the token in the URL
// can't leak through a Referer or a third-party load.

export function esc(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

const CSS = `
:root{color-scheme:light dark;--bg:#fff;--fg:#1d1d1f;--muted:#6e6e73;--line:#d2d2d7;--accent:#0071e3}
@media (prefers-color-scheme:dark){:root{--bg:#1c1c1e;--fg:#f5f5f7;--muted:#a1a1a6;--line:#3a3a3c;--accent:#2997ff}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.5 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif}
main{max-width:28rem;margin:12vh auto;padding:0 16px}h1{font-size:1.5rem;margin:0 0 .5rem}p{margin:.5rem 0;color:var(--muted)}
form{margin-top:1.25rem}label{display:flex;gap:.6rem;align-items:center;padding:.6rem 0;border-bottom:1px solid var(--line);color:var(--fg)}
button{margin-top:1rem;font:inherit;padding:.55rem 1.1rem;border-radius:999px;border:0;background:var(--accent);color:#fff;cursor:pointer}
button.plain{background:none;color:var(--accent);padding-left:0}a{color:var(--accent)}`;

export function page(title: string, body: string, status = 200): Response {
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>${esc(title)} · Homebot</title><style>${CSS}</style></head><body><main>${body}</main></body></html>`;
  return new Response(html, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "referrer-policy": "no-referrer",
      "x-robots-tag": "noindex",
      "x-content-type-options": "nosniff",
      "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
    },
  });
}

export function invalidLink(): Response {
  return page("Link not valid", `<h1>This link isn't valid</h1><p>It may have expired or already been used. You can sign up again in Homebot › Help.</p>`, 400);
}

/** What a subscriber gets: the one list there is. */
export const LIST_TEXT = "Homebot product updates: new versions and important changes";
