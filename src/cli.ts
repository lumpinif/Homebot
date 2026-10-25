// Command-line entry points. `run` is pure enough to test: all I/O targets are injected.
import { parseArgs, promisify } from "node:util";
import { execFile } from "node:child_process";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import type { BdkClient } from "./core/bdk.ts";
import type { Signer } from "./shortcut/sign.ts";
import type { SetupServer } from "./server/setup.ts";
import { keptPhrase, shortcutProfile, takenPhrases } from "./shortcut/profile.ts";
import { makeShortcut, localHostName } from "./shortcut/make.ts";
import { resolveHome, prepareHome } from "./core/home.ts";
import { resolveCredential } from "./core/credentials.ts";
import { createBdkClient, DEFAULT_BASE_URL, BdkError } from "./core/bdk.ts";
import { ConfigStore, StateStore } from "./core/store.ts";
import { DEFAULT_SIRI_LANG, SIRI_OPTIONS, isSiriLang } from "./core/lang.ts";
import { TokenStore } from "./core/tokens.ts";
import { createLogger } from "./core/log.ts";
import { AskService, isBusy } from "./core/ask.ts";
import { coldSync, resolveBotByName } from "./core/bots.ts";
import { BotLifecycle } from "./core/lifecycle.ts";
import { syncToEnd } from "./core/entries.ts";
import { errnoCode, isRecord as isRecordValue, writePrivateFile } from "./core/fsutil.ts";
import { createVoiceServer } from "./server/voice.ts";
import { LabService, SCENARIOS, isScenario, readLabState, writeLabState } from "./core/lab.ts";
import { ConversationService } from "./core/conversation.ts";
import { readFile } from "node:fs/promises";
import { existsSync, writeFileSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { createSetupServer, ApiError } from "./server/setup.ts";
import { Downloads } from "./server/downloads.ts";

const USAGE = `Usage: homebot <command>

  start                         Start the voice gateway and the setup page (http://127.0.0.1:8788/)
  doctor                        Check setup (read-only calls to Grok Bot)
  bot add-name "<exact name>" --key <key> --confirm "<exact name>" [--no-strict]
                                Add a bot by its exact name (a typo creates an empty bot,
                                which is detected and not added)
  bot add-id <sessionId> --key <key> --name <name> [--no-strict] [--preview]
                                Add a bot by numeric session id (advanced; read-only check)
  bot list | bot remove <key>   List bots / remove one (retires its Shortcut tokens)
  token issue <botKey> [--siri-lang en-US|es-ES|fr-FR|de-DE|it-IT|pt-BR|ru-RU|ja-JP|ko-KR|zh-CN|zh-TW] [--label <text>] [--replaces <tokenId>] [--curl-header]
                                Issue a client token; writes it to a 0600 file
                                (--curl-header: as "X-Homebot-Token: ..." for curl -H @file)
  token list | token revoke <tokenId>
  shortcut build <botKey> [--siri-lang en-US|es-ES|fr-FR|de-DE|it-IT|pt-BR|ru-RU|ja-JP|ko-KR|zh-CN|zh-TW] [--phone-lang en|es|fr|de|it|ja|ko|zh-Hans|zh-Hant|pt-BR|ru] [--name <Siri phrase>]
                 [--url http://host.local:8787] [--replaces <tokenId>] [--probe | --lab | --conversation]
                 [--sign] [--reveal]
                                Build a Shortcut file (token inside; private, short-lived).
                                --conversation: Siri keeps listening after each answer
                                (experimental, DESIGN §18)
  start --probe-wait            Also serve the Siri wait-limit probe (device session only)
  start --lab                   Also serve the lab Shortcut's experiments (device session only;
                                never contacts a bot)
  lab use <E1, E1b, E2..E7> [--delays 8,12,16]
                                Choose the experiment the lab Shortcut runs next
  lab report [--all]            Print the lab results since the last "lab use" (no speech text
                                is ever stored)

Environment: HOMEBOT_HOME (default ~/.homebot), CURSOR_API_KEY, CURSOR_API_KEY_FILE,
  HOMEBOT_DETECT_CREDENTIALS=0 (ignore an existing BDK login)
--sign sends the Shortcut to Apple's signing service (iOS imports only signed Shortcuts); using it
  records that consent, as the "Sign with Apple" switch on the setup page does.`;

/** I/O targets for `run`; tests inject all of them. */
export interface RunIO {
  env?: NodeJS.ProcessEnv;
  out?: (s: string) => void;
  err?: (s: string) => void;
  userHome?: string | undefined;
  onListening?: ((server: Server) => void) | undefined;
  onSetupListening?: ((server: SetupServer) => void) | undefined;
  hostName?: () => Promise<string>;
  signer?: Signer | undefined;
  reveal?: (file: string) => Promise<unknown>;
  probeUnitMs?: number | undefined;
  /** Scale for lab delays (tests). */
  labUnit?: number;
  cleanupMs?: number;
}

/** Returns the exit code. */
export async function run(argv: string[], { env = process.env, out = console.log, err = console.error, userHome, onListening, onSetupListening, hostName = localHostName, signer, reveal = revealInFinder, probeUnitMs, labUnit = 1, cleanupMs = 10 * 60_000 }: RunIO = {}): Promise<number> {
  const [cmd, sub, ...rest] = argv;
  try {
    const home = resolveHome({ env });
    // The Homebot app imported this folder (DESIGN §20.11 B8): one store, never two writers.
    if (existsSync(join(home.root, "MOVED"))) {
      throw new UserError(`${home.root} was moved to the Homebot app. Use the app, or its homebot command, from now on; this version no longer runs on it.`);
    }
    await prepareHome(home);
    const config = await new ConfigStore(home.paths.config).load();
    const state = await new StateStore(home.paths.state).load();
    const tokens = await new TokenStore(home.paths.tokens, { artifactsDir: home.paths.shortcuts }).load();
    await tokens.cleanupArtifacts(); // every run enforces the 24 h artifact lifetime
    const lifecycle = new BotLifecycle({ config, state, tokens });
    const baseUrl = env.HOMEBOT_BDK_BASE_URL || DEFAULT_BASE_URL; // override for tests only
    const credential = () => resolveCredential({ env, secretsFile: home.paths.secrets, userHome });
    const client = async () => {
      const c = await credential();
      if (!c) throw new UserError("No Grok Bot credentials found. Set CURSOR_API_KEY or CURSOR_API_KEY_FILE (see README).");
      return { bdk: createBdkClient({ key: c.key, baseUrl }), source: c.source };
    };

    if (cmd === "start") {
      const cred = await credential(); // also fails early on a malformed secrets.json
      const { log } = createLogger(home.paths.logs);
      await tokens.expirePending(); // also sweeps stale token artifacts
      // The key is resolved per call, so a key added on the setup page works without a restart.
      const currentBdk = async () => {
        const c = await credential();
        if (!c) throw new BdkError("no Grok Bot credentials configured", { kind: "auth" });
        return createBdkClient({ key: c.key, baseUrl });
      };
      const bdk: BdkClient = {
        getOrCreateSession: async (...a) => (await currentBdk()).getOrCreateSession(...a),
        getEntries: async (...a) => (await currentBdk()).getEntries(...a),
        sendMessage: async (...a) => (await currentBdk()).sendMessage(...a),
      };
      const ask = new AskService({ config, state, bdk, log, traceIdle: { maxMs: 30_000, everyMs: 1000 } });
      const probeWait = rest.includes("--probe-wait") || sub === "--probe-wait";
      const labOn = rest.includes("--lab") || sub === "--lab";
      const lab = labOn ? new LabService({ file: home.paths.lab, log, delayUnit: labUnit }) : undefined;
      const downloads = new Downloads();
      // Conversation runs (DESIGN §18); the follow-up wait is read from config.json per step.
      const conversation = new ConversationService({ ask, log, followupIdleMs: () => config.settings.followupIdleMs });
      const server = createVoiceServer({ ask, tokens, config, log, probeWait, probeUnitMs, downloads, lab, conversation });
      // Tell the Homebot app's importer a gateway runs here, then look for its marker again: either
      // the importer sees this file or this check sees MOVED, so the two never run at once.
      const running = join(home.root, "gateway.pid");
      writeFileSync(running, `${process.pid}\n`, { mode: 0o600 });
      if (existsSync(join(home.root, "MOVED"))) {
        unlinkSync(running);
        throw new UserError(`${home.root} was moved to the Homebot app. Use the app, or its homebot command, from now on; this version no longer runs on it.`);
      }
      server.once("close", () => {
        try {
          unlinkSync(running);
        } catch {
          // already gone
        }
      });
      const port = config.settings.port;
      const bind = env.HOMEBOT_BIND || config.settings.bind;
      await new Promise((resolve, reject) => server.once("error", reject).listen(Number(env.HOMEBOT_PORT || port), bind, () => resolve(undefined))).catch((e: unknown) => {
        unlinkSync(running);
        throw e;
      });
      const addr = listeningAddress(server);

      const setup = createSetupServer({
        config, state, tokens, downloads, log, signer, reveal, lifecycle, probeWait,
        secretsFile: home.paths.secrets,
        credential: async () => {
          const c = await credential();
          return c && { source: c.source };
        },
        getBdk: async () => {
          if (!(await credential())) throw new ApiError(400, "no-credentials", "Add your Grok Bot API key first (step 1).");
          return currentBdk();
        },
        gatewayUrl: async () => `http://${await hostName()}.local:${addr.port}`,
      });
      try {
        // Loopback only, by construction: the setup page is never reachable from the LAN.
        await new Promise((resolve, reject) => setup.once("error", reject).listen(Number(env.HOMEBOT_SETUP_PORT ?? config.settings.setupPort), "127.0.0.1", () => resolve(undefined)));
      } catch (e) {
        server.close();
        throw new UserError(`The setup page port is busy (${errnoCode(e)}). Is Homebot already running?`);
      }
      server.once("close", () => {
        ask.stop();
        setup.closeAllConnections();
        setup.close();
      });
      const setupPort = listeningAddress(setup).port;

      log({ event: "listening", port: addr.port, setupPort, credential: cred?.source ?? null, bots: config.bots().length });
      out(`Homebot voice gateway listening on ${bind}:${addr.port} (credentials: ${cred?.source ?? "none yet"}, bots: ${config.bots().map((b) => b.key).join(", ") || "none"})`);
      out(`Setup page: http://127.0.0.1:${setupPort}/ (open it in a browser on this Mac)`);
      if (!cred) out("No Grok Bot credentials yet: add your API key on the setup page.");
      out("Only use it on a trusted home network. Never port-forward this port.");
      if (probeWait) out("Wait-limit probe enabled at /v1/probe-wait (restart without --probe-wait when done).");
      if (lab) out(`Lab enabled at /v1/lab, experiment ${(await readLabState(home.paths.lab)).scenario} (homebot lab use <E1, E1b, E2..E7> to change; restart without --lab when done).`);
      // While the gateway runs, expired artifacts are removed within cleanupMs of their 24 h.
      const sweep = setInterval(() => {
        tokens.cleanupArtifacts().then(
          (removed) => {
            if (removed.length) void log({ event: "artifacts-removed", count: removed.length });
          },
          (e) => log({ event: "artifacts-cleanup-error", error: describe(e) }),
        );
      }, cleanupMs);
      sweep.unref();
      server.once("close", () => clearInterval(sweep));
      onSetupListening?.(setup);
      onListening?.(server);
      return 0;
    }

    if (cmd === "doctor") {
      out(`HOMEBOT_HOME: ${home.root}`);
      const c = await credential();
      out(`Credentials: ${c ? c.source : "MISSING"}`);
      let ok = !!c;
      const bots = config.bots();
      if (!bots.length) out("Bots: none configured (use `homebot bot add-id`)");
      for (const b of bots) {
        const cur = state.cursor(b.key);
        if (!cur) {
          out(`Bot ${b.key}: no cursor; run \`homebot bot add-id ${b.sessionId} --key ${b.key} --name ...\` again`);
          ok = false;
          continue;
        }
        if (!c) continue;
        try {
          const bdk = createBdkClient({ key: c.key, baseUrl });
          const r = await syncToEnd((x) => bdk.getEntries(b.sessionId, x), { cursor: cur.cursor, maxSeq: cur.maxSeq, maxPages: 50 });
          await state.setCursor(b.key, r, { sessionId: b.sessionId });
          out(`Bot ${b.key} (${b.name}): readable, ${isBusy(r.turn) ? "busy" : "idle"}, ${r.entries.length} new entries since last sync`);
        } catch (e) {
          out(`Bot ${b.key}: ${describe(e)}`);
          ok = false;
        }
      }
      const active = tokens.list().filter((t) => t.state !== "retired");
      out(`Tokens: ${active.length} usable`);
      return ok ? 0 : 1;
    }

    if (cmd === "bot" && sub === "add-id") {
      const { values, positionals } = parseArgs({
        args: rest,
        allowPositionals: true,
        options: { key: { type: "string" }, name: { type: "string" }, "no-strict": { type: "boolean" }, preview: { type: "boolean" } },
      });
      const sessionId = positionals[0];
      if (!sessionId || !values.key || !values.name) throw new UserError("Usage: homebot bot add-id <sessionId> --key <key> --name <name>");
      const bot = { key: values.key, name: values.name, sessionId, strictEcho: !values["no-strict"] };
      config.checkBot(bot); // format and identity conflicts, before any network call
      const { bdk } = await client();
      const r = await coldSync(bdk, sessionId);
      await lifecycle.add(bot, r); // re-checks identity under the lock, then cursor + bot together
      out(`Added ${bot.key} -> session ${sessionId}: readable, ${r.entryCount} entries in ${r.pages} page(s), ${isBusy(r.turn) ? "busy" : "idle"}.`);
      if (values.preview) out(`Latest bot message (true latest, via full sync): ${r.latestBotText ?? "(none)"}`);
      return 0;
    }

    if (cmd === "bot" && sub === "add-name") {
      const { values, positionals } = parseArgs({
        args: rest,
        allowPositionals: true,
        options: { key: { type: "string" }, confirm: { type: "string" }, "no-strict": { type: "boolean" } },
      });
      const name = positionals[0] ?? "";
      if (!name || !values.key) throw new UserError('Usage: homebot bot add-name "<exact bot name>" --key <key> --confirm "<exact bot name>"');
      // Get-or-create: a typo creates a new empty bot in the account, so the exact name must be
      // typed twice (DECISIONS item 13).
      if (values.confirm !== name) {
        throw new UserError(`Grok Bot creates a new empty bot if no bot is named exactly "${name}". Check the spelling, then repeat it with --confirm "${name}".`);
      }
      config.checkBot({ key: values.key, name, sessionId: "0", strictEcho: true }); // key format/conflicts before any call
      const { bdk } = await client();
      const found = await resolveBotByName(bdk, name);
      if (found.justCreated) {
        throw new UserError(`No bot was named exactly "${name}", so Grok Bot just created an empty one (session ${found.sessionId}). It was not added. Check the exact name, and delete the empty bot in the Grok Bot app.`);
      }
      const bot = { key: values.key, name, sessionId: found.sessionId, strictEcho: !values["no-strict"] };
      config.checkBot(bot);
      const r = await coldSync(bdk, found.sessionId);
      await lifecycle.add(bot, r);
      out(`Added ${bot.key} -> "${name}" (session ${found.sessionId}): readable, ${r.entryCount} entries, ${isBusy(r.turn) ? "busy" : "idle"}.`);
      return 0;
    }

    if (cmd === "bot" && sub === "remove") {
      const retired = await lifecycle.remove(rest[0] ?? "");
      if (!retired) throw new UserError(`Unknown bot: ${rest[0] ?? "(missing)"}`);
      out(`Removed ${rest[0]}; ${retired.length} Shortcut token(s) retired.`);
      return 0;
    }

    if (cmd === "bot" && sub === "list") {
      for (const b of config.bots()) out(`${b.key}\t${b.name}\t${b.sessionId}\tstrict=${b.strictEcho}\tsynced=${state.cursor(b.key) ? "yes" : "no"}`);
      return 0;
    }

    if (cmd === "token" && sub === "issue") {
      const { values, positionals } = parseArgs({
        args: rest,
        allowPositionals: true,
        options: {
          label: { type: "string" },
          replaces: { type: "string" },
          "siri-lang": { type: "string", default: DEFAULT_SIRI_LANG },
          "curl-header": { type: "boolean" },
        },
      });
      const bot = config.bot(positionals[0] ?? "");
      if (!bot) throw new UserError(`Unknown bot: ${positionals[0] ?? "(missing)"}`);
      const siriLang = values["siri-lang"];
      if (!isSiriLang(siriLang)) throw new UserError(`--siri-lang must be one of: ${SIRI_OPTIONS.map((o) => o.code).join(", ")}`);
      const { id, token } = await lifecycle.issueFor(bot, (b) =>
        tokens.issue({ bot: b.key, label: values.label ?? b.name, replaces: values.replaces, siriLang, sessionId: b.sessionId }),
      );
      // --curl-header: a ready header line for `curl -H @file`, so the token never appears on a
      // command line, in shell history or in `ps`.
      const file = tokens.artifactPath(id, values["curl-header"] ? "header" : "token");
      await writePrivateFile(file, values["curl-header"] ? `X-Homebot-Token: ${token}\n` : token + "\n");
      out(`Issued pending token ${id} for ${bot.key}. Secret written to ${file} (mode 0600). ` +
        "It becomes active on first use; the file is deleted then, on revoke/expiry, or once it is 24 h old " +
        "(by the running gateway, or by the next homebot command if none is running).");
      return 0;
    }
    if (cmd === "token" && sub === "list") {
      for (const t of tokens.list()) out(`${t.id}\t${t.bot}\t${t.state}\t${t.label}\t${t.siriLang ?? DEFAULT_SIRI_LANG}\t${new Date(t.createdAt).toISOString()}`);
      return 0;
    }
    if (cmd === "token" && sub === "revoke") {
      if (!(await tokens.revoke(rest[0] ?? ""))) throw new UserError(`Unknown token id: ${rest[0] ?? "(missing)"}`);
      out(`Revoked ${rest[0]}.`);
      return 0;
    }

    if (cmd === "shortcut" && sub === "build") {
      const { values, positionals } = parseArgs({
        args: rest,
        allowPositionals: true,
        options: {
          "siri-lang": { type: "string" },
          "phone-lang": { type: "string" },
          name: { type: "string" },
          url: { type: "string" },
          replaces: { type: "string" },
          probe: { type: "boolean" },
          lab: { type: "boolean" },
          conversation: { type: "boolean" },
          sign: { type: "boolean" },
          reveal: { type: "boolean" },
        },
      });
      const test = values.probe || values.lab;
      if ([values.probe, values.lab, values.conversation].filter(Boolean).length > 1) throw new UserError("Use only one of --probe, --lab and --conversation.");
      const bot = config.bot(positionals[0] ?? "");
      if (!bot) throw new UserError(`Unknown bot: ${positionals[0] ?? "(missing)"}`);
      const s = config.settings;
      const siriLang = values["siri-lang"] ?? s.siriLang;
      const profile = shortcutProfile({
        botName: bot.name,
        siriLang,
        phoneLang: values["phone-lang"] ?? s.phoneLang,
        name: values.name,
        keep: keptPhrase(values.replaces ? tokens.list().find((t) => t.id === values.replaces) : undefined, siriLang),
        taken: takenPhrases(tokens.list(), values.replaces),
      });
      const blocking = test ? [] : profile.problems.filter((p) => p.blocking);
      if (blocking.length) {
        const others = profile.alternatives.length ? ` Phrases you can use: ${profile.alternatives.map((a) => `"${a}"`).join(", ")}.` : "";
        throw new UserError(`${blocking.map((p) => p.message).join(" ")}${others}`);
      }
      if (!test) for (const p of profile.problems) out(`Note: ${p.message}`);
      const baseUrl = values.url ?? `http://${await hostName()}.local:${s.port}`;
      const host = new URL(baseUrl).host;
      // --sign is the user's consent to Apple's signing service, the same one the setup page
      // asks for. Recorded only once the build passed its checks, so a refused command leaves
      // no consent behind; the page then shows signing on (DESIGN §7.5).
      if (values.sign && config.settings.appleSigning !== true) await config.putSettings({ appleSigning: true });
      const r = await makeShortcut({
        tokens,
        lifecycle,
        bot,
        profile,
        baseUrl,
        probe: values.probe,
        lab: values.lab,
        conversation: values.conversation,
        replaces: values.replaces,
        sign: values.sign ? { signer, onAttempt: ({ attempt, mode }) => out(`Signing (attempt ${attempt}, mode ${mode})…`) } : false,
      });
      out(`Built "${r.name}" for bot ${bot.key} (Siri ${profile.siriLang}, gateway ${baseUrl}).`);
      if (!test && r.name !== profile.name) out(`Note: the name was changed from "${profile.name}" to "${r.name}" because iOS uses the file name, which can't contain / \\ : or start with a dot.`);
      out(`File: ${r.file} (${r.signed ? "signed" : "UNSIGNED: iOS will not import it until it is signed"}; private; deleted on first use, or once 24 h old by the running gateway or the next homebot command).`);
      out(`Token ${r.tokenId} is pending; it becomes active on the Shortcut's first use${values.replaces ? ` and then retires ${values.replaces}` : ""}.`);
      if (r.signed && values.reveal) await reveal(r.file);
      out("");
      profile.steps(host, r.name).forEach((step, i) => out(`${i + 1}. ${step}`));
      return 0;
    }

    if (cmd === "lab" && sub === "use") {
      const { values, positionals } = parseArgs({ args: rest, allowPositionals: true, options: { delays: { type: "string" } } });
      const id = positionals[0];
      if (!isScenario(id)) throw new UserError(`Choose one of: ${SCENARIOS.join(", ")}`);
      const delays = values.delays?.split(",").map((d) => Number(d.trim()));
      if (delays && !delays.every((d) => Number.isInteger(d) && d > 0 && d <= 120)) throw new UserError("--delays takes whole seconds from 1 to 120, e.g. 8,12,16");
      await writeLabState(home.paths.lab, { scenario: id, delays });
      out(`The lab Shortcut now runs ${id}${id === "E7" ? ` (delays ${(delays ?? (await readLabState(home.paths.lab)).delays).join(", ")} s, one per run)` : ""}. A running gateway picks this up on the next run.`);
      return 0;
    }

    if (cmd === "lab" && sub === "report") {
      const all = rest.includes("--all");
      const since = all ? 0 : (await readLabState(home.paths.lab)).version;
      const lines = (await readFile(createLogger(home.paths.logs).file, "utf8").catch(() => "")).split("\n");
      const cols = ["time", "scenario", "run", "step", "mode", "recv_len", "match", "gap_ms", "delay_ms", "client_gave_up_ms"];
      out(cols.join("\t"));
      let n = 0;
      for (const line of lines) {
        let e: unknown;
        try {
          e = JSON.parse(line);
        } catch {
          continue;
        }
        if (!isRecordValue(e) || e.event !== "lab" || typeof e.ts !== "string" || Date.parse(e.ts) < since) continue;
        n++;
        out(cols.map((c) => (c === "time" ? String(e.ts).slice(11, 19) : e[c] === undefined ? (c === "step" ? "" : "-") : String(e[c]))).join("\t"));
      }
      if (!n) out(all ? "No lab results yet." : "No lab results since the last \"homebot lab use\" (try --all).");
      return 0;
    }

    out(USAGE);
    return cmd ? 2 : 0;
  } catch (e) {
    err(`homebot: ${describe(e)}`);
    return 1;
  }
}

class UserError extends Error {}

/** Select the file in Finder (for AirDrop). Argument array, no shell. */
function revealInFinder(file: string): Promise<unknown> {
  return promisify(execFile)("open", ["-R", file]);
}

/** The TCP address of a server that is listening (never a pipe here). */
function listeningAddress(server: Server): AddressInfo {
  const a = server.address();
  if (!a || typeof a === "string") throw new Error("server is not listening on TCP");
  return a;
}

/** Error text for humans; BDK errors never carry keys or bodies. */
function describe(e: unknown): string {
  if (e instanceof BdkError) return e.kind === "auth" ? `Grok Bot rejected the credentials (${e.status})` : e.message;
  return e instanceof Error ? e.message : String(e);
}
