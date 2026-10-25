// Per-Shortcut client tokens (DESIGN D9, §7.5). Only SHA-256 hashes are stored. Each token is
// bound to one bot. A new token starts `pending`; its first successful use makes it `active`
// and retires the token it replaces, so a failed rebuild never breaks a working Shortcut.
//
// tokens.json is the single authority shared by the running gateway and CLI invocations:
// every mutation is a locked read-modify-write, and verify() re-reads the file when it changed.
//
// Plaintext only leaves this module inside short-lived artifacts in the artifacts dir: an
// exported `<tokenId>.token` file, or a `<tokenId>/` directory holding a Shortcut file. They are
// deleted once the token is used, revoked or expired, and when older than 24 h (checked by every
// CLI run and periodically by the running gateway; if nothing runs, at the next run).
//
// Artifact lifecycle vs concurrency: an artifact is only ever created after its token record was
// written, and cleanup decides under the same lock as mutations, against the file's current
// content. So a cleanup in one process never deletes an artifact another process just built.
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { stat, readdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { isRecord, readJson, writeJson, withFileLock } from "./fsutil.ts";

export const PENDING_TTL_MS = 7 * 24 * 3600 * 1000;
export const ARTIFACT_TTL_MS = 24 * 3600 * 1000;

/** How labels (Siri phrases) are compared: NFC, trimmed, single spaces, case-insensitive. */
export const labelKey = (s: string): string => s.normalize("NFC").trim().replace(/\s+/g, " ").toLowerCase();

export type TokenState = "pending" | "active" | "retired";
export type TokenKind = "ask" | "probe" | "lab";

/**
 * kind "probe": a wait-limit test Shortcut; only accepted by /v1/probe-wait. kind "lab": the
 * device-experiment Shortcut; only accepted by /v1/lab (DESIGN §19.1). Neither is ever accepted
 * by /v1/ask, and neither replaces or is replaced by a voice token.
 */
export interface TokenRecord {
  id: string;
  hash: string;
  bot: string;
  label: string;
  state: TokenState;
  createdAt: number;
  activatedAt?: number;
  retiredAt?: number;
  replaces?: string;
  siriLang?: string;
  sessionId?: string;
  kind?: "probe" | "lab";
}

/** A token as shown to the UI/CLI: everything but the hash. */
export type TokenInfo = Omit<TokenRecord, "hash">;

export type VerifyResult = { ok: true; record: TokenRecord } | { ok: false; reason: "invalid" | "forbidden" };

const sha256 = (s: string): Buffer => createHash("sha256").update(s, "utf8").digest();
const ARTIFACT = /^([0-9a-f]{12})(?:\.|$)/; // "<id>.<ext>" file or "<id>" directory

/** tokens.json is machine-owned, written only by this class. */
function recordsOf(v: unknown): TokenRecord[] {
  return isRecord(v) && Array.isArray(v.tokens) ? (v.tokens as TokenRecord[]) : [];
}

export class TokenStore {
  file: string;
  now: () => number;
  artifactsDir: string | undefined;
  records: TokenRecord[] = [];
  fingerprint = "";

  constructor(file: string, { now = Date.now, artifactsDir }: { now?: () => number; artifactsDir?: string | undefined } = {}) {
    this.file = file;
    this.now = now;
    this.artifactsDir = artifactsDir;
  }

  async #fingerprint(): Promise<string> {
    const s = await stat(this.file).catch(() => null);
    return s ? `${s.ino}:${s.size}:${s.mtimeMs}` : "missing";
  }

  async load(): Promise<this> {
    const fp = await this.#fingerprint();
    this.records = recordsOf(await readJson(this.file, { tokens: [] }));
    this.fingerprint = fp;
    return this;
  }

  async #refresh(): Promise<void> {
    if ((await this.#fingerprint()) !== this.fingerprint) await this.load();
  }

  /**
   * Locked read-modify-write against the latest file content, then artifact cleanup under the
   * same lock.
   */
  async #mutate<T>(fn: () => T): Promise<T> {
    return withFileLock(this.file, async () => {
      await this.load();
      const r = fn();
      await writeJson(this.file, { tokens: this.records });
      this.fingerprint = await this.#fingerprint();
      await this.#sweepArtifacts();
      return r;
    });
  }

  /**
   * Issue a new pending token.
   * `uniqueLabel`: refuse when another non-retired token (other than `replaces`) has the same
   * label. A Shortcut's label is its Siri phrase, and this check runs under the issuance lock,
   * so two concurrent builds can't both take one phrase (DESIGN §16.2, milestone review S1). The plaintext is returned once and never stored here.
   * `replaces` must be a non-retired token of the same bot (checked under the lock).
   * `sessionId` binds the token to the bot's conversation too, so a later bot reusing the key
   * can't be reached with it. Callers issue through BotLifecycle.issueFor (identity check).
   */
  async issue({ bot, label, replaces, siriLang, sessionId, kind, uniqueLabel = false }: {
    bot: string;
    label: string;
    uniqueLabel?: boolean | undefined;
    replaces?: string | undefined;
    siriLang?: string | undefined;
    sessionId?: string | undefined;
    kind?: TokenKind | undefined;
  }): Promise<{ id: string; token: string }> {
    const token = randomBytes(32).toString("base64url");
    const id = randomBytes(6).toString("hex");
    await this.#mutate(() => {
      if (replaces) {
        const old = this.records.find((r) => r.id === replaces);
        if (!old || old.state === "retired") throw new Error(`cannot replace ${replaces}: no such usable token`);
        if (old.bot !== bot) throw new Error(`cannot replace ${replaces}: it belongs to bot "${old.bot}", not "${bot}"`);
        if ((old.kind ?? "ask") !== (kind ?? "ask")) throw new Error(`cannot replace ${replaces}: test Shortcuts and voice Shortcuts never replace each other`);
      }
      const clash = uniqueLabel ? this.records.find((r) => r.state !== "retired" && r.id !== replaces && labelKey(r.label) === labelKey(label)) : undefined;
      if (clash) throw new Error(`Another of your Homebot Shortcuts (token ${clash.id}) already uses "${label}". Siri can't tell them apart. Revoke it first, or replace it.`);
      this.records.push({
        id, hash: sha256(token).toString("hex"), bot, label, state: "pending", createdAt: this.now(),
        ...(replaces ? { replaces } : {}), ...(siriLang ? { siriLang } : {}), ...(sessionId ? { sessionId } : {}), ...(kind === "probe" || kind === "lab" ? { kind } : {}),
      });
    });
    return { id, token };
  }

  #usable(r: TokenRecord): boolean {
    return r.state === "active" || (r.state === "pending" && this.now() - r.createdAt < PENDING_TTL_MS);
  }

  /**
   * Authenticate and authorize against the current file content.
   * `bot`: the requested bot; undefined means "the token's own bot".
   * `kind`: which endpoint is asking; checked before activation, so a token used at the wrong
   * endpoint never activates or retires anything.
   */
  async verify(token: unknown, bot?: string | undefined, { kind = "ask" }: { kind?: TokenKind } = {}): Promise<VerifyResult> {
    await this.#refresh();
    const presented = sha256(String(token ?? ""));
    let match: TokenRecord | undefined;
    for (const r of this.records) {
      if (timingSafeEqual(presented, Buffer.from(r.hash, "hex")) && this.#usable(r)) match = r;
    }
    if (!match) return { ok: false, reason: "invalid" };
    if ((match.kind ?? "ask") !== kind) return { ok: false, reason: "invalid" };
    if (bot !== undefined && bot !== match.bot) return { ok: false, reason: "forbidden" };
    if (match.state === "pending") {
      const id = match.id;
      match = await this.#mutate(() => {
        const rec = this.records.find((r) => r.id === id);
        if (rec?.state === "pending" && this.#usable(rec)) this.#activate(rec);
        return rec;
      });
      if (!match || match.state !== "active") return { ok: false, reason: "invalid" }; // revoked meanwhile
    }
    return { ok: true, record: match };
  }

  #activate(rec: TokenRecord): void {
    const t = this.now();
    rec.state = "active";
    rec.activatedAt = t;
    const old = rec.replaces && this.records.find((r) => r.id === rec.replaces);
    if (old && old.state !== "retired") Object.assign(old, { state: "retired", retiredAt: t });
  }

  revoke(id: string): Promise<boolean> {
    return this.#mutate(() => {
      const r = this.records.find((x) => x.id === id);
      if (!r) return false;
      Object.assign(r, { state: "retired", retiredAt: this.now() });
      return true;
    });
  }

  /** Retire every non-retired token of a bot in one locked write. Returns their ids. */
  revokeBot(bot: string): Promise<string[]> {
    return this.#mutate(() => {
      const hit = this.records.filter((r) => r.bot === bot && r.state !== "retired");
      for (const r of hit) Object.assign(r, { state: "retired", retiredAt: this.now() });
      return hit.map((r) => r.id);
    });
  }

  /** Drop pending tokens that were never used within the TTL. Returns removed ids. */
  expirePending(): Promise<string[]> {
    return this.#mutate(() => {
      const dead = this.records.filter((r) => r.state === "pending" && this.now() - r.createdAt >= PENDING_TTL_MS);
      this.records = this.records.filter((r) => !dead.includes(r));
      return dead.map((r) => r.id);
    });
  }

  /** Delete artifacts whose token is no longer pending, unknown, or older than 24 h. */
  async cleanupArtifacts(): Promise<string[]> {
    if (!this.artifactsDir) return [];
    return withFileLock(this.file, async () => {
      await this.load();
      return this.#sweepArtifacts();
    });
  }

  /** Caller holds the lock and has just loaded the file. */
  async #sweepArtifacts(): Promise<string[]> {
    if (!this.artifactsDir) return [];
    const names = await readdir(this.artifactsDir).catch((): string[] => []);
    const removed: string[] = [];
    for (const name of names) {
      const id = ARTIFACT.exec(name)?.[1];
      if (!id) continue;
      const path = join(this.artifactsDir, name);
      const rec = this.records.find((r) => r.id === id);
      const age = this.now() - ((await stat(path).catch(() => null))?.mtimeMs ?? 0);
      if (!rec || rec.state !== "pending" || age >= ARTIFACT_TTL_MS) {
        await rm(path, { force: true, recursive: true });
        removed.push(name);
      }
    }
    return removed;
  }

  artifactPath(id: string, ext: string): string {
    if (!this.artifactsDir) throw new Error("no artifacts dir");
    return join(this.artifactsDir, `${id}.${ext}`);
  }

  /** Per-token directory, for artifacts whose file name must be user-facing. */
  artifactDir(id: string): string {
    if (!this.artifactsDir) throw new Error("no artifacts dir");
    return join(this.artifactsDir, id);
  }

  /** Safe listing for UI/CLI: never includes hashes. */
  list(): TokenInfo[] {
    return this.records.map(({ hash: _hash, ...rest }) => rest);
  }
}
