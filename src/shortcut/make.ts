// Build one Shortcut file for one bot: issue a pending token bound to the bot and the Siri
// language, write the token-bearing plist as a short-lived 0600 artifact (deleted on first
// use / revoke / expiry / 24 h by TokenStore), optionally sign it.
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { hostname } from "node:os";
import { join } from "node:path";
import { rm, chmod } from "node:fs/promises";
import { writePrivateFile } from "../core/fsutil.ts";
import type { TokenStore } from "../core/tokens.ts";
import type { BotLifecycle } from "../core/lifecycle.ts";
import type { Bot } from "../core/store.ts";
import { toXmlPlist } from "./plist.ts";
import { buildAskShortcut, buildConversationShortcut, buildLabShortcut, buildProbeShortcut } from "./build.ts";
import { signShortcut, type SignMode, type Signer } from "./sign.ts";
import type { ShortcutProfile } from "./profile.ts";

/**
 * A display name made safe as one path segment: no separators, control characters or leading
 * dots, at most 60 characters.
 */
export function safeFileName(name: string): string {
  const s = [...name.replace(/[\/\\:\u0000-\u001f\u007f]/g, "_").replace(/^[.\s]+/, "_").trim()].slice(0, 60).join("");
  return s || "Homebot";
}

export type RunForStdout = (cmd: string, args: string[]) => Promise<{ stdout: string }>;

const execFileAsync = promisify(execFile);

/** The Mac's Bonjour name (DESIGN D10), e.g. "felix-mac" -> http://felix-mac.local:8787 */
export async function localHostName(run: RunForStdout = (cmd, args) => execFileAsync(cmd, args)): Promise<string> {
  try {
    const { stdout } = await run("scutil", ["--get", "LocalHostName"]);
    if (stdout.trim()) return stdout.trim();
  } catch {
    // not macOS or scutil unavailable
  }
  return hostname().replace(/\.local$/, "");
}

export interface SignWith {
  signer?: Signer | undefined;
  onAttempt?: ((i: { attempt: number; mode: SignMode }) => void) | undefined;
}

export interface MadeShortcut {
  tokenId: string;
  file: string;
  name: string;
  signed: boolean;
}

export async function makeShortcut({ tokens, lifecycle, bot, profile, baseUrl, probe = false, lab = false, conversation = false, replaces, sign = false }: {
  tokens: TokenStore;
  lifecycle?: BotLifecycle | undefined;
  bot: Bot;
  profile: ShortcutProfile;
  baseUrl: string;
  probe?: boolean | undefined;
  /** The device-experiment Shortcut (DESIGN §19.1); never with `probe`. */
  lab?: boolean | undefined;
  /** A voice Shortcut that keeps listening after each answer (DESIGN §18, experimental). */
  conversation?: boolean | undefined;
  replaces?: string | undefined;
  sign?: false | SignWith;
}): Promise<MadeShortcut> {
  // Non-secret inputs are checked before a token exists.
  const url = (() => {
    try {
      return new URL(baseUrl);
    } catch {
      return null;
    }
  })();
  if (!url || !["http:", "https:"].includes(url.protocol)) throw new Error(`gateway URL must be http(s)://host:port, got ${JSON.stringify(baseUrl)}`);
  // The phrase rule (DESIGN §16.2) is a hard rule: every known recognition failure broke it.
  const kind = probe ? "probe" : lab ? "lab" : "ask";
  if ([probe, lab, conversation].filter(Boolean).length > 1) throw new Error("a Shortcut is one of: voice, conversation, wait test, lab test");
  const blocking = profile.problems.filter((p) => p.blocking);
  if (kind === "ask" && blocking.length) throw new Error(blocking.map((p) => p.message).join(" "));
  // iOS names an imported Shortcut after its FILE name, so the effective Siri phrase is the
  // sanitized file name; it is also the name the setup steps tell the user to run.
  const name = safeFileName(kind === "probe" ? profile.probeName : kind === "lab" ? profile.labName : profile.name);

  // Issued only while the bot still exists with the same session (BotLifecycle, M4 review B1).
  // Probe tokens are their own kind: they never answer /v1/ask and never replace a voice token.
  const issue = (b: Bot) =>
    tokens.issue({ bot: b.key, label: name, replaces, siriLang: profile.siriLang, sessionId: b.sessionId, kind, uniqueLabel: true });
  const { id, token } = lifecycle ? await lifecycle.issueFor(bot, issue) : await issue(bot);
  const dir = tokens.artifactDir(id);
  try {
    const plist =
      kind === "probe"
        ? buildProbeShortcut({ baseUrl, token, speakLang: profile.speakLang })
        : kind === "lab"
          ? buildLabShortcut({ baseUrl, token, speakLang: profile.speakLang })
          : conversation
            ? buildConversationShortcut({ baseUrl, botKey: bot.key, token, prompt: profile.prompt, speakLang: profile.speakLang })
            : buildAskShortcut({ baseUrl, botKey: bot.key, token, prompt: profile.prompt, speakLang: profile.speakLang });
    const unsigned = join(dir, `${name}.unsigned.shortcut`);
    await writePrivateFile(unsigned, toXmlPlist(plist));
    if (!sign) return { tokenId: id, file: unsigned, name, signed: false };

    const signed = join(dir, `${name}.shortcut`);
    try {
      await (sign.signer ?? signShortcut)({ input: unsigned, output: signed, onAttempt: sign.onAttempt });
      await chmod(signed, 0o600); // the signer runs with umask 077 already; this covers custom signers
    } finally {
      await rm(unsigned, { force: true });
    }
    return { tokenId: id, file: signed, name, signed: true };
  } catch (e) {
    // One failure boundary once a token exists: no usable new token, no leftover files.
    // The token being replaced is untouched (it is only retired by the new token's first use).
    await rm(dir, { recursive: true, force: true });
    await tokens.revoke(id);
    throw e;
  }
}
