// One owner for a bot's identity: its config entry (key -> session), its cursor, and the
// tokens bound to it (M4 review B1, S1). Every change runs under one cross-process lock on
// config.json and starts by re-reading the files, so the setup page, CLI commands and the
// gateway can't interleave:
//  - removal retires all of the bot's tokens, then drops its cursor and entry, in one step;
//  - token issuance re-checks under the lock that the bot still exists with the same session,
//    so a build that captured the bot before a removal (or a remove + re-add) gets nothing;
//  - adding re-checks identity under the lock before it installs the cursor, so a rejected
//    concurrent add never touches another bot's cursor.
// Lock order is always config -> state/tokens; nothing takes the config lock while holding those.
import { withFileLock } from "./fsutil.ts";
import type { Bot, ConfigStore, StateStore } from "./store.ts";
import type { TokenStore } from "./tokens.ts";

export class BotLifecycle {
  config: ConfigStore;
  state: StateStore;
  tokens: TokenStore;

  constructor({ config, state, tokens }: { config: ConfigStore; state: StateStore; tokens: TokenStore }) {
    this.config = config;
    this.state = state;
    this.tokens = tokens;
  }

  #locked<T>(fn: () => Promise<T>): Promise<T> {
    return withFileLock(this.config.file, async () => {
      await this.config.load();
      await this.state.load();
      return fn();
    });
  }

  /**
   * Install a validated bot with its cold-sync cursor. Throws (changing nothing) if the key or
   * session became taken while the sync ran.
   */
  add(bot: Bot, sync: { cursor: string; maxSeq: string }): Promise<void> {
    return this.#locked(async () => {
      this.config.checkBot(bot);
      await this.state.setCursor(bot.key, sync, { sessionId: bot.sessionId, replace: true });
      await this.config.putBot(bot);
    });
  }

  /** Remove a bot and everything bound to it. Returns the retired token ids, or null if unknown. */
  remove(key: string): Promise<string[] | null> {
    return this.#locked(async () => {
      if (!this.config.bot(key)) return null;
      const retired = await this.tokens.revokeBot(key);
      await this.state.removeCursor(key);
      await this.config.removeBot(key);
      return retired;
    });
  }

  /** Run `issue` only while `bot` still exists with the same session (B1). */
  issueFor<T>(bot: Bot, issue: (current: Bot) => Promise<T>): Promise<T> {
    return this.#locked(async () => {
      const current = this.config.bot(bot.key);
      if (!current || current.sessionId !== bot.sessionId) {
        throw new Error(`bot "${bot.key}" was removed or changed meanwhile; nothing was issued`);
      }
      return issue(current);
    });
  }
}
