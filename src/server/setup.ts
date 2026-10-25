// Setup page listener (DESIGN §8): loopback only (127.0.0.1), never reachable from the LAN.
// Serves a static page and a small JSON API for languages, the account key, bots, Shortcuts and
// tokens. Defenses, in order:
//  - Host must be 127.0.0.1:<port> or localhost:<port> (DNS rebinding).
//  - /api/* needs the per-launch secret header, which only the served page knows (a page from
//    another origin can't read our HTML, so it can't learn it).
//  - State-changing calls must be POST + application/json + a matching Origin (CSRF).
//  - Responses never contain the API key, token plaintext or hashes. The one exception is a
//    one-time download link, returned once to the page that asked for it.
//  - The page renders everything with textContent (no HTML from data) under a strict CSP.
import http from "node:http";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { readFile, access } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { join, basename, dirname } from "node:path";
import { BdkError, type BdkClient } from "../core/bdk.ts";
import { coldSync, resolveBotByName } from "../core/bots.ts";
import { isRecord, readJson, writeJson } from "../core/fsutil.ts";
import { SIRI_OPTIONS, LANGUAGES, LANG_OPTIONS, isLang, isSiriLang, langOfSiri, heySiri, DEFAULT_SIRI_LANG } from "../core/lang.ts";
import { isValidBotKey, type Bot, type ConfigStore, type Settings, type StateStore } from "../core/store.ts";
import { encodeQr } from "../core/qr.ts";
import type { TokenStore } from "../core/tokens.ts";
import type { BotLifecycle } from "../core/lifecycle.ts";
import { errorName, type Log } from "../core/log.ts";
import { keptPhrase, shortcutProfile, takenPhrases, type ShortcutProfile } from "../shortcut/profile.ts";
import { makeShortcut, safeFileName, type MadeShortcut } from "../shortcut/make.ts";
import type { Signer } from "../shortcut/sign.ts";
import type { Downloads } from "./downloads.ts";
import type { DownloadLink, ShortcutBuild, ShortcutPreview, SetupState } from "./setup-api.ts";

const UI_DIR = join(dirname(fileURLToPath(import.meta.url)), "../setup-ui");
// The page is built from web/ (npm run build:ui) with fixed file names.
const STATIC: Record<string, [file: string, type: string]> = {
  "/": ["index.html", "text/html; charset=utf-8"],
  "/assets/app.js": ["assets/app.js", "text/javascript; charset=utf-8"],
  "/assets/app.css": ["assets/app.css", "text/css; charset=utf-8"],
  // Grok Bot's app icon (xAI's mark, used only to name the product; from web/public).
  "/grok-bot.png": ["grok-bot.png", "image/png"],
  // Homebot's own mark (same drawing as HomebotMark in web/src/app/brand.tsx).
  "/favicon.svg": ["favicon.svg", "image/svg+xml"],
};
const csp = (styleNonce?: string) =>
  `default-src 'none'; script-src 'self'; style-src 'self'${styleNonce ? ` 'nonce-${styleNonce}'` : ""}; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`;
const SECURITY_HEADERS = {
  "content-security-policy": csp(),
  "x-content-type-options": "nosniff",
  "x-frame-options": "DENY",
  "referrer-policy": "no-referrer",
  "cache-control": "no-store",
};
const SECRET_HEADER = "x-homebot-setup";

