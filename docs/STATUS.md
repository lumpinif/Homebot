# Status log

## 2026-10-21 — Claude: design draft v1

**Done**
- Read BRIEF.md, PROCESS.md and the spike reference code (`gateway.mjs`, `build_v3.py`, `resolve_session.mjs`, timing logs). Secrets were not opened.
- Researched bot listing. The public BDK and Grok Bot docs don't document the `grokbot/sessions` API or any "list my bots" call. On the Cursor forum (Oct 12, 2026), a Cursor representative said there is "no official public API or SDK for Grok Bot" for this. The only lead is an unofficial Rust crate that calls a private gateway. **Listing is unverified**, so the design uses a strategy interface with safe fallbacks (paste session id, read-only validation; guarded add-by-name). See DESIGN §6.
- Wrote **docs/DESIGN.md**: Node ≥ 22 with zero dependencies; one process with a LAN voice listener on :8787 and a loopback-only setup page on :8788; sync-only replies for v1; one Shortcut per bot with its own revocable token; signing via `shortcuts sign` with retry; delivery through a one-time QR download link; state stored in `~/.homebot`. It also covers failure modes, the security model, the test plan and milestones M0–M5.

**Blocked in this session (tool permission denied, not worked around)**
- Listing the bundled grok-bot tool folder (to inspect its "list" tool code) and downloading the `@cursor/bdk` npm tarball to grep for a list endpoint. Both are planned as M0-a.

**Next**
- Codex reviews DESIGN.md → `docs/reviews/design-review-1.md`. Then Claude revises it and starts M0/M1.

**Needs Felix** (details in DESIGN §14)
- Q1: OK to make one read-only GET probe for listing with your key, and to read the bundled grok-bot tool code (not `auth/`)?
- Q2: Which key types work on `grokbot/sessions` (bundled login key vs Cursor dashboard API key)?
- Q3: Can a user see a bot's numeric session id in the Grok Bot app?
- Q4: Reuse the Siri phrase "问拆解师" (already recognized by the HomePod)?
- Q5: Will you run the Siri wait-limit probe on the HomePod later (plays sound; will be announced)?
- Q6–Q9: reply linking field, Mac-always-on for v1, vendored QR file, license/name.

## 2026-10-21 — Codex: design review 1

- **Done:** Reviewed DESIGN.md against BRIEF.md, PROCESS.md, and safe spike source/timing evidence. Wrote [design review 1](reviews/design-review-1.md). Verdict: revise before implementation approval.
- **Blockers:** Cross-channel reply isolation, a proven new-user connection and complete bot-list route, and milestones that delay the first HomePod flow until after the full setup UI.
- **Next:** Claude revises the design. Prioritize one safe bot-to-Siri flow, then complete beginner setup. The review also covers timeout behavior, token replacement/scope, secret handling, and misleading status messages.
- **Needs Felix:** Any later account probe, login, Shortcut import, or HomePod sound test remains pending under PROCESS.md. No such action ran during this review. No messages were sent, no secrets were opened, and no code or DESIGN.md changes were made.

## 2026-10-21 — Claude: design v2 (addresses review 1)

**Done**
- Revised DESIGN.md to v2. All 3 blockers, 7 should-fixes and 2 nits were accepted. Per-item notes are in DESIGN §15.
  - B1: strict reply-ownership rule (§4.2). Homebot only accepts a reply if no foreign input or output appeared since the baseline and the bot echoed `[hb:<id>]`; otherwise it refuses to speak.
  - B2: account route (R1) and bot listing (R2) are now explicit release gates with concrete M0 outcomes. Add-by-name was removed; manual session id is a development aid only.
  - B3: milestones reordered so the HomePod device session (M3) comes right after the core gateway and Shortcut build, before the setup page.
- Next: implement M1 (core gateway) offline.

**Needs Felix** (DESIGN §14 — replaces the list above)
- Q-B1: strict reply ownership for any bot (my recommendation) vs a dedicated voice bot for v1.
- Q-B2: if listing proves impossible, narrow requirement 4 to "pick from bots you've added"?
- Q-B3: if only bundled credentials work, ship for those users first?
- Q1: permission for M0-a (read the bundled grok-bot tool code, not `auth/`, and the `@cursor/bdk` package source) and M0-b (≤2 read-only GET probes with your key).
- Q3: is a bot's numeric session id visible anywhere in the Grok Bot app?
- Q4: reuse "问拆解师" as the first Siri phrase?
- Q5: when can you do the M3 device session (iPhone + HomePod, sound announced first, incl. wait-limit probe)?
- Q6: any known BDK field linking a reply to a message?
- Q7: OK for v1 to require the Mac awake with Homebot started manually?
- Q9: license (MIT suggested) and final name.

## 2026-10-21 — Claude: M1 core gateway (offline) — ready for Codex milestone review

**Done** (6 commits, 65 offline tests, `node --test` green; no network beyond loopback)
- `src/core/home.js`, `fsutil.js`: `~/.homebot` 0700, files 0600 from creation via same-dir temp + rename, startup temp sweep, refusal of a `HOMEBOT_HOME` inside a git work tree.
- `entries.js`: `syncToEnd` (pages past the 200-entry page, cursor advances only on non-empty pages, page cap) and `decideReply`, the strict ownership rule O1–O5 from DESIGN §4.2.
- `envelope.js`, `speech.js`, `i18n.js`: `[Homebot voice · hb:<id> · lang]` envelope with echo instruction; speech sanitizer/truncation; zh/en spoken messages.
- `tokens.js`: SHA-256-only storage, bound to one bot, pending → active → old retired, 7-day pending expiry, revoke.
- `credentials.js`: env → `CURSOR_API_KEY_FILE` → service account → `secrets.json` → detected agent-serve; detection off with `HOMEBOT_DETECT_CREDENTIALS=0`. Only the source name is ever shown.
- `bdk.js`, `ask.js`: BDK client (errors carry no key/body); AskService with one hard deadline, abort on client disconnect, immediate in-flight rejection, busy check, send retry with the same `messageId`, poll until accept/refuse/deadline, no interrupt.
- `server/voice.js`, `cli.js`: `/v1/health`, `/v1/ask` (16 KB cap, 401/403, per-token rate limit, plain-text 200); CLI `start`, `doctor`, `bot add-id [--preview]`, `bot list`, `token issue|list|revoke`.
- Tests use an in-process fake of the sessions API (`test/fake-bdk.js`). They cover: a desktop message between the idle check and our send, a desktop message after ours, a missing echo tag, a >200-entry backlog, timeout before/after send, disconnect, an uncertain send, cross-bot tokens, and secret-free output/logs.

**Known limits / for review**
- The fake encodes our assumptions about the real API. Unverified: `latestUpdatedSeq` on an empty page; whether the real session emits other `role:user` entries (e.g. tool results), which would make O2 refuse every reply; and whether the bot actually echoes `[hb:<id>]`. All three are checked in the M3 device session.
- The rate limit counts a request before it is known to be busy/in-flight.

**Next**
- Codex: milestone review of M1 → `docs/reviews/milestone-M1-review.md`.
- Then M2 (offline): XML plist writer, Shortcut builder, signer wrapper tested with a fake `shortcuts` binary, wait-probe endpoint/Shortcut.

**Needs Felix** (nothing live was run; all wait for your OK)
- L1: `homebot doctor` + `homebot bot add-id 14752726 --key chai --name 拆解师` against the real API (read-only GETs with your existing credentials).
- L2: ≤3 `[Homebot test]` questions to 拆解师 via `curl` to `/v1/ask` (these do message the bot; they measure timing and echo compliance).
- M0-a / M0-b permissions (Q1), and the open product questions Q-B1–Q-B3 above.

## 2026-10-21 13:05 — 拆解师: Felix's decisions recorded
- See **docs/DECISIONS.md**. Summary: Q1 yes (read the bundled grok-bot tool code excl. auth/ + @cursor/bdk source; ≤2 read-only GET probes); Q-B1 strict attribution + echo approved; Q-B2 fallback to added bots OK; new Shortcut (not 问拆解师), **English default**, setup asks iPhone system language + Siri language; Mac on + manual start OK; MIT + "Homebot"; GitHub private personal repo created/pushed by 拆解师 only; device sound tests still ask first.

## 2026-10-21 — Codex: M1 review

- **Done:** Reviewed `7341c28..7ea6600` against DESIGN v2, BRIEF, DECISIONS, and design-review-1. Wrote [M1 review](reviews/milestone-m1-review.md). Verdict: changes required before M1 approval.
- **Blockers:** Running gateways accept CLI-revoked tokens. Interrupted uploads escape the request error boundary. Invalid credential JSON can expose text in errors. Textless entry updates can erase evidence that requires reply refusal.
- **Validation:** `node --test`: 43 passed, 22 failed at loopback `listen` with sandbox `EPERM`. Full integration success is unverified here. Socket-free probes with synthetic data confirmed the reported failure paths. No real secrets were opened, no bot/service calls or login ran, and code/DESIGN.md remain unchanged.
- **Next:** Claude addresses the review and reruns the offline suite with loopback available. For users, revocation must actually stop a copied Shortcut, and ambiguous replies must remain silent. No new owner decision is required for these corrections.

## 2026-10-21 — Claude: M1 fixes, M0 done, M2 offline done (DESIGN v3) — ready for Codex review

**Done** (commits `b5403f1..HEAD`; `node --test`: 109 passed, 0 failed, loopback available)
- **M1 review:** all 4 blockers and 6 should-fixes accepted and fixed with tests; nit N1 done. Per-item notes in DESIGN §15 v3.
  - B1: `tokens.json` is the single authority (locked read-modify-write, verify re-reads on change). A CLI revoke now stops a running gateway's Shortcut immediately.
  - B2: no crash on interrupted uploads; disconnect during token activation is caught.
  - B3: JSON errors never contain file content.
  - B4: ownership evidence is judged over all versions of an entry; any foreign `send-message` before ours refuses.
  - S1–S6: single UTF-8 decode; persistence off the response path + cold-sync time cap; key↔session identity enforced; English default and language bound to the token; token artifacts deleted on use/revoke/expiry/24 h/startup; baseline GET retries.
