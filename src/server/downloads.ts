// One-time download links for a built Shortcut file (DESIGN §7.8). The link id is a 128-bit
// bearer secret: in memory only, single use, 10 minutes, never logged. Served on the voice
// listener (the phone can't reach the loopback setup page) at GET /dl/<id>.
import { randomBytes } from "node:crypto";

export const LINK_TTL_MS = 10 * 60_000;
const ID = /^[A-Za-z0-9_-]{22}$/;

export interface Link {
  file: string;
  name: string;
  tokenId: string;
  expiresAt: number;
}

export class Downloads {
  now: () => number;
  ttlMs: number;
  links = new Map<string, Link>();

  constructor({ now = Date.now, ttlMs = LINK_TTL_MS }: { now?: () => number; ttlMs?: number } = {}) {
    this.now = now;
    this.ttlMs = ttlMs;
  }

  #prune(): void {
    for (const [id, l] of this.links) if (l.expiresAt <= this.now()) this.links.delete(id);
  }

  create({ file, name, tokenId }: { file: string; name: string; tokenId: string }): { id: string; expiresAt: number } {
    this.#prune();
    const id = randomBytes(16).toString("base64url");
    const expiresAt = this.now() + this.ttlMs;
    this.links.set(id, { file, name, tokenId, expiresAt });
    return { id, expiresAt };
  }

  /** Consume a link: returns it at most once, and only before it expires. */
  take(id: string): Link | null {
    this.#prune();
    if (!ID.test(id)) return null;
    const l = this.links.get(id);
    this.links.delete(id);
    return l ?? null;
  }

  /** Drop every link for a token (revoked / removed bot). */
  dropToken(tokenId: string): void {
    for (const [id, l] of this.links) if (l.tokenId === tokenId) this.links.delete(id);
  }
}