/** An error the page may show: fixed code + safe English message. */
export class ApiError extends Error {
  status: number;
  code: string;
  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export interface SetupDeps {
  config: ConfigStore;
  state: StateStore;
  tokens: TokenStore;
  downloads: Downloads;
  secretsFile: string;
  credential: () => Promise<{ source: string } | null>;
  getBdk: () => Promise<BdkClient>;
  gatewayUrl: () => Promise<string>;
  probeWait?: boolean | undefined;
  lifecycle: BotLifecycle;
  signer?: Signer | undefined;
  reveal: (file: string) => Promise<unknown>;
  log?: Log | undefined;
  secret?: string | undefined;
  maxBodyBytes?: number | undefined;
  coldSyncTimeoutMs?: number | undefined;
}

/** A Shortcut built by this run. */
interface Build {
  file: string;
  name: string;
  baseUrl: string;
  signed: boolean;
}

export type SetupServer = http.Server & { setupSecret: string };

export function createSetupServer(deps: SetupDeps): SetupServer {
  const { config, state, tokens, downloads, log = () => {}, maxBodyBytes = 16 * 1024 } = deps;
  const secret = deps.secret ?? randomBytes(24).toString("base64url");
  /** Shortcuts built by this run, by token id. */
  const builds = new Map<string, Build>();

  const json = (res: http.ServerResponse, status: number, body: unknown): void => {
    res.writeHead(status, { ...SECURITY_HEADERS, "content-type": "application/json; charset=utf-8" });
    res.end(JSON.stringify(body));
  };

  function allowedHost(req: http.IncomingMessage): boolean {
    const addr = server.address();
    const port = typeof addr === "object" && addr ? addr.port : undefined;
    return req.headers.host === `127.0.0.1:${port}` || req.headers.host === `localhost:${port}`;
  }

  function hasSecret(req: http.IncomingMessage): boolean {
    const got = Buffer.from(String(req.headers[SECRET_HEADER] ?? ""));
    const want = Buffer.from(secret);
    return got.length === want.length && timingSafeEqual(got, want);
  }

  async function body(req: http.IncomingMessage): Promise<Record<string, unknown>> {
    if (!/^application\/json\b/.test(req.headers["content-type"] ?? "")) throw new ApiError(415, "bad-request", "JSON body required");
    const chunks: Buffer[] = [];
    let size = 0;
    // No encoding was set on the request, so its chunks are Buffers.
    for await (const c of req as AsyncIterable<Buffer>) {
      size += c.length;
      if (size > maxBodyBytes) throw new ApiError(413, "bad-request", "request too large");
      chunks.push(c);
    }
    let v: unknown;
    try {
      v = JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
    } catch {
      throw new ApiError(400, "bad-request", "invalid JSON");
    }
    if (!isRecord(v) || Array.isArray(v)) throw new ApiError(400, "bad-request", "JSON object required");
    return v;
  }

  const str = (v: unknown, field: string, { max = 200, optional = false }: { max?: number; optional?: boolean } = {}): string | undefined => {
    if (v === undefined || v === null || v === "") {
      if (optional) return undefined;
      throw new ApiError(400, "invalid", `${field} is required`);
    }
    if (typeof v !== "string" || v.length > max) throw new ApiError(400, "invalid", `${field} must be text (at most ${max} characters)`);
    return v.trim();
  };

  /** Result of the last real use of the key from this page (bot add): access is only claimed
   * after Grok Bot accepted it. Reset whenever the active key source changes. */
  let keyAccess: { source: string; result: "unchecked" | "ok" | "rejected" } = { source: "", result: "unchecked" };
  const noteAccess = async (result: "ok" | "rejected"): Promise<void> => {
    keyAccess = { source: (await deps.credential())?.source ?? "", result };
  };

  async function snapshot(): Promise<SetupState> {
    await tokens.load();
    await config.refresh();
    await state.refresh();
    const cred = await deps.credential();
    const s = config.settings;
    // The menu shows the language's Siri locale; an older English variant (en-GB...) maps to English.
    const siriLang = LANGUAGES[langOfSiri(s.siriLang ?? DEFAULT_SIRI_LANG)].siri;
    return {
      settings: { uiLang: s.uiLang ?? "en", siriLang, phoneLang: s.phoneLang ?? "en" },
      options: {
        uiLangs: LANG_OPTIONS,
        // Grouped under their language, in the same order as the other two menus.
        siriLangs: SIRI_OPTIONS,
        phoneLangs: LANG_OPTIONS,
      },
      // kind: env (overrides everything, change it outside Homebot), saved (this page),
      // detected (another Grok Bot login on this Mac; a key saved here overrides it).
      credential: cred
        ? { source: cred.source, kind: credentialKind(cred.source), access: keyAccess.source === cred.source ? keyAccess.result : "unchecked" }
        : null,
      bots: config.bots().map((b) => ({ key: b.key, name: b.name, sessionId: b.sessionId, strictEcho: b.strictEcho, synced: !!state.cursor(b.key) })),
      tokens: await Promise.all(
        tokens.list().map(async (t) => ({
          id: t.id, bot: t.bot, state: t.state, label: t.label, siriLang: t.siriLang ?? DEFAULT_SIRI_LANG, kind: t.kind ?? "ask",
          createdAt: t.createdAt, activatedAt: t.activatedAt ?? null, replaces: t.replaces ?? null,
          hasFile: t.state === "pending" && builds.has(t.id) && (await exists(builds.get(t.id)?.file)),
          // Installed Shortcuts keep the language they were built with (§7.3).
          languageDiffers: t.state !== "retired" && (t.kind ?? "ask") === "ask" && langOfSiri(t.siriLang ?? DEFAULT_SIRI_LANG) !== langOfSiri(siriLang),
        })),
      ),
      probe: { enabled: !!deps.probeWait },
      gatewayUrl: await deps.gatewayUrl(),
      // Read last, after every await, so a response never carries a consent older than its own
      // request's write.
      signing: { consent: config.settings.appleSigning === true },
    };
  }

  /** Strict reply checking may only be switched off with an explicit acknowledgement (§4.2). */
  function strictFrom(b: Record<string, unknown>): boolean {
    if (b.strictEcho !== false) return true;
    if (b.confirmNonStrict !== true) {
      throw new ApiError(400, "confirm-non-strict", "Without strict checking, a message the bot wrote for something else could be read aloud to the room. Confirm to continue.");
    }
    return false;
  }

  /** Cold-sync a session and install the bot through the lifecycle owner (B1/S1). */
  async function syncAndAdd(bot: Bot, bdk: BdkClient): Promise<void> {
    let r;
    try {
      r = await coldSync(bdk, bot.sessionId, deps.coldSyncTimeoutMs ? { timeoutMs: deps.coldSyncTimeoutMs } : undefined);
    } catch (e) {
      if (e instanceof BdkError && e.kind === "auth") await noteAccess("rejected");
      log({ event: "setup", action: "bot-add", outcome: e instanceof BdkError ? e.kind : "error" });
      throw bdkFailure(e);
    }
    await noteAccess("ok");
    try {
      await deps.lifecycle.add(bot, r); // re-checks the identity under the lock (S1)
    } catch (e) {
      log({ event: "setup", action: "bot-add", outcome: "conflict" });
      throw new ApiError(409, "invalid", messageOf(e));
    }
    log({ event: "setup", action: "bot-add", outcome: "ok" });
  }

  /** A bot key derived from the display name, unique among configured bots. */
  function deriveKey(name: string, sid: string): string {
    const slug = name.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 32).replace(/-+$/, "");
    for (const k of [slug, `bot-${sid}`.slice(0, 32)]) if (k && isValidBotKey(k) && !config.bot(k)) return k;
    return `bot-${sid}`.slice(0, 32);
  }

