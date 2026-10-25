// config.json (bots + settings, user-editable) and state.json (per-bot cursors, machine-owned).
import { stat } from "node:fs/promises";
import { isRecord, readJson, writeJson, withFileLock } from "./fsutil.ts";

/** Language is not a bot property: it comes from the Shortcut (its token's Siri language). */
export interface Bot {
  key: string;
  name: string;
  sessionId: string;
  strictEcho: boolean;
  style?: string | null;
}

/**
 * siriLang/phoneLang: the user's answers from setup; Shortcut builds default to them.
 * uiLang: the setup page's own language.
 */
export interface Settings {
  answerBudgetMs: number;
  pollMs: number;
  maxSpokenChars: Record<string, number>;
  port: number;
  bind: string;
  setupPort: number;
  maxQuestionChars: number;
  rateLimitPerMin: number;
  logText: boolean;
  /**
   * Conversation mode (DESIGN §18.3): how long a follow-up inside a run may wait for the bot's
   * previous turn to go idle before it is answered "busy". 0 = answer "busy" at once.
   */
  followupIdleMs: number;
  siriLang?: string;
  phoneLang?: string;
  uiLang?: string;
  /**
   * The user agreed, on the setup page or by passing --sign, that Shortcuts are sent to Apple's
   * signing service (DESIGN §7.5). Off until they agree; iOS imports only signed Shortcuts.
   */
  appleSigning?: boolean;
}

export interface ConfigData {
  bots: Record<string, Omit<Bot, "key">>;
  settings: Partial<Settings>;
}

export const DEFAULT_SETTINGS: Settings = {
  answerBudgetMs: 25_000,
  pollMs: 500,
  // Per reply language (src/core/lang.ts); languages written without spaces count characters,
  // so they get a lower cap. Unlisted languages use 600.
  maxSpokenChars: { "zh-CN": 300, "zh-TW": 300, ja: 300, ko: 400, en: 600 },
  port: 8787,
  bind: "0.0.0.0",
  setupPort: 8788, // setup page; always bound to 127.0.0.1
  maxQuestionChars: 1000,
  rateLimitPerMin: 10,
  logText: false,
  followupIdleMs: 0,
};

const BOT_KEY = /^[a-z0-9][a-z0-9-]{0,31}$/;
export const isValidBotKey = (k: string): boolean => BOT_KEY.test(k);

export function validateBot(bot: Bot): void {
  if (!isValidBotKey(bot.key)) throw new Error("bot key must be 1-32 chars: a-z, 0-9, '-'");
  if (!/^\d+$/.test(bot.sessionId)) throw new Error("session id must be numeric");
}

async function fingerprintOf(file: string): Promise<string> {
  const s = await stat(file).catch(() => null);
  return s ? `${s.ino}:${s.size}:${s.mtimeMs}` : "missing";
}

/** A JSON file's top-level object, or {} (the files' documented shape is trusted from there on). */
const objectOf = (v: unknown): Record<string, unknown> => (isRecord(v) ? v : {});

export class ConfigStore {
  file: string;
  data: ConfigData = { bots: {}, settings: {} };
  fingerprint = "";

  constructor(file: string) {
    this.file = file;
  }
  async load(): Promise<this> {
    const fp = await fingerprintOf(this.file);
    // config.json is user-editable; it is trusted to follow ConfigData, as before the TS port.
    // Bots are validated when written (checkBot) and settings are read with defaults.
    this.data = { bots: {}, settings: {}, ...objectOf(await readJson(this.file, {})) } as ConfigData;
    this.fingerprint = fp;
    return this;
  }
  /** Re-read if another process changed the file (writes are rename-based: new inode). */
  async refresh(): Promise<this> {
    if ((await fingerprintOf(this.file)) !== this.fingerprint) await this.load();
    return this;
  }
  async save(): Promise<void> {
    await writeJson(this.file, this.data);
    this.fingerprint = await fingerprintOf(this.file);
  }
  get settings(): Settings {
    const s = this.data.settings;
    return { ...DEFAULT_SETTINGS, ...s, maxSpokenChars: { ...DEFAULT_SETTINGS.maxSpokenChars, ...s.maxSpokenChars } };
  }
  bot(key: string): Bot | undefined {
    const b = Object.hasOwn(this.data.bots, key) ? this.data.bots[key] : undefined;
    return b && { key, ...b };
  }
  bots(): Bot[] {
    return Object.entries(this.data.bots).map(([key, b]) => ({ key, ...b }));
  }
  /**
   * Validate a bot and refuse identity changes: a key never moves to another session (its
   * cursor and token grants belong to the old one), and a session belongs to one key only.
   */
  checkBot(bot: Bot): void {
    validateBot(bot);
    const existing = this.bot(bot.key);
    if (existing && existing.sessionId !== bot.sessionId) {
      throw new Error(`bot key "${bot.key}" already belongs to session ${existing.sessionId}; choose another key`);
    }
    const other = this.bots().find((b) => b.sessionId === bot.sessionId && b.key !== bot.key);
    if (other) throw new Error(`session ${bot.sessionId} is already configured as bot "${other.key}"`);
  }