- **Felix's decisions applied:** English default; Siri language + iPhone language model (`src/core/lang.js`, `src/shortcut/profile.js`); new Shortcut names "Ask <bot>" / "问问<bot>"; MIT `LICENSE`.
- **M0 (read-only inspection + exactly 2 probes):**
  - Read: the bundled grok-bot tool folder (not `auth/`), including the bundled `@cursor/bdk` grokbot-agents extension and docs. No `bdk login`, no messages.
  - Findings: 4 session routes only (get-or-create by name, messages, entries, interrupt); **no account-wide bot list**; personal Cursor user API key; no reply↔message link field. DESIGN §5.1, §5.2, §6.1.
  - **Probes run** (script `scripts/m0-probe.mjs`; credential via Homebot's own `resolveCredential`, source `detected:agent-serve`; only status, shape and non-secret scalars printed):
    - **P1** `GET /v0/grokbot/sessions/14752726/entries?afterUpdatedSeq=999999999999999999` → **200**; `entries: []`; `latestUpdatedSeq: "999999999999999999"` (the requested cursor is echoed on an empty page); `turn: {idle: true, inFlight: false, queued: 0}`. No conversation content was read.
    - **P2** `GET /v0/grokbot/sessions` → **404** (body shape `{message, error, statusCode}`): there is no list route.
  - Consequences in code: busy = `!idle || inFlight || queued > 0`; the fake BDK uses the real turn shape. The 2-probe allowance is used up; no further live call was made.
- **M2 (offline):** XML plist writer; Ask and wait-probe Shortcut builders; language profiles with setup steps in the iPhone language; `homebot shortcut build <bot> [--siri-lang] [--phone-lang] [--name] [--url] [--replaces] [--probe] [--sign] [--reveal]`; `homebot start --probe-wait`. The signer wrapper (`shortcuts sign`, mode alternation, backoff) is tested with a fake signer only and is **refused unless `HOMEBOT_ALLOW_SIGNING=1`**. Generated XML passes `plutil -lint`. A built Shortcut's exact request is answered end to end against the fake BDK.
- Found while building: iOS names an imported Shortcut after its **file name**, so files are `~/.homebot/shortcuts/<tokenId>/<name>.shortcut` (DESIGN §7.5).

**Disagreements with the M1 review:** none.

**Known limits / for review**
- Unverified until M3: whether `shortcuts sign` accepts XML (else `plutil -convert binary1` first), whether `.local` resolves when the HomePod triggers the Shortcut, whether a 401 body is spoken, real echo compliance, the Chinese iOS setting labels in the zh-Hans steps.
- Still from M1: the rate limit counts a request before busy/in-flight is known.

**Next**
- Codex: review of the M1 fixes + M2 (`744d06b..HEAD`).
- Everything else left needs Felix (below). M4 (setup page) depends on Q-ADD and Q-KEY.

**Needs Felix** (replaces earlier lists; DESIGN §14)
- **L1 — live read-only:** `homebot doctor` and `homebot bot add-id 14752726 --key chai --name 拆解师` (cold sync = many GETs, beyond the 2-probe allowance).
- **L2 — signing:** allow `HOMEBOT_ALLOW_SIGNING=1 homebot shortcut build chai --siri-lang zh-CN --phone-lang en --sign --reveal` (uploads the file to Apple's signing service). Also one probe Shortcut (`--probe`).
- **L3 — bot messages:** ≤3 `[Homebot test]` questions to 拆解师 via `curl` (timing + echo compliance).
- **M3 device session:** AirDrop import, run on iPhone, then HomePod (sound, announced first); wait-limit probe; 401 behavior; `.local` resolution.
- **Q-NAME:** Siri phrase for 拆解师 (default "问问拆解师").
- **Q-ADD:** may users add a bot by exact name (`POST /sessions {name}`, which creates an empty bot on a typo; guarded by confirmation + "newly created" check)? Or **Q3:** is the numeric session id visible to users?
- **Q-KEY:** confirm the new-user route (a Cursor dashboard API key pasted in setup), to be validated at M4 with detection off.
- **Q6:** any known field linking a reply to a message.

## 2026-10-21 — Codex: M2 review

- **Done:** Reviewed `744d06b..b1bc804`, DESIGN v2 and current v3, prior reviews, decisions, spike builder source, code, and tests. Wrote [M2 review](reviews/milestone-m2-review.md). Localized corrections requested; no new release blocker established.
- **Findings:** Stale cleanup can delete another build's artifact. The 24-hour cleanup promise lacks an automatic trigger. Probe/name instructions can point to the wrong Shortcut. Replacement validation and signer creation modes need correction. Original M1 fixes are present, with verification limits recorded.
- **Validation:** `node --test`: 61 passed; 48 environment-blocked at loopback listen with `EPERM`, not counted as product failures. Socket-free synthetic probes confirmed lifecycle and replacement issues. XML lint passed. No real secrets, bot/service calls, login, signing, or device actions. Code and DESIGN.md unchanged.
- **Next:** Claude addresses the review and reruns the offline suite with loopback available. For users, a generated Shortcut must remain available for import, and its instructions must name that same Shortcut. Existing signing/M3 approvals remain separate; no new owner decision is required for these fixes.

## 2026-10-21 — Claude: M2 closeout (addresses M2 review)

**Done** (commits `657622d`, `e39cf95` + this docs commit; `node --test`: **119 passed, 0 failed**, loopback available; 10 new tests)
- All 5 should-fixes and 2 nits accepted and fixed with tests. **No disagreements.** Per-item notes in DESIGN §15 v3.1.
  - S1: artifact cleanup now decides under the `tokens.json` lock against the current file, so a sweep in one process can't delete another's fresh build.
  - S2: the 24 h artifact lifetime is enforced by every CLI run and by the running gateway every 10 min. CLI text says what happens when nothing runs.
  - S3: one effective Shortcut name (the sanitized file name) is used in the output, setup steps and token label. Probe builds name the probe Shortcut.
  - S4: `--replaces` must be a usable token of the same bot; otherwise nothing is issued and the old token stays usable.
  - S5: the signer runs through a fixed `/bin/sh` umask-077 launcher (arguments only, no interpolation), so its output is 0600 from creation. Tested with a fake signer script only.
  - N1: gateway URL validated before a token exists; after that, any build failure revokes the new token and deletes its files.
  - N2: test names narrowed; the ordered-persistence test now checks several writes for overlap and order.
- Nothing live ran: no bot/service calls, no login, no signing (Apple's `shortcuts` was not invoked), no device actions, no remotes.

**M2 is closed** as far as offline work goes. Real signing, iOS import and Siri/HomePod behavior remain M3 acceptance.

**Next**
- 拆解师 pushes the repo to Felix's private GitHub repo (Claude/Codex don't touch remotes).
- Then M3 once Felix approves the items below. M4 (setup page) waits on Q-ADD and Q-KEY.

**Needs Felix** (unchanged; DESIGN §14)
- **L1 — live read-only:** `homebot doctor` and `homebot bot add-id 14752726 --key chai --name 拆解师` (cold sync = many GETs, beyond the 2-probe allowance).
- **L2 — signing:** allow `HOMEBOT_ALLOW_SIGNING=1 homebot shortcut build chai --siri-lang zh-CN --phone-lang en --sign --reveal` (uploads the file to Apple's signing service). Also one probe Shortcut (`--probe`).
- **L3 — bot messages:** ≤3 `[Homebot test]` questions to 拆解师 via `curl` (timing + echo compliance).
- **M3 device session:** AirDrop import, run on iPhone, then HomePod (sound, announced first); wait-limit probe; 401 behavior; `.local` resolution.
- **Q-NAME:** Siri phrase for 拆解师 (default "问问拆解师").
- **Q-ADD:** may users add a bot by exact name (`POST /sessions {name}`, which creates an empty bot on a typo; guarded by confirmation + "newly created" check)? Or **Q3:** is the numeric session id visible to users?
- **Q-KEY:** confirm the new-user route (a Cursor dashboard API key pasted in setup), to be validated at M4 with detection off.
- **Q6:** any known field linking a reply to a message.

## 2026-10-21 — Claude: M4 (offline) — setup page + README — ready for Codex review

**Done** (commits `af6a4d1..HEAD`; `node --test`: **137 passed, 0 failed**, fakes only; 18 new tests)
- **Setup page** (`src/server/setup.js`, `src/setup-ui/`), started by `homebot start` on **127.0.0.1:8788 only**, next to the voice listener. DESIGN §8 describes it as built.
  - Page language (English default, 简体中文). **Siri language** and **iPhone language** questions, English preselected. Felix's mix (iPhone en / Siri zh-CN) is tested end to end through the page API: "问问拆解师", Chinese prompt and voice, English iPhone steps, Chinese reply.
  - Account: paste a key → `secrets.json` (0600), never returned; only the credential *source* is shown. `start` now runs without a key, and a key saved on the page works without a restart.
  - Bots: add by session id + name through the existing read-only cold sync; remove (also revokes the bot's Shortcuts and drops its cursor). No listing API exists, as before.
  - Shortcut: live preview of phrase/question, build, replaces (defaults to the bot's active Shortcut), Show in Finder, one-time QR link. **Signing stays disabled** (checkbox disabled, API refuses with 403 before any token is issued) unless `HOMEBOT_ALLOW_SIGNING=1`, which was not set.
  - Shortcut list with honest states (waiting for first request / Homebot received a request with this Shortcut's token / retired) and revoke.
- **Security, tested:** Host check (421 for DNS-rebinding hosts), per-launch secret header for every API call, POST + JSON + same Origin for changes, 16 KB cap, strict CSP / nosniff / no-store / no-referrer, no key / token / hash in any response (checked over every response in a test), no HTML rendering of data (a test forbids `innerHTML` & co., inline scripts/styles/handlers).
- **One-time link:** `GET /dl/<128-bit>` on the voice listener: single use, 10 min, dropped on revoke/remove, never logged. **Own QR encoder** (`src/core/qr.js`), verified by Apple's CoreImage detector in a macOS test for versions 1–10.
- **README:** install and setup guide for non-technical users (prerequisites, install, start, setup page, importing, iPhone/HomePod settings, troubleshooting: recognition lag, Personal Requests, Mac asleep, signing outages), unverified steps marked. It states plainly that signing is off, so import isn't possible yet.
- `scripts/dev-setup.mjs`: offline demo of the page against the fake Grok Bot API (ports 18787/18788, throwaway home).
- Nothing live ran: no BDK/Grok Bot calls (fake only), no messages, no login, no signing, no device actions, no remotes.

**Browser smoke test** (Codex Computer Use, local demo against the fake API only; my own browser tool was denied in this headless session):
- PASS:
  - The page renders with no console errors.
  - Key saved → "Connected (homebot:secrets)".
  - Siri zh-CN + iPhone en.
  - Bot 拆解师 added.
  - Preview "问问拆解师"; unsigned build with the English "Allow Running When Locked" steps; signing disabled with an explanation.
  - QR shown (link not opened).
  - Switching the page to 简体中文 relabels it.
- Not completed: revoke via the confirm dialog and the literal `<b>x</b>` name. Codex's browser control timed out on the dialog. Both behaviors are covered by API tests (revoke) and the static no-HTML-rendering test, but have not been clicked through in a browser.
- Its two usability findings are fixed, without a browser re-check:
  - After a page-language switch, the build result and QR expiry stayed in English. They are now re-rendered.
  - Unsigned builds showed import steps without caveat. They now carry a note that the steps apply once signed.

**Deferred (not in this milestone):** "you confirmed you heard it" button and an "answered" state; advanced settings on the page (deadline, spoken length, style, log text, detection toggle); add-by-name (Q-ADD).

**Unverified until M3 / Felix:** iOS handling of the downloaded `.shortcut` from the QR link; macOS firewall prompt wording; where users find the session id (Q3); which key a new user should create (Q-KEY).

**Next**
- Codex: review of M4 (`af6a4d1..HEAD`).
- Everything else needs Felix (below).

**Needs Felix** (unchanged, all still open; DESIGN §14)
- **L1 — live read-only:** `homebot doctor` and `homebot bot add-id 14752726 --key chai --name 拆解师` (cold sync = many GETs, beyond the 2-probe allowance).
- **L2 — signing:** allow `HOMEBOT_ALLOW_SIGNING=1` for one "问问拆解师" build (Siri zh-CN, iPhone en) plus one probe Shortcut (uploads the files to Apple's signing service).
- **L3 — bot messages:** ≤3 `[Homebot test]` questions to 拆解师 via `curl` (timing + echo compliance).
- **M3 device session:** import (AirDrop and the QR link), run on iPhone, then HomePod (sound, announced first); wait-limit probe; 401 behavior; `.local` resolution.
- **Q-NAME:** Siri phrase for 拆解师 (default "问问拆解师").
- **Q-ADD:** may users add a bot by exact name (`POST /sessions {name}`, which creates an empty bot on a typo; guarded by confirmation + "newly created" check)? Or **Q3:** is the numeric session id visible to users?
- **Q-KEY:** confirm the new-user route (a Cursor dashboard API key pasted in setup), to be validated with detection off.
- **Q6:** any known field linking a reply to a message.

## 2026-10-21 — Codex: M4 review

- **Done:** Reviewed `1e98288..0a77422`, current DESIGN v4 and historical v2, prior reviews, BRIEF, decisions, code, tests, and spike builder source. Wrote [M4 review](reviews/milestone-m4-review.md). **Changes required before approval.**
- **Findings:** A build during removal can leave an old Shortcut authorized for a newly added bot. Concurrent adds can attach the wrong cursor. Socket-free synthetic probes confirmed both issues and a wait probe retiring a working voice token. Setup also needs the latest naming/account decisions and accurate replacement/privacy instructions.
- **Validation:** `node --test`: 71 passed, 65 blocked by loopback `EPERM`, one QR decoder check blocked by its environment. A focused QR rerun could not decode either Homebot symbols or a separate Apple-generated control. No encoder defect was established. No live calls, login, real secrets, signing, device actions, or code/DESIGN changes.
- **Next:** Claude fixes lifecycle coordination and the documented setup issues, then runs HTTP/browser checks where supported. For users, removing a bot must stop every old Shortcut, and a wait test must preserve the working voice Shortcut. DECISIONS round 2 already resolves the named approvals; device acceptance remains separate.

## 2026-10-21 — Claude: M4 fix round (Codex M4 review + DECISIONS 9–15) — ready for 拆解师's online steps

**Done** (commits `4c0e6cb..HEAD`; `node --test`: **151 passed, 0 failed, 0 skipped**, fakes only; 14 new tests)
- **M4 review: all accepted, no disagreements.** Per-item notes in DESIGN §15 v5.
  - **B1:** new `BotLifecycle` (DESIGN §6.3). Add, remove and token issuance share one lock on `config.json` and re-read the files. Issuance re-checks that the bot still has the same session, so a build racing a remove (or remove + re-add of the key) issues nothing. Tokens record the session id. The voice listener refuses (401) a token whose bot now points at another session, and sends nothing.
  - **S1:** identity is re-checked under the lock before the cursor is written; a rejected add changes nothing. Cursors are session-tagged, StateStore writes are locked, and AskService skips persisting for a changed bot.
  - **S2:** token kinds. A wait-test token only works on `/v1/probe-wait`, is refused by `/v1/ask` before activation, and never replaces (or is replaced by) a voice token. The page offers the option only with `--probe-wait` and rejects probe + replaces.
  - **S3:** owner decisions applied (below). Historical STATUS/DESIGN entries keep their old names.
  - **S4:** saving a Siri language says it applies to new Shortcuts. Tokens built for another language are flagged, with a "Make a replacement" action.
  - **S5:** the account shows which key is used (env / saved / detected) and whether Grok Bot accepted it. It shows `unchecked` until a bot add reaches Grok Bot. It explains env precedence and how to change an env key. Tested for every state.
  - **S6:** page and README say what stays on the Mac and what goes to Grok Bot or Apple. Strict checking is described by what it refuses. Turning it off needs a confirmed warning; the server enforces `confirmNonStrict`.
  - **N1:** README: rename the unzipped folder; Siri in iCloud; 25 s described as the reply budget; the 24 h lifetime qualified.
  - **N2:** the page refreshes on focus/visibility and has a Refresh button.
  - **N3:** the QR check first decodes an Apple-generated control symbol. It skips, with the reason, if the control fails or Swift can't run; otherwise every symbol must decode. On this Mac the control decoded and all 14 symbols decoded.
- **DECISIONS 9–15 applied:**
  - Bot 14752726 is "homebot" in current docs, examples and tests.
  - **Q-NAME:** the zh-CN default is `<bot> 你好` ("homebot 你好"); it never starts with 问. A bot name with Latin letters also gets the all-Chinese alternative "家庭助手" (page button / `--name 家庭助手`). Phrase warnings (`starts-with-ask`, `mixed-language`) show under the preview. M3 picks one.
  - **Q-ADD:** add by exact name, typed twice.
    - CLI: `homebot bot add-name "<name>" --key <key> --confirm "<name>"`. Page: two fields.
    - Just-created detection (empty and < 60 s old): the bot is reported and **not** added.
    - The session-id route moves under "Advanced".
    - Built and tested **only against the fake API**; never called live.
  - **Q-KEY:** README and page copy say "Cursor dashboard API key". The caveat stays that a brand-new account's key is unverified.
  - Signing is described as off by default. Felix's approval for his own install (item 10) is recorded separately in DESIGN §7.5.
- **New CLI:** `bot remove <key>` retires the bot's tokens. `token issue … --curl-header` writes a 0600 `X-Homebot-Token: …` file for `curl -H @file`, so the token never appears on a command line. `/v1/ask` accepts `"test": true` to send a `[Homebot test · …]` envelope.
- Nothing live ran this round: no BDK/Grok Bot calls (fake only), no messages, no login, no signing, no device actions, no remotes, no Codex or browser tools.

**Not verified this round:** the page changes weren't clicked through in a browser (browser tools were not allowed). Covered instead by API tests and a static check that every element id and error code the page uses exists.

**Next**
- 拆解师 runs the M3 kit plan below (L1 → L2 → L3), then records the results here.
- Then the M3 device session with Felix, asked first.
- Codex can review this round (`4c0e6cb..HEAD`) in parallel.

**Needs Felix**
- **L1 — live read-only: APPROVED** (DECISIONS item 9). 拆解师 runs it; see the M3 kit plan.
- **L2 — signing for Felix's own install: APPROVED** (item 10). 拆解师 runs it; see the M3 kit plan.
- **L3 — ≤3 `[Homebot test]` messages to session 14752726: APPROVED** (item 11). 拆解师 runs it; see the M3 kit plan.
- **M3 device session: PENDING.** Timing is not set. Ask before any HomePod sound (item 15). It covers:
  - import (AirDrop and the QR link), then run on iPhone, then HomePod;
  - phrase choice ("homebot 你好" vs "家庭助手");
  - wait-limit probe, 401 behavior, `.local` resolution.
- Q-NAME, Q-ADD, Q-KEY: **decided** (items 12–14) and applied offline. Two live checks are still open:
  - add-by-name against the real API: it is a `POST`, not covered by L1, so it needs its own OK;
  - a dashboard key from a fresh account, with detection off.
- **Q3** (is the numeric session id visible to users) and **Q6** (a reply↔message link field): still open, lower priority now that add-by-name exists.

### M3 kit plan (for 拆解师: exact commands, in order)

Run everything from `~/Desktop/felix-projects/homebot`. Use one Terminal tab for the gateway and one for commands.
- **Credentials:** Felix's existing login is detected automatically (`detected:agent-serve`). Do not set or print any key. No command below prints a secret.
- **Never paste the contents of these anywhere** (chat, logs, git): `~/.homebot/secrets.json`, `tokens.json`, `*.header`, `*.token` and `*.shortcut` files.

**L1 — read-only (DECISIONS item 9)**
1. `node bin/homebot.ts doctor`
   Record: `Credentials: detected:agent-serve` (the source name only) and "Bots: none configured".
2. `node bin/homebot.ts bot add-id 14752726 --key homebot --name homebot`
   - This is a full cold sync: many GETs, no messages.
   - Record: entries, pages, idle/busy.
   - **Do not add `--preview`**: it prints conversation content.
3. `node bin/homebot.ts doctor`
   Expect `Bot homebot (homebot): readable, idle, N new entries since last sync`. Record the line.

Stop and report if step 2 fails, or if the doctor shows "busy" for a long time.

**L2 — signing, Felix's install only (DECISIONS item 10)**
- Shortcut files are deleted once 24 h old, so build these **within 24 h before the device session**. If older, rebuild and revoke the stale pending tokens (`node bin/homebot.ts token list`, then `token revoke <id>`).
- The gateway address defaults to `http://<this Mac's LocalHostName>.local:8787`. If `.local` fails in M3, rebuild with `--url http://<Mac IP>:8787`.
- Each build is one command.

4. Primary phrase (Siri zh-CN, iPhone en), "homebot 你好":
   `HOMEBOT_ALLOW_SIGNING=1 node bin/homebot.ts shortcut build homebot --siri-lang zh-CN --phone-lang en --sign --reveal`
5. All-Chinese alternative, "家庭助手":
   `HOMEBOT_ALLOW_SIGNING=1 node bin/homebot.ts shortcut build homebot --siri-lang zh-CN --phone-lang en --name 家庭助手 --sign --reveal`
   - **No `--replaces`.** The two are independent, so both can be tried in M3.
   - Afterwards, revoke the one not chosen.
6. Wait-limit probe Shortcut, "Homebot 等待测试":
   `HOMEBOT_ALLOW_SIGNING=1 node bin/homebot.ts shortcut build homebot --probe --siri-lang zh-CN --phone-lang en --sign --reveal`
   - Its token only works while the gateway runs with `--probe-wait` (step 7 variant). It never touches the voice Shortcuts.

For each build, record:
- the "Signing (attempt N, mode …)" lines;
- success or failure, with the error text;
- the file name shown.

If signing fails with a format error, **stop and report it; don't work around it**. It's the open D6 question: XML vs binary plist.

Do not AirDrop or import yet. Importing is part of the M3 device session.

**L3 — ≤3 `[Homebot test]` messages to session 14752726 (DECISIONS item 11)**
7. Gateway, in its own tab, left running: `node bin/homebot.ts start`
   - For the M3 wait test later, use `node bin/homebot.ts start --probe-wait` instead.
8. Each question needs **its own token**: the header file is deleted when its token is first used. For each question:
   - a. Issue the token:
     `node bin/homebot.ts token issue homebot --siri-lang zh-CN --label "M3 curl test 1" --curl-header`
     - It prints `Secret written to ~/.homebot/shortcuts/<id>.header`. **Don't `cat` it.**
     - For the English question (3), use `--siri-lang en-US`.
   - b. Ask (paste the printed path after `@`):
     `curl -sS -w '\nHTTP %{http_code} in %{time_total}s\n' -X POST http://127.0.0.1:8787/v1/ask -H @"$HOME/.homebot/shortcuts/<id>.header" -H 'Content-Type: application/json' --data '{"text":"用一句话介绍你自己。","test":true}'`
   - Suggested questions:
     1. `用一句话介绍你自己。` (zh-CN)
     2. `一加一等于几？` (zh-CN)
     3. `In one sentence, what can you help me with?` (en-US token)

   Count every curl as one message, even when Homebot answered "busy" (then nothing was sent). **Stop at 3.**
9. After each question, record:
   - **curl:** HTTP code, `time_total`, and the spoken text Homebot returned. This is the answer to our test question.
   - **Gateway log:** `tail -n 3 ~/.homebot/logs/homebot.jsonl`. It contains no question or answer text and no token. From the `"event":"ask"` line, record:
     - `outcome`: `answered` / `refused` / `no-reply:deadline` (sent, no owned reply within 25 s) / `busy` or `not-sent:*` (nothing was sent) / …;
     - `reason` if refused: `O5` = the reply lacked the `[hb:<id>]` echo; `O2`/`O3` = other activity in the conversation;
     - `requestId` (= the `hb:` id), `baseline_ms`, `sent_ms`, `reply_ms`, `total_ms`, `poll_errors`.
   - **Echo compliance:** open the conversation in the Grok Bot app. Check whether the bot's reply **starts with `[hb:<requestId>]`** and whether it is 1–3 short sentences in the right language. Homebot strips the tag before returning text, so curl never shows it.
10. Clean up:
    - Stop the gateway (Ctrl-C).
    - `node bin/homebot.ts token list`, then `node bin/homebot.ts token revoke <id>` for the three curl tokens.

Then add a STATUS entry with the L1/L2/L3 records. No secrets, and no answer text beyond what is needed.

## 2026-10-21 14:23 (Asia/Taipei) — 拆解师: L1/L2/L3 run per the M3 kit plan
**L1 (read-only)**: `doctor` → `Credentials: detected:agent-serve`. `bot add-id 14752726 --key homebot --name homebot` → readable, 233 entries in 3 pages, idle. `doctor` → `Bot homebot (homebot): readable, idle, 0 new entries since last sync`. No `--preview`.
**L2 (signing, Felix only)**: all three signed on attempt 1, mode people-who-know-me, AEA1 header, mode 0600:
- `homebot 你好`, `家庭助手` and the `Homebot 等待测试` probe (three tokens, pending). Gateway URL `http://<mac-name>.local:8787`. Built 14:20; Mac copies expire after 24 h (copies held by 拆解师 for delivery).
**L3 (3 of 3 messages used; stop)**: gateway `start`, one token per question, curl to 127.0.0.1:8787:
| # | lang | outcome | HTTP / total | baseline | sent | reply | a_len |
|---|---|---|---|---|---|---|---|
| 1 (80a05418f381) | zh-CN | answered | 200 / 10.73 s | 1589 ms | 4506 ms | 10730 ms | 35 |
| 2 (678e11f21d4c) | zh-CN | answered | 200 / 5.69 s | 736 ms | 1140 ms | 5684 ms | 7 |
| 3 (9d5317f3c17c) | en-US | answered | 200 / 6.87 s | 775 ms | 2710 ms | 6865 ms | 109 |
- All three passed strict ownership (so the bot echoed `[hb:<id>]` 3/3; not separately checked in the app). Answers were one short sentence in the right language. poll_errors not logged (absent).
- Cleanup: gateway stopped, port 8787 free; the 3 curl tokens revoked. The three Shortcut tokens remain pending for M3.
**Next**: M3 device session with Felix (ask before any HomePod sound).

## 2026-10-21 — Claude: TypeScript migration (DECISIONS item 16, DESIGN v6) — ready for Codex review
**What changed**
- **Code:** all code in `src/`, `bin/`, `scripts/`, `test-helpers/` and `test/` is now strict TypeScript.
  - Node runs it directly with built-in type stripping. The entry point is now `node bin/homebot.ts start`.
  - **Minimum Node: 24.12.0** (`engines`). Source: <https://nodejs.org/api/typescript.html>, which says stable from v24.12.0 / v25.2.0 and no warning from v24.3.0. Checked here on v24.14.0: no warning.
- **Users still install nothing.** Runtime imports are only `node:` built-ins. `typescript` 7.0.2 and `@types/node` are dev dependencies, pinned in `package-lock.json`.
- **Strictness.** `tsconfig.json` sets `strict`, `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes` and the unused/implicit-return checks. It also enforces erasable-only syntax (`erasableSyntaxOnly`, `verbatimModuleSyntax`). Explicit `.ts` import paths are a source convention that `allowImportingTsExtensions` permits but does not enforce (corrected after the TS review, N2).
  - There is no `any`, no `@ts-ignore` and no non-null `!`.
  - `as` assertions appear only at JSON/stream/address boundaries, each with a comment.
  - Tests use `must()` (`test-helpers/must.ts`) instead of `!`.
- **Setup page.** `src/setup-ui/app.ts` and `strings.ts` are checked against the DOM (`tsconfig.ui.json`). `npm run build:ui` compiles them to `app.js` / `strings.js`, which stay committed. `npm run check:ui` and `test/ui-build.test.ts` fail when those files are stale; the test is skipped without dev deps.
  - API response shapes are declared once, in `src/server/setup-api.ts`.
- **Small interface narrowing for injected dependencies** (types only; runtime behavior unchanged):
  - `createVoiceServer` takes `VoiceConfig` and `Pick<TokenStore, "verify">`.
  - Signers are typed `Signer`.
  - `TokenStore.verify(token, bot?)`.
  - The `start` command's BDK wrapper now also forwards `getOrCreateSession`. AskService never calls it.
- **Slightly more defensive, otherwise identical** (not quite: `/v1/ask` also started rejecting JSON array bodies; see the fix-round entry below, TS review S1):
  - Malformed but valid JSON in `secrets.json` / `tokens.json` (e.g. `null`, or no `tokens` array) is treated as empty instead of raising a TypeError.
  - The setup page throws a clear error if an element it expects is missing.

**Checks:** `npm test` → **152 passed, 0 failed** (the 151 earlier tests + 1 UI drift test). `npm run typecheck` → clean (both configs). Commits: a6f50dc, 037428e, 8c95cda, 1797586, c9d796a, 08a70dc, 68e2867, plus this docs commit.
**Not done:** a real-browser check of the compiled setup page. The browser tool needed an approval that wasn't available in this run. The page's script is exercised only by the offline API tests, the HTML/ID consistency test and `node --check`. Worth a quick look via `node scripts/dev-setup.ts`, or in the Codex review.
**M3 kit:** commands above now use `node bin/homebot.ts`. The Shortcuts built at 14:20 are unaffected: token format and API are unchanged.

**Needs Felix**
- **Minimum Node 24.12 (current LTS line) vs allowing 22.18+.** 22.18+ and 24.3+ run without a warning but are not marked stable before 24.12 / 25.2; 23.6+ and 24.0–24.2 warn (DECISIONS item 16 lists each line; corrected after the TS review, N1). I chose 24.12. Lowering it is a one-line `engines` + README change.
- **Install as an npm package does not work.** Node won't strip types under `node_modules`, so `npm install -g` / `npx` can't run Homebot. Repo folder only (as the README says). This is fine for v1; if a published package is wanted later, it would need a compiled build.
- **TypeScript 7.0.2** (the native compiler) for type-checking. Pinned. 5.8+/6.x would work equally with this config if preferred.

## 2026-10-21 — Codex: TS migration review

- **Verdict:** Reviewed `a4640d2..1f453ab`. No blocker found in the supported Shortcut flow. [Review](reviews/ts-migration-review.md) requests an explicit resolution for changed array-body handling and accurate signing status. Two documentation nits cover Node versions and import enforcement.
- **Checks:** Typecheck passed. `npm test`: 152 discovered, 79 passed, 72 blocked by loopback `EPERM`, one Swift QR decoder check skipped. No product test failure established, but full-suite success is not confirmed here. All 151 prior tests remain. UI drift detection passed, including rejection of a changed generated file in a disposable copy. Runtime imports loaded without `node_modules`. Old/new QR output matched for 214 payload lengths.
- **User impact:** Normal generated Shortcuts retain their request format and safety rules. A malformed array request now gets HTTP 400 before token use. Signing succeeded before this migration according to the earlier record, but phone/HomePod acceptance remains open.
- **Scope:** Offline review only. No real secrets inspected, bot/service calls, login, Apple signing, device actions or browser acceptance. Code and DESIGN.md unchanged. Rerun the complete suite where loopback is allowed before claiming independently verified migration acceptance.

## 2026-10-21 — Claude: TS migration fix round (DESIGN v6.1)
All four findings accepted; no disagreement. Review committed as-is in a9af3f0.
- **S1 (array bodies):** two separate commits.
  - e5c0869 `fix(port)`: restores the JavaScript handling (any non-null JSON object, arrays included), so the port itself is behavior-preserving.
  - af32271 `fix(voice)`: a deliberate API correction. A body that is not a JSON object gets 400 `bad json` before the token is checked, so it can't activate or retire a token. Contract test `TS review S1: …` (arrays, `null`, string, number, boolean → 400, no token check, no bot call; an object still works). The test was confirmed to fail on e5c0869 (`[]` → 200). DESIGN §4.1 step 3 documents the rule. Generated Shortcuts always send an object, so they are unaffected.
  - The migration entry's "otherwise identical" now points here. The malformed-file changes it lists remain deliberate.
- **S2 (signing status):** 8d99aeb. README and DESIGN §7.5 say signing worked for Felix (14:23, XML accepted directly) before the migration; post-migration signing, iPhone import and HomePod use are unchecked. The default-off gate and the new-account key caveat are unchanged.
- **N1, N2:** e03e3b2. DECISIONS item 16 gives Node support per release line (minimum stays 24.12.0). `.ts` import paths are described as a convention that `allowImportingTsExtensions` permits but doesn't enforce (also the tsconfig comment). The two lines in the migration entry above are corrected in place.

**Checks:** `npm test` → **153 passed, 0 failed** (152 + the S1 contract test). `npm run typecheck` → clean.
**Not done (unchanged):** browser check of the setup page; post-migration signing and device acceptance (M3).

## 2026-10-21 — Claude: BDK transport improvements (DECISIONS item 17, DESIGN v7)
Offline only: fake BDK, no live calls. The source repo has no license; ideas only, nothing copied.
**Evidence used:** the official `@cursor/bdk` client (`backend.js`, `conversation.js`, read-only) and homebot's read-only GETs at ~15:50 on session 14752726:
- Page `latestUpdatedSeq` = page tail, not session tail (200 entries → "205"; 3 requests to the tail "264"). Empty page echoes the cursor.
- A cursor beyond the tail returns 0 entries, echoes it and still carries `turn`. `GET /sessions/14752726` → 404.
- Not observed live: turn values during a reply, `/interrupt`, `POST /sessions`.

**Integrated**
- **O6, whole-turn replies** (74afdd6). The official client joins all `send-message` deliveries of a turn; Homebot spoke only the first. Now, after the first owned delivery, it polls until the turn settles: no new entries, not busy, `idle`. One poll suffices if the turn was seen busy, else two. The wait is capped at `settleMs` (3 s) and the deadline. It stops at foreign input. An owned reply is never dropped at the deadline.
  - Tests: three-part reply spoken whole; a backend that never reports busy still answers; a turn stuck busy is spoken at the cap or the deadline; deliveries after a desktop message are never spoken; pure `turnReplies` unit tests.
- **Delivery check** (ba02248). Any `delivery` other than `accepted_temporal`/`duplicate` ends the wait at once (`outcome: "not-accepted"`, value logged). Siri still says "may have been delivered". A missing field keeps the old behavior.
- **Turn trace** in the `ask` log line: `turns` (per poll: `B`/`I`/`?`), `parts`, `settle`, `settle_ms`. No content.
- **Fake BDK** (6541467): turns busy while replying, multi-part replies, a never-busy mode, configurable `delivery`.

**Not integrated** (DECISIONS item 17): `POST /sessions` for the baseline (get-or-create; no `turn`), the beyond-tail cursor (no tail), `interrupt` (shared session), waiting out a busy turn (D13).
**Safety:** ~~O6 only adds deliveries from the same turn…~~ **Wrong; see the fix-round entry below.** O6 could speak unproved text (an untagged re-update, or a separate task's output), and wrong turn flags could cost more than ~1 s. O6 has been reverted.
**Checks:** `npm test` → **160 passed, 0 failed** (153 + 7 new). `npm run typecheck` → clean. The suite now takes ~11 s instead of ~4 s: the setup/CLI tests use the default 500 ms poll, and each answer now has a settle poll.

**Needs Felix**
- **Turn values during a reply (live):** superseded by the fix-round entry below (`parts`/`settle` no longer exist).
- **`interrupt` (not proposed now).** Only needed if you want a spoken "stop" command (DESIGN §9.1). The live check would be `POST https://api.cursor.com/v0/grokbot/sessions/14752726/interrupt` with `{"reason":"Homebot interrupt test"}` during a test turn, then one GET of entries to see what it leaves in the transcript. It costs one test message. I recommend leaving it until a stop command is actually planned.
- **`POST /sessions {name}`:** no check needed. It's used only for add-by-name, as before.

## 2026-10-21 — Codex: BDK transport review

- **Verdict:** Changes required for `cc7078f..e43063d`. [Review](reviews/bdk-transport-review.md) records two ownership blockers: unchecked reply updates and unrelated later deliveries entering speech. In user terms, HomePod could read text that was not proved to answer the voice question.
- **Other findings:** settle cap is not enforced during sleep/fetch, unknown delivery strings can enter logs, and tests need malformed/missing turn and ownership cases. The total request abort remains in place.
- **Checks:** Typecheck passed. `npm test`: 160 discovered, 81 passed, 78 blocked by loopback `EPERM`, one Swift check skipped. No product failures inferred from those environment blocks. In-memory offline probes reproduced the ownership, settle-cap, and logging defects.
- **Scope:** Review and this status entry only. Code and DESIGN unchanged. No secrets read, network calls, login, signing, or device actions. No copied-looking third-party material found in the diff, but no source-to-source comparison with the unlicensed repository was possible offline.

## 2026-10-21 — Claude: BDK transport fix round (DESIGN v7.1)
All findings accepted; no disagreement. Review committed as-is in 0560c2f.
- **B1, B2 → O6 reverted** (693ac35). With what the API gives, O6 can't be made provably safe. Turn flags are session activity, not a delivery-to-request link, and later deliveries carry no echo. Homebot again speaks only the text a single `decideReply` call checked, and returns at once: nothing read after the proof is spoken. `turnReplies` and `settleMs` are removed.
  - New service tests run on a socket-free scripted BDK (`test-helpers/scripted-bdk.ts`, `test/ask-ownership.test.ts`):
    - A replacement of the accepted reply in a later poll is never fetched or spoken.
    - A replacement in the same observation is re-checked and refused (O5).
    - Late O2/O3 evidence refuses.
    - Untagged output from another task is never spoken, in the same poll or later.
  - Pure tests: untagged re-update → O5; a later delivery is not the answer.
  - HTTP fake test: a two-part turn speaks only the proved first part.
  - A future multi-part answer would need real evidence per delivery: an API link, or a per-delivery echo with live-measured compliance (DECISIONS item 17).
- **S1:** the settle phase is gone with O6, so there is no settle cap to enforce. The total deadline still bounds everything after step 6. DESIGN §4.1 step 6 now says the local config/state reload before it is not counted.
- **S2** (42647d7). Unknown `delivery` values are logged only as `"unknown"`. Tests cover a sensitive-looking lowercase value, a punctuated one and a 500-character one; none appears in the logs.
- **S3:** the scripted seam above. It covers missing, malformed (`{}`, wrong types) and stuck-busy turn flags. In each case the answer is the proved text, returned without waiting. The HTTP fake stays for transport tests.
- **N1** (693ac35). `turnCode`: `I` only for exactly `idle: true, inFlight: false, queued: 0`; `B` per the busy rule; `?` otherwise. Unit test included.
- **N2.** DESIGN §4.1 steps 6/10/11, §4.2, §4.3 and §5.1, DECISIONS item 17, and the overstated safety line in my previous entry are corrected. The previous entry's live-check bullet is superseded below.

**Checks:** `npm test` → **163 passed, 0 failed**. `npm run typecheck` → clean. The suite is back to ~4.5 s.

**Needs Felix**
- **Turn values during a reply (live, diagnostics only).** At the next approved L3/M3 run (the existing `/v1/ask` curl with `"test": true`), read `turns` from the `"event":"ask"` log line, e.g. `BBI` or `III`. It shows whether the backend reports busy while a reply is produced. It only matters for the pre-send busy check; ownership never uses it.
- **`interrupt`:** unchanged; not proposed.

## 2026-10-22 — Felix: M3 device session (recorded by Claude from Felix's report and the gateway log)

**Result: requirement 5 met.** Saying "家庭助手" to the Chinese HomePod starts the Shortcut on the iPhone (Personal Requests), and Siri speaks the bot's answer on the HomePod. Manual runs on the iPhone are fast and stable. Health check OK. The `.local` gateway address resolved when the Shortcut ran from the HomePod.
- **Phrases:** "家庭助手" is active. "homebot 你好" did not trigger reliably on the Chinese HomePod and is retired. "Homebot 等待测试" is still pending (not yet run).
- **Gateway log (metadata only, `~/.homebot/logs/homebot.jsonl`):** 6 voice requests.
  | time (UTC) | outcome | q_len | baseline | sent | total | turns |
  |---|---|---|---|---|---|---|
  | 06:46:17 | answered | 2 | 1092 ms | 1524 ms | 6039 ms | BBBB |
  | 06:46:41 | answered | 3 | 1843 ms | 2818 ms | 7556 ms | BBBB |
  | 07:42:15 | no-reply:disconnect | 4 | 1077 ms | 1590 ms | 10266 ms | BBBBBBB |
  | 13:18:54 | answered | 4 | 1816 ms | 2614 ms | 8404 ms | BBB |
  | 13:19:50 | answered | 9 | 727 ms | 1093 ms | 9376 ms | BBBB |
  | 13:20:27 | answered | 19 | 1585 ms | 1950 ms | 10535 ms | BB |
  - Every answered request passed strict ownership (the bot echoed the tag each time).
  - `turns` is `B` in every poll while the reply is produced: the backend does report busy during a reply (the open diagnostics question from the BDK fix round).
  - **Open:** the 07:42 request was dropped by the client after 10.3 s. Whether that was the user, the iPhone or a Siri/HomePod limit is unknown; a later answer took 10.5 s and was spoken. The wait-limit probe (DESIGN §7.6) answers this.
  - Short questions (2–4 characters) are consistent with the cut-off problem below, but the log stores no text, so this is not proof.
- **Problems found (next phase, DECISIONS item 19):** mixed-script phrases are unreliable on a Chinese HomePod; a pause cuts the question off and sends it; after the answer people expect to keep talking.
- **Also to document in the README:** HomePod can take minutes to a day to learn a new or renamed Shortcut (it then says it found web results); `.local` worked, with an IP address as the fallback.

## 2026-10-22 — Claude: takeover, next phase started

- Claude now leads design and development and works with Felix directly (DECISIONS round 5). Baseline checked: `npm test` 163 passed, `npm run typecheck` clean, gateway running from the new folder.
- **Next:** DESIGN §16–§18 (phrase table, cut-off questions, conversation mode) with a device-experiment plan; then implement §16, which needs no device results.

## 2026-10-22 — Claude: voice UX phase 1 (offline) — ownership fix, phrase rule, lab

**Done** (all offline: no bot messages, no signing, no device actions; `npm test` 186 passed, typecheck clean)
- **Codex re-review of the BDK fix round** ([review](reviews/bdk-fix-round-rereview.md)): R1 (blocker) and R2 fixed in f3f87f2.
  - R1: a page that failed after an earlier page of the same poll could drop O2/O3/O5 evidence. Entries now count as soon as their page arrives. Tests fail on the old code.
  - R2: logged error names come from a fixed list.
  - **The gateway on Felix's Mac still runs the old code until it is restarted.**
- **Turn-tail diagnostic** (d6c3e9f, 1e84429): after each answer, the gateway watches the session with GETs (≤ 30 s) and logs `turn-tail` with `idle_after_ms` (or `timeout`) and counts of other activity. It never affects replies. Felix's normal use of "家庭助手" now measures how long a turn stays busy after its answer (input for DESIGN §18.3).
- **DESIGN Part 2 (§16–§19), v8.1:** phrase rule, cut-off questions, conversation mode, device experiments. Reviewed by Codex ([review](reviews/design-review-v8.md)) and Grok ([review](reviews/design-review-v8-grok.md)); all blockers accepted; changes listed in DESIGN §15.
- **Phrase rule (DESIGN §16)** (3e17a61, 1e84429, 8b08531):
  - A Siri phrase may only use the letters of its Siri language, and may not start with "问". Other leading command words are advice.
  - A phrase must differ from the user's other usable Homebot Shortcuts, except the one it replaces.
  - Defaults: zh-CN "家庭助手" → "我家助手" → "居家助手"; English "House Butler" → "Homebot" → "House Helper" (Q16-1 open); then the bot's own name when it fits.
  - The setup page asks for the HomePod's Siri language and says where to find it. README updated.
- **Lab (DESIGN §19)** (c3fff2a, 8b08531): `homebot shortcut build <bot> --lab` makes "家庭实验", a looping Shortcut. `homebot start --lab` serves `/v1/lab` (lab tokens only; never contacts a bot). `homebot lab use E1..E7` picks the experiment; `homebot lab report` prints the results. What is said is matched against the expected sentence and discarded; the log stores no speech text.
  - **Unverified:** the loop's plist (Repeat, If, Get Dictionary Value, variables) follows public action definitions (ScPL, ShortcutsBench). It has passed `plutil -lint`, but has not yet been checked against an Apple export or imported anywhere. The Mac dry run checks it.

**Codex milestone review** ([review](reviews/milestone-voice-ux-1-review.md)): 1 blocker, 7 should-fix, 3 nits; all accepted and fixed (DESIGN §15, v8.2), `npm test` 192 passed.
- B1 (0898727): the R1 fix let a poll with a failed page accept a reply before the remaining pages were read. A reply is now accepted only after a complete poll. The test fails on the old code.
- S1, S2 (b61cd7c): phrase uniqueness is enforced inside the token lock for every kind; a replacement keeps its phrase, and the setup preview matches the build.
- S3–S7 (a671300): `/v1/lab` always answers JSON with a spoken line; runs have an end state; E1b split from E1; run ids validated; stricter sentence matching; E5 is six steps.
- **Codex re-review** ([re-review](reviews/milestone-voice-ux-1-rereview.md)): B1, S1, S4–S7 and the nits fixed; two gaps closed afterwards (`npm test` 193 passed): a replacement now keeps its phrase when only advice applies (S2), and `/v1/lab` without `--lab` tells a lab token that the lab is off and stops (S3).
- Plist check: the Repeat, Get Dictionary Value and Get Contents of URL parameters match Apple's own gallery samples on this Mac. No Apple sample has If, Set Variable or Stop This Shortcut, so those still need the Mac dry run.

**Needs Felix** (superseded by the next entry)
1. **Restart the gateway** so the R1 safety fix and the turn-tail diagnostic run (no sound, no bot message). Claude can do it if Felix agrees.
2. **Sign the lab Shortcut** (Apple's signing service) and a **Mac dry run**: import "家庭实验" into Shortcuts on the Mac and run E1/E4 there (the Mac speaks; no HomePod). This checks the loop before any device time.
3. **Device session:** import "家庭实验" on the iPhone at least a day before the HomePod part; then E1, E1b, E2–E7 (HomePod speaks; ~20 min timebox).
4. Questions: **Q16-1** English phrase ("House Butler" default, "Homebot" alternative?), **Q16-2** languages for the next release (recommended: en + zh-CN now; zh-TW/yue-HK next), **Q18-1** conversation mode opt-in while experimenting, **Q18-2** end words, **Q18-3** follow-up idle wait (stays 0 until measured).
5. Revoke the pending "Homebot 等待测试" (mixed-script name; lab E7 replaces it)?

## 2026-10-22 — Claude: work ahead of the device session (Felix: "do everything that doesn't need me")

**Done** (`npm test` 205 passed, typecheck clean, check:ui OK)
- **Gateway restarted** on Felix's Mac with the current code (no sound, no bot message): the B1 ownership fix and the turn-tail diagnostic are now live. Normal use of "家庭助手" now logs `turn-tail` lines for Q18-3.
- **Codex milestone review and re-review** of voice UX phase 1: all findings fixed (entries above; reviews in docs/reviews/).
- **First-run review of the setup page** in a browser, on the offline demo (`node scripts/dev-setup.ts`: fake Grok Bot API, throwaway home; no real accounts). Screenshots of every step went to Felix (not committed). Fixed: the wait-test option is hidden unless the gateway serves it; no QR link for an unsigned Shortcut; Siri language names follow the page language; the signing note explains why signing is needed and how to turn it on; README status updated with the 2026-10-22 device result.
- **Conversation mode (DESIGN §18) built, opt-in, CLI only:** `homebot shortcut build <bot> --conversation`. Every answer still passes strict ownership; the follow-up idle wait exists but stays 0 (Q18-3). It shares the lab Shortcut's loop, so the lab's Mac dry run also checks its plist.

**Needs Felix** (unchanged items carry over)
1. **Sign and dry-run on the Mac:** approve calling Apple's signing service for "家庭实验" (and optionally a conversation Shortcut "我家助手"); import on the Mac and run E1/E4 there.
2. **Device session** (HomePod speaks): import "家庭实验" on the iPhone a day ahead; then E1, E1b, E2–E7.
3. **Questions:** Q16-1, Q16-2, Q18-1, Q18-2, Q18-3.
4. Revoke the pending "Homebot 等待测试"?
5. ~~**Open product question (new):**~~ *(Answered 2026-10-23, DECISIONS item 24: consent switch on the page.)* signing is gated by `HOMEBOT_ALLOW_SIGNING=1`, so a new user can't finish setup from the page alone. Proposal: an explicit consent checkbox on the page ("send this Shortcut to Apple to sign it") instead of the environment variable.


## 2026-10-23 — Claude: setup page rebuilt with beUI (DECISIONS item 20)

**Done** (`npm test` 209 passed, typecheck clean, check:ui OK)
- **New setup page** (45351b9, e64da18): React 19 + Tailwind v4 in `web/`, every control a beUI component (MIT; license kept). Vite builds it into `src/setup-ui/`, which stays committed, so users still install and build nothing.
  - Five steps with a rail (wide screens) or a progress bar (phones): Account → Language → Bot → Shortcut → iPhone. A returning user lands on the first unfinished step, or on the Shortcuts tab once a Shortcut works.
  - The Shortcut step shows the exchange as its headline: "Hey Siri, <phrase>" in Siri's language and Siri's question. Phrase alternatives are one tap; problems show inline; advanced options (replaces, address, wait test) fold away.
  - Feedback: stateful buttons (saving, done, try again), toasts, confirmation dialogs for revoke / remove / turning off reply checking, light and dark appearance from the system.
  - Same API and the same rules as before: strict-echo opt-out needs a confirm, the wait test shows only while the gateway serves it, no QR link for an unsigned Shortcut, Siri language names follow the page language.
- **CSP:** still same-origin only. The page response adds a fresh per-load nonce for the `<style>` elements motion inserts; no `'unsafe-inline'`, no inline scripts, no `data:` URLs (the QR code is SVG paths). Tests cover the nonce, the served files and that no page source renders HTML.
- Checked in the in-app browser on the offline demo (`node scripts/dev-setup.ts`): the whole new-user flow in English and Chinese, light and dark, desktop and phone width; no console errors. Screenshots went to Felix (not committed).
- Not checked: the signed path (QR code and download) on the demo, since signing calls Apple's service; it uses the same API calls as before.

### Same day, second round — fluid motion, menus, languages (DECISIONS item 21)

**Done** (`npm test` 210 passed, typecheck clean, check:ui OK)
- Fluid hover and sliding selection on the view switch, step rail, menus and phrase chips. Page language and appearance are icon menus in the header. The title carries the Grok Bot face (blinks, glances) and Homebot's Siri orb, both centred on the text's capital-letter midline (measured: within 0.02 px at 28 and 64 px). Apple's own Siri icon is not used (Apple's trademark rules).
- The Siri / iPhone / bot / "replaces" lists are portal menus: they are no longer clipped by the card and they scroll.
- Account step: Cursor mark + "Cursor dashboard" link (underlines on hover) and a "Create a key" button.
- Layout: on wide screens the content sits a little above the middle of the window.
- Review fixes (Codex review of 45351b9, Grok review): consent for "reply checking off" is per form; Build waits for the preview of the current inputs and the preview reruns when token states change; a replacement request applies once; the QR link can be renewed; a revoked Shortcut or removed bot clears the iPhone step; delayed navigation stops when its step is gone; an older background refresh no longer overwrites a newer change; errors follow the current page language; menus and the confirm dialog have accessible names and descriptions; focus moves to the new step's title.
- Checked in the in-app browser on the demo: menus open, scroll and pick; theme switch; collapsibles and the confirm dialog work under the CSP (Grok's CSP "blocker" did not reproduce: CSSOM writes are allowed); the iPhone step in German; revoke clears the iPhone step; phone width; no console errors.
- iPhone setup steps in 11 languages. Labels checked against the iOS 26 tables in macOS 26.6 (WorkflowUI, Home, AssistantServices); **not yet followed on a phone** in any language but English.

**Needs Felix**
- Confirm the Cursor dashboard URL for User API Keys (`https://cursor.com/dashboard?tab=integrations`).
- More Siri languages are a product decision (DESIGN §16): each needs phrase rules and a reply catalog.

### Same day, third round — one language table, eleven page languages, polish (DECISIONS item 22)

- Page, iPhone and Siri language menus come from `LANGUAGES` in `src/core/lang.ts`. The page has a catalog for each of its 11 languages (`web/src/i18n/`); the nine new ones are machine drafts checked against the iOS 26 tables, **not reviewed by native speakers**.
- Grok Bot's official app icon in the title and on bot rows. No font-weight change on hover or selection. Folding rows and their contents align with the cards (measured: every block at the column's edges).
- The Siri orb no longer shows as a square while the step slides in (clip-path), and the Shortcut preview no longer flashes "…" before its first answer (first request immediate, bubbles appear with real text).
- Buttons no longer grow on hover (beUI's 1.02 scale removed): hover changes colour only. Checked with the real pointer on the demo: header, rail, bot rows, folding rows, buttons and menu options keep their size, position and font weight.
- Checked in the in-app browser after a gateway restart: the page language menu lists all 11 languages in table order; each language renders with no clipped text and no sideways scroll (German and Russian screenshots looked at). `npm test` 210 passed, typecheck clean.
- Grok review of round two: six should-fix and five nits, all fixed (segmented-control arrow focus, Tab out of a menu, menus scroll only themselves, icon menus announce their value, a replacement request applies once, overlapping refreshes and language changes keep the newest).

### Same day, fourth round — HomePod Siri in eleven languages, Homebot mark (DECISIONS item 23)

**Done** (`npm test` 211 passed, typecheck clean, check:ui OK)
- The HomePod Siri menu offers the same eleven languages as the page and iPhone menus. Each has a phrase row, spoken system messages, envelope text, end words and the wait-test sentence; the preview's "Hey Siri, …" line follows the Siri language. Tokens made for older English variants keep working.
- Homebot mark (header and favicon) and a calmer Siri orb: one slow conic light in four hues; the mark is lit from the bottom edge, its eyes glance and blink.
- Secondary buttons rest in muted text and light up on hover (their hover had been a no-op).

**Needs Felix**
- Try one new-language Shortcut on a HomePod set to that language before relying on it; none of the new phrases has been tried on a device.
- The nine new spoken catalogs are drafts (Claude, cross-checked with Grok), not reviewed by native speakers.
- Portuguese (Brazil) and Korean: HomePod Siri support unconfirmed (Apple's pages list none); iPhone Siri supports both.

### Same day, fifth round — no terminal for users; signing consent on the page (DECISIONS item 24)

**Done** (`npm test` 212 passed, typecheck clean, check:ui OK)
- `HOMEBOT_ALLOW_SIGNING=1` is gone. The Shortcut step has a "Sign with Apple" switch: off for a new user, it records the user's consent (`settings.appleSigning`), stays on for later builds and can be turned off again. When it is off the page says iOS won't import the Shortcut until it's signed. A build that asks to sign without consent is refused with 403 `signing-consent` before a token is issued. `--sign` on the CLI records the same consent. This answers open product question 5 of 2026-10-22.
- Grok review: three findings, all fixed. (1) Make Shortcut now sends what the switch shows, even while its save is in flight. (2) Settings writes run under the config lock against the current file, and a response reads the consent last, so a language change can't paint the switch back. (3) `--sign` records consent only after the build passed its checks. Tests added for the last two.
- The offline demo (`scripts/dev-setup.ts`) now uses a fake signer, so turning the switch on there never contacts Apple. Checked in the in-app browser: switch off by default with the warning, on after a click, a build then went through the fake signer and showed "is ready".

**Not yet tried:** signing started from the page switch on a real Mac (needs Felix's approval, as every call to Apple's signing service does).

**Next, planned (needs Felix's decisions first):** start Homebot without Terminal, and an agent setup prompt in the README.
- Research (Grok, `.agent-logs/no-terminal-packaging-grok.md`, sources cited there): ship a Mac app per architecture that embeds the official Node binary and Homebot's sources with a small launcher. It opens the setup page, registers itself to keep running after login, and keeps the Mac from idle sleep while serving. Node's single-executable apps don't fit Homebot's file layout on Node 24; Electron/Tauri add a second web runtime for no gain.
- Since macOS 15, an app that is not notarized can be opened only through System Settings → Privacy & Security → Open Anyway (Control-click → Open no longer works). A click-only first launch needs Apple notarization: Apple Developer Program (99 USD a year), a Developer ID certificate, the hardened runtime with JIT entitlements for the embedded Node.

**Needs Felix**
- ~~Q24-1~~ Answered (DECISIONS 24): no notarization; un-notarized app plus an "Open Anyway" guide.
- ~~Q24-2~~ Deferred by Felix: one device test (Chinese and English) once the product is finished.

## 2026-10-23 — Claude: Swift S1 — `HomebotCore` (DESIGN §20.9 S1, v9.2)

**Done** (commits `affb716` … this entry; `swift build`, `swift test` 169 tests in 19 suites passing three times in a row, universal `swift build -c release --arch arm64 --arch x86_64` OK; TypeScript `npm test` unchanged at 212)
- Rules first: DESIGN §20.4–§20.6 rewritten as frozen rules (credential generation, bot-set tokens T0–T6, entry rules 1–5, activity A1–A6) and reviewed by Codex xhigh (17 points, all folded in, v9.1).
- `mac/Package.swift`: library `HomebotCore` plus a Swift Testing target (Swift 6, strict concurrency, macOS 15). `mac/spike/` untouched.
- Ported modules: home and file rules (0700/0600, atomic writes, kernel `flock` lock, git work-tree refusal), config/state/token stores (actors), bot lifecycle with one-step `admit`, entries and the strict reply-ownership rule, envelope, speech, languages and phrase catalogs, conversation runs (pinned key and session, input fingerprint), Shortcut builder and signer wrapper, BDK client and cold sync, credentials (§20.4), JSONL log.
- Golden tests compare Swift output with the TypeScript output (`scripts/swift-golden.ts`); catalogs are generated from the TypeScript source (`scripts/swift-catalogs.ts`). An in-process fake of the Grok Bot API backs the client tests.
- `mac/PORTING.md` maps each of the 212 TypeScript tests to its Swift test, to S2/S3, or to "dropped, reason".
- Codex adversarial review of the Swift code (gpt-6-astra high, `.agent-logs/s1-swift-review-codex.md`): 14 findings (3 blocking). 13 verified and fixed with regression tests (`c051a67`); details in DESIGN §15 v9.2.
- Optional Grok pass (`.agent-logs/s1-swift-review-grok.md`): stopped by the coordinator after more than 27 minutes. It had started on the pre-fix code and its partial output names no defect.

**Open risks**
- Codex finding 4: cancelling the HTTP request does not yet cancel a conversation step's shared work. Deferred to S2 with AskService (no HTTP listener exists in S1, so nothing can trigger it yet).
- The exact `backendUrl` string the BDK writes for Cursor's API is taken from the S0 package reading, not from a real login file (that file is never read by agents).
- Phrase and message catalogs in the eleven languages are generated from the TypeScript tables and were not reviewed by native speakers.
- The x86_64 slice builds with a deprecation warning for the macOS 27 SDK; Rosetta launch was checked in S0 only.
- Backup exclusion of `Activity/` is still unverified (the activity store is S2).

**Next:** S2 gateway (listener, AskService with cancellation, activity store, CLI import).

**Needs Felix:** nothing for S1.

## 2026-10-23 — Claude: Swift S2 — gateway, activity, CLI, importer (DESIGN §20.9 S2, v9.3)

**Done** (commits `d0b5c72` … this entry; `swift build`, `swift test` 306 tests (242 core + 64 gateway/CLI) passing three times in a row, universal `swift build -c release --arch arm64 --arch x86_64` OK; TypeScript `npm test` 213 passed, typecheck clean)
- `HomebotGateway`: the LAN listener on Hummingbird 2.28.0 (Apache-2.0; swift-nio 2.104.0, swift-nio-extras 1.35.1, swift-log 1.16.2), `voice.ts` and `downloads.ts` ported rule by rule; AskService with deadline and disconnect cancellation (also of a conversation step's shared work); conversation runs, `/v1/bots`, the entry flow, run pinning; `/v1/health`, `/dl/`, `/v1/probe-wait`, `/v1/lab`. Owner lock and a 0600 control socket (A5); artifact sweep while serving.
- Activity store (§20.6) on the system SQLite: 0600 files, backups excluded and checked with `tmutil isexcluded` (`[Excluded]`, in a test on a temporary folder); Clear removes the database with `-wal`/`-shm`; no tokens, keys or echo tags. Keep-awake service (IOPMAssertion + ProcessInfo activity).
- `homebot` CLI on swift-argument-parser 1.8.2: start (headless), status, doctor, bot, token, shortcut build, log, account, import, lab, on the same stores under the same locks.
- Importer from `~/.homebot` (§20.11) with the `MOVED` marker; the TypeScript CLI refuses a moved folder and its `start` now writes `gateway.pid`. Tested only on fixtures and private copies; the live `~/.homebot` was never touched.
- Parity: the Swift gateway gives the TypeScript gateway's answers (status, content type, body) to 24 Shortcut-shaped requests on the same fake transcripts, after importing a folder the TypeScript CLI made (`scripts/swift-gateway-golden.ts`).
- `mac/PORTING.md`: no S2 rows left open; intended differences listed.
- Codex adversarial review (gpt-6-astra xhigh, `.agent-logs/s2-codex-review.md`): 16 findings, 15 verified and fixed with regression tests (`1f41935`), 1 not reproduced but guarded (DESIGN §15 v9.3).
- Codex smoke run (`.agent-logs/s2-codex-smoke.md`): headless gateway on 127.0.0.1:18787 with the fake Grok Bot (`scripts/fake-grokbot.ts`): a curl Shortcut request answered `现在三点。` as `text/plain`, a wrong token 401, a v2 start JSON, status/log without secrets, a second start refused, clean SIGINT stop. All 8 steps passed. Ports 8787/8788 untouched.
- Grok was not used (Felix's rule for S2).

**Open risks**
- Felix's running TypeScript gateway predates `gateway.pid`; for it the importer relies on the port check (8787/8788 on 127.0.0.1). Stop it before importing.
- The control-socket stop no longer waits for a request in flight; a request already accepted is answered after stop (harmless, untested timing).
- Message and phrase catalogs in the eleven languages are still not reviewed by native speakers.
- The x86_64 slice builds with the macOS 27 SDK deprecation warning; launch under Rosetta was checked in S0 only.

**Next:** S3 UI.

**Needs Felix**
- The cut-over of your Mac is not part of S2. When you want it: stop the TypeScript gateway, then run `.agent-logs/felix-migrate.sh` yourself (dry run first, asks before importing; copies the old key without printing it). Agents have not run it.

## 2026-10-23 — Claude: Swift S3 — Homebot.app user interface (DESIGN §20.9 S3, v9.4)

**Done** (commits `875e270` … this entry; `swift test` 336 tests (242 core + 64 gateway/CLI + 30 UI) passing; universal `OUT=build/release mac/scripts/build-app.sh` builds `Homebot.app` with an x86_64 + arm64 app and CLI, `codesign --verify --strict` OK)
- `Homebot.app` from the command line, no Xcode project: `mac/scripts/build-app.sh` (universal release, or `DEBUG=1`), CLI at `Contents/Helpers/homebot` (case-insensitive volumes, §20.2). `mac/scripts/dev-app.sh` runs it in dev mode against the fake Grok Bot.
- The gateway runs in the app process; closing the window keeps it in the menu bar; Quit asks first. Menu bar item: running state, last outcome and time (never question text), open, quit.
- Setup flow (Account with BDK login detection and "use an API key instead", Language, Bot with name typed twice, just-created check, renamed-bot notice, session id and Create under Advanced, strict-echo opt-out with confirmation, rename; Shortcut with live preview, chips, inline problems, the "Sign with Apple" consent switch and options; iPhone with Show in Finder, a one-time Core Image QR link and the steps in the iPhone's language), Home (status with a fix per problem, activity with full text, outcome and timings, Clear with confirmation, the plain-HTTP note), Shortcuts list (states, revoke, replace, language-differs notice), Settings (languages, keep awake, open at login via SMAppService with the translocation refusal, page language, appearance).
- String Catalog: 238 keys × 11 languages generated by `scripts/swift-ui-strings.ts` from `web/src/i18n/*.ts` + `mac/App/app-strings.ts`; a test checks every key and placeholder in every language.
- Liquid Glass buttons and toasts on macOS 26, system styles on macOS 15 (by availability; not run on a macOS 15 machine). Mark, Siri orb and Grok Bot icon drawn in SwiftUI; still under Reduce Motion; page slides and disclosures fade under Reduce Motion. App icon rendered from the mark.
- Dev mode: temporary folder (or `--dev-home`, never a real Homebot folder), 127.0.0.1:18787, Grok Bot API only on loopback and never 8787/8788/18787, fake signer, in-memory login item, `--dev-seed/--dev-page/--dev-lang/--dev-appearance`.
- Screenshots: `.agent-logs/s3-screens/INDEX.md`: 9 pages × en, zh-Hans, de, ja × light, dark (72 shots), web page shots and an honest comparison.
- Codex adversarial review (gpt-6-astra xhigh, `.agent-logs/s3-review.md`): 6 findings, all verified and fixed with tests where testable (`f10ca05`, `4c9c71c`).
- Own checks fixed: the window did not open at launch (`defaultLaunchBehavior(.presented)`), `scutil` ran on the main actor every poll, the icon's mark was drawn off centre, disclosures and Settings rows did not share edges, "Grok Bot" could wrap away from its icon (coordinator's note), long error toasts vanished too soon.
- Grok was not used.

**Smoke run**
- Codex computer use was blocked: "Computer Use was not approved to use Homebot" (`.agent-logs/s3-smoke.md`). It needs an approval in Codex's Computer Use app (Needs Felix).
- Claude drove the dev build instead (background accessibility, real pixels checked with `screencapture`): BDK login detected → Account done → Language → Bot: mismatch shown, a typo typed twice gives the "created an empty bot" error and adds nothing, "homebot" added and Shortcut/iPhone opened. Stopped there because someone moved and resized the window (Felix may have been at the Mac). The rest of the flow is covered end to end by `--dev-seed activity` (key, bot, signed fake Shortcut, three requests answered through the gateway by the fake Grok Bot, shown on Home) and by `HomebotUITests` against the fake Grok Bot API.
- Hover: code changes colour only; selection measured (rail items keep the same frame); hover with a real pointer not measured.

**Open risks**
- Not run on macOS 15 (only availability-checked fallbacks) or under Rosetta.
- Non-English app-only strings are Claude's drafts, not reviewed by native speakers.
- Secure text fields can't be typed into by background automation; a full click-through smoke still needs Codex's Computer Use approval or a foreground session.
- `--dev-home` with a long path makes the control socket path too long (the gateway then doesn't start; dev only).

**Next:** S4 single entry.

**Needs Felix**
- Approve Homebot in Codex's Computer Use app if you want Codex to click through the dev build (`mac/scripts/dev-app.sh`).
- Look at `.agent-logs/s3-screens/INDEX.md` and say what should change in the look.

## 2026-10-23 — Claude: Swift S4 — the entry Shortcut, one phrase for a set of bots (DESIGN §20.5, §20.9 S4, v9.5)

**Done** (commits `aa6abb1` … this entry; `swift test` 364 tests (252 core + 80 gateway/CLI + 32 UI) passing; universal `mac/scripts/build-app.sh` builds `Homebot.app` x86_64 + arm64, `codesign --verify --strict` OK; golden `entry-en`/`entry-zh` match and pass `plutil -lint`)
- Builder: `entryShortcut` (the §18.2 loop on `/v1/ask` without a `bot` field), `ShortcutKind.entry` (1–9 bots, token mode `entry`), `Profile.entry` named from the §16 phrase table (zh-CN 家庭助手 → 我家助手 → 居家助手; zh-TW 居家助理; ja うち助手; en House Butler / Homebot / House Helper; a Latin name is refused where the script forbids it).
- Gateway choosing per §20.5 plus the S4 amendments in DESIGN (Mandarin sound matching, always asked back; every name competes for the margin; session-checked pin; chain-wide set edits; `confirm` outcome). Nothing is sent to a bot while choosing.
- Offline end to end: `HomebotTestSupport/ShortcutRunner` plays the built Shortcut file against the gateway and the fake Grok Bot (`EntryFlowTests`, 13 scenarios: one bot, clear choice, by number, mis-heard Chinese 拆姐诗 and English names, 厨房/出房 by sound, no match, alias, "no" after a choice, silence, step cap, set edit, follow-up stays on the chosen bot).
- App: Shortcut step "One bot / All my bots" with the bot checklist (menu numbers, at most 9), entry phrase, exchange preview with the "which bot?" turn, number-only names and an "untested on a HomePod" note; Shortcuts list offers "One Shortcut for all my bots" while there is none, shows an entry Shortcut's bots and edits its set (T4). Per-bot Shortcuts stay; an entry Shortcut replaces by default only an entry Shortcut it covers. 13 new strings × 11 languages.
- CLI: `homebot shortcut build --entry [--bots a,b]` (prints what Siri will say and number-only names), `homebot token bots <id> <a,b>`, `homebot bot alias <key> [names…]` (at most 5).
- Screens: `.agent-logs/s4-screens/INDEX.md` (en, zh-Hans × light, dark; 16 shots). Dev-only `--dev-scroll-bottom` added for long pages.
- Codex adversarial review (gpt-6-astra xhigh, `.agent-logs/s4-codex-review.md`): 7 findings, all verified and fixed with regression tests (`979040f`). Grok was not used.

**Open risks**
- Pre-existing flaky test, not from S4: "follow-up wait: no wait (0) or a turn that stays busy answers busy and sends nothing" (`AskOwnershipTests`) failed 1 of 5 repeated core runs; one earlier core run hung. Timing-dependent; worth a look before S5.
- The Edit bots sheet was not captured as a screenshot (tested in `AppModelTests`); in zh-Hans the entry row's date is truncated next to the badge.
- New strings in 10 languages are Claude's drafts, not native-reviewed.

**Next:** S5 release.

**Needs Felix (device test, S6)** — none of this has run on a HomePod:
- Whether the extra spoken round trips (menu, choice, confirm) stay inside Siri's limits (§19).
- How an Ask for Input with the numbered menu as a long prompt plays on HomePod (U6).
- How bot names survive HomePod transcription (Chinese names, Latin names on a Chinese HomePod, numbers as the fallback).
- Whether 家庭助手 (and 我家助手, 居家助手) start the Shortcut reliably on a Chinese HomePod.
- Keep the per-bot Shortcuts until the entry Shortcut works for you; then say whether the app should still offer per-bot ones first.

## 2026-10-23 — Claude: Swift S5 — release readiness (DESIGN §20.9 S5, v9.6)

**Done** (commits `643ea42` … this entry; nothing pushed or published)
- Tests: `swift test` from `mac/` runs all three test targets and prints one summary line each: 252 core + 80 gateway/CLI + 48 UI = **380**. The full suite passed 20 times in a row on the final code (no flake, no hang).
- Flaky test root cause ("follow-up wait: no wait (0) or a turn that stays busy…", 7 failures in 100 core runs): near the end of the allowance the remaining time under 1 ms rounded to a zero sleep, so the wait loop read the busy turn in a tight loop and ran out of scripted pages. The loop now always sleeps at least 1 ms and never past the allowance; the test checks that the wait polls at the poll interval (0 failures in 200 runs).
- Hang root cause (1 of 13 full runs): `StoreTests` "process death" called `Process.waitUntilExit()` after an `await`, on another thread than `run()`; Foundation posts the exit to the launching thread's run loop, so the wait never returned (confirmed with a stack sample). It now waits on the termination handler, with a one-minute time limit.
- zh-Hans entry Shortcut row: the bot list truncates (full text on hover), the language and date never do (`.agent-logs/s5-screens/list-entry-zh.png`).
- Release: `mac/VERSION` (0.5.0) is the one version source; the build number is the commit count. `mac/scripts/release.sh` refuses a dirty `mac/`, builds universal, signs ad hoc inside out (CLI, then the bundle, no `--deep`), sets file times to the commit time, checks `lipo` (x86_64 arm64), `vtool` minos 15.0, `codesign --verify --strict` (CLI) and `--deep --strict` (app), packs with `ditto -c -k --keepParent --norsrc --noextattr`, verifies the unpacked zip again and writes `mac/build/Homebot-<version>.txt` (hashes, signature, `spctl`). `spctl --assess` says **rejected**, as expected for an un-notarized app.
- Quarantine: a zip with `com.apple.quarantine` unpacked with `ditto -x -k` puts the attribute on every file; opening the copy shows the real "Not Opened" dialog (`docs/images/install/not-opened-en.png`). A real translocated launch could not be made: `SecTranslocateCreateSecureDirectoryForURL` returns EPERM here and only LaunchServices translocates after Open Anyway, which is Felix's click. Placement was checked on real copies instead (`/Applications/Homebot-S5test.app` → applications, a downloads-like folder → elsewhere; both removed); the translocated path and the refused login item are covered by tests.
- First run in the app: if `~/.homebot` exists and the app has no bots or tokens, a card explains what was found (bots, Shortcuts, whether a key is there, never the key) and imports only on **Import** (sessionless pre-M4 tokens can be kept one by one; Not now hides it; Settings keeps an Import row). The app stops its own gateway, runs `TSImport.run`, starts the gateway again; a running old gateway is refused with nothing changed. A "move to Applications" notice (danger when translocated, warning elsewhere); a Home card for Open at login and Keep this Mac awake. New Help page with the install steps. 31 new strings × 11 languages. Proved in the real app process with the dev fixture (`--dev-legacy --dev-click-import`): the old Shortcut token got HTTP 200 `text/plain` after the import. 10 new UI tests (`FirstRunTests`).
- Docs: `docs/INSTALL.md`, `docs/INSTALL.zh-Hans.md` (real screenshots; the Open Anyway picture is pending), README rewritten for the native app (eleven languages, "Personal Content", privacy, a copy-paste AI agent prompt through `Homebot.app/Contents/Helpers/homebot`, a short TypeScript reference section), `docs/ACCEPTANCE.md` (Chinese acceptance pack for Felix).
- Codex adversarial review (gpt-6-astra xhigh, `.agent-logs/s5-codex-review.md`): 6 findings, all verified and fixed with regression tests (`2d43c8b`): Quit now waits for an import in progress (it could leave the old folder marked as moved with nothing copied); after the import the key is checked with Grok Bot and a rejected key or a gateway that cannot start again is said instead of "imported"; Settings' Import reopens the card with its keep choices; a dev run never probes 8787/8788 from the importer and refuses a linked `user/.homebot`. No finding in the wait-loop fix, the release script, placement or the strings. Grok was not used.

**Notes**
- The dev import fixture uses ports 18927/18928: 18797 is held on this Mac by an unrelated HomebotSpike.app (left alone).
- The first Codex run stalled reading stdin (`codex exec` in the background needs `</dev/null`); it was stopped and rerun once.
- Release build on the clean tree (commit `315f112`, build 149): zip about 28.3 MB, checks as above. Built twice from the same commit: the CLI binary is byte-identical, the app binary (and so the zip) is not; the manifest records the hashes. The script is repeatable, the app binary is not bit-for-bit reproducible yet (not investigated further).
- A crash (not Quit) in the middle of an import still leaves `~/.homebot/MOVED` behind with `"importing":true`; deleting that file makes the folder importable again (`docs/ACCEPTANCE.md`). Not automated: telling an interrupted import from a running one needs the owner lock and a look at the half-written store.

**Needs Felix**
- Click **Done** on the "Homebot.app Not Opened" dialog left on screen from the quarantine test (its copy is already deleted).
- Real Finder install with Open Anyway, including opening once from Downloads (translocated) to see the move notice and the refused login item; whether macOS asks a second time after Open Anyway.
- The Privacy & Security › Open Anyway screenshot (and a zh-Hans "Not Opened" one) for the install guide.
- The version number (0.5.0) and publishing the GitHub release (by hand).
- The cut-over (stop the TypeScript gateway, import) and the device checks: see `docs/ACCEPTANCE.md`, which also lists every open item from earlier phases.

## 2026-10-24 — Claude: Swift S7 — first-party look (Felix's UI feedback of 2026-10-24)

**Done** (UI only; product behaviour unchanged; nothing pushed; the installed app was not rebuilt or replaced)
- Root cause of "no Liquid Glass" and the mismatched sidebar/toolbar: SwiftPM wrote the deployment target as the SDK version (`LC_BUILD_VERSION sdk 15.0`), so macOS 26 ran the app with the macOS 15 window chrome. `scripts/build-app.sh` now records the SDK the app is really built with (`vtool -set-build-version macos 15.0 <sdk>`, then re-signs the binary before the icon step). Universal release build checked: both slices `minos 15.0 sdk 27.0`, `codesign --verify --deep --strict` OK; `release.sh` checks only `minos`, unchanged. Result: the floating Liquid Glass sidebar, glass toolbar items and the Tahoe window shape.
- Window (point 1): no custom canvas colour; pages sit on the window background, the page name is the toolbar title (as in Notes), content blurs softly under the toolbar (`scrollEdgeEffectStyle(.soft)` on macOS 26). Theme is now the system's semantic colours: label colours, the user's accent colour, system green/red/orange, `quaternarySystemFill` groups, `separatorColor`.
- Liquid Glass (point 2): `.glassProminent` (accent, no custom tint) and `.glass` buttons, grouped in `GlassEffectContainer` (`ActionBar`, `glassGroup()`), `.borderedProminent`/`.bordered` before macOS 26. Every macOS 26 API was checked in the macOS 27 SDK's swiftinterface and sits behind `#available(macOS 26, *)`.
- Setup steps (point 3): the floating card is gone; header (tile + title) and controls sit on the canvas. Inputs are System Settings-style grouped rows (label left, entry right; `Field`, `PickerRow`), with the strict-checking switch inside the bot group, the iPhone steps as one numbered group, and the buttons in one trailing action bar.
- Shortcuts (point 4): all Shortcuts are rows of one grouped list; the kind labels (old version, asks which bot, probe/lab) moved into the subtitle; each row keeps a slot per action (empty where it has none) and a status dot, so states and buttons share one column. Measured on the screenshots: every block on Home, Shortcuts, Settings and Bot spans the same x (750–1949 px at 2x).
- Home (point 5): a status view: the Siri orb with "Homebot is running / not running" and the address, three equal tiles (Grok Bot, Shortcuts, last request) with a fix on each problem, the frequent actions (Make Shortcut, Shortcuts, Settings), then Activity as one grouped list (full question and answer, then date · bot · Shortcut · step and the timings). Open at login and Keep awake are only in Settings ("This Mac"); Home shows a one-line hint linking there until Done, and a callout when the Mac is not kept awake.
- Sidebar (point 6): system sizes (13 pt, 32 pt rows, accent symbols); the selection is one quiet fill that slides between rows with `.snappy(0.24)`, the hover highlight glides with `.snappy(0.16)` (was springs of 0.5 s and 0.32 s). Colour only.
- No new strings. Tests: 380 pass (252 + 80 + 48); no UI test asserted on removed structure.
- Screenshots before/after, en and zh-Hans, light and dark, every page: `.agent-logs/s7-screens/INDEX.md` (one "before" capture failed: en-light-shortcut).
- Codex adversarial review (gpt-6-astra high, `.agent-logs/s7-codex-review.md`): 4 findings, all verified and fixed: long picker values could push a row past the column; Home showed keep-awake from the switch instead of the real state; activity timings could be cut by long names; VoiceOver lost the gateway failure text.

**Not verified**
- The hover glide and selection slide with a real pointer (screenshots are taken in the background, no pointer); the active-window look (all shots show the inactive window: grey prominent buttons, unaccented selection).
- macOS 15 (the fallbacks compile; not run).
- Other page languages than en and zh-Hans (layout uses wrapping and truncation, not fixed widths).
- A thin system separator stays under the toolbar on macOS 26 with the standard toolbar; hiding the toolbar background removed it but also the scroll-edge blur, so it was kept.

**Needs Felix**
- Reinstall the app when the orchestrator decides (the installed 0.5.0 still has the old build stamp and look).

## 2026-10-24 — Claude: Swift S8 — Home follow-up (Felix's screenshot of the installed app)

**Done** (nothing pushed; the installed app was not rebuilt or replaced)
- Button row removed (point 1). Settings is no longer a Home button (point 2); the app menu's **Settings…** (Cmd-,) now brings the window forward on the Settings page, as first-party apps do (checked in the dev build: the item carries ⌘, and opens the window on Settings).
- The three status tiles are buttons (point 3): Grok Bot opens Account, Shortcuts opens the Shortcuts list, Last request scrolls to Activity (it is not a button while there is no activity). A chevron marks them; hover and press darken the fill only. When a tile has a problem, the fix is the whole tile's action and its label is shown on the tile (Open Account, Make one): no nested buttons. VoiceOver reads "title: value" with the fix or destination as the hint.
- Make Shortcut is the toolbar's + button at the trailing end, in a glass button of its own (`ToolbarSpacer(.fixed)` on macOS 26, checked in the macOS 27 SDK; plain toolbar item before), on Home and the Shortcuts list, with tooltip and accessibility label (point 4). Home and Shortcuts now share one rule for where it goes (`AppModel.makeShortcutPage`).
- Bug: "Last request: None yet" next to answered requests. Root cause: `GatewayHost.status()` read the voice API's in-memory last request, empty after every restart. It now reads the newest record from the activity store (`ActivityStore.latest`), so Home, the menu bar and `homebot status` agree with the activity list and Clear empties both; `VoiceAPI.last` is gone. Test: HostTests "the last request comes from the activity store…" (restart on the same folder, then Clear).
- Bug: a green check next to "Not checked yet". Root cause: the tile's mark was `access != .rejected`, so unchecked counted as fine. Marks now come from `HomeStatus` (tested): green only for a checked state, orange for a problem, a grey minus for nothing to judge. The app now runs its read-only key check once at launch when the key is unchecked (`GET …/entries`, never a message); its result is dropped if another result arrived meanwhile (Codex finding). Tests: AppModelTests `launchChecksAnUncheckedKeyReadOnly` (exactly one GET, no posts), CredentialTests "a background check never replaces…", HomeStatusTests.
- Bug: Last request had no mark. All three tiles now always show one (answered: green; end word, silence, choice, new start: grey; failures: orange).
- Tests: 387 pass (253 + 81 + 53). Screens: `.agent-logs/s8-screens/INDEX.md` (en and zh-Hans, light and dark, the restart case, each click, hover; edges measured).
- Codex adversarial review (gpt-6-astra high, `.agent-logs/s8-codex-review.md`): 2 findings and a test gap, all verified and fixed: the scroll reader now wraps the page's scroll view; the launch check can no longer overwrite a newer result for the same key; the launch test asserts exactly one read.

**Not verified**
- Keyboard focus ring on the tiles with Full Keyboard Access (not driven); macOS 15 (fallbacks compile, not run).
- The "Not checked yet" grey state on screen (the launch check answers within a second against the fake bot; covered by tests).

**Notes**
- The Home hint "Make this Mac ready for Siri" still has its own Settings link until Done; it is the hint's action, not a general Settings entry. Remove it if Felix wants no Settings button on Home at all.
- The Shortcuts tile counts working asking Shortcuts; the sidebar badge counts every Shortcut not retired, so they can differ.
- In this session the dev window never presented at launch (S7's code behaves the same here), so screenshots open it through Settings…. Worth checking on the installed app: does the window open when Homebot launches?

## 2026-10-24 — Claude: Swift S8 follow-up — iPhone-step jump, toast width, language replacements

**Done** (nothing pushed; the installed app was not rebuilt or replaced)
- **Priority bug (b729be8): clicking Scan or AirDrop on the iPhone step moved the window content up, with no QR code or Finder window.**
  - Cause, step 1: the Shortcut file was gone. This is by design: `TokenStore.sweepArtifacts` deletes it once the Shortcut is in use (its token went active at the first ask), or when it was never used in time. So `builtFile` threw "gone" and the app showed an error toast.
  - Cause, step 2: the toast stack was a sibling of the page in a `ZStack`. When a toast appeared, the split view laid the detail out at the scroll view's full content height (AX: splitter 760 → 1594 pt). That pushed the page up and put the toast below the window, out of sight. Each click added a toast and moved the content again.
  - Fix: toasts are an `.overlay` of the detail and never size it. The same toast again replaces the one shown.
  - The iPhone step now reads the token state (`PhoneDelivery`):
    - AirDrop/Scan only while the file exists;
    - "“X” is on your iPhone: it has answered Siri" once in use;
    - "This file is gone… Make it again" otherwise.
  - Test: `WindowLayoutTests.toastsNeverGrowTheWindowContent` hosts `RootView` in a real 1060×760 window and adds three error toasts. It fails on the old layout and passes now.
  - The rename and edit-bots sheets present in their own sheet windows; no other sibling-in-`ZStack` overlays exist.
- **Toasts hug their content (9fee1ba):**
  - Each capsule is now its icon, text and padding, centred; before, it had a fixed width.
  - A long message wraps inside a 460 pt cap set on the stack.
  - The capsule is glass on macOS 26 and uses a material before that.
  - Test: `toastsHugTheirContent`.
- **Language replacements (5a6ee6e):**
  - `Flow.outdated` lists the Shortcuts that can be rebuilt: made for another Siri language, every bot still added, and no current-language replacement made yet.
  - On the Language step, the warning is now an action row ("“House Butler” speaks English. Make a version in 简体中文?"). Its primary button, "Make replacement(s)", runs `AppModel.makeReplacements` and goes straight to the iPhone step.
  - Replacements use the existing replace path: same bots, a replacement's phrase rules (DESIGN §16; an old phrase is kept only if it passes the new language's blocking rules, so 家庭助手 → an English default), and the user's signing choice.
  - The Shortcuts page row gets a one-click "Update to <language>". It replaces the old "Replace" link, and the "Built for …" badge now shows only while a replacement is on its way.
  - On the iPhone step, a segmented picker switches between Shortcuts made together.
  - The iPhone picker's note now says what it controls: the language of the "On your iPhone" steps; Siri and the Shortcuts use the Siri language. This is a new app key; the shared web `phoneNote` is unchanged.
  - Auto-retire was already built (T5: the old token retires when its replacement is first used), so the old Shortcut keeps working until the new one answers.
  - Tests: `LanguageReplacementTests` covers the offer rule, the two-bot batch build with the old ones still active, retire-on-first-use of only the used one, a single-row update, and that a normal build ends the batch.
- Codex review (gpt-6-astra high, `.agent-logs/s8b-codex-review.md`): 6 findings. All were checked against the code and fixed, each with a test:
  - "Make it again" for a Shortcut in use now makes a copy that replaces nothing. Before, it replaced the working one by default, so setting up a second iPhone would retire the first iPhone's Shortcut.
  - A replacement whose file expired unsent no longer hides the update offer.
  - Replacement runs are serialised (`AppModel.replacing`; the buttons and the Siri picker are disabled meanwhile), and a batch stops if the Siri language changes mid-run.
  - A late QR link is dropped if another Shortcut of the batch was picked.
  - Revoking the shown Shortcut of a batch moves the iPhone step to the next one.
  - Not changed (T5, older than this work): a replacement goes active, and its predecessor retires, when its first request is admitted, not when an answer is delivered. So a first request that fails can still retire the old one. Changing this is a gateway decision for Felix and the orchestrator.
- Tests: 394 pass (253 + 81 + 60).
- Screens: `.agent-logs/s8-screens/` (`phone-gone-*`, `phone-send-en`, `toast-*`, `lang-offer-*`, `lang-replaced-phone-en`, `shortcuts-update-*`).

**Not verified**
- The iPhone-step picker for two or more replacements on screen (covered by tests only).
- The "installed" state of the iPhone step on screen (covered by a unit test).
- A real iPhone import of a replacement.

**Notes**
- The "On your iPhone" steps follow the iPhone language, not the app language. With a Chinese app and an English iPhone, they stay English. This is intended, and the new note explains it.

## 2026-10-24 — Claude: Swift S10 — choose the app icon (Glow, Black, White)

**Done**
- Three icons, one geometry. They share the mark's roof and eyes (vector, `MarkDrawing`), Apple's icon grid (824 of 1024 points), the continuous squircle and the shadow.
  - **Glow** is the original and the default. It stays the bundle icon and is pixel-identical to before (max channel difference 3/255, blur noise).
  - **Black** drops Siri's light.
  - **White** is a white squircle with a black roof and eyes and a faint dark rim.
- Assets: `build-app.sh` runs `Homebot --render-icon <dir>`, which draws an `.iconset` per icon, and `iconutil` turns each into `Homebot.icns`, `Homebot-Black.icns` and `Homebot-White.icns` in Resources. All three are sealed with the bundle, and `codesign --verify --deep --strict` passes.
- How macOS lets a Mac app change its icon (checked against the macOS 27 SDK headers):
  - AppKit has no alternate-icon API. `setAlternateIconName` is in UIKit only, `API_AVAILABLE(ios, tvos)`.
  - `NSWorkspace.setIcon(_:forFile:)` was tested on a scratch copy of the dev build. It writes an `Icon\r` file and a `com.apple.FinderInfo` xattr into the bundle. After that, `codesign --verify --strict` fails with "resource fork, Finder information, or similar detritus not allowed"; non-strict verification still passes. It would also need write access to the installed app, and an update would drop it. Not used. Log: `.agent-logs/s10-seticon-test.txt`.
  - Chosen approach: `NSApp.applicationIconImage`. The bundle never changes.
- The choice is `appIcon` in `app.json`. An old or unknown value falls back to Glow.
- When the icon is applied:
  - in `applicationWillFinishLaunching`;
  - on every change in Settings;
  - each time the window opens (`AppModel.showInDock`). Found on screen: when the app goes back from `.accessory` to `.regular`, the new Dock tile starts with the bundle icon again.
- Settings › Appearance › "App icon": three thumbnails like System Settings' appearance swatches. The chosen one has an accent ring 2 pt outside the squircle and a primary label. Hover tints the ring only. Each thumbnail is a button with a name and the selected trait. Strings are in 11 languages (en/zh reviewed by Claude, others drafted).
- Where the chosen icon shows: the Dock tile and Cmd-Tab while Homebot runs with its window open, and the app's own alerts.
- Where it does not: Finder, Spotlight, Launchpad/Apps, Login Items, notifications, and a pinned Dock tile while Homebot isn't running. These keep Glow. The window closed means no Dock tile, as before. From launch until `applicationWillFinishLaunching`, the Dock tile can briefly show Glow.
- Tests: `AppIconTests` covers the default, back-compat decoding, the choice saved and read by a new model on the same folder, the variants' pixels (background, light, clear corners) and the dock image. 427 pass (65 + 87 + 275).
- Screens (`.agent-logs/s10-screens/`):
  - `icons-preview.png`: the three icons on light and dark, large and at Dock sizes; `preview.swift` makes it.
  - `settings-light.png`, `settings-dark.png`.
  - `dock-black.png`, `dock-white.png`, `dock-white-after-restart.png`.
  - `dock-white-after-reopen.png`: the bug before the fix. `dock-white-after-reopen-fixed.png`: after the fix.
  - `cmdtab-white.png`.
- Codex review (gpt-6-astra high, `.agent-logs/s10-codex-review.md`): no confirmed bugs. It flagged the activation-policy case as unverified, which is the bug found and fixed on screen above.

**Not verified**
- The Dock's tinted/clear icon styles (macOS 26) with a runtime icon. The bundle icon stays a plain `.icns` as before (no Icon Composer `.icon`, no dark or tinted variants).
- The installed app (not reinstalled here), macOS 15, and VoiceOver on the picker.
- A Dock tile plugin (`NSDockTilePlugIn`) could show the choice on a pinned tile while the app isn't running. It is not built: it runs inside the Dock process, and an ad-hoc signed plugin is likely refused there.

## 2026-10-24 — Claude: Swift S10 add-on — Home alignment, no Siri imitation (Felix's screenshot 18)

**Done**
- Home hero alignment: the hero row had a 12 pt inset of its own. On Felix's screenshot the orb started 20 px right of the Grok Bot tile. Now the hero icon, the tiles, the callout and the Activity card share one leading edge, measured pixel-exact at x = 716 in four captures (`.agent-logs/s10-screens/alignment.txt`).
- The fake Siri orb is gone.
  - Home shows the app icon the user picked (S10). It is drawn as the bare squircle, so its edge is the page's leading edge.
  - The running state's dot pulses softly with the system's own symbol effect (`symbolEffect(.pulse)`, still under Reduce Motion). It is orange when Homebot is stopped.
  - `SiriOrb` and the inline marks are removed.
- Facts checked:
  - No public API exists for Siri's orb or its animation.
  - Apple HIG (Siri): "Never impersonate Siri, attempt to reproduce the functionality that Siri provides, or provide a response that appears to come from Apple."
  - Apple's trademark guidelines: no Apple-owned graphic symbol, logo or icon without a written licence, and no imitation of Apple's trade dress. Product names may be used in text, referentially.
  - SF Symbols has a `siri` symbol (macOS 26 / SF Symbols 7). The system's `symbol_restrictions.strings` says: "This symbol may not be modified and may only be used to refer to Apple's Siri."
- Sidebar headline: "Talk to your Grok Bot with [siri] Siri."
  - The `siri` symbol is unmodified, in the text colour, and refers to Siri. On macOS 15 the name is plain text.
  - "Grok Bot" is plain text. xAI's brand guidelines allow its logos only "exactly as provided … without any alteration", and the inline icon was clipped to a squircle.
- Shortcut step illustration: Siri's line uses the `siri` symbol (`waveform` on macOS 15). The Siri-coloured glow along the card's bottom edge was removed.
- Dev flag `--dev-app-icon glow|black|white` for screenshots (AppEnvTests).
- Codex review (gpt-6-astra high, `.agent-logs/s10b-codex-review.md`): one P3 finding. VoiceOver could read "Siri" twice (the symbol, then the name). Fixed: the headline has a plain-text label (`Hero.plain`), tested in all 11 languages.
- Tests: 428 pass (66 + 87 + 275).
- Screens (`.agent-logs/s10-screens/`): `home-light-en`, `home-dark-en`, `home-dark-zh`, `home-light-white`, `home-dark-black`, `shortcut-siri-symbol-dark`, `shortcut-siri-symbol-light`.

**Not changed (for Felix)**
- The Bot step still shows Grok Bot's official icon (`GrokBotAvatar`), clipped to a squircle and tilting every 5 s. Under xAI's "without any alteration" rule this should be shown unaltered and still, or replaced by text.
- The Glow icon's light uses Siri-like hues. It is Homebot's own mark and stays as Felix asked.

**Not verified**
- The headline on macOS 15 (plain-text fallback, covered by the availability check only).

## 2026-10-24 — Claude: Swift S11 — live mark, Siri orb, brand header (Felix's screenshot 19)

**Done**
- Sidebar header: the sentence and subtitle are gone. It shows the live mark (28 pt, in the user's chosen icon style) and "Homebot", as a header.
- Home hero:
  - The live mark (46 pt), then "Talk to your [Grok Bot icon] Grok Bot with [orb] Siri." (`heroTitle`, already in all 11 languages; no new strings).
  - Below it: the status dot and "Listening at <host>:<port>". "Homebot is running" is gone from Home (the menu bar keeps it).
  - When the line doesn't fit, it falls back to wrapping text with Siri's SF Symbol. German fits at the 860 pt minimum width (`narrow-de-light.png`).
  - One leading edge for the hero, tiles, callout and Activity: x = 752 px in three captures (`alignment.txt`).
- Grok Bot icon (`GrokBotAvatar`): shown exactly as provided — no squircle clip, no tilt, scaled only (xAI: "without any alteration"). This also fixes the Bot step, which S10 flagged.
- Live mark (`LiveMark.swift`):
  - Drawn by `MarkDrawing` (the icon's vector geometry), now `Animatable` in gaze and blink. Nothing redraws between movements.
  - Eyes follow the pointer anywhere in the window within 220 pt of the mark (`EyeGaze`: clamped to an ellipse of 3.2 × 2.4 grid units, less while the pointer is over the mark), with a spring; back to centre when the pointer leaves or goes beyond reach. Tracking: an `NSTrackingArea` on the window's content view (`.activeAlways`), plus a re-check after scrolling.
  - Idle (`MarkLife`): a blink every 4–9 s at random; in about one gap in three, a glance left or right first. Deadline-based, so act time doesn't stretch the gaps.
  - Still under Reduce Motion; paused while the window is minimised, hidden or covered (`occlusionState`).
  - Dock icon: left static. `NSDockTile.contentView` could draw it, but only while Homebot runs, with a `display()` call per frame.
- Siri orb (`SiriOrb.swift`), Homebot's own drawing (no third-party code; research in `.agent-logs/s11-siri-research.md`):
  - 4×4 `MeshGradient` with drifting inner points and turning hues (magenta, violet, blue, cyan, coral), two soft ribbons, a small core light, edge vignette, glass rim and highlight.
  - Every motion repeats in 24 s. The loop is drawn once per size and scale (288 frames, about 0.1 s) and Core Animation plays it, cross-fading frames. Still frame under Reduce Motion; paused (layer time) while the window isn't visible.
  - Used in the Home headline (22 pt) and next to Siri's lines on the Shortcut step (28 pt).
- The status dot's pulse is a Core Animation opacity loop now; S10's `symbolEffect(.pulse)` redrew the page every frame.
- CPU (dev app, `top`, 2 s samples): Home 35–40% with a SwiftUI `TimelineView` orb at 30 fps → 6.0% final; Shortcut step 3.7%; Settings 3.5%; minimised 0.1–0.2%. Details in the research file.
- Tests: `LiveMarkTests` (gaze clamp, reach, ramp, quantising; blink gaps 4–9 s and glances on a seeded generator; the run loop on an injected clock; headline parts). 439 pass (77 + 87 + 275).
- Research: Grok 4.7 xhigh and Codex gpt-6-astra xhigh in parallel; licences cross-checked with `gh api`. Both recommended a native `MeshGradient` orb for the small size. metasidd/Orb (MIT) doesn't build on macOS as is (UIKit particle code).
- Codex review (gpt-6-astra high, `.agent-logs/s11-codex-review.md`): two P3 findings, both fixed (stale gaze after scrolling; act time stretching blink gaps).
- Screens: `.agent-logs/s11-screens/` (`home-dark-en`, `home-light-en`, `home-dark-zh`, `shortcut-orb-dark`, `narrow-de-light`, `eyes/` frames with the pointer at nine positions, `orb/` frames).

**Risk**
- Apple's HIG says apps should not imitate Siri, and Apple's trademark guidelines forbid imitating its trade dress. The orb is our own drawing but meant to evoke Siri. Felix asked for it for a personal app; reconsider before any public release.

**Not verified**
- A blink on screen (the window was covered while capturing; covered by tests).
- Reduce Motion on screen (code path only), VoiceOver, macOS 15, the installed app (not reinstalled here).
- The scroll re-check after the Codex fix (built and tested, not driven on screen).

## 2026-10-24 — Claude: Swift S11 follow-up (Felix's screenshot 20)

**Done**
- Home hero: the logo is gone (the sidebar header carries it). The headline is 22 pt; the status line sits below it. Leading edge: the headline's first glyph at 753 px and the dot, tiles, callout and Activity at 752 px (the 1 px is the glyph's side bearing), in light/en, dark/zh and dark/de window captures.
- Siri orb redrawn, still our own render (not Apple's artwork, not a third-party recreation): a dark glass sphere with four saturated, soft ribbons of light (magenta #ff2bd6, blue #2f5bff, cyan #22e6ff, orange #ff8a1f) sweeping inside it and running white where they cross; a rim in the same colours; a soft highlight; and a bloom around it (normal blending, so it shows on light windows as well as dark). The bloom spills past the view's bounds (`OrbFrame.bloom` = 1.5) without changing the layout.
- Grok Bot icon: the black square came from the asset itself. `grok-bot.png` is the App Store artwork: a full-bleed, opaque 192 px square (corner pixels opaque #3F3F40) that Apple always shows inside its continuous-corner icon mask. xAI publishes no transparent or pre-rounded version of this icon. It is now shown the way the App Store shows it: the same mask (22.37% continuous corners), no border, no tint, no motion. Checked in light and dark (Home, Bot step).
- Screens: `.agent-logs/s11-screens/v2-*` (window captures by id: home light/en, dark/zh, dark/de, Shortcut step light, Bot step dark).
- Tests: 439 pass.

**Not verified**
- No side-by-side comparison with real Siri footage: no video was played and no Apple image was downloaded; the look is matched to a written description of the macOS Siri orb.
- CPU after the redraw, with the window in front (4.0% on Home while the window may have been covered by another app; the loop is still one pre-rendered Core Animation animation, as in the 6.0% measurement).

## 2026-10-24 — Claude: Swift S12 — pictures instead of paragraphs (Felix: novices don't read long text)

**Done** (nothing pushed; the installed app was not rebuilt or replaced)
- **Visual guides** (`Guide.swift`): a stage that plays drawn mini-scenes one step at a time, a 2–5 word caption, arrows and step dots.
  - `StepTour` (pure, seconds on an injected clock): 4.2 s per step, +2 s on the last before it loops, a manual pick holds 10 s; deadlines count from the missed one (no drift) but never lie in the past.
  - `TourPlayer` drives it; it pauses while the pointer is over the stage and while the window is hidden, minimised or covered (`PointerProbe`'s occlusion signal), and resumes with the time left.
  - Slide of 28 pt plus fade, spring 0.45 s; captions never overlap (old fades out in 0.1 s, new fades in after). Under Reduce Motion: no auto-advance, each scene shows its end frame, fades only.
  - Dots and arrows change colour only on hover and selection.
- **Help › Install or update** (`InstallGuide.swift`): five scenes drawn in SwiftUI, no Apple screenshots — Downloads with Homebot.zip opening to Homebot; the drag onto Applications in Finder's sidebar; "“Homebot.app” Not Opened" with Done highlighted (not Move to Trash); System Settings › Privacy & Security with Open Anyway highlighted; Homebot's icon arriving in the menu bar with "Homebot is running". A pointer moves and clicks in each. "After an update, repeat from step 2." is one line under it.
- **iPhone step** (`PhoneGuide.swift`): the five text rows are now an iPhone of our own drawing that stays still while its screen changes: AirDrop brings the file → Add Shortcut; Shortcuts → tap it once → Allow (the real phrase and host); details → Allow Running When Locked switches on; Home app › your profile (Home Settings › People) → Recognize My Voice and Personal Content switch on; "Hey Siri, <phrase>" in the Siri language with the orb. Captions and iOS words are in the iPhone language (`AppModel.phoneTr`); the full sentences are behind (i) next to "On your iPhone". `ShortcutBuild` now carries `host` and `say`.
- **Text cut** (each now a short line, an icon row, or behind a small (i) popover, `InfoButton`):
  - Home: the paragraph under Activity (kept as spoken, Time Machine, plain HTTP, never forward the port, a sleeping Mac) → a lock and "Stored only on this Mac" with (i). The HTTP and sleep notes moved to Help.
  - Home: "Make this Mac ready for Siri" callout → icon, that one line, Done and Settings (its second sentence is gone).
  - Help: the five numbered install sentences → the guide, with the full sentences behind (i) next to "Install or update" (also for VoiceOver); the update sentence → one line; "Guide with pictures" link removed (the guide is in the app now); "This Mac" paragraphs → four icon rows (stored only here, home network only, works while awake, command-line tool for AI agents), details behind (i).
  - Language step: the iPhone-language paragraph → (i) at the end of the Home app › … path.
  - Settings: the Open at login and Keep awake notes and the App icon note → (i); the "Siri reaches Homebot only while…" footer removed.
  - Import card: the "Import it once…" paragraph → (i) next to its title.
  - Kept as they are: the signing consent line on the Shortcut step (consent must stay visible), the move-to-Applications warnings (actionable), one-line notes on the Bot step, the one-phrase Shortcut and the sheets.
  - Strings: 34 new keys in 11 languages (en and zh-Hans/zh-Hant reviewed by Claude, the others drafted), 3 unused ones removed (`helpGuide`, `helpUpdate`, `macNote`). `docs/INSTALL*.md` unchanged (its wording did not change).
- **Siri orb edge** (`SiriOrb.swift`): the hard circular clip is now a feathered radial mask (0.75 pt at 22 pt, about 1.5 px on a 2x screen, growing with size); the rim stroke is softer (opacity 0.5, more blur, inside the feather); frames for 22 and 28 pt are drawn at twice the backing scale and filtered down by Core Animation (trilinear). Before/after at 400%: `.agent-logs/s12-screens/orb/home-22pt-before-after-400.png`, `shortcut-28pt-before-after-400.png`.
- **Dev data**: every Activity answer was "现在三点。" because the dev fake Grok Bot (`scripts/fake-grokbot.ts`) answered every message with one canned line. It now answers each question plausibly in Simplified Chinese, Traditional Chinese or English, following the language Homebot asks for (time, rain, a joke, lights, else a generic line); other languages get English. The dev seed asks in Traditional Chinese for a zh-TW/zh-HK Siri. `fake-bdk.ts` `autoReply` accepts a function for `text`; its default and every test are unchanged. Dev only.
- Tests: `GuideTests` (sequencing, loop pause, late wake, wrap, manual hold, pause/resume, Reduce Motion and its change while hidden, the player on an injected clock, hover and hidden window). Swift 450 pass (88 + 87 + 275); TypeScript 213 pass.
- Codex review (gpt-6-astra high, `.agent-logs/s12-codex-review.md`): 6 findings, all checked against the code and fixed:
  - The voice settings are in the Home app under the user's own profile, not under HomePod: caption "Home app › Your profile", the scene shows a profile.
  - Help had no text alternative to the drawings: the full five sentences are back behind (i); the third caption is now "Open it, click Done" (opening from Applications was missing).
  - Turning Reduce Motion on mid-scene kept it animating: scenes are keyed by Reduce Motion too.
  - Changing Reduce Motion replaced the player and lost a hidden-window pause: `TourPlayer.setAuto` keeps it.
  - German and Russian lock labels were cut at two lines: four lines, scaling down to 80%.
  - The fake bot answered zh-TW in Simplified Chinese: Traditional Chinese added (dev only).
  - Noted, not changed: the orb loops take about 66 MiB on a 2x screen (22, 28 and 40 pt); measured app memory about 90 MB.
- Measured: page blocks on Help and Home share x = 716–1915 px (`.agent-logs/s12-screens/alignment.txt`). German at the 860 pt minimum width: `narrow-*.png`. CPU (dev app, window in front): Home 0.5%, iPhone step 2.0%; memory about 90 MB.
- Screens: `.agent-logs/s12-screens/` (`before/`, `help-*`, `phone-*`, `home-*`, `help-sheet.png` and `phone-sheet.png` are frame sequences of the guides).

**Follow-ups from Felix (same day)**
- **Typed space invisible** (commit 194740b): in the Shortcut step's phrase field (and the bot name, session id and gateway URL fields) a space showed only after the next word. Cause: labelled `Field`s were right-aligned, and AppKit doesn't draw a right-aligned field's trailing spaces. No binding normalised the text. Entries are now leading-aligned; the phrase is trimmed only where it is checked and built (`ShortcutInput.phrase`). A hosted test types "a " and expects "a " in the field and "a" as the phrase (it fails on the old alignment).
- **Activity rows** (commit 1e07ba7, `ActivityLine`): one metadata line per row, e.g. "1:52 PM · 居家助手 · 7.5 s". The time alone for today, "Yesterday" (localized) or a short date otherwise; the bot only with more than one bot; Grok Bot's time only when it differs from the total by more than 1 s or 20%. The full date, bot, both timings, step, outcome and reason are in the row's tooltip. Answered rows have no badge; other outcomes keep theirs. Long answers show three lines with Show more / Show less. The dev seed adds a long answer and yesterday's failed request.
- **Shortcuts page**: fixed columns in every row: icon | name over one detail line ("bot · kind · language · date", cut in the middle only when very narrow) | status (sized by the longest status in the language) | a "⋯" menu (Update to <language> when it needs one, Show in Finder when the file is here, Make it again, Choose bots for the one-phrase Shortcut, Revoke). Unavailable actions are not in the menu; retired rows have none. The language is plain detail, no badge. Status is one of Working, Not used yet (also while tried but not answered), Needs update, Retired. Order: working first, then the rest, newest first; retired stay folded.
  - "Needs update" comes from the new `Flow.outdated` rule (DESIGN §7.3): only Shortcuts in the Siri language the user switched away from, never a mere difference from the setting.
  - The empty bot name of the CLI-built "居家对话" was the view, not the data (its bot is "homebot"): a wide badge plus a layout priority on the rest of the line squeezed the bot name to its ellipsis.
  - Measured (2120 px captures, `.agent-logs/s12-screens/shortcuts-*.png`): status column starts at x = 1627 px in all three rows (en), 1690 px (zh-Hans); the ⋯ menu at 1852–1875 px in every row, both languages. At the 860 pt minimum width (zh-Hans) the detail line still shows whole.
- Tests: Swift 462 pass (98 + 87 + 277); TypeScript 213 pass.

**S15 UI parts (Felix approved `.agent-logs/s15-language-proposal.md`, decisions D4 and D5)**
- **D4, a language per Shortcut**:
  - The "language differs → outdated" logic is gone: `TokenView.languageDiffers`, the "Built for …" badge, "Update to …" (row menu), the `langApplies` callout and the `updateTo`/`langReplaceOne`/`langReplaceMany` strings. The web keys `langDiffers`, `langApplies` and `siriLang` stay, because the web page still uses them; the Mac app no longer does.
  - The Siri language setting is now "Default language for new Shortcuts" (Language step and Settings).
  - The Shortcut step has a per-Shortcut language picker that starts at the default (`ShortcutInput.siriLang`, `ShortcutDraft.siriLang`; "Make it again" keeps the Shortcut's own language).
  - Changing the default marks no row. Right after a change, the Language step (and Settings) shows one dismissible suggestion to make replacements for the Shortcuts in the language switched away from (`Flow.languageSuggestion`, which replaces `Flow.outdated`). "Not now" clears it (`dismissLanguageSuggestion`).
  - "Needs update" now means only a broken Shortcut: one built for this Mac's address (`AppPrefs.builtFor`, host:port recorded at build) whose address has since changed (`Flow.needsUpdate`). The S12 "Needs update from the language switch" above is superseded.
- **D5, setup closure**:
  - The iPhone guide has four scenes: Add, tap once and Allow, Allow When Locked, and a new "Ask something" (the prompt, a typed question, the answer, a green check). The Home-app voice scene and the "Hey Siri" scene are gone.
  - Above the guide, one row says "Tap it once in Shortcuts and ask something." and turns into "✓ Answered" on that token's first answered request (`delivery == .installed`, pending → active).
  - Voice is a bonus line under it ("Then try your voice: Hey Siri, <phrase>") with an (i). The (i) holds the HomePod learning delay, Personal Requests and the same-language note, and Settings › Siri › Responses › Prefer Spoken.
- **Name preview**: blocking problems show as red errors. Advice shows as one hint line with "Use <alternative>". Today's codes map as follows: `wrongScript` → "other script", `badStart` → "leading 问", anything else → a generic hint.
  - **Depends on S13**: the split between error and hint uses the problem's `blocking` flag. When S13's new `PhraseProblem` codes are merged (`unsafeChars`, digits), `hint()` in `ShortcutPhone.swift` must map them.
- Strings: 15 new app keys in 11 languages, 7 removed (345 app keys). DESIGN §7.3 is rewritten for this model.
- Screens: `.agent-logs/s12-screens/s15/` (`language-en-light.png` suggestion card, `shortcut-en-light.png` language picker, `phone-en-light.png`, `phone-zh-Hans-dark.png`).
- Tests: `eachShortcutKeepsItsOwnLanguage`, `needsUpdateOnlyWhenTheAddressChanged`, a "Not now" check; Swift 464 pass (100 + 87 + 277); TypeScript 213 pass.

**Same day, two more items from Felix (commit 896c544)**
- **"Why didn't Siri speak?"** (`SpeakHelp.swift`): a small (?) on the iPhone step's answer row, and next to Activity on Home once there is activity. It opens a popover with a drawn iOS list (Settings › Siri › Responses: Automatic, Prefer Spoken checked, iOS words in the iPhone language) and one line: iPhone may only show the answer when Siri Responses is Automatic or silent mode is on. No deep link (the Mac can't open iPhone settings). Not added to the Home "Last request" tile: the tile is one button, and a nested button would break it.
- **Conversation mode in the app**: see DESIGN §18.2. Strings: 10 new keys in 11 languages (en, zh-Hans and zh-Hant written carefully, the others drafted; the iOS words reuse the earlier phSiriTip wording, not checked against iOS). Tests: `ConversationChoiceTests` (off by default; the file is the looping Shortcut; end word in English and Chinese; the one-phrase Shortcut is never a conversation; a replacement keeps the kind).
- **First-run pass** (fresh `--dev-home`, every step from no key to a made Shortcut, en light and zh-Hans dark, `.agent-logs/s16-firstrun/`). Fixed:
  - Home said "Shortcuts: None yet · Make one" while a Shortcut was made but not yet used (the sidebar said 1, the Shortcut step was ticked). It now says "Not used yet · Add it to your iPhone" and opens the iPhone step (`HomeStatus.shortcuts`, test added).
  - The (?) next to Activity showed on a fresh install with nothing to ask about: now only once there is activity, closer to the title.
  - Noted, not fixed (S13's area): the phrase chips offer "Homebot" and "homebot" side by side (same phrase to Siri).
  - Noted: the Siri default language starts as English in the dev run even with a Chinese page; a real first run should be checked on a Chinese Mac.
- Tests: Swift 467 pass (103 + 87 + 277; one timing test in `AskOwnershipTests` failed once under load and passed on rerun); TypeScript 213 pass.

**Same day, Codex P2 fixes and two items from Felix (commits 7fc2e4e and the next one)**
- "Make it again" on the iPhone step keeps the Shortcut's own language and kind (`PhoneDelivery.again`).
- New-language versions are extra Shortcuts: the old ones keep working, as the suggestion says (`replaces: ""`; `Flow.languageSuggestion` skips a bot that already has a Shortcut of the same kind in the new language). The button is "Make new version(s)". DESIGN §7.3.
- **App icon follows the system** (`IconChoice`): Automatic (new default, first thumbnail, split white/black) is White in Light and Black in Dark, switching live (KVO on `NSApp.effectiveAppearance`). Glow, Black, White stay as choices. app.json `icon` replaces `appIcon`: a stored black or white is kept, glow or none becomes Automatic (Glow was the old default and could not be told apart from a choice).
  - Bundle icon: `App/AppIcon.icon` (Icon Composer, light and dark fills) compiled by `actool` into `Assets.car` (Aqua and DarkAqua renditions) plus `AppIcon.icns` for macOS 15. `codesign --verify --deep --strict` passes.
  - Caveat: macOS 26 uses the dark bundle icon only when the user's icon style (System Settings › Appearance › Icon & widget style) is Dark; with Default, Finder shows White even in Dark mode. The Dock follows the appearance while Homebot runs.
- **(i) and (?) right after their label**: `InlineInfo` (first-text-baseline, 2 pt spacing, buttons 16 pt wide) in section titles, picker rows, switch rows and lines across Settings, Language, iPhone, Home and Help. Measured at 2x: the visible gap from the last letter to the symbol is 9–10 px (about 5 pt). The iPhone-language (i) moved from the path row to the iPhone picker row.
- Tests: `AppIconTests` (Automatic resolves to White/Black; old files migrate; an explicit choice is kept), `makeItAgainKeepsLanguageAndKind`, `newVersionsAreMadeAndTheOldOnesKeepWorking`; Swift 469 pass (105 + 87 + 277); TypeScript 213 pass.
- Screens: `.agent-logs/s16-icon/`.

**Not verified**
- The "⋯" menu opened and each action clicked on screen (built from standard menu items; not driven in the dev app).
- Reduce Motion on screen (code path and tests only), VoiceOver on the guides, macOS 15 (including the .icns fallback icon), the installed app, the Dark icon style in Finder.
- The iPhone guide in a non-English iPhone language on screen (the dev run's iPhone language is English; strings are generated for all 11).
- The first run clicked through by hand: the pages were rendered from a fresh folder at each level (the dev seed uses the app's own actions), but typing and clicking was not driven. Driving through Accessibility doesn't update SwiftUI fields, and another session was using the screen (Codex computer use on Safari), so a Codex click-through was not started.
- The (?) popover and the conversation switch seen open on screen.
- S15: the "✓ Answered" change seen live (the dev seed `shortcut` leaves the token pending; covered by the existing pending → active tracking), the (i) tip opened, and the "Use <alternative>" button clicked on screen.

## 2026-10-24 — Claude: Siri phrase defaults; phrases as advice; reply in the question's language (DECISIONS items 28, 29)

**Done**
- English product phrases: "Grok Bot", "My Grok Bot", "Our Grok Bot" (was "House Butler", "Homebot", "House Helper"). Other languages unchanged (notes in DESIGN §16.4).
- `--experiment-phrase` (item 28) built, then removed (D6): with item 29 the rules it relaxed are advice for every build.
- D1 (DESIGN §16.2 v10): `wrong-script`, digits and leading words are advice; a leading 问/問 is `search-start` with the strongest wording; new blocking `unsafe-chars` (the name must equal its file name); uniqueness still blocks; defaults carry no problem. A replacement keeps its phrase only in the same reply language (`keptPhrase`). Page strings `wrong-script-advice`, `search-start-advice`, `unsafe-chars` in eleven languages.
- D3: the envelope asks the bot to answer in the language of the question, the token's language as fallback, eleven locales. Speak Text voice and Homebot's messages unchanged (D2).
- TypeScript reference, `Catalogs.generated.swift`, core and gateway goldens regenerated.
- Docs: DESIGN §7.2, §7.3, §16.2; DECISIONS 29 (18, 23 and 28 marked superseded in part); README (voice is a bonus, HomePod learning delay, Prefer Spoken).
- Tests: `swift test` 460 pass (95 + 87 + 278), `npm test` 213 pass.

**UI (S15 proposal steps 3–4):** done by S12 on main (f5d988b, 7fc2e4e); merged here on 2026-10-25.

**Not verified**
- Any phrase on a device; whether bots follow the new reply-language line; the web page bundle was not rebuilt (no `web/node_modules` in this worktree; the TypeScript page is the reference only).

## 2026-10-25 — Claude: S16 install flow and Shortcuts page (D1–D6)

**Done** (commits 708d080, 5c1004c and the docs commit; proposal `.agent-logs/s16-install-proposal.md`)
- Core: `ShortcutsLibrary` reads `/usr/bin/shortcuts list` (read-only; nil on failure). Tokens record `answeredHereAt` / `answeredElsewhereAt` from the voice connection's addresses. `supersedeUnused` retires never-used copies after a successful build (DESIGN §7.7).
- UI: setup is four steps (the Language step is merged into the Shortcut step and Settings; the first run takes the app language). The Install step asks once whether the iPhone uses the same Apple Account: Yes adds the Shortcut on this Mac and watches the library (taken name, renamed copy, no file, unsigned), No keeps the AirDrop / QR path. An answer on this Mac completes setup. The Shortcuts list hides retired and unusable rows, shows a status dot with words in the tooltip, and has Install on every row (DESIGN §7.9).
- **Codex review** (gpt-6-astra high, `.agent-logs/s16-install-codex-review.md`, 5 findings, all verified and fixed with regression tests): Install on a Shortcut that needs an update now makes a new copy; the app's phrase check exempts the whole takeover chain like the token store; "Add to Shortcuts" reads the library first and stops over a same-name Shortcut; "Make a new copy" without signing keeps the Shortcut's settings; "Show in Shortcuts" opens a renamed copy.
- Tests: `InstallCoreTests`, `AnsweredFromTests`, `InstallStateTests`, Flow/HomeStatus/AppModel updated. Swift 501 pass (123 + 90 + 288). TypeScript 213 pass, 1 fail: `ui-build` says `src/setup-ui/assets/app.js` is stale; this predates S16 (no web changes here; S15 noted the page bundle was not rebuilt).
- Screens: `.agent-logs/s16-install-screens/` (Install first visit, This Mac, iPhone, Shortcuts list; en light and zh-Hans dark).

**Needs Felix's real-device check**
- This Mac path end to end: "Add to Shortcuts" → Shortcuts' Add window → "Ask it once" → Always Allow → Ask for Input → the spoken answer, and the row ticking.
- iCloud: the Shortcut appears on the iPhone, works without another Allow prompt (or how often it asks), and on the HomePod.
- Replacing on the Mac path: delete the old Shortcut first, then add (D3); and what iOS does on a same-name import (Replace vs renamed copies).
- The iOS Settings path named in the sync tip ("Settings › Apps › Shortcuts", and Shortcuts › Settings on the Mac).
- Delete the probe Shortcuts "HB Install Probe 1", "2" and "3" from the Shortcuts library (left from the phase-1 probes; computer use could not delete them).

## 2026-10-25 — Claude: pre-release pass (docs, release check; nothing published)

**Done** (nothing pushed, tagged, published or notarized; the installed app, port 8787 and Application Support were not touched)
- `npm test`: the setup page bundle was stale since S15's phrase advice text; rebuilt with `npm run build:ui`. 214 pass.
- User docs brought to the S12–S16 app: README, `docs/INSTALL.md` (+ zh-Hans), `docs/ACCEPTANCE.md` (rewritten for the four-step setup and from-scratch test). Four steps and the Install paths; one answer finishes setup; switches are in Settings (the docs said Home); English default phrases; phrase rules as advice; reply language as a request; conversation mode (one-bot Shortcuts; end word, silence, errors, 10 rounds); Prefer Spoken; app icon; the Shortcuts list (dot, Install, ⋯ › Revoke).
- README agent prompt: the person pastes the API key into the app and clicks Open Anyway; the agent never handles the key or security settings; steps are marked ME / YOU; aligned with the website branch's `site/public/install.md`.
- Codex review of the docs (gpt-6-astra high): 12 findings, all checked against the code and fixed (labels "All my bots" and "Try it", the account form without a link, Find My and same-language HomePod notes, iCloud Sync needed and unverified, `doctor` is not read-only, and others).
- Release check in a clean worktree (`mac/scripts/release.sh`, commit aeaad6c): 0.5.0 (208), universal, minos 15.0, codesign strict OK for app, CLI and unpacked zip, spctl rejected (expected), 11 localizations, zip holds only the app. Found and fixed: the release binary carried the build checkout's absolute path (`#filePath` in the catalog fallback, now `#if DEBUG`). Results, checklist and draft notes: `docs/RELEASE.md`.
- Tests: Swift 501 pass (123 + 90 + 288), npm 214 pass.

**Needs Felix** (`docs/RELEASE.md`)
- The S16 real-device checks; version; a GitHub Release (none exists); the repository is private, so the Releases and repository links don't work for others; website hosting; the Open Anyway picture; the Siri orb for a public release.

**Follow-ups**
- The website branch's agent guide calls `homebot doctor` read-only; it refreshes each bot's sync cursor (README now says so). Not edited (another session's branch).
- zh-Hans `installSigning` says "使用 Apple 签名" while the switch is "用 Apple 签名".


## 2026-10-25 — Claude: S19 — Reset everything, key status, version 0.1.0

**Done** (commits `1a7bf51` … this entry; nothing pushed; the installed app, port 8787 and Felix's support folder were not touched; no real bot was contacted)
- **Reset everything** (Settings, last row) and `homebot reset [--remove-key] --yes`. `Reset.run` (HomebotCore) takes the gateway owner lock and the config → state → tokens store locks for the whole run, empties `tokens.json`, `state.json` and `config.json` without reading them (a damaged file is reset too), deletes the activity database, logs (lock files stay), `lab.json`, `app.json` and every built Shortcut file. The saved key goes only when asked; a Grok Bot login is never touched. A linked `Logs`/`Shortcuts`/`Activity` folder is refused before any change. The app stops its gateway, resets, starts it again, clears in-memory builds, download links, prefs and the credential's accepted state, turns off Open at login and opens the Account step (first-run languages set again). The CLI refuses while a gateway runs; without `--yes` it only says what would go (and changes nothing). Installed Shortcuts get 401 afterwards (unknown token).
- Confirmation: a native critical `NSAlert`, "Reset Homebot?", an iPhone and a Mac with a red ✕ badge, "Delete them in the Shortcuts app", and a checkbox "Also remove the saved API key" (off).
- **"Not checked yet" removed.** The read-only check (`getEntries` on a configured bot, as `account status` does) is impossible without a bot: Cursor's API has no list or account route (`GET /sessions` is 404, probe P2), and get-or-create would create a bot. So before a bot exists the Account step shows no status and Home's tile names the credential ("Key saved on this Mac" / "Grok Bot login on this Mac"). The check runs when the Account step appears and after a key is saved; Accepted (green) or Rejected otherwise. With a saved key and a usable login, a note says the key is used and that removing it falls back to the login.
- **Version 0.1.0** (`mac/VERSION`, RELEASE.md checklist and notes draft, ACCEPTANCE.md). 0.5.0 came with the release script in S5 (`0f46c70`) as a placeholder ("可改"), tied to no decision. Nothing in code, migrations or golden fixtures depends on it. Earlier STATUS entries keep their historical 0.5.0.
- 8 new strings × 11 languages (drafts by Claude for non-English).
- Tests: Swift 510 pass (294 core + 91 gateway/CLI + 125 UI; new: `ResetTests` ×6, `AppResetTests` ×2, CLI `reset`, Home tile), npm 214 pass.
- Codex review (gpt-6-astra high, `.agent-logs/s19-codex-review.md`): 5 findings. Fixed with tests: linked parent folders could lead deletions outside the folder (P1); the config lock ended before cleanup, so a CLI write could slip in (P2); a damaged `state.json` left a half-done reset (P2); the kept key's old accepted state survived the reset (P2). Not changed: the preview's 24 h artifact cleanup (now gone anyway: `reset` no longer opens the stores).
- Screens (dev app, fake Grok Bot): `.agent-logs/s19-screens/` — `account-login-no-bot.png`, `account-key-over-login.png`, `settings-reset-row.png`, `reset-alert.png`, `after-reset-account.png` (scrolled down only because that run used `--dev-scroll-bottom`).

**Needs Felix**
- Try Reset everything in the installed build (after the orchestrator installs it), with and without the key checkbox; delete the old Shortcuts in the Shortcuts app.
- Native speakers have not checked the 8 new strings.

**Follow-ups**
- A bot-less key check would need an undocumented probe (e.g. `GET /<invalid id>/entries` and telling 401 from 404); not done, since its meaning is unverified.

## 2026-10-25 — Claude: S19 — consent to Apple signing on the Make button

**Done** (commits `9f5d209` … this entry; nothing pushed; the installed app, port 8787 and Felix's support folder were not touched; no real bot was contacted)
- The "Sign with Apple" switch in the Shortcut step is gone. Without a stored consent (`settings.appleSigning` false) the button reads **"Sign with Apple and make"**, with one line under it: iPhones and Macs only add Shortcuts signed by Apple; this sends the Shortcut to Apple, including its phrase, the address it calls (usually the Mac on the home network) and its own access code (not the API key). Clicking it stores the consent and builds signed; afterwards it is "Make Shortcut" and the line is gone. Same pattern for the Install step's new copy (needs-file / unsigned states) and the language suggestion. Settings › This Mac › **Sign Shortcuts with Apple** withdraws it ("Off: new Shortcuts can't be added to an iPhone."). CLI unchanged (`--sign`). DECISIONS item 30; DESIGN §7.5 lists exactly what the signed file holds.
- Still enforced (item 24): a build asking to sign without consent is refused (`signing-consent`) before a token is issued, and consent is checked again right before the signer runs.
- 5 new strings, 1 reworded (`installSigning`) × 11 languages (drafts by Claude for non-English).
- Tests: Swift 513 pass (294 core + 91 gateway/CLI + 128 UI; new `SigningConsentTests` ×3), npm 214 pass.
- Codex review (gpt-6-astra high, `.agent-logs/s19-sign-codex-review.md`): all fixed. Return in the phrase field and "Try again" could consent without saying so (now Return only makes once consent is stored, and the failed title stays "Sign with Apple and make"); a consent that failed to save still built unsigned copies (now nothing is built); `ConfigStore.putSettings` kept an unsaved value in memory after a failed write (now reloads); consent withdrawn during a build was not checked before signing (now re-checked); "your Mac's home network address" was wrong for a custom URL (reworded).
- Screens (dev app, fake Grok Bot): `.agent-logs/s19-screens/sign/` — `shortcut-en-light.png`, `settings-en-light.png`, `shortcut-zh-dark.png`, `settings-zh-dark.png` (taken before the wording change for custom URLs).

**Needs Felix**
- Make a Shortcut with "Sign with Apple and make" in the installed build; check the toggle in Settings.

**Follow-ups**
- The website branch `claude/website-2fd2d7`, `site/public/install.md` lines 19 and 61, still describe the "Sign with Apple" switch (not edited here).

## 2026-10-25 — Claude: S19 — Show in menu bar, centred empty states

**Done** (commits `1321594`, the empty-state commit and this entry; nothing pushed; the installed app, port 8787 and Felix's support folder were not touched)
- **Settings › This Mac › Show in menu bar** (on by default; `app.json` `showMenuBar`; Reset everything restores it). Off hides the menu bar item; the gateway keeps running. Opening Homebot again with no window shown brings the window back (`applicationShouldHandleReopen` → `AppModel.reopen`, which uses the window's `openWindow`, handed over when it first appears). Checked in the dev app: off → the item is gone, window closed (0 windows), a reopen Apple Event sent to the dev pid → the window is back. Settings' footer: "Closing this window keeps Homebot running in the menu bar." / "Closing this window keeps Homebot running. Open Homebot again to see this window."
- Found while testing: SwiftUI writes the `isInserted` binding back on scene updates; saving the same value again looped the main menu at 100 % CPU. `setShowMenuBar` now ignores an unchanged value (tested).
- **Empty states**: one `EmptyState` (system `ContentUnavailableView`) for Shortcuts ("No Shortcuts Yet", "Make one" button) and Home's activity card ("No Requests Yet"). The detail canvas is at least as tall as the window, so the Shortcuts page's empty state is centred. Activity has no page of its own and Help has no empty state. The Install step's "Make a Shortcut first" stays a step layout. "Make one" was grey because the window was inactive (glass prominent buttons ignore the tint there); the empty state's button now uses the bordered prominent style with the accent colour, which stays blue.
- 7 new strings × 11 languages (drafts by Claude for non-English).
- Tests: Swift all pass (incl. new `MenuBarPrefTests` ×3), npm 214 pass.
- Screens: `.agent-logs/s20-screens/` — `settings-menubar-off-dark.png`, `shortcuts-empty-en-light.png`, `shortcuts-empty-zh-dark.png` (inactive window), `shortcuts-empty-en-dark-inactive.png`, `home-activity-empty-en-light.png`.

**Needs Felix**
- In the installed build: turn the menu bar item off, close the window, open Homebot from Applications or Spotlight.

**Follow-ups**
- If the window never appeared since launch (none so far: it opens at launch), reopen has no `openWindow` to call yet.

## 2026-10-25 — Claude: S10 follow-up — Glow is the website's colourful logo

**Done**
- The Glow choice is now the website logo, frozen at the frame Felix picked: `.agent-logs/s17-glow-icon/`, master v4, t = 78 s.
  - It is the first colourful logo with the square pulled in to 88 %.
  - A four-corner vignette makes the corners and edges near-black.
  - The top is darker, so the roof reads.
  - A small warm ellipse sits low in the middle and stops short of the bottom corners.
  - It replaces the earlier picks t = 81 s and t = 84 s, which were rejected for too much colour.
  - The old Glow (black with Siri's light at the bottom) is gone, along with `SiriLight` and `Theme.siri`.
- The frame is data. `GlowFrame` (Brand.swift) holds every frame-specific number:
  - the base colour;
  - the flow scale and turn;
  - the corner fields (none in t78);
  - the five patches;
  - the top shade;
  - the breath;
  - the vignette, drawn over the breath;
  - the glyph shadow.
- `GlowField` draws `GlowFrame.current` layer by layer, like S17's `homebot-glow.svg`. Switching to another candidate (for example t30 or t81 of v4) means adding one `GlowFrame` value and resampling the five points in `glowMatchesTheMaster`.
- It is vector, so the `.icns` (16–1024 px), the Settings thumbnail and the sidebar mark (when Glow is chosen) are all sharp. Glow has no rim, as in the master.
- Match with the master at 1024 px (full bleed):
  - background: mean 2.0/255, max 5.6/255;
  - with the glyph: only the 1-px anti-aliased glyph edges differ by more than 8/255 (0.22 % of pixels);
  - test: `glowMatchesTheMaster` checks five points of the master within 8/255.
- Defaults are unchanged:
  - The bundle icon (Finder, Spotlight, a Dock tile while Homebot isn't running) is still `App/AppIcon.icon`: White, with Black under macOS 26's Dark icon style.
  - The default choice is still Automatic: White in Light, Black in Dark.
  - Glow shows only when the user picks it: in the running Dock tile and Cmd-Tab, the Settings thumbnail and the sidebar mark.
  - Black and White are untouched.
- Tests: all 529 pass (132 + 91 + 306). `codesign --verify --deep --strict` passes on the dev build.
- Evidence is in `.agent-logs/s10-glow2/`:
  - `glow-master-vs-port.png`: the master, the port and a diff map, then every `.icns` size at 1:1 on light and dark, plus 16 and 32 px enlarged;
  - `settings-light.png` and `settings-dark.png`: the picker with Glow chosen, and the sidebar mark;
  - `finder-bundle-icon.png`: the unchanged bundle icon.

**Not verified**
- The Dock and Cmd-Tab for t78. The Dock would not reveal for a screenshot, and the app switcher did not appear for a synthetic Cmd-Tab today. Both use the same `Homebot.icns` that `glow-master-vs-port.png` shows.
- The installed app. It was not reinstalled here.

**For Felix**
- For the colourful Glow to also be what Finder and a closed app's Dock tile show, either `App/AppIcon.icon` needs a Glow layer or the default choice changes. Today's default is Automatic (White in Light, Black in Dark).

## 2026-10-25 — Claude: S20 — download counts, opt-in usage counts, update check, email sign-up (batch 1)

**Done** (nothing deployed; no Cloudflare resource was created or changed; no email was sent)
- `cloud/`: a Worker for `homebot.fun` with D1 and R2 (33715c6, then 1d5697a after review).
  - `/download/*` serves release zips from a private bucket. It counts one download per day, version, link (`?from=`) and country. The country comes from Cloudflare's `cf.country`; the IP is never read.
  - `/api/v1/latest` is the update check. It takes no parameters and only the daily number of checks is counted.
  - `/api/v1/ping` takes opt-in usage counts: closed sets only, with no ID. Pings are never stored; they only add 1 to marginal counters.
  - Email has double opt-in: `/api/v1/subscribe`, `/confirm`, `/unsubscribe` (RFC 8058 one-click) and `/manage`. HMAC links work with no login. GET shows a page; only POST acts.
  - Crons: a daily clean-up; a monthly snapshot to R2 with rare values merged into "other" (k = 10), plus a hash-chained ledger.
  - Workers Logs are off. `cloud/DEPLOY.md` has the steps for Felix's personal account only, never `wrangler login`.
- `HomebotCore/Usage.swift` (f2c6a89). It sends at most one ping a day, only when `settings.usageCounts == true`. `DO_NOT_TRACK=1` and `HOMEBOT_NO_USAGE=1` force it off. Requests use an ephemeral session. The update check is compiled out under `HOMEBOT_MAS`. Reset deletes `usage.json`.
- UI (699c535):
  - Settings › This Mac: "Share anonymous usage counts" (off until switched on; its (i) shows the last ping sent) and "Check for updates", plus a Download row when there is a newer release.
  - Help ends with "Stay in touch": an email field and two unticked topics.
  - Dev runs and runs with another Homebot folder reach no server.
  - 16 strings were added in 11 languages (Claude's drafts).
- Codex gpt-6-astra (high) did an adversarial review. It found 10 issues and all were confirmed and fixed in 1d5697a:
  - races on the mail limits;
  - an old confirm link could confirm changed topics;
  - an expired confirm link still gave a manage link;
  - bodies were buffered before the size limit;
  - unreleased versions could be counted;
  - 204 was sent before the write;
  - day/week boundaries could disagree between app and server;
  - bad ranges caused errors;
  - k-anonymity was weak (an "other" under 10, and other dimensions were unsuppressed);
  - a ledger line could be lost on a retry.
- Website handoff for S17: `.agent-logs/s20-site-handoff.md` (download links with `?from=`, the new `privacySub`, the full privacy policy text, an optional site sign-up form).
- Tests: Swift 306 + 91 + 135 pass; Worker 64 pass plus typecheck; root npm 214 pass. `wrangler deploy --dry-run` bundles 31.6 KiB.

**Known limits (accepted)**
- The rate limit bindings count per Cloudflare location, not worldwide (noted in DEPLOY.md).
- A ping whose 204 is lost on the way back is counted again on the retry. Avoiding that needs a per-ping receipt, which is not worth an identifier.

**Needs Felix**
- Cloudflare setup on the personal account `c511849a…`:
  - Workers Paid (Email Sending needs it);
  - D1 and R2;
  - Email Routing for `privacy@`;
  - Email Sending DNS for `hello@homebot.fun`;
  - the `HMAC_SECRET`.
- Approval to deploy, done by Codex in Ego Lite per DEPLOY.md.
- D12: the controller name for the privacy policy.
- D8: a postal address before any "offers" email goes out.

## 2026-10-25 — Claude: S21 — no signing switch, Remove asks first, one "Make one"

**Done**
- Settings › This Mac no longer has "Sign Shortcuts with Apple" (Felix: signing is required, so the switch could only break the product). The consent stays on the Make button ("Sign with Apple and make"), stored once in `settings.appleSigning`. Reset everything clears it (new test), and the CLI keeps `--sign`. `setSigning` and the strings `signSetting`, `signSettingNote` and `signSettingOff` are gone.
- `signConsent` is now one short sentence in 11 languages: "Apple signs it so iPhone can add it. Apple gets its phrase, your Mac's address and its own access code."
- Account › Remove now asks first, in a native destructive alert ("Remove the API key?"). If there is no usable Grok Bot login, the alert says the key must be pasted again. If there is one, it says Homebot will use that login. Remove is shown only for a saved key, and after it the detected login applies at once (dev run with `--dev-bdk-login`). The misleading "Saved" toast after Remove is gone.
- The Shortcuts page's empty-state "Make one" uses the same Liquid Glass prominent style as the Install step. `keepsColor` is removed, so in an inactive window it greys like other glass buttons. On the Install step's empty state, the line and the button sit together, 12 pt apart. The icon and title have not moved.
- Screens (before/after): `.agent-logs/s21-screens/`.
- Tests: Swift 306 + 91 + 135 pass; root npm 214 pass.
- Task 4: Home's status line is now one plain word: "Ready" (with a green dot that breathes slowly, fading and shrinking a little; it stays still under Reduce Motion), "Not running" (orange) or "Couldn't start" (red, with the reason in the tooltip). Home shows no address. Settings ends with a new **About** section: Version, Check for updates (moved from This Mac, with the Download row when an update exists) and Shortcut address, with a copy button. The IP address is not shown: the app has no reading of it, and `.local` is what Shortcuts call. 6 strings were added in 11 languages. Screens: `t4-*` in `.agent-logs/s21-screens/`.

## 2026-10-25 — Claude: S20 — one email list (product updates)

- Felix's call: email sign-up is for **product updates only**, and "Occasional offers" is gone. Done in `cloud/` (ef15413):
  - The subscribe API takes `{email, lang, source}` and ignores any topic fields an older app sends.
  - The `updates`/`promos` columns are removed from `0001_init.sql`. Nothing was deployed, so it changed in place.
  - The mails and pages name the one list.
  - `/manage` shows the address and the list, with an Unsubscribe button.
  - The monthly file counts confirmed subscribers only.
- **D8 (a postal address for offers emails) no longer applies**, because no promotional mail is planned.
- The email pages were checked on a local-only `wrangler dev`: no login, local D1/R2, a throwaway `HMAC_SECRET` in `.dev.vars`, and the mails written to local files. Screenshots in light and dark are in `.agent-logs/s20-email-pages/`.
- Tests: Worker 64 pass, plus the typecheck.

## 2026-10-25 — Claude: S22 — step gating, Account copy, Share anonymous analytics, one email list

**Done**
- Setup steps are a chain: Bot opens after Account, Shortcut and Install after Account and Bot. A step that is not open shows its greyed number and never a ✓. Saved bots and Shortcuts stay, so removing the key greys Bot/Shortcut/Install, and pasting it back brings every ✓ back. `Flow.landing` routes every way into a step: the sidebar, Home tiles, +, "Make one", the list's Install and ⋯ actions, and Continue. A locked step lands on the first step not done instead of being hidden. A step that closes while on screen moves the window there.
- Without a usable key, Home's Shortcuts tile and the Shortcuts list no longer say "working" in green; both show "Waiting for the key" (grey).
- Account: the "There's no Grok Bot login on this Mac" banner is gone (`loginNone` removed). Homebot reads only the CLI login, so it can't know whether the user has Grok Bot (the desktop app signs in elsewhere). The other-server and unreadable-login notes stay.
- Settings › This Mac: "Share anonymous usage counts" is now **Share anonymous analytics** (sentence case, like the other rows). Its (i) is one line ("Helps improve Homebot. Never includes your questions or anything that identifies you.") with a "What's sent" link to homebot.fun/privacy. The last ping is no longer shown; it stays in `usage.json`. It is still off by default.
- Help › Stay in touch: no checkboxes. The field and Subscribe sign up for product updates, the one list. The app sends `{email, lang, source}`, as `cloud/src/email.ts` takes since ef15413. `emailUpdates` and `emailOffers` are removed.
- Screens: `.agent-logs/s22-screens/`.

- Home says "Ready" (green, breathing) only when Siri can get an answer: the gateway runs, the key is usable and a Shortcut has answered (`Flow.isSetUp`). If the gateway runs but setup is unfinished, it says "Finish setup" (orange, static), and clicking it opens the first step not done. "Not running" and "Couldn't start" are unchanged.
- With no key, "Make one" stays and opens Account (Felix's call).