  /** Map a bot-add failure to a safe message. Non-BDK errors here are Homebot's own (time cap,
   * history too long); BdkError messages carry no key or body either. */
  function bdkFailure(e: unknown): ApiError {
    if (e instanceof ApiError) return e;
    if (!(e instanceof BdkError)) return new ApiError(502, "add-failed", e instanceof Error ? e.message : "failed");
    if (e.kind === "auth") return new ApiError(400, "auth", "Grok Bot rejected the API key.");
    if (e.kind === "request") return new ApiError(400, "not-found", "No Grok Bot with this session id can be read with this key.");
    return new ApiError(502, "upstream", "Grok Bot can't be reached right now. Try again later.");
  }

  async function api(method: string, path: string, req: http.IncomingMessage): Promise<unknown> {
    if (method === "GET" && path === "/api/state") return snapshot();
    if (method !== "POST") throw new ApiError(405, "bad-request", "method not allowed");
    const b = await body(req);
    let m: RegExpExecArray | null;

    if (path === "/api/settings") {
      const patch: Pick<Settings, "uiLang" | "siriLang" | "phoneLang" | "appleSigning"> = {};
      for (const [k, v] of Object.entries(b)) {
        if (k === "appleSigning" && typeof v === "boolean") {
          patch.appleSigning = v;
          continue;
        }
        const ok = typeof v === "string" && (k === "uiLang" || k === "phoneLang" ? isLang(v) : k === "siriLang" ? isSiriLang(v) : false);
        if (!ok || (k !== "uiLang" && k !== "siriLang" && k !== "phoneLang")) throw new ApiError(400, "invalid", `unsupported setting: ${k}`);
        patch[k] = v;
      }
      await config.putSettings(patch);
      log({ event: "setup", action: "settings", fields: Object.keys(patch) });
      return snapshot();
    }

    if (path === "/api/credential") {
      const key = str(b.key, "key", { max: 512 });
      if (!key || !/^[\x21-\x7e]{8,512}$/.test(key)) throw new ApiError(400, "invalid", "That doesn't look like an API key.");
      const secrets = await readJson(deps.secretsFile, {});
      await writeJson(deps.secretsFile, { ...(isRecord(secrets) ? secrets : {}), bdkApiKey: key });
      keyAccess = { source: "", result: "unchecked" }; // a new key is unchecked until Grok Bot accepts it
      log({ event: "setup", action: "credential-saved" });
      return snapshot();
    }
    if (path === "/api/credential/remove") {
      const secrets = await readJson(deps.secretsFile, {});
      const { bdkApiKey: _drop, ...rest } = isRecord(secrets) ? secrets : {};
      await writeJson(deps.secretsFile, rest);
      keyAccess = { source: "", result: "unchecked" };
      log({ event: "setup", action: "credential-removed" });
      return snapshot();
    }

    // Advanced route: numeric session id.
    if (path === "/api/bots") {
      const sessionId = str(b.sessionId, "session id", { max: 40 }) ?? "";
      const name = str(b.name, "name", { max: 60 }) ?? "";
      if (!/^\d+$/.test(sessionId)) throw new ApiError(400, "invalid", "The session id is a number.");
      await config.refresh();
      const key = b.key === undefined ? deriveKey(name, sessionId) : str(b.key, "key", { max: 32 }) ?? "";
      const bot: Bot = { key, name, sessionId, strictEcho: strictFrom(b) };
      try {
        config.checkBot(bot); // early answer before any network call; re-checked under the lock
      } catch (e) {
        throw new ApiError(409, "invalid", messageOf(e));
      }
      await syncAndAdd(bot, await deps.getBdk());
      return snapshot();
    }

    // Beginner route (DECISIONS item 13): the bot's exact name, typed twice. Get-or-create
    // makes a new empty bot on a typo; that case is detected and the bot is not added.
    if (path === "/api/bots/by-name") {
      const name = str(b.name, "name", { max: 60 }) ?? "";
      if (typeof b.confirmName !== "string" || b.confirmName.trim() !== name) {
        throw new ApiError(400, "confirm-name", `Type the exact name again to confirm. If no bot is named exactly "${name}", Grok Bot creates a new, empty one.`);
      }
      const strictEcho = strictFrom(b);
      const bdk = await deps.getBdk();
      let found: { sessionId: string; justCreated: boolean };
      try {
        found = await resolveBotByName(bdk, name);
      } catch (e) {
        if (e instanceof BdkError && e.kind === "auth") await noteAccess("rejected");
        throw bdkFailure(e);
      }
      await noteAccess("ok");
      if (found.justCreated) {
        log({ event: "setup", action: "bot-add-name", outcome: "created-new" });
        throw new ApiError(409, "created-new", `No bot was named exactly "${name}", so Grok Bot just created a new, empty one. Homebot did not add it. Check the exact name, and delete the empty bot in the Grok Bot app.`);
      }
      await config.refresh();
      const taken = config.bots().find((x) => x.sessionId === found.sessionId);
      if (taken) throw new ApiError(409, "invalid", `This bot is already added as "${taken.name}".`);
      await syncAndAdd({ key: deriveKey(name, found.sessionId), name, sessionId: found.sessionId, strictEcho }, bdk);
      return snapshot();
    }

    if ((m = /^\/api\/bots\/([^/]+)\/remove$/.exec(path))) {
      const key = decodeURIComponent(m[1] ?? "");
      // One locked step: retire its tokens (a later bot under this key must not inherit them),
      // drop its cursor and entry. Builds can't issue in between (BotLifecycle.issueFor).
      const retired = isValidBotKey(key) ? await deps.lifecycle.remove(key) : null;
      if (!retired) throw new ApiError(404, "not-found", "No such bot.");
      for (const id of retired) {
        downloads.dropToken(id);
        builds.delete(id);
      }
      log({ event: "setup", action: "bot-remove" });
      return snapshot();
    }

    if ((m = /^\/api\/tokens\/([0-9a-f]{12})\/revoke$/.exec(path))) {
      const id = m[1] ?? "";
      if (!(await tokens.revoke(id))) throw new ApiError(404, "not-found", "No such Shortcut token.");
      downloads.dropToken(id);
      builds.delete(id);
      log({ event: "setup", action: "token-revoke" });
      return snapshot();
    }

    if (path === "/api/shortcuts/preview" || path === "/api/shortcuts") {
      await config.refresh(); // the CLI may have changed bots meanwhile
      const bot = config.bot(str(b.bot, "bot", { max: 32 }) ?? "");
      if (!bot) throw new ApiError(404, "not-found", "No such bot.");
      const s = config.settings;
      const probe = b.probe === true;
      const replaces = str(b.replaces, "replaces", { max: 12, optional: true });
      const siriLang = str(b.siriLang, "Siri language", { optional: true }) ?? s.siriLang;
      let profile: ShortcutProfile;
      try {
        profile = shortcutProfile({
          botName: bot.name,
          siriLang,
          phoneLang: str(b.phoneLang, "iPhone language", { optional: true }) ?? s.phoneLang,
          name: str(b.name, "name", { max: 60, optional: true }),
          keep: keptPhrase(replaces ? tokens.list().find((t) => t.id === replaces) : undefined, siriLang),
          taken: takenPhrases(tokens.list(), replaces),
        });
      } catch (e) {
        throw new ApiError(400, "invalid", messageOf(e));
      }
      const baseUrl = str(b.url, "gateway URL", { optional: true }) ?? (await deps.gatewayUrl());
      let host: string;
      try {
        host = new URL(baseUrl).host;
      } catch {
        throw new ApiError(400, "invalid", "The gateway address must look like http://your-mac.local:8787");
      }
      if (path === "/api/shortcuts/preview") {
        const name = safeFileName(probe ? profile.probeName : profile.name);
        const preview: ShortcutPreview = {
          kind: probe ? "probe" : "ask", name, prompt: probe ? null : profile.prompt, siriLang: profile.siriLang, say: heySiri(profile.siriLang, name),
          alternatives: probe ? [] : profile.alternatives, problems: probe ? [] : profile.problems, steps: profile.steps(host, name),
        };
        return preview;
      }
      const sign = b.sign === true;
      // Checked before a token is issued: nothing goes to Apple unless the user agreed (§7.5).
      if (sign && (await config.refresh()).settings.appleSigning !== true) throw new ApiError(403, "signing-consent", "Turn on “Sign with Apple” first. It sends the Shortcut to Apple's signing service.");
      // A wait test only works while `homebot start --probe-wait` runs, and never replaces a
      // voice Shortcut (its first use would otherwise retire the working one, M4 review S2).
      if (probe && !deps.probeWait) throw new ApiError(409, "probe-disabled", "The wait test needs Homebot started with: homebot start --probe-wait");
      if (probe && replaces) throw new ApiError(400, "invalid", "A wait-test Shortcut never replaces a voice Shortcut.");
      let r: MadeShortcut;
      try {
        r = await makeShortcut({
          tokens, lifecycle: deps.lifecycle, bot, profile, baseUrl, probe, replaces,
          sign: sign ? { signer: deps.signer, onAttempt: ({ attempt, mode }) => log({ event: "setup", action: "sign-attempt", attempt, mode }) } : false,
        });
      } catch (e) {
        log({ event: "setup", action: "shortcut-build", outcome: "error" });
        throw new ApiError(400, "build-failed", messageOf(e));
      }
      builds.set(r.tokenId, { file: r.file, name: r.name, baseUrl, signed: r.signed });
      log({ event: "setup", action: "shortcut-build", outcome: "ok", signed: r.signed });
      const built: ShortcutBuild = { tokenId: r.tokenId, name: r.name, signed: r.signed, fileName: basename(r.file), steps: profile.steps(host, r.name), state: await snapshot() };
      return built;
    }

    if ((m = /^\/api\/shortcuts\/([0-9a-f]{12})\/(reveal|link)$/.exec(path))) {
      const tokenId = m[1] ?? "";
      const build = builds.get(tokenId);
      if (!build || !(await exists(build.file))) throw new ApiError(404, "gone", "This Shortcut file is gone (used, revoked or older than 24 h). Make a new one.");
      if (m[2] === "reveal") {
        await deps.reveal(build.file);
        return { ok: true };
      }
      const { id, expiresAt } = downloads.create({ file: build.file, name: build.name, tokenId });
      const url = `${new URL(build.baseUrl).origin}/dl/${id}`;
      log({ event: "setup", action: "link-created" }); // never the URL
      const link: DownloadLink = { url, expiresAt, qr: encodeQr(url).modules.map((row) => row.map((d) => (d ? "1" : "0")).join("")) };
      return link;
    }

    throw new ApiError(404, "not-found", "not found");
  }