  async putBot(bot: Bot): Promise<void> {
    this.checkBot(bot);
    const { key, ...rest } = bot;
    this.data.bots[key] = rest;
    await this.save();
  }

  async removeBot(key: string): Promise<boolean> {
    if (!this.bot(key)) return false;
    delete this.data.bots[key];
    await this.save();
    return true;
  }

  /**
   * Under the same cross-process lock as bot changes, against the file as it is now, so two
   * writers (page and CLI, or two page requests) never drop each other's setting.
   */
  putSettings(patch: Partial<Settings>): Promise<void> {
    return withFileLock(this.file, async () => {
      await this.load();
      this.data.settings = { ...this.data.settings, ...patch };
      await this.save();
    });
  }
}

/** sessionId: the conversation this cursor belongs to (cursors written before M4 fixes lack it). */
export interface Cursor {
  cursor: string;
  maxSeq: string;
  syncedAt: number;
  sessionId?: string;
}

export interface StateData {
  cursors: Record<string, Cursor>;
}

/**
 * state.json: per-bot cursors. Written by the gateway (after each request) and by setup/CLI
 * (bot add/remove), possibly in different processes, so every write is a locked
 * read-modify-write against the current file.
 */
export class StateStore {
  file: string;
  data: StateData = { cursors: {} };
  fingerprint = "";

  constructor(file: string) {
    this.file = file;
  }
  async load(): Promise<this> {
    const fp = await fingerprintOf(this.file);
    // Machine-owned file, written only by this class.
    this.data = { cursors: {}, ...objectOf(await readJson(this.file, {})) } as StateData;
    this.fingerprint = fp;
    return this;
  }
  /** Re-read if another process changed the file. */
  async refresh(): Promise<this> {
    if ((await fingerprintOf(this.file)) !== this.fingerprint) await this.load();
    return this;
  }
  cursor(bot: string): Cursor | undefined {
    return Object.hasOwn(this.data.cursors, bot) ? this.data.cursors[bot] : undefined;
  }
  #mutate(fn: (cursors: Record<string, Cursor>) => void): Promise<void> {
    return withFileLock(this.file, async () => {
      await this.load();
      fn(this.data.cursors);
      await writeJson(this.file, this.data);
      this.fingerprint = await fingerprintOf(this.file);
    });
  }
  /**
   * Record a bot's position. Normally forward-only and only for the same conversation: a write
   * tagged with another session id than the stored one is dropped (a late write from a removed
   * bot). `replace` (bot add, under the lifecycle lock) installs a fresh cold-sync cursor.
   */
  setCursor(bot: string, { cursor, maxSeq }: { cursor: string; maxSeq: string }, { sessionId, replace = false }: { sessionId?: string | undefined; replace?: boolean } = {}): Promise<void> {
    return this.#mutate((cursors) => {
      const prev = Object.hasOwn(cursors, bot) ? cursors[bot] : undefined;
      const tag = sessionId ? { sessionId } : prev?.sessionId ? { sessionId: prev.sessionId } : {};
      if (replace || !prev) {
        cursors[bot] = { cursor, maxSeq, syncedAt: Date.now(), ...tag };
        return;
      }
      if (sessionId && prev.sessionId && prev.sessionId !== sessionId) return;
      if (BigInt(prev.cursor) > BigInt(cursor)) return;
      cursors[bot] = { cursor, maxSeq: BigInt(prev.maxSeq) > BigInt(maxSeq) ? prev.maxSeq : maxSeq, syncedAt: Date.now(), ...tag };
    });
  }
  removeCursor(bot: string): Promise<void> {
    return this.#mutate((cursors) => {
      delete cursors[bot];
    });
  }
}