  async function handle(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
    if (!allowedHost(req)) {
      res.writeHead(421, { ...SECURITY_HEADERS, "content-type": "text/plain; charset=utf-8" });
      res.end("Open the setup page at http://127.0.0.1 on this Mac.");
      return;
    }
    const method = req.method ?? "GET";
    const path = (req.url ?? "/").split("?")[0] ?? "/";
    const asset = Object.hasOwn(STATIC, path) ? STATIC[path] : undefined;
    if (method === "GET" && asset) {
      const [file, type] = asset;
      const headers: Record<string, string> = { ...SECURITY_HEADERS, "content-type": type };
      if (!type.startsWith("text/")) {
        res.writeHead(200, { ...headers, "cache-control": "max-age=86400" });
        res.end(await readFile(join(UI_DIR, file)));
        return;
      }
      let data = await readFile(join(UI_DIR, file), "utf8");
      if (file === "index.html") {
        // The animation library inserts a few <style> elements; a fresh nonce per page load
        // admits those and nothing else (no 'unsafe-inline').
        const nonce = randomBytes(16).toString("base64");
        data = data.replace("__HOMEBOT_SETUP_SECRET__", secret).replace("__HOMEBOT_STYLE_NONCE__", nonce);
        headers["content-security-policy"] = csp(nonce);
      }
      res.writeHead(200, headers);
      res.end(data);
      return;
    }
    if (!path.startsWith("/api/")) return json(res, 404, { error: { code: "not-found", message: "not found" } });
    if (!hasSecret(req)) return json(res, 403, { error: { code: "forbidden", message: "Reload the setup page." } });
    if (method !== "GET" && req.headers.origin !== `http://${req.headers.host}`) {
      return json(res, 403, { error: { code: "forbidden", message: "Cross-origin request refused." } });
    }
    try {
      json(res, 200, await api(method, path, req));
    } catch (e) {
      if (e instanceof ApiError) return json(res, e.status, { error: { code: e.code, message: e.message } });
      throw e;
    }
  }

  const server = http.createServer((req, res) => {
    handle(req, res).catch((e: unknown) => {
      log({ event: "setup-error", error: errorName(e) });
      if (!res.headersSent && !res.destroyed) json(res, 500, { error: { code: "internal", message: "Homebot ran into an error." } });
      else if (!res.destroyed) res.destroy();
    });
  });
  return Object.assign(server, { setupSecret: secret });
}

const exists = (f: string | undefined): Promise<boolean> => (f === undefined ? Promise.resolve(false) : access(f).then(() => true, () => false));
const credentialKind = (source: string) => (source.startsWith("env:") ? "env" : source === "homebot:secrets" ? "saved" : "detected");
const messageOf =(e: unknown): string => (e instanceof Error ? e.message : String(e));
