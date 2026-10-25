# Homebot — Design

> Author: Claude Code (lead designer/implementer). Status: **v7.1, 2026-10-21; Part 2 (§16–§19) v8.3 draft, 2026-10-22.** Revised after [design review 1](reviews/design-review-1.md), Felix's [decisions](DECISIONS.md) (rounds 1–3), M0 findings, and the [M1](reviews/milestone-m1-review.md), [M2](reviews/milestone-m2-review.md) and [M4](reviews/milestone-m4-review.md) reviews.
> Inputs: docs/BRIEF.md, docs/PROCESS.md, docs/DECISIONS.md, the retired spike (`~/homepod-spike/`), public Cursor docs, the `@cursor/bdk` 0.2.x source.
> What changed and why: §15 (Changelog). Next phase (v8 draft): §16–§19 at the end.

## 0. Summary

Homebot is a small **Node.js gateway that runs on the user's Mac** on the home LAN. No `npm install` is needed to run it. It has two faces:

1. A **voice API** (`POST /v1/ask`, LAN-visible, token-protected) that a generated **Siri Shortcut** calls. Shortcut flow: *Ask for Input → Get Contents of URL → Speak Text*. The gateway forwards the question to one Grok Bot over the BDK HTTP API. It waits for a reply it can **prove belongs to this question** (§4.2) and returns it as `text/plain`. Siri reads it aloud on the HomePod (or iPhone) that heard the question.
2. A **setup web page** (`http://localhost:8788`, loopback only) for credentials, bot selection, language, and Shortcut generation and delivery. Built offline in M4 (§8, §13); not yet used on a device.

The plan builds **one narrow complete flow first**: one configured bot, safe reply handling, one bounded request, and one signed Shortcut. Felix tests it on iPhone and HomePod. Only after that do we build discovery and the beginner setup page.

## 1. Goals and non-goals

**v1 goals:**
- G1: HomePod/iPhone Siri → Shortcut → Homebot → one Grok Bot → answer spoken by Siri on the same device.
- G2: **Never speak a reply that doesn't provably answer this voice question** (privacy: a HomePod speaks to the whole room).
- G3: A stranger can install it from the README on macOS with only Node ≥ 24.12 (no `npm install` or build at runtime). Account connection = a personal Cursor user API key (§5.2, M0 result).
- G4: The setup page configures the gateway and produces an importable, signed Shortcut, with no plist editing and no token copy-paste.
- G5: **English is the default.** Setup asks for the user's **iPhone system language** and **Siri language** and generates the Shortcut from them (§7.2). Supported now: English (all Siri English variants) and Mandarin Chinese (zh-CN). Felix's mix (iPhone English, Siri/HomePod Chinese) must work.
- G6: The setup page lets the user pick from **bots they have added** (DECISIONS item 2). Listing every bot on the account is not possible with the current API (§6).
- G7: No secret is printed, logged or committed.

**Designed for, not built in v1:** voice commands (switch bot, stop) (§9.1), late-answer retrieval (§9.2), autostart (launchd), Linux/Pi signing, cloud gateway.

**Non-goals for now:** multi-room audio, OwnTone/pyatv output, Windows. (Multi-turn loops were a v1 non-goal; they are now designed in §18.)

### 1.1 Release gates (status after M0 and DECISIONS)
- **R1 — Account connection: route decided (DECISIONS item 14), not yet validated with a fresh account.** The API takes exactly one credential type, a personal Cursor user API key (`@cursor/bdk` credentials source). New users create one in the **Cursor dashboard** and paste it into the setup page. Validating a non-Felix key with detection off is still open.
- **R2 — Bot discovery: resolved by narrowing (DECISIONS items 2, 13).** No list route exists (§6). v1 = pick from bots the user added; users add a bot by its exact name with a confirmation step (§6.2).
- **R3 — Reply ownership: approved (DECISIONS item 8).** Strict ownership with the echoed `[hb:<id>]` tag for any bot.

## 2. Key decisions (with reasons)

| # | Decision | Why | Alternatives rejected |
|---|---|---|---|
| D1 | **Node.js ≥ 24.12, strict TypeScript run directly by Node's built-in type stripping; no npm install or build step at runtime** (DECISIONS item 16). Only erasable syntax (enforced by `tsconfig.json`); runtime imports are `node:` built-ins only. The setup page script is compiled to JS that is committed and drift-checked. Dev-only: `typescript`, `@types/node`. | The spike proved Node + `fetch` is enough. `git clone && node bin/homebot.ts start` works with nothing installed. 24.12.0 is the first LTS where type stripping is stable and warning-free (<https://nodejs.org/api/typescript.html>). No runtime dependencies keeps the supply-chain surface small (Node itself is still trusted code). | Committed compiled JS for all code (two copies, drift). A user-side build or `npm install`. Plain JS + JSDoc (v1–v5). A second runtime (Python). |
| D2 | **One process, two HTTP listeners:** voice API on `:8787` (all interfaces), setup UI on `127.0.0.1:8788` | The voice API must be reachable from the iPhone. The setup UI handles keys and must never be reachable off-host. A separate loopback socket is a stronger guarantee than per-route checks. Note: binding all interfaces does **not** restrict callers to the home LAN. See §11 (no port forwarding). | Single port with loopback checks. |
| D3 | **Synchronous reply only, one hard deadline per request** (§4.3) | Measured 6.6–9.1 s gateway time for short questions (spike, one-reply version). Siri speaks on the right device with no room detection. | Async + OwnTone (2.3 s buffer, interrupts music, GPL sidecar). |
| D4 | **Deadline default 25 s, configurable; no late answers in v1** | The real Siri/HomePod wait limit is **unmeasured**. The spike `/delay` records (2 s, 5 s) only show the server delivered; they are not a HomePod limit. 25 s is under the reported ~60 s Shortcut URL timeout. The M3 device session measures the real limit. | Persisting late answers for a v2 command (no recovery path in v1). |
| D5 | **Each Shortcut is bound to its bot(s) and to its Siri language; a bot may have several** | One Siri phrase maps to one bot, which is the most natural voice UX. A bot may have several Shortcuts (other phrases, languages or modes); making one adds it and replaces nothing unless the user picks one to replace (DECISIONS item 37). Binding limits what a copied Shortcut can do (§11). The language belongs to the Shortcut (the person speaking), not to the bot: one bot can have an English and a Chinese Shortcut. A generic "active bot" Shortcut waits for voice commands (§9.1). | A single routing Shortcut in v1; a per-bot language. |
| D6 | **Shortcut written as an XML plist by a minimal serializer** (only the types we use: dict, array, string, integer, boolean), then `shortcuts sign`. No binary plist; we convert only if signing rejects XML. | Keeps one runtime. Testable as a pure function. Not a general plist library. | Reusing `build_v3.py` (Python dependency). |
| D7 | **Signing: `shortcuts sign --mode people-who-know-me` first, then `anyone`, with retries and backoff** | The spike saw minutes-long 502/503/504 errors. `people-who-know-me` sometimes worked when `anyone` failed. The file goes to the user's own iPhone. | Third-party signers (they upload a token-bearing file). |
| D8 | **Delivery: AirDrop via "Show in Finder" first (M2); one-time QR link added in M4** | AirDrop is enough for Felix's device test. QR is the beginner path and needs the setup page. | Email/iCloud (sends secrets to third parties). |
| D9 | **Per-Shortcut client tokens**: 32 random bytes; only the SHA-256 hash is stored, together with the bound bot and a state (`pending` / `active` / `retired`) | Revocable per Shortcut. A leaked config doesn't leak usable tokens. Replacement without breakage (§7.7). | One global token. |
| D10 | **Gateway URL in the Shortcut defaults to the Mac's Bonjour name** (`http://<LocalHostName>.local:8787`), with an IP override | DHCP changes the IP. *Unverified that iOS Shortcuts resolves `.local` when run from a HomePod Personal Request*; the M3 device session checks it. | Hard-coded IP. |
| D11 | **State in `~/.homebot/`** (dir 0700; `config.json`, `secrets.json`, `state.json`, `tokens.json`, `logs/`, `shortcuts/`; files 0600 from creation), overridable with `HOMEBOT_HOME` | Outside the repo by default. Homebot **refuses to start** if `HOMEBOT_HOME` is inside a git work tree (override flag for tests only). | `data/` in the repo. |
| D12 | **JSON request, plain-text response.** After authentication succeeds, `/v1/ask` always answers 200 with a speakable sentence. Authentication failure keeps 401 semantics; whether the Shortcut speaks a 401 body is **unverified** (M3). | Speak Text reads whatever comes back. Non-200 handling in Shortcuts on HomePod is unknown. | JSON response (more Shortcut actions). |
| D13 | **One in-flight voice request per bot session; extra requests are rejected immediately** (not queued) | The Siri user can't wait in a queue. Rejecting keeps the deadline honest. Keyed by session id, and a session can only have one bot key. | A serial queue (the spike's `chain`). |
| D14 | **`tokens.json` is the single authority** shared by the gateway and CLI: every mutation is a locked read-modify-write (O_EXCL lock file), and verify re-reads the file when it changed | A revoke from the CLI must reach a running gateway, and a stale process must never overwrite newer state (M1 review B1). | One in-memory store per process. |

## 3. Architecture

```
 HomePod ──(voice, Personal Request)──► iPhone runs Shortcut "Ask <bot>" / "homebot 你好"
                                          │ Ask for Input (text)
                                          │ POST http://mac.local:8787/v1/ask  {"bot","text","v":1}  X-Homebot-Token
                                          ▼
 ┌──────────────── Homebot (Node, one process, on the Mac) ────────────────┐
 │ voice listener :8787                  setup listener :8788 (127.0.0.1)  │
 │   /v1/ask  /v1/health  (/dl/<once> M4)   static UI + /api/*  (M4)       │
 │        │                                                                │
 │   AskService: auth → bot binding → in-flight guard → deadline           │
 │        │                                                                │
 │   BdkClient (HTTP) + reply ownership rules (pure)     Stores (0700/0600)│
 └────────┼────────────────────────────────────────────────────────────────┘
          ▼
   https://api.cursor.com/v0/grokbot/sessions/<numericId>/{entries,messages}
```

### 3.1 Repository layout

All code is TypeScript that Node runs directly (D1); the only JS files are the generated setup page scripts.

```
bin/homebot.ts            thin entry → src/cli.ts
src/cli.ts                CLI: `start`, `doctor`, `bot add-id|add-name|list|remove`, `token issue|list|revoke`, `shortcut build`
src/core/home.ts          HOMEBOT_HOME resolution, private dir, git work-tree refusal
src/core/fsutil.ts        atomic JSON write with 0600 temp files, file lock, startup cleanup
src/core/store.ts         ConfigStore (bots, settings) and StateStore (per-bot cursors, forward-only)
src/core/lifecycle.ts     BotLifecycle: add/remove/issue under one lock (§6.4)
src/core/log.ts           JSONL logger, 0600, rotation
src/core/credentials.ts   BDK key resolution (env → secrets.json → detected, detection switchable)
src/core/bdk.ts           BdkClient: HTTP calls only (fetch injected)
src/core/bots.ts          cold sync and add-by-name for setup (read-only)
src/core/entries.ts       pure: paging, cursor sync, reply ownership decision
src/core/envelope.ts      pure: message envelope, request marker, echo tag
src/core/speech.ts        pure: speakable sanitize + truncate
src/core/tokens.ts        token issue/verify/bind/state transitions
src/core/i18n.ts          spoken message catalog (zh-CN, en)
src/core/lang.ts          Siri / iPhone language model
src/core/qr.ts            QR encoder (§8)
src/core/ask.ts           AskService: guard, deadline, abort, outcome
src/server/voice.ts       LAN listener (+ one-time downloads, downloads.ts)
src/server/setup.ts       loopback setup listener and JSON API; response shapes in setup-api.ts
src/shortcut/*.ts         plist writer, builder, profile (names/steps), make, signer
web/                      setup page source: React + Tailwind + beUI components (DECISIONS item 20)
src/setup-ui/             the built page (index.html, assets/app.js, assets/app.css; generated, committed)
scripts/build-ui.ts       builds web/ into src/setup-ui (`npm run build:ui`; `--check` for drift)
test/, test-helpers/      node:test tests, an in-process fake BDK server, small assertion helpers
tsconfig.json             type check of the Node code (noEmit); tsconfig.ui.json for the page script (DOM)
```

## 4. One voice question

### 4.1 Steps
1. Siri recognizes the Shortcut name, and the Shortcut runs on the iPhone. *Ask for Input* prompts, and Siri transcribes.
2. The Shortcut POSTs `{"bot":"<botKey>","text":"<input>","v":1}` with header `X-Homebot-Token`.
3. The voice listener caps the body at 16 KB and parses JSON. A body that is not a JSON object (an array, a string, a number, `null`) → 400 `bad json`, before the token is looked at, so it never activates or retires a token. It then **authenticates**: hash the token and compare in constant time against stored hashes in state `pending` or `active`. Failure → 401 (§12, S6). On the first success of a `pending` token, the token becomes `active` and the token it replaces becomes `retired` (§7.7).
4. **Authorization**: the token's bound bot must equal `bot` (or `bot` is omitted → the bound bot). Mismatch → 403 "not allowed".
5. The **in-flight guard** for the bot's session is taken. If it's already held → "<bot> is still answering the previous question". The guard is released in `finally`, at the deadline at the latest. (Spoken messages use the reply language bound to the token, §7.2; examples here are English.)
6. **Deadline** `T = now + answerBudgetSec` (default 25 s) starts. The local reload of `config.json`/`state.json` before this point is not counted. One `AbortController` covers all the work from here. It aborts on the deadline or on client disconnect (§4.3).
7. **Cursor sync**: read entries from the persisted per-bot cursor to the end (§5.3), tracking `maxSeq` (largest creation `seq`). If the cursor is missing (cold), that's a configuration error: "run `homebot doctor`" (cold sync happens at setup, not in the voice path).
8. **Busy check**: busy = `!turn.idle || turn.inFlight || turn.queued > 0` (turn shape verified by probe P1; rule as in `@cursor/bdk`'s grokbot-agents extension) → "<bot> is busy". Nothing is sent. Transient baseline errors are retried within the deadline.
9. **Last abort point**: if the deadline or a disconnect already fired → stop. Nothing was sent, so the reply is "That didn't get sent in time".
10. **Send** `POST /messages {messageId, text: envelope}` (§5.4). On a network error, retry **with the same `messageId`** while time remains (`duplicate` counts as success). From the moment the first send request leaves, delivery is **uncertain-or-done**: we never claim it was cancelled. If the response names any other `delivery` value, the official client treats the message as not accepted; Homebot stops waiting at once (`outcome: "not-accepted"`, logged only as `delivery: "unknown"`, never the value itself) but still says it *may* have been delivered. A response without `delivery` is treated as accepted.
11. **Poll** from the cursor every 500 ms (1 s after 10 s) until the reply decision is `accept` or `refuse`, or the deadline (§4.2). On `accept`, the text that decision checked is returned at once; nothing read later is spoken. In strict mode, untagged interim deliveries keep the loop polling; if the turn ends (two idle polls in a row) or the deadline passes with only such deliveries, the answer is the O5 refusal. Each poll's turn state is logged as `turns` for diagnostics only (`B` busy per step 8, `I` exactly `idle: true, inFlight: false, queued: 0`, `?` missing or malformed). It never affects ownership.
12. **Respond** `200 text/plain; charset=utf-8` with the sanitized answer or the outcome message (§10).
13. **Log** one JSONL line: ids, stage timings, outcome. No question or answer text by default.

### 4.2 Reply ownership rule (closes B1)

The API has no known field tying a reply to a message (Q6). So Homebot **accepts a reply only when the entry sequence proves nothing else could have caused it**. Over the entries with `seq > maxSeq` (the baseline), in `seq` order:

- **O1 — our input found:** exactly one `kind=message, role=user` entry carries our request marker `hb:<id>`. Its `seq` is `userSeq`.
- **O2 — no foreign input:** there is **no other** entry with `role=user` (any kind) and `seq > maxSeq`. A desktop message that arrives between the idle check and our send, before our entry, or after it is foreign input. The conversation is then ambiguous → **refuse**.
- **O3 — no foreign output before ours:** there is no `send-message` (with or without text) with `seq` in `(maxSeq, userSeq)`. Such output came from something else (a routine, an earlier turn) → **refuse**. "With or without text" because an entry's text can be re-updated away before we ever see it (M1 review B4).
- **Evidence over all versions:** every observed version of an entry counts. A later re-update never erases a version that disqualifies the request (e.g. a `role:user` version, or output). Only the answer text comes from the latest non-empty version.
- **O4 — candidates:** the `send-message` entries with non-empty text and `seq > userSeq`, in `seq` order (strict mode: O5 picks the first tagged one; non-strict: the first one). Attachment-only sends are skipped.
- **O5 — echo check (strict mode, default on):** the envelope asks the bot to begin its reply with `[hb:<id>]`. The answer is the **first** `send-message` after `userSeq` whose latest non-empty text has that exact tag in its first 40 characters (UTF-16 units). The tag is stripped before speaking.
  - **Interim deliveries (v9.7, DECISIONS item 26):** an untagged delivery before the tagged one is interim output (e.g. a "looking that up" line while the bot runs a tool). It is never spoken, it is not a refusal by itself, and polling continues. The ask log and Activity record which delivery was spoken (`delivery`, 1-based) and how many interim deliveries were skipped (`interim`): counts only, never text.
  - **O5 refuses** when only untagged deliveries exist and the turn has ended (two complete polls in a row report `idle: true, inFlight: false, queued: 0`; one idle poll may come between deliveries) or the deadline passes. With no delivery at all, the deadline gives the usual "didn't reply in time" (§4.3).
  - **O5 also refuses at once** when the first complete `[hb:…]` tag anywhere in a delivery's text (in any observed version) belongs to another request: that output answers another question. This holds for non-strict bots too. Fragments of other tags *after* our own tag are only removed before speech (§10, A1).
  - **A tagged delivery re-updated without the tag** is refused (BDK review B1): its text was replaced by something we can't attribute. The loss stays evidence even if a still later version has the tag again, and every delivery is checked for it before an answer is chosen. An untagged delivery later re-updated *with* our tag is the answer; only the tagged text is spoken.
  - With strict mode **off**, the first delivery with text is the answer, as before.
- **Only one proved delivery is spoken: the first tagged one.** A bot may answer in several `send-message` entries (the official client joins all deliveries of a turn). Homebot speaks only the delivery O1–O5 proved. Untagged deliveries carry no evidence and the API has no delivery-to-request link; `turn` flags describe session activity, not ownership. So an untagged delivery, before or after the tagged one, can't be told apart from output of a separate task (BDK review B1/B2; v7's whole-turn collection was reverted in v7.1). Before v9.7 only the *first* delivery was judged, which refused a correct tagged answer that followed a progress message (live request `8508c283077b`, 2026-10-23: `refused`, `O5`, turns `BBBBBBBBBB`). The turn flags still decide nothing about ownership; they only end the wait.
- **TypeScript reference:** `src/core/entries.ts` keeps the pre-v9.7 first-delivery rule. The Swift app is the product; the TypeScript code is not ported forward (its catalogs, which feed the Swift ones, carry the new wording).
- **Refuse** = speak "A reply arrived, but Homebot can't confirm it answers this question, so it won't be read aloud…" and log `outcome: "refused", reason: O2|O3|O5`.
- M0 support for O2: per the `@cursor/bdk` source, the transcript holds user messages and `send-message` deliveries; "its internal work never appears in the transcript". So `role:user` entries should only be real user messages. M3 confirms this on the live session.
- Unknown entry kinds that have `role: "user"` count as foreign input (O2). Unknown kinds without a role are ignored.

**Why strict echo (O5) is on by default:** O2/O3 detect visible foreign input. They can't detect a reply caused by something invisible (e.g. a routine that starts after our idle check and produces no user entry). The echo tag is evidence from the bot itself. It's not an upstream guarantee: a bot could echo a tag and still answer something else, but that would need a confused bot *and* a concurrent event. The cost is that a bot that forgets the tag gets refused rather than spoken. In the M3 device session we measure the echo compliance rate. If it's poor, Felix chooses (R3/Q-B1): keep strict, use a dedicated voice bot, or turn strict off for that bot (a per-bot setting with a clear privacy warning).

**What this does not cover:** a bot that *volunteers* private content in its answer to our question. That's the bot's behavior. The envelope says the answer will be spoken aloud in a room. Since v9.7 it no longer asks the bot to leave out private details (Felix: anything a user can ask the Grok Bot directly, Homebot answers aloud too; DECISIONS item 26). Ownership, not content, is what the refusal protects, and its wording says so.

### 4.3 Deadline and cancellation (closes S1)

| Moment of deadline / disconnect | Action | Spoken (if the client is still there) |
|---|---|---|
| Before send (steps 7–9) | Abort fetches; nothing sent | "That didn't get sent in time. Please ask again." |
| During or after send, before reply | Stop polling; **don't interrupt** the bot (it's a shared session); don't retry | "<bot> didn't reply in time. Your question may have been delivered; check Grok Bot instead of asking again." |
| Reply refused | — | refusal message (§4.2) |

The guard is released in all cases. Nothing is persisted except the advanced cursor, which is safe: it only moves forward and old entries are filtered by creation `seq`. Cursor writes are ordered and **off the response path**: a slow or failing write never delays the spoken answer; failures are logged (M1 review S2). On restart, in-memory state is gone and there's nothing to recover. If a bot is still answering a timed-out question, the next request sees the turn busy and gets "busy".

## 5. BDK integration

### 5.1 Endpoints (verified in the spike, undocumented publicly)

Base `https://api.cursor.com/v0/grokbot/sessions`, headers `Authorization: Bearer <key>`, `x-cursor-client-type: agent-serve`, `redirect: "error"`, per-call timeout 10 s (bounded by the request deadline).

| Call | Use |
|---|---|
| `GET /:id/entries?afterUpdatedSeq=N` | Sync and poll. Max 200 per page. |
| `POST /:id/messages {messageId,text}` | Send → `{messageId, delivery}`. `accepted_temporal` or `duplicate` = OK; anything else = not accepted (as in `@cursor/bdk`'s `backend.js`; §4.1 step 10). |
| `POST /:id/interrupt` | Only for a future explicit "stop" voice command (§9.1). Never for cleanup. |
| `POST / {name}` | Get-or-create by exact name → `{id, name, createdAtMs, latestUpdatedSeq}`. It creates a bot on a typo. Used only for add-by-name, after the user typed the name twice (§6.2, DECISIONS item 13). |

Response shapes, from the `@cursor/bdk` zod schemas and probe P1: entries `{seq: string, updatedSeq: string, kind: string, role?: string, text?: string, createdAtMs: number}`; page `{entries, latestUpdatedSeq: string, turn: {idle: boolean, inFlight: boolean, queued: number}}`. **An empty page echoes the requested cursor** as `latestUpdatedSeq` (P1), which our "cursor advances only on non-empty pages" rule already handles. There is **no** `GET /v0/grokbot/sessions` (P2: 404).

**Transport check (2026-10-21, read-only GETs on session 14752726, see STATUS):** a page's `latestUpdatedSeq` is the max `updatedSeq` of that page, not the session's tail (200 entries → "205", tail "264" after 3 pages). A GET with a cursor beyond the tail returns no entries, echoes the cursor and still carries `turn`: it gives the turn state but not the tail. `GET /sessions/:id` is 404. So the only non-paging tail source is `POST / {name}` (get-or-create), which the official client uses as its starting cursor. Homebot does **not** use it for the voice baseline: it would create a bot if the name was changed in the app, it doesn't return `turn` (a GET is needed anyway), and the warm cursor already makes the baseline one or two GETs. Turn values *while* a reply is being produced were not observed. They are only used for the pre-send busy check (step 8) and the diagnostic `turns` trace, never as ownership evidence. If the flags are missing or wrong, the busy check may let a send through or refuse one. Ownership is still decided by O1–O5 alone.

All HTTP goes through `src/core/bdk.ts`. Paging and ownership logic is pure (`src/core/entries.ts`) and tested offline.

### 5.2 Credentials

Resolution (first hit wins; UI and logs only show the *source* name):
1. `CURSOR_API_KEY` env → 2. `CURSOR_API_KEY_FILE` env → 3. `CURSOR_SERVICE_ACCOUNT_KEY` env → 4. `~/.homebot/secrets.json` `bdkApiKey` → 5. **detected** existing BDK credentials (`$AGENT_SERVE_CONFIG_DIR/credentials.json`, then `~/.config/agent-serve/credentials.json`), read in place, never copied.

Detection (5) can be switched off (`HOMEBOT_DETECT_CREDENTIALS=0` / setting). **New-user validation must run with detection off**, otherwise Felix's existing credentials hide the real setup problem (B2).

**M0 result (key type):** per `@cursor/bdk`'s `internal/cursor/credentials.js`, *"Exactly one kind of secret exists at runtime: a personal Cursor user API key"*. `bdk login` only mints such a key (named, dashboard-revocable). The resolution order is the same as ours. The stored login file is `{backendUrl, apiKey}` under `~/.config/agent-serve/` (or `$AGENT_SERVE_CONFIG_DIR`). A tool that bundles BDK can point that directory at its own `auth/`. **New-user route:** create a user API key in the Cursor dashboard and give it to Homebot via `CURSOR_API_KEY`/`CURSOR_API_KEY_FILE` (or the setup page in M4). Validating that a dashboard-created key works on these routes needs a non-Felix account or Felix creating a key (§14).

### 5.3 Cursor sync (closes S5's pagination point)

- `syncToEnd(fetchPage, cursor)` pages with `afterUpdatedSeq=cursor` until a page is empty or `latestUpdatedSeq` doesn't move. The cursor only advances on non-empty pages. It returns `{cursor, maxSeq, entries, turn}`.
- **Cold sync** (`cursor = -1`) walks the whole history once, at setup (`homebot bot add-id`, later the setup page), with a page cap (default 500 pages ≈ 100k entries) and a time cap. The resulting cursor and `maxSeq` are persisted in `state.json`. The voice path never does a cold sync.
- If a history exceeds the cap, setup fails with a clear message. Resetting the cursor can't fix that; the cap would have to be raised.
- Anything that shows "the latest message" (e.g. an optional preview) must come from `syncToEnd`, never from a single page fetched with `-1`.

### 5.4 Message envelope (requirement 6: the bot can see it's Homebot)

```
[Homebot voice · hb:7f3a2c9d1e04 · en]
<transcribed question>

(Homebot: the user said this to Siri on a HomePod or iPhone, and Siri reads your reply aloud in
English. Start your reply with [hb:7f3a2c9d1e04]. Answer in English, short and spoken. No markdown
or emoji. End with a statement, not a question.)
```
The language tag and instructions follow the Shortcut's Siri language (11 languages).

- **Only load-bearing guidance (DECISIONS item 35); the rest of the voice is the bot's own.** One context sentence (where the words came from, and that Siri reads the reply in the token's language); the echo tag (strict ownership, §4.2); the answer language, short and spoken (the Speak Text voice reads only that language, item 31); no markdown or emoji. A one-shot question adds "End with a statement, not a question" (the user can't answer back); a conversation turn adds the `[end]` instruction instead (§18.4). No sentence or length counts: the gateway's `maxSpokenChars` cap still cuts at a sentence boundary.
- Line 1 is a stable, machine-parseable marker. Bot owners can add rules for `[Homebot voice`.
- `hb:<id>` = 12 hex chars from a random request id (enough to never collide within one session).
- The style text is per language and per bot configurable. The echo instruction is always present when strict mode is on.
- Test-mode requests use `[Homebot test · …]`: a `/v1/ask` body with `"test": true` (the M3 curl questions; a setup page "Test" button later).

## 6. Account connection and bot discovery

### 6.1 M0 findings (2026-10-21)
Sources: `@cursor/bdk` 0.2.x as bundled with a Grok Bot tool on Felix's Mac (read-only; `auth/` not opened), its bundled docs, and two read-only probes (STATUS has the exact record; script `scripts/m0-probe.ts`).
- **The session API has four routes only:** `POST /v0/grokbot/sessions {name}` (get-or-create), `POST …/:id/messages`, `GET …/:id/entries`, `POST …/:id/interrupt` (`extensions/cursor-grokbot-agents/lib/backend.js`).
- **No account-wide list.** The extension's `list` tool returns configured names plus agents *this caller already contacted*, kept in the host's own KV store. The bundled docs say: "it does not enumerate the whole account". Probe P2 confirmed that `GET /v0/grokbot/sessions` returns 404.
- **Official bots are addressed by exact name.** The extension resolves a name with `POST /sessions {name}`, and treats `latestUpdatedSeq === "-1"` plus `createdAtMs` within 60 s as "this call created an empty bot". It warns the user in that case. It protects against typos only with a configured allowlist of names.
- **Credentials:** a personal Cursor user API key (§5.2).
- **Q6 (reply↔message link):** none. Sends use a random `messageId`, which does not appear in entries, and the extension attributes replies by waiting for the turn to settle *and* refusing to send while a turn is in flight. That is the same principle as our busy check, but weaker than §4.2.
- **Q3 (is the numeric id visible to users?):** nothing in the BDK code or docs exposes it. Users know bots by **name**. Answer from Felix or a device check still needed.

### 6.2 Adding a bot (R2: pick from added bots)
- **Now (dev aid):** `homebot bot add-id <numericId> --key <key> --name <label>`. It validates with a read-only cold sync (page cap + total time cap), rejects a key that already belongs to another session and a session that already has a key, and shows conversation content only with `--preview` (the true latest bot message, via `syncToEnd`).
- **For users (approved, DECISIONS item 13; built offline, not yet run live):** add by **exact bot name**, the way the official extension does: `POST /sessions {name}` (`resolveBotByName`). The user types the name twice (page: two fields; CLI: `homebot bot add-name "<name>" --key <key> --confirm "<name>"`); a mismatch is refused before any call, with a warning that a typo creates a new empty bot. If the response looks newly created (`latestUpdatedSeq === "-1"` and `createdAtMs` in the last 60 s), Homebot does **not** add it, and tells the user to check the name and delete the empty bot in the Grok Bot app. An old empty bot is a real bot and can be added. It is never called automatically or in a loop. Then the same read-only cold sync as `add-id`. The numeric session id stays as an advanced route (page: "Advanced").
- No speculative `BotDirectory` strategies. If Cursor adds a list API, it replaces the add step.

### 6.3 Bot lifecycle (M4 review B1, S1)
A bot's identity is its config entry (key → session), its cursor in `state.json`, and the tokens bound to it. `BotLifecycle` (`src/core/lifecycle.ts`) owns all three changes, each under one cross-process lock on `config.json`, re-reading the files first:
- **add** re-checks the key and session under the lock (another add may have won while this one was cold-syncing), then installs the cursor (tagged with the session id) and the entry. A rejected add changes nothing.
- **remove** retires every token of the bot, drops its cursor and its entry in one step.
- **issue** (every Shortcut build and `token issue`) re-checks that the bot still exists with the **same session** and issues inside the lock, so a build that read the bot before a remove (or a remove + re-add of the key) issues nothing.
- Defense in depth: tokens record the bot's session id, and the voice listener refuses (401) a token whose bot now points at another session. Cursor writes carry the session id; a write for another session is dropped, and AskService skips persisting when its bot changed mid-request. Config and state stores reload when their file changes (inode/size/mtime).
- Lock order is always config → state/tokens.

## 7. Siri Shortcut

### 7.1 Action graph (same as the spike's working v3)
1. `is.workflow.actions.ask` — prompt (i18n), `WFInputType: "Text"`.
2. `is.workflow.actions.downloadurl` — POST `<baseUrl>/v1/ask`, headers `X-Homebot-Token` and `Content-Type: application/json`, JSON body `{bot, text: <Provided Input>, v: "1"}`. No language field: the language is bound to the token.
3. `is.workflow.actions.speaktext` — Contents of URL, `WFSpeakTextLanguage` = the Siri language (e.g. `en-US`, `en-GB`, `zh-CN`), `WFSpeakTextWait: true`.

The single-question graph has no If. The loop Shortcuts (§18.2, §19.1, §20.5) read every If variable as Text; see §18.2.

Pure builders `buildAskShortcut` / `buildProbeShortcut` (`src/shortcut/build.ts`) produce plist objects. `toXmlPlist` serializes them, and `plutil -lint` checks the output in tests on macOS.

### 7.2 Language model (DECISIONS items 3, 29)
Two settings, both asked during setup. **English is the default for both.** Since DECISIONS item 29 (v10) the first is a default for new Shortcuts, not a rule about what the user says.

| Setting | Values now | Drives |
|---|---|---|
| **Voice language** (each Shortcut's own; the setting is the default for new ones) | the eleven Siri locales of §16.3 (older tokens: any English variant) | The default phrase and its advice (§16.2), the Ask-for-Input prompt, the Speak Text voice (`WFSpeakTextLanguage`, D2), Homebot's own spoken messages, and the **fallback** reply language. **Bound to the Shortcut's token.** |
| **iPhone system language** (the Shortcuts/Settings UI) | the eleven page languages | The setup steps only, because they name iOS settings as the user sees them. |

- **The bot replies in the Shortcut's language** (DECISIONS item 31, replacing item 29 D3): the envelope asks for the token's language whatever the question's, because Speak Text is fixed to that voice. A voice can't read other scripts: on 2026-10-25 an English Shortcut on Felix's Mac read a Chinese answer to a typed "你是谁" as noise (S25). As a guard, a reply with letters its voice can't read (`readableBy`: Latin, Common and Inherited everywhere; Cyrillic for ru; Han for zh; Han and kana for ja; Hangul for ko) is never spoken: the user hears the `unspeakable` message in the token's language and Activity shows reason `script`. Voice detection in Shortcuts and a voice chosen per reply were considered and left out: Speak Text has no automatic language, and a voice picked from a variable is untested on HomePod.
- Siri's own dictation uses one language (S15 proposal F6, F14), so a question asked by voice is usually in the Siri language; the benefit is for questions typed or dictated with another keyboard when the Shortcut is tapped, and for common English words a Chinese Siri writes out.
- Before authentication the language is unknown, so 401/403 bodies are English.
- More languages = one row in `src/core/lang.ts` plus a message catalog and envelope text. No other code changes.

### 7.3 Embedded settings
The Siri phrase, voice language, gateway address, bot and token are **baked into the Shortcut**. Changing any of them marks the Shortcut "needs replacement" and guides the user through §7.7. Saving a setting alone never claims to update the phone. As built (S15, D4): a Shortcut's language is its own. The Shortcut step has a language picker that starts at the default ("Language for new Shortcuts" in Settings; S16 D2 removed the Language step, and the first run takes the app language for Siri and the iPhone), and the token keeps it (`siriLang`). Changing the default never marks an existing Shortcut: one made in another language keeps working in it, so there is no "language differs" badge, update button or note. Right after the user changes the default, Homebot remembers the language left behind (`app.json` `siriLangBefore`) and shows one optional suggestion, "Your <old> Shortcuts keep working. Make <new> versions too?", with "Make new version(s)" and "Not now" (`Flow.languageSuggestion`); "Not now" clears it. The new versions are extra Shortcuts for the same bots and kind; they replace nothing, so the old ones keep working after the new ones answer. A Shortcut is no longer suggested once a version in the new language (same bots and kind) is in use, waiting for its first answer, or has its file ready to send. The Shortcuts page marks a Shortcut "Needs update" only when it can no longer reach Homebot: Homebot records the gateway address ("host:port") each file was built with when it built it for its own address (`app.json` `builtFor`), and a different current address (the Mac renamed, the port changed) is `Flow.needsUpdate`; "Make it again" in the row's menu replaces it. Shortcuts made elsewhere (CLI) or for a typed address are never judged.

- A replacement keeps the old phrase in any language (`keptPhrase`, DECISIONS item 33): the default no longer depends on the language, so a language change never renames a Shortcut.

### 7.4 Naming
**Superseded by §16 (v8).** Before v8: `Ask <bot>` / `<bot>你好` with a mixed-script warning and the all-Chinese "家庭助手" offered as an alternative. The device session showed the mixed phrase fails on a Chinese HomePod, so the script rule is now enforced (§16.2). Probe names: "Homebot Wait Test" / "家庭等待测试".

### 7.5 Files and signing
- **iOS names an imported Shortcut after its file name.** So the file carries the sanitized display name (no `/ \ :`, control characters or leading dots; at most 60 characters) inside a private **per-token directory** with an internal name: `~/.homebot/shortcuts/<tokenId>/<name>.shortcut`. The display name never chooses a directory. The sanitized name is the **one effective name**: it is printed, used in the setup steps, and stored as the token label. A voice Shortcut whose phrase sanitizing would change is refused (`unsafe-chars`, §16.2), so its imported name is the phrase the user chose. Probe builds name the probe Shortcut in their steps.
- Directories are 0700 and files 0600 from creation. The whole `<tokenId>/` directory is deleted when the token is first used, revoked or expired, and once it is 24 h old. The 24 h rule is enforced by **every CLI run** and by the **running gateway every 10 min**; if Homebot isn't running at all, the file goes at the next run (the CLI says this). Cleanup decides under the `tokens.json` lock against the current file, and an artifact is only written after its token record exists, so one process never deletes another's fresh build.
- `shortcuts sign` runs through a fixed launcher, `/bin/sh -c 'umask 077 && exec "$0" "$@"' shortcuts sign …`: the script is a constant and the signer and every path are separate arguments, so nothing is interpolated, and the output is 0600 from creation even if signing is interrupted. Mode alternation and backoff follow D7. **Signing needs the user's consent, given in the product (DECISIONS item 24):** in the Mac app, clicking a button labelled **"Sign with Apple and make"** (the Shortcut step, the Install step's new copy, the language suggestion), shown while no consent is stored, with one short line under it: "Apple signs it for iPhone and sees its phrase, your Mac’s address and an access code." (S25: one line at the default width in English and Chinese, 14 pt below the button, the column's full width) (the address is a custom URL when one is given; the API key is never sent). Once given, the button is just "Make Shortcut" / "Make a new copy" and the line is gone. There is no switch to withdraw it (S21): signing is required, since iPhone and Mac only add Apple-signed Shortcuts, so a switch could only break the product. Reset everything clears the consent with the rest of the settings, and the next Make asks again. On the CLI, `--sign`. What the signed file holds: the action graph with the phrase (the file name), the question prompt, the gateway origin (`http://<mac>.local:<port>` or the URL given), the token in the `X-Homebot-Token` header and, for a one-bot Shortcut, the bot's key; never the Cursor API key or a bot's session id. The consent is stored as `settings.appleSigning` (S19; before, a switch in the Shortcut step, which novices skipped). A build that asks to sign without consent is refused (403 `signing-consent`) before a token is issued. No environment variable is involved (the old `HOMEBOT_ALLOW_SIGNING=1` gate is removed). **Checked:** `shortcuts sign` accepted our XML plist directly (no `plutil -convert binary1`, D6), and on 2026-10-22 a signed "家庭助手" imported on Felix's iPhone and worked on his HomePod (STATUS). *Unverified:* signing started from the page switch on a real Mac (tested with a fake signer only).
- **Build failure boundary:** non-secret inputs (gateway URL, names, languages) are validated before a token exists. After that, any failure (XML encoding, disk, signing) deletes the token's directory and revokes the new token. The token being replaced is untouched.
- On Linux, signing isn't available (later: iCloud template + pairing code).

### 7.6 Wait-limit probe
`homebot shortcut build <bot> --probe` makes a "Homebot Wait Test" Shortcut (GET `/v1/probe-wait`, then speak). `homebot start --probe-wait` enables the endpoint, which is off otherwise. Each call answers after the next delay in 5, 10, 15, 20, 25, 30, 40, 50, 58 s, in the token's language ("Waited N seconds."), and logs `delivered` / `client_gave_up_ms`. The longest delay Siri speaks on the HomePod is the limit. It never contacts a bot. Its token has kind `probe` (M4 review S2): only `/v1/probe-wait` accepts it, `/v1/ask` refuses it before activation, and a probe never replaces (or is replaced by) a voice Shortcut, so a wait test can't retire the working Shortcut. The setup page offers the option only while `--probe-wait` is on.

### 7.7 Replacing a Shortcut (closes S2)
- **Replacement is explicit only (DECISIONS item 37).** A plain Make (the Shortcut step, `homebot shortcut build` without `--replaces`, the language suggestion) adds a Shortcut and replaces nothing; the bot's other Shortcuts keep working. A Shortcut is replaced only when the user asks for it on that Shortcut: the row menu's "Make it again", the Needs-update path, or the step's Replaces picker. Only then does the Install step ask to delete the old one first. A phrase already used by an active or pending Shortcut on this Apple Account is never reused: the form starts on a free phrase and offers the next free ones.
- Making a Shortcut issues a **`pending`** token. The existing Shortcut's token stays **`active`**.
- The pending token becomes `active` only when one of its requests **ends with an answer Siri speaks** (outcome `answered`; v9.8, DECISIONS item 27). At that moment the token it replaces becomes `retired`. (Either one only works for its bound bot.) Its first authenticated request only marks it *used* (`usedAt`), which deletes its file. A refused, timed-out, busy, failed or not-configured request changes neither token: the old Shortcut keeps answering, and the new one keeps serving requests until it has truly answered once.
- The takeover is one locked write and does nothing for a token that is no longer pending, so a second answer, two answers at once, or answers in two processes never retire twice and never leave neither Shortcut usable. Down a chain of replacements (C replaces B replaces A, B never answered) C's first answer retires every Shortcut its set covers, stopping at one it doesn't cover or one already retired. A copy that replaces nothing (a copy for another iPhone, §7.9) never retires anything.
- Wait-test and lab Shortcuts talk to no bot, so they still take over on their first use.
- `--replaces` must name an existing, non-retired token of the **same bot**; anything else is refused before a token is issued, so a wrong id can't silently disable another bot's Shortcut.
- The setup page also offers "revoke old Shortcut now" explicitly.
- Pending tokens never used within 7 days expire, and their files are deleted at 24 h. A failed signing or an abandoned import therefore never breaks the working Shortcut. A pending token that was used is on a phone: it stays usable after the 7 days, until it answers (and takes over) or is revoked.
- The app shows a used pending Shortcut as "Waiting for its first answer"; its iPhone step says it takes over from the old one once it has answered, and "Make it again" for it makes a copy that replaces nothing.
- **Never-used copies (S16).** After a build succeeds, `supersedeUnused` retires the pending tokens down the new token's replaces chain that were never used (no file on any device). The new token replaces the first usable token that chain covers, so "Make a new copy" or "Change language" twice does not leave a list of dead rows. A failed build leaves them alone. The label check exempts only that chain, so the copy keeps the phrase.
- **Another Apple Account (S26, item 34).** A token may carry `otherAccount: true`: a copy for an iPhone on another Apple Account, whose Siri never sees this account's Shortcuts. It skips the label check (it may share any phrase), and its own label never counts against a Shortcut made for this account (the issue-time check and the profile's taken phrases both leave it out). A replacement of one inherits the flag. Like any copy for another device it replaces nothing, so supersede never touches the original.
- **Where it answered (S16).** Each answered request records `answeredHereAt` or `answeredElsewhereAt` once, from the voice connection's addresses (`VoiceResponder.isThisMac`: the remote address is loopback or equals the local one, after dropping `::ffff:` and `%zone`). The Install step uses it to tick "Ask it once on this Mac" and "Then on your iPhone".

### 7.8 Delivery
- M2: "Show in Finder" (`open -R`, argument array) → AirDrop. Short import instructions in the README.
- M4 (built): one-time QR link `GET /dl/<128-bit random>` on the voice listener (the phone can't reach the loopback page): in memory only, single use, 10 min expiry, dropped when its token is revoked or its bot removed. Unknown, used and expired links get the same 404. The URL is a bearer secret: never logged (only `download served|gone`), `Cache-Control: no-store`, `Content-Disposition: attachment` with the Shortcut's name. *Unverified:* how iOS Safari hands the downloaded `.shortcut` to Shortcuts.
- **QR encoder:** our own zero-dependency encoder (`src/core/qr.ts`, byte mode, level M, versions 1–10, ~200 lines after Project Nayuki's reference design) instead of a vendored library. It is checked against published Reed-Solomon and format-information vectors, and **decoded by Apple's CoreImage QR detector** in a macOS test (`scripts/qr-verify.swift`) for every version, including UTF-8 text. The page draws the module matrix on a `<canvas>`, so no markup is generated from data.
- After import (checklist on the page / README): run it once on the iPhone and allow network access; turn on Allow Running When Locked if shown; HomePod prerequisites (Recognize My Voice, Personal Requests, this iPhone as the location device, Siri in iCloud; Apple support 108397); test on the iPhone, then the HomePod.


### 7.9 Install (S16)
Setup is four steps: Account, Bot, Shortcut, Install. Install replaces the iPhone step and the folder icon on each row.
- **One question, asked once:** "Does your iPhone use the same Apple Account as this Mac?" (`app.json` `installTarget`). No public API tells the Apple Account or whether iCloud Sync for Shortcuts is on, so the user answers. A segmented control switches later.
- **This Mac (Yes).** Three rows: (1) "Add to Shortcuts" opens the signed file with the Shortcuts app, which shows its own "Add Shortcut" window; (2) "Ask it once on this Mac" runs it (`shortcuts://run-shortcut?name=`) to grant Always Allow and checks off on the first answer from this Mac; (3) "Then on your iPhone" checks off on an answer from another device. An answer on this Mac completes setup (D6).
- **The library is read, never written.** `ShortcutsLibrary.list()` runs `/usr/bin/shortcuts list` (no import, delete or rename exists) while the This Mac page is open, at most every 2 s. nil (the command failed) is never taken for an empty library. `InstallState.macAdd` turns the list into the row's state: a name already taken before we opened the file is `nameTaken` (the old Shortcut must be deleted first, D3: on macOS 26 "Replace" left only renamed copies). For `nameTaken` the row's button is "Open Shortcuts" with the line "Right-click it, then **Delete…**" (S26): "Show in Shortcuts" opens the Shortcut's editor, which can't delete it. Checked on macOS 26: Apple's URLs are `open-shortcut` (the editor), `run-shortcut`, `create-shortcut` and the gallery, with none for the library or for deleting; the `shortcuts` CLI has run, list, view (the editor) and sign; the AppleScript dictionary has only `run`; the editor's Edit › Delete removes actions. Apple's guide says to select a Shortcut in the library, then Edit › Delete or Command-Delete, but a single click on a library tile runs that Shortcut, and macOS runs one at a time, so it stopped a live Grok Bot conversation (unified log, 2026-10-26). The hint therefore uses the tile's context menu, which doesn't run it: Run, Edit, Rename…, Change Icon…, Add to Dock, Share, Duplicate, Delete… (Felix's screenshot, 2026-10-26). "Delete…" in each language is Shortcuts' own string. "<name> 1" after we opened it is `renamed` (Siri needs the exact name), no file is `needsFile` ("Make a new copy"), an unsigned file is `needsSigning`.
- **iPhone (No).** The AirDrop / QR path of §7.8. It is always offered (S26), so the same tab serves another iPhone, another Apple Account or someone in the family. Once the Shortcut is in use, the page shows "Answered" first, then "Install on another iPhone" with AirDrop and the code.
- **Another iPhone (S26).** One signed file works on any number of devices while it exists: the token is a bearer secret, not bound to a device. But the file is deleted at the first use (or at 24 h), and only the token's hash is kept, so after setup there is nothing left to send. A click on AirDrop or the code then makes a new copy right there (`makeCopy(replacing:)`), with no trip to the Shortcut step. A copy of a Shortcut in use replaces nothing, so its first answer never retires the one on the first device. Two Shortcuts can't share a phrase (§16.2), so it takes the first free one ("My Grok Bot"), shown in the page title and the voice line. A checkbox above the cards, "This iPhone uses another Apple Account" (off by default), makes it keep the phrase instead (§7.7, item 34); its row in the Shortcuts list then says "Other Apple Account", so the two rows with one phrase can be told apart. A never-used one whose file is gone is replaced, keeping its phrase.
- **No trap.** The stored answer only picks the tab that opens. The This Mac | iPhone switch is always shown once answered, and switching keeps the code shown and every row's state. A wrong "Yes" (added on the Mac, but the iPhone uses another Apple Account) is undone by the iPhone tab: AirDrop or the code sends it.
- **Shortcuts list (D4, D5).** Retired rows and never-used rows whose file is gone are hidden (`ShortcutList.visible`). Status is a dot (green working, orange needs update, grey ring waiting) with words in the tooltip. Every row has Install, which is also the way to another iPhone (S26: the menu item that opened the Shortcut step for a copy under a new phrase is gone); its menu has Change language, the conversation switch and Delete.

## 8. Setup web page (M4, built offline)

`homebot start` runs both listeners in one process: voice on `:8787` (LAN) and setup on **`127.0.0.1:8788` only** (`settings.setupPort`; the bind address is not configurable). A React page built from `web/` with beUI components (DECISIONS item 20; the build in `src/setup-ui/` is committed, so users build nothing, D1); JSON API in `src/server/setup.ts`. The page is English by default, with a page-language switch (`settings.uiLang`: `en`, `zh-Hans`).
- **Wizard as built:** (1) connect account: paste a Cursor dashboard API key (DECISIONS item 14), saved to `secrets.json` (0600) and never returned. The page shows which credential is used (`env` / `saved` / `detected` and its source name) and whether Grok Bot **accepted** it: `unchecked` until a bot add reaches Grok Bot, then `ok` or `rejected` (reset when the key changes). It explains that an env key overrides a saved one (change it where Homebot is started) and that a saved key replaces a detected login. The voice gateway resolves the key per call, so a key saved on the page works without a restart; `start` no longer requires a key. (2) **your languages**: "What language do you speak to Siri?" and "What language is your iPhone set to?" (§7.2; English preselected); a Siri-language change says it applies to new Shortcuts (§7.3). (3) **your bots**: add by **exact name typed twice** (§6.2), or under "Advanced" by session id + name; both use the read-only cold sync and `BotLifecycle` (§6.3). Strict echo is on by default; turning it off needs an explicit confirmation after the room-privacy warning (`confirmNonStrict`, else 400). The key is derived from the name (`kitchen-bot`, or `bot-<sid>` for non-ASCII names). **Removing a bot retires its tokens** and drops its cursor in one locked step. (4) **make a Shortcut**: live preview of the Siri phrase and question, warnings and the all-Chinese alternative (§7.4), optional phrase, "replaces" (defaults to the bot's active voice Shortcut), gateway address; the wait-test option is disabled unless `--probe-wait` is on, clears "replaces" and previews a timed answer; the "Sign with Apple" switch (the user's consent, §7.5); result with Show in Finder and the QR link. (5) the iPhone steps, in the iPhone's language.
- **Shortcut list:** label, bot, Siri language, kind (wait test), created; state shown honestly as "waiting for its first request" (pending) / "Homebot received a request with this Shortcut's token" (active) / retired; language-differs flag with "Make a replacement"; revoke. The page refetches state on window focus / visibility and with a Refresh button, so a phone's first use shows up without another change.
- **Copy (M4 review S6):** settings and keys are stored on this Mac; questions go to Grok Bot; signing sends the Shortcut (with its token) to Apple. Strict checking is described as "refuses a reply when its checks can't confirm it belongs to your question", not as a guarantee.
- **Not built (deferred):** the "you confirmed you heard it" button and an "answered" state per Shortcut (would need per-request bookkeeping); advanced settings (deadline, max spoken chars, style hint, log text, detection toggle); a "Test" button.
- **Security (tested):** Host must be `127.0.0.1:<port>` or `localhost:<port>` (421 otherwise; DNS rebinding). Every `/api/*` call needs the per-launch secret header, which is only in the served page's `<meta>`. Changes need POST + `application/json` + an Origin equal to `http://<Host>` (CSRF; form posts can't send JSON). Body ≤ 16 KB. CSP `default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'`, nosniff, no-store, no-referrer. Responses never contain the API key, token plaintext or hashes; the one-time link is returned once to the page that created it. The page renders all data with `textContent`/`createElement` (a test forbids `innerHTML` and friends, inline scripts, styles and handlers).

## 9. Extension points (later)

### 9.1 Voice commands
A `CommandRouter` before forwarding matches only whole short utterances: "停止/stop" → explicit `interrupt`; "切换到 <bot>" for a generic Shortcut (needs a token bound to "any enabled bot", an explicit separate grant); "现在是哪个 bot". Also `POST /v1/command`.

### 9.2 Late answers
Not in v1 (§4.3). If added: the reply-ownership rule still applies, answers are kept in memory only, retrieved with an explicit command, and expire in 30 min.

### 9.3 Cloud gateway
The `/v1/ask` contract is transport-neutral. No v1 work.

## 10. Failure modes

| Situation | Response |
|---|---|
| Mac asleep / Homebot down | iOS's own error. README: keep the Mac awake; autostart is a later opt-in. |
| Bad/revoked token | 401, "This shortcut no longer works. Please make a new one in Homebot." (always English: the language is unknown before authentication). **Unverified** whether the Shortcut speaks a 401 body; the setup page/README carry the recovery steps. |
| Token not allowed for this bot | 403, "This shortcut isn't allowed to use that bot." |
| Empty transcription | "I didn't catch that. Please say it again." |
| Bot not configured / cursor missing | "Homebot isn't set up for this bot yet. Run homebot doctor." |
| BDK 401/403 | "Homebot can't sign in to Grok Bot. Please check the settings." |
| BDK 5xx / network | Retry GETs while time remains; send retried with the same `messageId`; then "Grok Bot can't be reached right now. Please try again later." |
| Bot busy (`!idle \|\| inFlight \|\| queued > 0`) | "<bot> is busy. Please ask again later." |
| Homebot request already in flight | "<bot> is still answering the previous question." |
| Deadline before send | "That didn't get sent in time. Please ask again." |
| Deadline after send | "<bot> didn't reply in time. Your question may have been delivered; check the conversation in Grok Bot instead of asking again." |
| Reply refused (§4.2) | "A reply arrived, but Homebot can't confirm it answers this question, so it won't be read aloud. Please check Grok Bot." |
| Long reply | sanitized, truncated at a sentence boundary + "…" |

Exact wording lives in `src/core/i18n.ts` (en, zh-CN). After authentication, the language is the reply language of the token's Siri language (§7.2), with English as the fallback.

## 11. Security model

- **Secrets:** BDK key; client tokens (hash only at rest; plaintext only inside the Shortcut); Shortcut files; one-time download URLs. None go to stdout, logs, the setup API (credential *source* only), or git.
- **Files (closes S4):** `HOMEBOT_HOME` is created 0700. Every secret file is written by `writeFile` to a temp file **in the same dir with mode 0600 at creation**, then renamed. Leftover temp files and expired Shortcut files are deleted at startup. Homebot refuses a `HOMEBOT_HOME` inside a git work tree (overriding this is the user's risk, and the README says so).
- **Network (closes S3):** `:8787` listens on all interfaces. That means **anyone who can reach that port** (same Wi-Fi, guest network, VPN, or a port forward) can try tokens. README: **never port-forward or expose it via a public proxy**; use it only on a trusted home network. HTTP is plain, so someone on the same network can read the token, questions and answers. A copied Shortcut works until revoked, but only for its one bot. HTTPS isn't in v1 (Shortcuts rejects self-signed certs).
- **Abuse limits:** body ≤ 16 KB, question ≤ 1000 chars, one in-flight request per bot, 10 requests/min per token.
- **Processes:** `execFile` with argument arrays only; no shell strings; generated filenames.
- **Logs:** `~/.homebot/logs/homebot.jsonl` (0600; rotation at 5 MB × 3). Request id, bot key, stage timings, outcome, lengths. No text unless enabled, never headers, never download URLs.

## 12. Test plan

**Offline (node --test, every commit):**
- Paging/sync: pages of exactly 200; cursor advances only on non-empty pages; >200 history; page cap.
- Ownership (B1): accept the clean case; refuse a desktop message between idle check and send; refuse a desktop message after our entry and before the reply; refuse foreign output in `(maxSeq, userSeq)`; skip attachment-only; ignore re-updated old entries; strict echo missing → refuse; echo stripped; unknown user-role kind → refuse. **Assert the unrelated reply text is never returned.**
- Deadline (S1): timeout before send → nothing sent; uncertain send (network error after request left) → same `messageId` retried, "may have been delivered" message; client disconnect aborts before send; guard released in every path; second concurrent request rejected.
- Tokens (S2/S3): hash/verify, constant time; cross-bot rejection; pending → active → old retired; pending expiry; signing failure leaves the old token active.
- Files (S4): dir/file modes; temp files 0600; startup sweep; git work-tree refusal; hostile names (`../`, quotes, newlines, HTML) never reach paths or markup; errors contain no secrets.
- Speech sanitizer, envelope, i18n.
- HTTP: `/v1/ask` against an in-process **fake BDK server** for all of the above, plus interrupted uploads, split UTF-8 chunks, disconnect during token activation, CLI revoke seen by the running gateway.
- Shortcut: plist writer (escaping, rejected values), builder snapshots, language profiles (English default; Felix's iPhone-en/Siri-zh-CN mix), file naming and hostile names, signer wrapper with a fake `shortcuts`, signing gate, signing failure revokes, `plutil -lint` on macOS, a built Shortcut's exact request answered end to end, probe-wait.

**Live (approved, DECISIONS items 9–11; run by 拆解师 from the STATUS "M3 kit plan"):** `homebot doctor` read-only; `bot add-id 14752726` cold sync for bot "homebot"; signing for Felix's install; ≤3 `[Homebot test]` questions via curl. (M0 used its own two-probe allowance; see STATUS.)

**Device session (M3, Felix):** import via AirDrop; iPhone Siri; HomePod Siri (sound, announced first); 401 body spoken or not; `.local` resolution; Siri wait-limit probe; echo compliance. Separate timings: gateway response (log) vs. Siri input start and audible completion (Felix's observation).

## 13. Milestones (closes B3)

| M | Content | Exit criteria |
|---|---|---|
| **M0 — Bound the unknowns** ✅ | Package inspection; 2 read-only probes; account route. | Done 2026-10-21: §5.1, §5.2, §6.1. R1: route found. R2: no list, narrowed (DECISIONS). |
| **M1 — Core gateway (offline)** ✅ | home/fs/credentials, BdkClient, sync + ownership, envelope, speech, tokens, AskService with deadline, voice listener, `start`, `bot add-id`, `doctor` | Done; Codex M1 review items fixed (§15 v3). |
| **M2 — Shortcut (offline build)** ✅ | XML plist writer, builder, language profiles, signer wrapper (fake signer in tests, gated), `homebot shortcut build <bot>` → file + Show in Finder; wait-probe Shortcut + `/v1/probe-wait` | Done: offline tests green, `plutil -lint` OK. Real signing waits for OK. |
| **M3 — Device session (Felix)** | live doctor/add-id for bot "homebot" (14752726) → sign → AirDrop → iPhone → HomePod; phrase choice ("homebot 你好" vs "家庭助手"); wait limit; echo rate; 401 behavior; `.local` | **Requirement 5 met** if HomePod speaks the right answer. Defaults tuned. |
| **M4 — Beginner setup** ✅ offline | setup page with the language questions, key, bots by exact name (or session id), Shortcut build, QR link, tokens (§8); README guide | Done offline with fakes, M4 review fixed (§15 v5). Still open: add-by-name and the dashboard key run against the real API (a fresh account, detection off), and everything device-side (M3). |
| M5 — Extras | voice commands, launchd opt-in, Linux notes | per item |

Spike timing evidence, separated by version (S7): the **final one-reply version** shows `first_reply_ms` ≈ `http_reply_ms` (e.g. 6639 / 6640). Records where `http_reply_ms` trails `first_reply_ms` by 1–4 s, or that deferred at 20 s, come from the **older collect-until-idle loop** (`gateway.sync.mjs`), which waited for the bot to go idle and joined multiple replies. Homebot returns on the first owned reply. M1 logs stage timings; Siri-side times are measured separately in M3.

## 14. Open questions for Felix

Answered in docs/DECISIONS.md (2026-10-21): English default + setup asks iPhone and Siri language (G5, §7.2); new Shortcut, not "问拆解师" (Q4); MIT (Q9; LICENSE added); strict attribution with echo (Q-B1); fallback to user-added bots (Q-B2); Mac on + manual start (Q7); M0 permissions (Q1, done).

Round 2 (DECISIONS items 9–15): L1/L2/L3 live steps approved; bot 14752726 is now named "homebot"; Q-NAME: not starting with 问, based on the bot name, plus an all-Chinese alternative (§7.4); Q-ADD: add by exact name with confirmation (§6.2); Q-KEY: Cursor dashboard API key (§5.2, §8).

**Still open:**
- **Q3** — Can a user see a bot's numeric session id anywhere in the Grok Bot app? (M0 found nothing that shows it; add-by-name makes this an advanced route only.)
- **Q5** — M3 device session: timing not set; any HomePod sound is announced and asked first (DECISIONS item 15).
- **Q6** — M0 found no field linking a reply to a message. If Cursor knows one, it would replace the echo rule.

## 15. Changelog

### v9.9 — 2026-10-25 (S16 install flow, D1–D6)
- §7.9 new: the Install step (this Mac with iCloud, or the iPhone), the read-only Shortcuts library check, the calmer Shortcuts list. §7.7: never-used copies are retired after a successful build; answers record whether they came from this Mac. §7.3: the Language step is gone (D2).

### v9.8 — 2026-10-24 (takeover after the first answer, DECISIONS item 27)
- §7.7 / T5: a replacement takes over only when one of its requests ends `answered`. A use only marks it used (file deleted, usable past the 7-day window); refused, timed-out, busy, failed and not-configured requests leave both Shortcuts as they are. The takeover is one locked, idempotent write that retires the covered chain behind it. Under the config → tokens locks it re-checks that the token still grants the bot that answered with its current session, and that the client is still there to hear the answer; a restart's cleanup never removes a used pending token. Single questions, conversation turns and the entry run all count; the entry pin and menu don't. Wait-test and lab tokens take over on first use, as before.
- App: "Waiting for its first answer" state, an iPhone-step line for it, and "Make it again" makes a copy that replaces nothing; a waiting replacement counts as on its way for the language rebuild (§7.3).
- The TypeScript reference keeps first-use activation.

### v9.7 — 2026-10-24 (tagged reply after interim messages, DECISIONS item 26)
- §4.2 O5: untagged deliveries after our message are interim (skipped, counted, never spoken); the first delivery with our tag is the answer. O5 refuses at the turn's end (two idle polls) or the deadline, at once for another request's tag, and for a tagged delivery re-updated without its tag. O2/O3 unchanged. Applies to every bot turn: single questions, conversation follow-ups (§18.3) and the entry run (§20.5) all go through `AskService`.
- Activity and the ask log keep `delivery` and `interim` counts (two nullable columns, added to existing databases).
- The refusal no longer says the reply was withheld "to protect privacy" (zh-Hans, zh-Hant): it says the reply could not be confirmed as the answer. The envelope no longer asks the bot to leave out private details (all eleven languages).
- The TypeScript reference keeps the first-delivery rule (§4.2).
- **Codex adversarial review** (gpt-6-astra high, `.agent-logs/tagged-reply-codex-review.md`, 4 findings), verified: a foreign tag past the 40-character head was missed (now the first complete tag anywhere decides); a tag lost and restored, or lost on a later delivery, could be bypassed (now checked for every delivery first); idle polls before the first interim counted toward the turn's end (now counted from the latest interim). All three fixed with regression tests. The fourth, an answer returned after the deadline fired while `stillGranted` was awaited, predates v9.7 and only delays our own answer; it is a follow-up.

### v9.6 — 2026-10-23 (S5 release readiness)
- Release: `mac/VERSION` is the one version source (build number = 287 + commit count). `mac/scripts/release.sh` builds the universal app, signs it ad hoc inside out without `--deep`, gives every file the commit's time, checks architectures, `minos 15.0` and the signatures, packs `build/Homebot-<version>.zip` with `ditto -c -k --keepParent --norsrc --noextattr`, verifies the unpacked zip and writes a manifest with hashes and the `spctl` verdict (rejected, as expected without notarization). Nothing is published.
- First run (§20.11 B1, B8): the app offers the TypeScript folder's import with an explicit button and never imports by itself; it stops its own gateway for the import and starts it again, and refuses while the old gateway runs. Placement (`AppPlacement`: applications, translocated, elsewhere) drives a move notice; Open at login stays refused from a translocated copy. A Home card for Open at login and keep-awake, a Help page with the install steps.
- Fixes: the follow-up idle wait never sleeps 0 ms (a sub-millisecond remainder spun on the Grok Bot API); a test no longer calls `Process.waitUntilExit()` off the launching thread.
- Docs: `docs/INSTALL.md` (+ zh-Hans) with real screenshots, README for the native app with the AI agent prompt, `docs/ACCEPTANCE.md` for Felix.
- **Codex adversarial review of S5** (gpt-6-astra xhigh, `.agent-logs/s5-codex-review.md`, 6 findings): all verified and fixed with regression tests (`2d43c8b`); the import is complete only when the gateway runs again and Grok Bot accepted the key (§20.4).
- Unverified: a real translocated launch and the Open Anyway flow on screen (only LaunchServices can translocate, after Felix's click), a fresh-account install (§20.9 S5 acceptance), macOS 15 and Intel hardware.

### v9.5 — 2026-10-23 (S4 entry Shortcut built, offline)
- `ShortcutBuilder.entryShortcut`: the §18.2 conversation loop posting to `/v1/ask` without a `bot` field; golden files `entry-en.plist`, `entry-zh.plist` (this builder's own output; there is no TypeScript entry Shortcut), `plutil -lint` clean. `ShortcutKind.entry` makes a token of kind `ask`, mode `entry`, for 1–9 bots; `Profile.entry` names it from the §16 phrase table (zh-CN 家庭助手, then 我家助手 …; never a Latin name where the script forbids it).
- Gateway choosing as in §20.5 with the S4 amendments there (sound matching for Mandarin, every name competes for the margin, session-checked pin, chain-wide set edits, `confirm` outcome).
- `ShortcutRunner` (tests only) interprets the built Shortcut file against the real gateway and the fake Grok Bot: one bot, a clear choice, by number, mis-heard Chinese and English names, sound-alike, no match, alias, silence, step cap, set edit, follow-up pinned. It proves the wiring, not Siri's timing or transcription.
- App: "One bot / All my bots" in the Shortcut step with the bot checklist and the exchange preview, the entry offer and set editing in the Shortcuts list; 13 new strings × 11 languages (drafts). CLI: `shortcut build --entry --bots`, `token bots`, `bot alias`.
- **Codex adversarial review of S4** (gpt-6-astra xhigh, `.agent-logs/s4-codex-review.md`, 7 findings): all verified and fixed with regression tests (`979040f`).
- Unverified until S6 (§19): the extra spoken round trips within Siri's limits, an Ask for Input menu as a long prompt on HomePod, how names and pinyin survive HomePod transcription, the phrases 家庭助手/我家助手 on a device.

### v9.4 — 2026-10-23 (S3 app UI built)
- `mac/` gains `HomebotUI` (view model, setup state machine, views) and `HomebotApp` (the app binary). No Xcode project: `mac/scripts/build-app.sh` builds the SwiftPM products (universal release, or `DEBUG=1`), wraps them into `build/Homebot.app`, compiles the String Catalog into `<lang>.lproj`, renders the Glow, Black and White choices from the vector mark (`--render-icon`, then `iconutil`; Glow is the website logo's colourful light, ported from S17's master), compiles the bundle icon `App/AppIcon.icon` (Icon Composer: white with a black mark, a dark variant black with a white mark) with `actool` into `Assets.car` plus an `AppIcon.icns` fallback for macOS 15, writes Info.plist (`CFBundleIconName` and `CFBundleIconFile`) and signs ad hoc. The running app sets its Dock icon from the App icon choice; the default, Automatic, is White in Light and Black in Dark and follows the appearance live. Finder shows the bundle icon: White, or Black only when the user's macOS 26 icon style is Dark. The CLI moves to `Contents/Helpers/homebot`: in `Contents/MacOS/` it would be the same file as the app binary `Homebot` on a case-insensitive volume (§20.2).
- The window owns the gateway in-process (`GatewayHost`, activity store, keep-awake). Closing it keeps Homebot in the menu bar (no Dock icon); Quit asks, then stops the gateway. The menu bar item shows running state and the last outcome and time, never question text. Settings › This Mac › **Show in menu bar** (on by default, `app.json` `showMenuBar`, back on after Reset everything) hides it; the gateway keeps running, and opening Homebot again (Applications, Spotlight, the Dock) brings the window back (`applicationShouldHandleReopen`). Settings' footer says which of the two applies.
- Setup flow: the web page's five steps natively, with the setup server's semantics ported into the view model (key shape, add by name typed twice, just-created detection with the renamed-bot notice, add by session id, explicit Create with confirmation, rename, remove, signing consent before a signed build, one-time download link with a Core Image QR code, replace from the Shortcuts list). Home, Shortcuts and Settings as in §20.6; open at login through `SMAppService.mainApp`, refused from a translocated copy.
- Text: one String Catalog (`mac/App/Localizable.xcstrings`, 238 keys × 11 languages) generated by `scripts/swift-ui-strings.ts` from `web/src/i18n/*.ts` plus the app-only strings in `mac/App/app-strings.ts`; the generator refuses missing or extra keys, a test checks every key and placeholder in every language. The page language is chosen in the app, so tables are read per language, not through Bundle's preferred localization.
- Look: Liquid Glass buttons and toasts on macOS 26 (`glassEffect`, `.glass`/`.glassProminent`), the bordered system styles and `.regularMaterial` on macOS 15; the mark, the Siri orb and the Grok Bot icon drawn in SwiftUI with the web page's hues and timings, still under Reduce Motion; colour-only hover with a gliding highlight; light and dark.
- Dev mode (`--dev`, verification only): a temporary support folder (or `--dev-home`, never a real Homebot folder), 127.0.0.1:18787, the Grok Bot API only on loopback and never on 8787/8788/18787 (`--bdk-base-url`, else a dead end), a fake signer that copies the file, an in-memory login item, `--dev-seed none|key|bot|shortcut|activity`, `--dev-page`, `--dev-lang`, `--dev-appearance`. `mac/scripts/dev-app.sh` runs it against `scripts/fake-grokbot.ts`.
- Tests instead of XCUITest (§20.8): a SwiftPM package has no UI-test target, so the view model is tested against the in-process fake Grok Bot API (`HomebotUITests`), and the flow is checked by screenshots and a Codex computer-use run of the dev build.
- **Codex adversarial review of S3** (gpt-6-astra xhigh, `.agent-logs/s3-review.md`, 6 findings): all verified and fixed (`f10ca05`, `4c9c71c`): dev-home and dev-port guards; a key check records against the generation of the key it sent; an overtaken refresh drops its data; a step's late "done" moves on only in its own visit; Reduce Motion fades instead of moving.

### v9.3 — 2026-10-23 (S2 gateway and CLI built)
- `mac/` gains `HomebotGateway` (the LAN listener on Hummingbird 2.28.0, Apache-2.0, with swift-nio 2.104.0, swift-nio-extras 1.35.1 and swift-log 1.16.2, all Apache-2.0) and `HomebotCLI` (`homebot`, on swift-argument-parser 1.8.2, Apache-2.0). `voice.ts` and `downloads.ts` are ported rule by rule: 16 KiB body cap and the JSON-object check before the token is used, auth/scope/in-flight guard, deadline, `text/plain` for v1 and JSON for v2, `/v1/health`, one-time `/dl/` links, `/v1/probe-wait`, `/v1/lab`, `/v1/bots` (never activates or retires a token), run pinning.
- Hummingbird does not cancel a handler when the client leaves. A per-connection channel handler cancels the request's signal on input close, inactivity or error, and that cancels AskService and a conversation step's shared work (closes S1 Codex finding 4). It also closes the connection after a response that says `Connection: close` (Hummingbird honours only the request's header) and limits a request to 70 s from head to end; the 10 s idle timeout covers gaps between body parts.
- Activity store (§20.6) on the system SQLite: files created 0600 before SQLite opens them (the `-wal`/`-shm` copy that mode), path resolved with `realpath(3)` and opened with `SQLITE_OPEN_NOFOLLOW`, folder excluded from backups and read back; `tmutil isexcluded` reports `[Excluded]` (checked in a test on a temporary folder). Clear deletes the database with its `-wal`, `-shm` and `-journal`. Spoken text is filtered of protocol fragments, the key and the token (A1).
- One gateway per support folder (A5): a `flock` owner lock, and a 0600 control socket (peer uid checked) for status, activity and Clear. The CLI reads or clears activity through the owner, or directly only while it holds the lock itself.
- Keep-awake service: an `IOPMAssertion` (PreventUserIdleSystemSleep) plus a `ProcessInfo` activity, held while the gateway serves.
- Importer from `~/.homebot` (§20.11): refuses while the old ports listen, refuses links and other users' folders, takes the new owner lock and the old `O_EXCL` locks (kept fresh while it copies), imports only into an empty store, retires sessionless tokens unless kept (T2), copies the old key once, then writes a `MOVED` marker that the TypeScript CLI now refuses.
- **Codex adversarial review of S2** (gpt-6-astra xhigh, `.agent-logs/s2-codex-review.md`, 16 findings): 15 verified and fixed with regression tests (`1f41935`), 1 not reproduced but guarded. T3 is now checked again right before a question is sent and before an answer is returned; another token can't end a run; the entry flow follows the token's mode (a one-bot entry token stays an entry token) and its menu never activates; import claims the old folder with an exclusive `MOVED` marker and refuses while the TypeScript gateway's new `gateway.pid` names a live process (the TypeScript start writes it, then checks for the marker again, so one side always sees the other); a failed import restores both folders; the old key is saved only if none exists; control-socket stop no longer waits on a request that needs the gateway actor (deadlock); stop waits for a start in progress; Clear drops records of requests that started before it; usage errors under `homebot account` never echo arguments; bot previews are filtered of the key. Not reproduced: a pipelined request replacing the older one's cancel signal (NIO holds pipelined requests back); every open request is cancelled on disconnect anyway.
- Parity: a Swift test imports a folder the TypeScript CLI made, loads the same fake transcripts and replays 24 Shortcut-shaped requests recorded from the TypeScript gateway; status, content type and body match (`scripts/swift-gateway-golden.ts`). Intended differences are listed in `mac/PORTING.md`.

### v9.2 — 2026-10-23 (S1 core built; Codex adversarial review of the Swift code)
- `mac/` holds the `HomebotCore` Swift package (§20.9 S1): the core modules ported rule by rule, golden tests against the TypeScript output, an in-process fake of the Grok Bot API; `mac/PORTING.md` maps all 212 TypeScript tests.
- **Codex review of the Swift code** (`.agent-logs/s1-swift-review-codex.md`, 14 findings, 3 blocking): 13 fixed with regression tests, 1 deferred to S2. A refused token edit leaves the in-memory cache unchanged; an edit mirrors both added and removed bots into a pending replacement (T4); the grant is checked again after the bot's answer arrives, also for a waiting retry (rule 3); a refused step ends its run; an expired pending token is not a usable predecessor (T6). Files: the home is refused when its resolved path is inside a git work tree; the BDK login is opened once with `O_NOFOLLOW|O_NONBLOCK` and must be a regular file of at most 1 MB; the startup sweep removes only temp files older than 10 minutes, so it never breaks another process's write; the log holds a cross-process lock across rotation and append; a build whose token is revoked while it is written or signed deletes its file and fails. BDK calls and cold sync have a hard time limit even when the transport ignores cancellation; the spoken-length limit never traps.
- **Deferred to S2:** cancelling the HTTP request does not yet cancel a conversation step's shared work (Codex finding 4); fixed together with AskService, which owns the send.

### v9.1 — 2026-10-23 (rules frozen before the Swift core, Grok review S9)
- §20.4 credentials: one 0600 `api-key` file, then the BDK login at `~/.config/agent-serve/credentials.json` only when its `backendUrl` is Cursor's API; no environment variables; no other logins.
- §20.5 single entry: the per-language phrase from §16 (not the word "Homebot"); tokens scoped to an explicit bot set (T1–T6; old tokens migrate as one-bot sets); choosing never activates a token; the chosen bot is spoken back and confirmed; a run is pinned to one bot; the changes to §4.1, §6.3, §7.7 and §18.2 are listed there.
- §20.6 activity: record fields, outcome codes, nothing before authentication, never tokens/keys/echo tags/refused text, backup-excluded `Activity/` directory, Clear deletes the database with its `-wal`/`-shm`.
- §20.10: Liquid Glass where it fits (Felix).
- **Codex adversarial review of these rules** (`.agent-logs/s1-rules-review-codex.md`, 17 points, 8 blocking): all agreed and folded in before S1 code. Verify, admit and activate in one locked step that returns the authorized `(key, sessionId)`, and the turn uses that session; a grant removed mid-turn stops the send or the reply; a pending replacement is edited with its predecessor and the subset rule is re-checked at activation; runs are pinned to key and session and revalidated before every step and cached reply; the numbered menu is a snapshot; ambiguous names are matchable by number only; the single-bot entry still says the bot's name; retries must carry the same input fingerprint; activity has no text for choosing steps, filters protocol fragments and the key before speech and storage, counts unauthenticated requests instead of storing them, is opened only by the gateway owner (Clear goes through it), and writes no text unless the backup exclusion reads back; `kind` (authorization) is separate from `mode` (Shortcut shape); sessionless TypeScript tokens import retired unless the user binds them; the credential's accepted state belongs to a generation; the cross-process lock is a kernel `flock`, never broken by time.

### v8.3.1 — 2026-10-23 (conversation reviews: docs/reviews/conversation-review-codex.md, -grok.md)
- **B1 (both reviewers): agreed.** The follow-up wait now judges user entries from the follow-up's first sync on, not only during the polls after it. Dormant while `followupIdleMs` is 0; fixed before it can be turned on.
- **Agreed:** the wait never sleeps past its allowance; a v2 request always gets JSON once its body is parsed (token or config errors included); a step that throws ends its run and its retry gets the same answer; only a run's start counts toward the rate limit, so a 10-step run and its retries are never cut off; a cached retry is answered only for its run's bot.
- **Not changed:** a body that isn't JSON or is over 16 KiB can't be read as v2, so it keeps the v1 400/413 (a Shortcut always sends valid JSON well under the limit). A retried step 0 starts a second run; nothing reaches the bot, and the first run expires.

### v8.3 draft — 2026-10-22 (conversation mode built ahead of the device results)
- §18 built offline and opt-in (CLI `--conversation` only): runs on `/v1/ask` `v: "2"`, end words and silence end a run without reaching the bot, any non-answer ends the run, the step cap is the one sent at the start, retries never ask twice, a run is bound to its token and bot. The envelope carries the turn number and says only the first message is heard (§18.4).
- The follow-up idle wait (§18.3) is implemented but off (`followupIdleMs` 0) until Felix answers Q18-3 and the turn-tail data gives a value.
- Setup page (first-run review with screenshots): the wait-test option is hidden unless the gateway serves it; no QR link for unsigned Shortcuts; Siri language names follow the page language; the signing note says why and how.

### v8.2 draft — 2026-10-22 (after the Codex milestone review, docs/reviews/milestone-voice-ux-1-review.md)
- **B1: agreed.** A poll with a failed page keeps its evidence for refusals, but a reply is accepted only after a poll that read every page to the end (§4.2 unchanged in intent; the R1 fix had opened this gap).
- **S1: agreed.** Phrase uniqueness (§16.2) is checked again inside the token lock, for every Shortcut kind (voice, wait test, lab).
- **S2: agreed.** A replacement keeps the replaced Shortcut's phrase when it still passes §16.2; the setup page previews with the replaced token.
- **S3: agreed.** Every `/v1/lab` response is JSON with a spoken line, including bad JSON, oversized bodies and server errors (§19.1).
- **S4: agreed.** Runs (§18.2) have an end state: a retry of the last step gets the final response, a later step is refused, and a step is refused while the previous one is still pending. The step cap is the one sent at the start.
- **S5: agreed.** E1 is split: E1 (silence on the first prompt) and E1b (silence after an answer) are separate runs (§19.2).
- **S6, S7: agreed.** Run ids are validated before lookup or logging; the matcher reports full only for the whole sentence and adds `partial` (§19.1).
- Re-review (docs/reviews/milestone-voice-ux-1-rereview.md): the kept phrase is refused only by blocking problems, not advice; `/v1/lab` without `--lab` answers lab tokens with a spoken "lab is off" and `next: end`.
- Nits: E5 has six steps as specified; the setup steps say to test on an iPhone whose Siri language matches the HomePod's.

### v8.1 draft, Grok review — 2026-10-22 (docs/reviews/design-review-v8-grok.md)
- Agreed with the second reviewer: V1 (Speak Text) is the default and V2 needs E4 (B2); the follow-up wait refuses on any user entry during the wait and stays 0 until measured (B1); one unknown per run, fresh runs for E2/E7, marker words for E4, import the lab Shortcut a day ahead (B3); phrase uniqueness across all languages (S1); the envelope says only the first delivery was heard (S3). B4 (lab text) was already fixed by B3 of the Codex review.
- Not adopted: "E0" (the question in the same breath as the Shortcut name): a Shortcut run by Siri receives no part of the spoken invocation, so there is nothing to measure.

### v8.1 draft — 2026-10-22 (after Codex design review v8, docs/reviews/design-review-v8.md)
- **B1 (runs): agreed.** A run id issued by the gateway plus an ordered step number; duplicates are answered from cache; overlapping runs keep separate state (§18.2).
- **B2 (last answer lost): agreed.** The last step's response always ends the run, so its answer is spoken; no hold on the last step (§18.2).
- **B3 (lab privacy): agreed.** Received text is matched and discarded; no keep-text option (§19.1).
- **S1: agreed.** The follow-up idle wait is a scheduling allowance, with a full re-sync and idle re-check; it changes D13 and needs Felix's OK (Q18-3).
- **S2: agreed.** The turn tail counts other activity and reports "idle not observed" as a timeout (code done).
- **S3: agreed.** No shortness heuristic; hold only on explicit continuation words and only if the pause tests call for it; "发送" defined; silence never sends (§17.3).
- **S4: agreed.** Lab tokens are their own kind; normal mode refuses them (§19.1).
- **S5: agreed.** Only a leading 问 is refused; other leading words are advice (code done, §16.2).
- **S6: agreed.** Replacement keeps its phrase; uniqueness is "within Homebot's records" (§16.2; code already exempted the replaced token).
- **S7: agreed.** 5-minute run expiry; unknown or expired runs end with a spoken restart hint; JSON for every v2 response; the step cap can only be lowered by the gateway (§18.2).
- **S8: agreed.** Scenarios restartable, controls added, observed bounds labeled as such, `followupIdleMs` from the turn tail, not the lab (§19).
- **N1: agreed.** §7.4 marked superseded; run / step / bot turn terms (§18.1).
- Conversation mode: recommendation changed to opt-in while experimenting (Q18-1).

### v8 draft — 2026-10-22 (first device session, DECISIONS items 18–19)
- §16–§19 added: one script per Siri language for phrases, cut-off questions, conversation mode, and the device experiments that decide the open points. Multi-turn is no longer a non-goal (§1).

### v7.2 — 2026-10-22 (after Codex BDK fix-round re-review, docs/reviews/bdk-fix-round-rereview.md)
- **R1 (blocker): agreed.** A failed page no longer discards entries that earlier pages of the same poll returned: `syncToEnd` hands each page to the caller as it arrives (§4.1 step 11). Tests: O2, O3 and O5 evidence before a failed page still refuses; a failure alone still answers.
- **R2: agreed.** Logged error names come from a fixed list; anything else is `"other"`.

### v7.1 — 2026-10-21 (after Codex BDK transport review, docs/reviews/bdk-transport-review.md)
- **B1, B2 (O6 spoke unproved text): agreed; O6 reverted.** Turn flags can't prove that a later delivery belongs to our request, and the collected text skipped re-checking. Homebot again speaks only the text one `decideReply` checked, returned at once (§4.1 step 11, §4.2). Service tests on a socket-free scripted BDK cover replacement text, late O2/O3 evidence, other-task output and bad flags.
- **S1 (settle cap): resolved by the revert** (no settle phase). The local reload before the deadline is now described as outside the budget (§4.1 step 6).
- **S2: agreed.** Unknown `delivery` values are logged as `"unknown"` only.
- **S3: agreed.** Scripted page seam added; the HTTP fake stays for transport tests.
- **N1: agreed.** `I` only for a fully valid idle state; otherwise `?`.
- **N2: agreed.** Stale O6/timing claims removed. The spike-timing note "Homebot returns on the first owned reply" is true again.

### v7 — 2026-10-21 (BDK transport, DECISIONS item 17)
- **O6 (§4.2, §4.1 step 11):** after the first owned reply, wait for the turn to settle and speak all of its deliveries, stopping at foreign input; capped by `settleMs` (3 s) and the deadline.
- **Delivery check (§4.1 step 10, §5.1):** a `delivery` other than `accepted_temporal`/`duplicate` stops waiting at once; the user still hears "may have been delivered".
- **Evidence (§5.1):** page vs session tail, cursor-beyond-tail, no single-session GET; POST-by-name rejected for the baseline. Per-poll turn states are logged (`turns`) so the next live run shows real turn values.
- Not adopted: `interrupt` (still only for a future explicit "stop" command), waiting for a busy turn instead of answering "busy" (D13).

### v6.1 — 2026-10-21 (after Codex TS migration review, docs/reviews/ts-migration-review.md)
- **S1 (array bodies): agreed.** The port had silently started rejecting JSON arrays on `/v1/ask`; the JavaScript listener authenticated them and asked an empty question. The port now restores the old handling, and a separate API correction rejects every non-object body with 400 before authentication (§4.1 step 3), with a contract test. v6's "no behavior change" also overlooked this; the malformed-file handling changes are listed in STATUS.
- **S2 (signing status): agreed.** §7.5 and the README now say signing worked for Felix before the migration (XML accepted directly), and that post-migration signing, iPhone import and HomePod use are unchecked. The default-off gate and the new-account key caveat stay.
- **N1, N2: agreed.** DECISIONS item 16 now gives Node support per release line (minimum stays 24.12.0) and calls `.ts` import paths a convention that `allowImportingTsExtensions` permits but doesn't enforce.

### v6 — 2026-10-21 (TypeScript, DECISIONS item 16)
- **D1 changed:** the code is strict TypeScript that Node ≥ 24.12 runs directly (built-in type stripping, stable from 24.12.0 per <https://nodejs.org/api/typescript.html>). Users still install and build nothing. Only erasable syntax is allowed, enforced by `tsconfig.json`; `npm run typecheck` checks everything.
- The setup page is TypeScript too (`web/`, React + beUI). Vite builds it into `src/setup-ui/`, which is committed and checked for drift by `npm run check:ui` and a test. The API response shapes are declared once (`src/server/setup-api.ts`) and used by the server, the page and the tests.
- G3 and §3.1 updated (Node ≥ 24.12, `.ts` layout). No behavior change: all 151 existing tests pass unchanged in substance, and one new test was added (UI drift).

### v5 — 2026-10-21 (after Codex M4 review, docs/reviews/milestone-m4-review.md, and DECISIONS items 9–15)
All accepted; no disagreement.
- **B1 (a build during removal could authorize an old Shortcut for a new bot): agreed.** New `BotLifecycle` (§6.3): add, remove and token issuance run under one config lock and re-read the files; issuance re-checks the bot's session. Tokens record the session id and the voice listener refuses a token whose bot now points elsewhere. Tests: a build that captured the bot before remove + re-add issues nothing and writes no file; ten raced build/remove rounds never leave a usable token; a token whose key now points at another session gets 401 and sends nothing.
- **S1 (a rejected concurrent add could overwrite another bot's cursor): agreed.** Identity is re-checked under the lock before the cursor is written; cursors are session-tagged; StateStore writes are locked read-modify-write; AskService skips persisting for a changed bot. Tests: the losing add leaves config and cursor untouched; a stale writer for another session can't advance the cursor.
- **S2 (a wait test could retire the working voice Shortcut): agreed.** Token kinds (`ask`/`probe`), checked before activation; cross-kind replacement refused; the page gates the option on `--probe-wait` and rejects probe + replaces (§7.6). Tests at the store and over HTTP.
- **S3 (owner decisions not applied): agreed.** Bot "homebot" in examples; Chinese phrase `<bot> 你好` with the all-Chinese alternative and warnings (§7.4); add by exact name with confirmation and just-created detection (§6.2; offline with the fake only); dashboard key copy; signing described as off by default with Felix's own-install approval kept separate. Historical changelog entries keep their old names.
- **S4 (Siri-language change silently leaves Shortcuts unchanged): agreed.** Notice on save, `languageDiffers` flag and "Make a replacement" (§7.3). Test: an English token is flagged after switching to Chinese, and not once retired.
- **S5 (account status overclaimed; precedence text wrong): agreed.** Credential kind + access state (`unchecked` until Grok Bot accepted the key); env override instructions; saved overrides detected (§8). Tests for env, saved, detected, saved-over-detected, accepted and rejected.
- **S6 (privacy copy overstated): agreed.** Page and README say what stays on the Mac and what goes to Grok Bot or Apple; strict checking is described by what it refuses; turning it off needs a confirmed warning (server-enforced).
- **N1 (README details): agreed.** Rename the unzipped folder; Siri in iCloud; 25 s as the reply budget; the 24 h lifetime qualified.
- **N2 (page didn't refresh): agreed.** Refresh on focus/visibility and a button. Not browser-tested this round (no browser tools allowed); a test checks every element id the script uses exists.
- **N3 (QR decoder check had no control): agreed.** The Swift script decodes an Apple-generated symbol first; the test skips with the reason if that control fails or Swift can't run, and otherwise requires every symbol to decode.
- New CLI: `bot add-name`, `bot remove`, `token issue --curl-header` (header file for `curl -H @file`, so the token never appears in argv); `/v1/ask` accepts `"test": true` for `[Homebot test]` envelopes.

### v4 — 2026-10-21 (M4 offline: setup page + README)
- §8 rewritten as built: loopback-only setup listener started by `homebot start`; languages, account key, bots by session id (add/remove), Shortcut build/preview, QR link, Shortcut list with honest states and revoke. Deferred items listed in §8.
- `start` no longer requires credentials; the key is resolved per BDK call (§8 step 1). A Shortcut request without a key gets the existing "can't sign in to Grok Bot" message.
- Removing a bot revokes its tokens (new rule, §8 step 3).
- §7.8: one-time link built; own QR encoder verified by Apple's detector instead of a vendored library (no runtime dependency, no third-party code to audit).
- README: end-user install and setup guide with troubleshooting (recognition lag, Personal Requests, Mac asleep, signing outages); unverified steps marked.
- `scripts/dev-setup.ts`: offline demo of the page against the fake Grok Bot API (for reviewers).

### v3.1 — 2026-10-21 (after Codex M2 review, docs/reviews/milestone-m2-review.md)
All accepted; no disagreement.
- **S1 (cleanup deleted another process's fresh artifact): agreed.** Cleanup now runs inside the `tokens.json` lock after reloading the file (both after mutations and when called directly). Artifacts are created only after their record is written, so a pending record always exists when another process sweeps. Tests: a stale store's sweep keeps a build made after its snapshot; concurrent builds and sweeps from two stores keep every live artifact (§7.5).
- **S2 (24 h lifetime not enforced): agreed.** Every CLI run sweeps; the running gateway sweeps every 10 min; the CLI text now says files go "once 24 h old, by the running gateway or the next homebot command". Tests exercise the triggers (an unrelated CLI command; a running gateway with no requests), not only the predicate.
- **S3 (wrong name in the setup steps): agreed.** One effective name (the sanitized file name) is printed, used in the steps and stored as the label; a changed name is announced. Probe builds tell the user to run the probe Shortcut. Tests check the full steps for both.
- **S4 (`--replaces` could retire another bot's Shortcut): agreed.** Validated under the lock: must exist, be non-retired and belong to the same bot. Rejections issue nothing and leave the old token usable (§7.7).
- **S5 (signer output not 0600 from creation): agreed.** Fixed `/bin/sh` umask-077 launcher with argument passing only. Test: a fake signer script creating its output under a permissive parent umask, both on success and on failure, plus a hostile output path (§7.5).
- **N1 (failed builds left pending tokens): agreed.** URL validated before issuing; one failure boundary after (revoke + delete directory). Test: invalid URL issues nothing; an XML failure during a replacement build leaves the old Shortcut working.
- **N2 (test claims): agreed.** Renamed to "token-to-HTTP integration" and "separate CLI store instances"; the ordered-persistence test now makes several writes, the first slowest, and asserts no overlap and non-decreasing order. Real Shortcut execution stays M3 acceptance.

### v3 — 2026-10-21 (after Felix's DECISIONS, M0, and Codex M1 review)
**Felix's decisions (docs/DECISIONS.md):**
- English is the product default (G5). The setup asks for the iPhone system language and the Siri language. The Siri language drives the Shortcut name, prompt, Speak Text voice, reply language and spoken messages; the iPhone language drives the setup steps (§7.2, §8). Felix's iPhone-en / Siri-zh-CN mix is a test case.
- New Shortcut, default "Ask <bot>" / "问问<bot>", never the spike's "问拆解师" (§7.4). MIT license (LICENSE). Strict attribution with echo approved (§4.2, R3). Fallback "pick from bots you've added" approved (G6, R2). Mac on + manual start is acceptable for v1.

**M0 (§5.1, §5.2, §6.1):** four session routes, no account-wide list (P2 = 404), empty pages echo the cursor (P1), turn = `{idle, inFlight, queued}` (busy rule updated in §4.1), personal user API key. Add-by-name is back as a **proposal** (Q-ADD) because that is how the official extension addresses bots.

**Codex M1 review (docs/reviews/milestone-m1-review.md):**
- **B1 (CLI revoke ignored by the running gateway): agreed.** `tokens.json` is the single authority (D14). Every mutation is a lock-file read-modify-write against the latest file; `verify` re-reads the file when its fingerprint changed; activation re-checks the state under the lock, so a token revoked meanwhile is refused. Test: CLI revoke while the gateway runs → 401.
- **B2 (gateway crash on an interrupted upload): agreed.** The abort controller and `close` listener are set before any `await`; the request handler has an outer catch (500 with an internal-error message, never a crash); a disconnect during token activation is noticed and `ask` is not called. Tests for both.
- **B3 (bad JSON could print credential content): agreed.** `readJson` errors are fixed texts (`cannot read <name> (<code>)` / `<file> is not valid JSON`), never the parser message. Test with a secret inside invalid JSON.
- **B4 (re-update could erase ownership evidence): agreed.** The ownership check keeps all versions of each entry; O2 refuses if any version of a foreign entry was user input, O3 refuses on any `send-message` (with or without text) before our entry. Tests for the re-update cases.
- **S1 (split UTF-8): agreed.** The body is collected as Buffers and decoded once.
- **S2 (deadline vs persistence; cold sync cap): agreed.** Cursor persistence is chained off the response path (`flush()` on shutdown and in tests). Cold sync has a page cap and a 120 s total cap with a fixed message.
- **S3 (bot key ↔ session ownership): agreed.** A key can't move to another session, a session can't get a second key (`checkBot` before any network call). The in-flight guard is per session id.
- **S4 (English default): agreed.** English fallback everywhere. Language is bound to the token (`--siri-lang`), not to the bot.
- **S5 (abandoned plaintext artifacts): agreed.** Token and Shortcut artifacts are deleted on first use, revoke, expiry, after 24 h, and at startup (§7.5).
- **S6 (baseline retries): agreed.** Baseline GETs retry within the same deadline.
- **N1: agreed.** Test names and comments tightened; file-mode assertions added.

**M2:** §7 rewritten for the implementation: language model (§7.2), naming (§7.4), file naming because iOS names an imported Shortcut after its file (§7.5), signing gate `HOMEBOT_ALLOW_SIGNING` (§7.5), wait-limit probe (§7.6). §10 examples now English, quoted from the catalog.

### v2 — 2026-10-21 (after Codex design review 1)
- **B1 (reply ownership): agreed.** Replaced "first reply after our entry, accepted risk" with a strict ownership rule (§4.2): no foreign user input since the baseline, no foreign output before our entry, and by default an echoed `[hb:<id>]` tag from the bot. Otherwise Homebot refuses and doesn't speak. Tests must assert the unrelated reply is never returned, including a desktop message between the idle check and the send. Any-bot vs dedicated-bot is Felix's decision (Q-B1, R3); my recommendation is strict + any bot.
- **B2 (account route and listing): agreed.** Made both explicit release gates (R1, R2) with concrete M0 outcomes (§6.2). Manual id = dev aid only, not requirement 4. **Removed add-by-name.** New-user validation runs with credential detection off (§5.2). Key-type questions moved from Felix to M0 investigation. Narrowing requirement 4 is Felix's decision (Q-B2).
- **B3 (milestones): agreed.** Reordered: core (M1) → Shortcut build (M2) → **device session with HomePod (M3)** → discovery/setup page/QR (M4). The wait-limit probe is built in M2 and run in M3, the same device session.
- **S1: agreed.** No late answers in v1. One deadline covers sync, send and poll; abort before send; after send no cancel claim, no interrupt, no repeat advice; guard released in `finally`; cold sync moved out of the voice path (§4.3).
- **S2: agreed.** pending/active/retired token states; old token survives until the new one is used (§7.5).
- **S3: agreed.** Tokens bound to one bot, checked every request; generic Shortcut needs an explicit grant (later); network exposure described honestly; no port forwarding (§11).
- **S4: agreed.** 0700 dir, 0600 from creation incl. temps, startup sweep, git work-tree refusal, textContent rendering, generated filenames, argument arrays, bearer URLs never logged.
- **S5: agreed.** Validation by read-only cold sync; preview optional, labeled, and taken from `syncToEnd` (§5.3, §6.3). Clarified that a history over the cap can't be fixed by resetting.
- **S6: agreed.** 401 kept, spoken behavior marked unverified; "received a request with this Shortcut's token" instead of "your iPhone reached Homebot"; received/answered/confirmed states; embedded settings flagged "needs a new Shortcut".
- **S7: agreed.** Removed the "likely the shared serial chain" guess. Timing evidence separated by spike version.
- **N1: agreed.** "No npm install needed at runtime"; QR source/version/license to be recorded; "JSON request, plain-text response"; XML-only minimal serializer.
- **N2: agreed.** One directory implementation after M0, immediate busy rejection instead of a queue (D13), QR choice made as an engineering decision (old Q8 removed).

### v1 — 2026-10-21
- First draft.

---

# Part 2 — Voice UX after the first device session (v8 draft, 2026-10-22)

The first HomePod session (STATUS 2026-10-22) met requirement 5 and found three problems (DECISIONS item 19). §16–§19 design them. Facts come from Apple documentation, public user reports and our own logs. Each is labeled **checked** (our device or log), **documented** (Apple page), **reported** (users, not Apple) or **unverified**. Research notes with sources: Grok research of 2026-10-22, summarized in §19.6.

## 16. Siri phrases: advice per language

### 16.1 Problem and facts
- **Checked:** on a Chinese (Mandarin) HomePod, "家庭助手" triggers reliably; "homebot 你好" does not; "问拆解师" worked; "问 Grok Bot" did not.
- **Documented:** you run a Shortcut by saying its name; if the name equals a built-in command, the Shortcut wins (Shortcuts User Guide, "Run shortcuts with Siri"). Apple states no rule about the script of a name. The likely mechanism: the recognizer for one Siri language rarely outputs a word from another script, so the exact name never appears in the transcript and the "name match" never happens.
- **Documented:** each HomePod has its own Siri language (Home app → HomePod → Settings → Language). It is copied from the iPhone at setup and can be changed later.
- **Researched, nothing found:** no Shortcuts action, Home app export or public HomeKit characteristic exposes the HomePod's Siri language. Get Device Details describes the device the Shortcut runs on, which is the iPhone. So **the user tells us** (as now), and the page explains where to look.

### 16.2 Design (v10, DECISIONS item 29)
Apple states no rule about the script of a Shortcut's name (§16.1), and tapping a Shortcut runs it whatever its name. So only what Homebot can guarantee blocks a phrase; how likely Siri is to hear it is advice.

1. **Phrase table per Siri language** (`src/shortcut/profile.ts`, generated into `Catalogs.generated.swift`). Each row has:
   - `script`: the characters Siri in this language most likely hears (Han only for Chinese; Latin letters, space, apostrophe and hyphen for English). No digits: Siri may say a number in several ways. Advice for the user's own phrase; defaults must pass it.
   - `products`: ranked default phrases. Since DECISIONS item 33 every row starts with "Grok Bot", then a "my Grok Bot" form where natural (zh-CN "我的 Grok Bot", ja "うちの Grok Bot", de "mein Grok Bot"; English "My Grok Bot", "Our Grok Bot"), then two native names as suggestions (zh-CN "家庭助手", "我家助手"). The first unused one is the default. "问 Grok Bot" is left out: a leading 问 failed on a device (DECISIONS item 12). The brand never counts against `script`: the check runs on the phrase without "Grok Bot".
   - The bot's own name, offered as a phrase only when it has no problem at all in this row (e.g. zh-CN bot "拆解师" → "拆解师"), and never when it reads as the app ("homebot", "Home Bot"). Without "你好" or "问": the bot name alone is shorter and avoids leading intent words.
   - `badStarts`: leading words that Siri may parse as its own intent (zh: 问, 查, 播放, 打开, 设置, 什么; en: ask, call, play, set, open, turn, text, what). All advice. `strong` marks a device failure ("问", DECISIONS item 12; "問" for zh-TW by analogy), worded as a likely failure.
   - `prompt`: the Ask for Input question, in the row's language. It names the Shortcut's phrase, never the bot (S25: a bot called "homebot" read as the app's name): "What would you like to ask Grok Bot?", "想问家庭助手什么？". A phrase with advice (another script, a leading command word) is left out ("想问什么？"). An entry Shortcut's prompt names nothing; its step 0 says the chosen bot's name instead. The dialog itself is Apple's Ask for Input; Homebot sets only its text.
2. **Problems.** Comparison is on the NFC form, trimmed, with single spaces, case-insensitive; English leading words match whole words only. Prompts are not phrases: they keep their punctuation.

   | Code | When | Blocks? | Page text key |
   |---|---|---|---|
   | `wrong-script` | a character outside `script` (other scripts, digits, symbols) | no | `wrong-script-advice` |
   | `search-start` | a `strong` leading word (问, 問) | no; strongest wording | `search-start-advice` |
   | `bad-start` | another leading command word | no | `bad-start-advice` |
   | `unsafe-chars` | the name is not equal to its file name (`safeFileName`: no `/ \ :`, control characters, leading dot or space), so iOS would import another name | **yes** | `unsafe-chars` |
   | `in-use` | another pending or active Homebot Shortcut has the phrase (rule 3) | **yes** | `in-use` |

   A name must also be 1–60 characters. **Defaults never carry advice:** a product phrase or the bot's name is only offered when it has no problem at all. A replacement keeps the old phrase when it has no *blocking* problem and is for the same reply language (`keptPhrase`); a Shortcut for another language gets that language's default.
3. **Uniqueness, within Homebot's records:** a new phrase must differ from every pending or active Homebot Shortcut, in any language and including test Shortcuts (they all live on one iPhone; Grok review S1), except the one it replaces. The default skips phrases in use and moves to the next one. Homebot can't see Shortcuts it didn't make, or retired ones still installed on the phone; the steps tell the user to delete a replaced Shortcut. Because `unsafe-chars` blocks, the checked phrase is always the imported name.
4. **Setup page wording:** "What language is your HomePod's Siri set to?" Hint: "Home app → your HomePod → Settings → Language." With item 29 this is the default for new Shortcuts.
5. **Done means answered.** Setup is complete when the new Shortcut, tapped on the iPhone, gets its first answer (pending → active, DECISIONS item 27); that proves the gateway address, token, bot and speech. Saying the phrase to Siri is a bonus, with hints: a phrase outside the Siri language may not be heard; HomePod needs Personal Requests, the same Siri language as the iPhone, and minutes to a day to learn a new name; an iPhone that only shows the answer needs Settings › Siri › Responses › Prefer Spoken (muted iPhones answer silently when Siri is started with the button). UI: S15 proposal step 4.
6. **The experiment flag is gone.** `--experiment-phrase` (DECISIONS item 28) only turned these rules into advice for one build; they are advice for every build now.
7. **README:** the phrase advice, voice as a bonus, the HomePod's learning delay (minutes to a day; it may answer with web results meanwhile), testing on the iPhone first, and the Prefer Spoken tip.

### 16.3 Languages
**v8.4 (DECISIONS item 23):** all eleven page languages are Siri languages, one Siri locale each (en-US, es-ES, fr-FR, de-DE, it-IT, pt-BR, ru-RU, ja-JP, ko-KR, zh-CN, zh-TW), with the rows in `src/shortcut/profile.ts`. The table below is where their phrases came from. Before v8.4: English (8 variants) and zh-CN. Each new language needs a phrase row plus about 15 spoken system messages and the envelope text (`i18n.ts`, `envelope.ts`). Candidates, from Apple's HomePod update notes (HomePod Siri languages) and the naming research; each must be tested on one HomePod in that language before release:

| Siri language | Phrase candidates (ranked) | Note |
|---|---|---|
| English (all variants) | Grok Bot · My Grok Bot · Our Grok Bot | Q16-1, decided 2026-10-24 |
| zh-CN Mandarin | 家庭助手 · 我家助手 · 居家助手 | 家庭助手 checked on device |
| zh-TW Mandarin (Taiwan) | 居家助理 · 家裡助理 | 助理 is the Taiwan word |
| yue-HK Cantonese | 屋企幫手 · 屋企管家 | avoids 家居 (the Hong Kong name of the Home app) |
| ja-JP | うち助手 · 家事助手 | avoids ホーム |
| ko-KR | 집비서 · 집도우미 | Korean HomePod support: confirm |
| fr (FR, CA, BE) | majordome · aide foyer | avoids "Maison" (the Home app) |
| de (DE, AT) | Hausgeist · Haushelfer | |
| es (ES, MX, US) | mayordomo · ayuda hogar | avoids "Casa" |
| it-IT | maggiordomo · factotum | |
| nl (NL, BE) | huisgeest · huishelper | avoids "Woning" |
| Portuguese | — | Not a HomePod Siri language (user reports) |

### 16.4 Questions for Felix
- **Q16-1 English phrase.** You suggested "Homebot". Risk: on a HomePod, "Homebot" sounds close to "HomePod", and a phrase that starts with "home" can be taken by the Home app. If the transcript never contains exactly "Homebot", the Shortcut never runs (the same failure as "homebot 你好"). Options:
  - (a) "Homebot", tested first;
  - (b) "house butler";
  - (c) "Homebot" as the product name and "house butler" as the default phrase, with "Homebot" offered as an alternative.

  My recommendation is (c), and an English-Siri device test decides it.

  **Decided 2026-10-24 (DECISIONS item 28):** neither. The default names the real target: "Grok Bot", then "My Grok Bot", "Our Grok Bot". "Ask Grok Bot" is not a default: "ask" is a leading command word (advice), and the default list only holds phrases with no problem at all. Other languages keep their native-script phrases, because "问 Grok Bot" did not trigger on a Mandarin HomePod. No official localized name of Grok or Grok Bot exists (web search 2026-10-24: Japanese, Korean and Russian media transliterate it as グロック, 그록, Грок; Chinese media and the Cursor docs keep "Grok"). A bot whose own name fits the row's script is still offered through `fromBot`.
- **Q16-2 Which languages in the next release?** My recommendation: English and zh-CN now (the phrase rule and table as above). Next zh-TW and yue-HK (same Han script, small change), then ja/fr/de/es when someone can test them on a HomePod.

## 17. Questions cut off by a pause

### 17.1 Facts
- **Documented:** iPhone, iPad and Apple Watch have **Settings → Accessibility → Siri → Siri Pause Time** (Default / Longer / Longest), "how long Siri waits for you to finish speaking". Durations are not published. HomePod settings show no such option.
- **Unverified (key unknowns):**
  - U1: whether Pause Time also applies to the listening of *Ask for Input*, on the iPhone and when the HomePod runs the Shortcut;
  - U2: what Ask for Input returns when the user says nothing (empty text, an error, a repeated question, or the Shortcut stops);
  - U3: whether touch-and-hold on the HomePod keeps the microphone open until released, as holding the iPhone side button does.
- **Reported:** answering Ask for Input with "No" stops the whole Shortcut (Reddit 2021; Apple Communities, iOS 26.1). Dictate Text launched from a HomePod is skipped, or makes Siri suggest the iPhone (2018, 2023 reports), so it is not a candidate.
- **Checked (log):** today's questions were 2, 3, 4, 4, 9 and 19 characters long. Consistent with cut-offs, but the log has no text, so it proves nothing.

### 17.2 Options

| | Approach | Cost to the user | Risk | Depends on |
|---|---|---|---|---|
| P | **Platform setting:** Siri Pause Time "Longest" on the iPhone (README step) | none after setup | may not affect Ask for Input or the HomePod | U1 |
| H | **Hold to talk:** hold the HomePod top (iPhone: side button) while speaking | a habit | may not exist for Ask for Input | U3 |
| A | End word: keep listening until "好了 / send" | every question | awkward; long sessions | U2 |
| B | Always ask "anything else?" after each piece | one extra round each time | slow | U2 |
| C | Gateway judges completeness; asks to continue when the text looks unfinished | only on suspected cut-offs | misjudges short complete answers ("Why?", "继续") | U2 |
| L | **Conversation loop (§18)** without any guessing: a cut-off question gets an answer, and the user continues in the next turn; the bot sees both parts | one extra turn when cut off | the bot may act on half an instruction | U2, §18 |

### 17.3 Recommendation (revised after design review v8 S3)
1. **P and H first.** No code, only the experiment (§19). If either works on the HomePod path, it goes into the README and the setup steps.
2. **L next**, built with §18. It needs no completeness guessing.
3. **C only if the pause tests show P/H/L are not enough**, and then only on *explicit* continuation signals, never on shortness: the utterance ends, after punctuation is removed, in a whole word that needs a continuation (zh 因为, 所以, 但是, 然后, 而且, 如果, 还有, 就是; en and, or, but, because, so, if). Then the gateway holds the fragment, answers with a short cue ("嗯，你说。" / "Go on."), and joins the next utterance (a space for English, none for Chinese; combined length ≤ the question limit). Defined commands while holding: "发送" / "send" submits the held text; an end word (§18.2) drops it with "好的，没发送。"; empty input or expiry drops it too (silence is never taken as permission to send an uncertain instruction). One hold per question. No hold on the last step (§18.2). Each hold is logged with lengths only.

## 18. Conversation mode

### 18.1 Goal and facts
After the answer, Siri should keep listening, so the user can just continue. **Reported:** loops of Ask for Input → POST → Speak (e.g. clawpod, up to 50 rounds, with an end flag from the server) work on HomePod. **Unverified:** how long a HomePod keeps such a session (U4), the longest wait for Get Contents of URL on HomePod (U5; one disconnect at 10.3 s today, while another answer at 10.5 s was spoken), and whether a long text works as the Ask for Input prompt, so that Siri reads the answer and then listens in one step (U6).

Terms: a **run** is one invocation of the Shortcut; a **step** is one listen-and-POST inside a run (`Repeat Index`); a **bot turn** is a step that sends a message to the bot.

### 18.2 Design: the Shortcut is a thin loop; the gateway decides
The Shortcut contains no policy. It repeats one step; the gateway's reply says what to say and whether to listen again. End words and holds can change on the gateway without a new Shortcut. That matters because every Shortcut change means a re-import and up to a day of HomePod learning. The step cap is fixed in the Shortcut: the gateway can end earlier, never later.

```
Text "<first prompt>"                     -> say          (variables: say, run)
Repeat 10 times                                           (Repeat Index = step)
  Ask for Input   prompt = say                            [V2]   (V1: Speak say; Ask "还有吗？")
  Get Contents of URL POST /v1/ask {v:"2", bot, text: Provided Input, run, step: Repeat Index, last: 10}
  Get Dictionary Value say / next / run   (run is "" on step 1; the gateway issues it)
  If next is "listen"  -> (nothing; loop)
  Otherwise            -> Speak Text say (wait); Stop This Shortcut
End Repeat
Speak Text say                                            (only reached if the gateway broke the contract)
```
- **Contract:** the response to the step with `step == last` always has `next: "end"`, so the last answer is spoken by the Otherwise branch (design review B2). A hold is never offered on the last step.
- **Every failure ends the loop and is spoken:** for `v: "2"` the gateway answers JSON in every case, including 400/401/403 (the body is parsed before authentication, as today, §4.1 step 3). A missing or unexpected `next` falls into Otherwise: speak and stop. Network failures surface as Siri's own error (out of our control).
- **Variant V1 (default):** `Speak Text say` (explicit language, §7.2; the action that met requirement 5), then `Ask for Input` with a short prompt. **Variant V2** (only if E4 shows it works): the answer is the next prompt. V2 must also show the whole answer is read, in the right language.

**Gateway (`v: "2"`):** response `application/json` `{"say", "next": "listen" | "end", "run"}`. v1 Shortcuts keep plain text, unchanged.
- **Runs (design review B1):** step 1 creates a run: a random id, bound to the authenticated token and its bot, returned as `run`. Later steps must carry the same `run` and the token that created it, and `step` must be the run's last step + 1. A repeat of the last step (an HTTP retry) gets the cached response and sends nothing to the bot again. Any other step number, an unknown run (e.g. after a restart) or a run from another token → `{say: <"Let's start again: say the Shortcut's name again">, next: "end"}`, nothing sent. A token can have several runs (two runs of the same Shortcut overlapping); each keeps its own state.
- **Expiry:** a run expires 5 minutes after its last step (an answer, its playback and the user's thinking fit easily). An expired run is treated as unknown (above). A held fragment is dropped with the run; the user is told the next time (never silently sent).
- **Per step:**
  1. **End words** (the whole utterance, punctuation removed, case-folded; never a substring, so "怎么结束这个项目" is a question) → `{say: <goodbye>, next: "end"}`; nothing is sent to the bot. Since S25 every language's list counts on every Shortcut (Felix said "没有了" and "结束" to an English one), and the lists hold "no", "nothing", "that's all", "I'm done", 没有了, 没了, 就这样, 不用了 and their equivalents (`END_WORDS`). While the entry chooser asks "Did you mean …?", its own yes/no words answer that question first.
  1b. **The bot ends the run** (S25): on a conversation turn with strict echo, the envelope says: if the user is clearly ending the conversation, start the reply with `[hb:<id>] [end]`, then a short goodbye. `[end]` counts only right after our own tag at the very start of the accepted reply (`endMarked`); anywhere else it ends nothing. It is never spoken. The goodbye is spoken (Homebot's goodbye when the bot wrote none), and the response says `next: "end"`. All ownership rules apply unchanged; a bot that omits the mark keeps today's behaviour.
  2. **Empty input** (depends on U2) → end the run.
  3. **Hold** (§17.3, only if built) → `next: "listen"` with the cue.
  4. Otherwise a **bot turn** (§4, unchanged ownership, one request id per turn). The answer comes with `next: "listen"` (or `"end"` on the last step); every error, refusal or timeout message comes with `next: "end"`.

- **Built (offline, experimental):** `src/core/conversation.ts` (runs, end words, step cap), `v: "2"` on `/v1/ask` (JSON in every case after the body is parsed; a body that isn't JSON still gets the v1 plain-text 400, since its version is unknown), `buildConversationShortcut` (the same loop as the lab Shortcut, so the lab's Mac dry run checks it too), `homebot shortcut build <bot> --conversation`. Not on the setup page until the device results (Q18-1). The Mac app (2026-10-24, Felix testing as a user) offers it opt-in on the Shortcut step: "Keep listening after each answer", off by default, per-bot Shortcuts only (never the one-phrase Shortcut). It builds the same Shortcut as `--conversation`; the Shortcuts list shows "Conversation" in the row's detail line; "Make it again" and language replacements keep the kind; the iPhone guide's last caption and the Shortcut step's note say to end by saying you're done, in any words (S25; before, they named one end word). Step 0 sends the Shortcut's own question and the gateway returns it as a V2 prompt, so a run starts like today's Shortcut; answers use V1.
- **If on a JSON field (checked 2026-10-24: seen on Felix's iPhone, iOS 26; reproduced and fixed on macOS 26):** `next` and `mode` come from Get Dictionary Value, which has no fixed type. For such a variable Shortcuts offers only "has any value" / "does not have any value", so `If next is not "listen"` imported with its value dropped and the run stopped at the first If with "Please choose a value for each parameter in this action." Fix: each If reads its variable as Text (the editor's "Get: Text"), the `WFCoercionVariableAggrandizement` to `WFStringContentItem` on the `WFInput` variable. With it the app keeps `WFCondition` 4/5 and `WFConditionalActionString` as we write them. Evidence: our If, typed as Text in the macOS editor and exported by the app, differs from the builder's output only by that aggrandizement (`mac/Tests/HomebotCoreTests/Fixtures/apple-if-macos26.plist`; `IfShapeTests` checks every loop Shortcut against it). A probe Shortcut made of the builder's own If actions, run with `shortcuts run` on macOS 26, took the right branches (`next` end/listen, `mode` v2/v1). The keys are the long-standing ones (no new `WFConditions` form), so older iOS should read them too (not tested). The JSON contract is unchanged. The fallback, an If on "has any value" of a key sent only while listening, was not needed.

### 18.3 Ownership across bot turns (revised after design review v8 S1)
Today's log shows the turn flags stay **busy while the reply arrives** (`turns` = `B…`). Homebot returns as soon as the reply is proved, so when the user continues 2–5 s later the bot's previous turn may still be running. Under the current rules the follow-up is answered "busy" (§4.1 step 8).
- **Rule:** inside a run, if the previous bot turn of *this run* was answered, the gateway may wait up to `followupIdleMs` for the session to become idle before taking the baseline. It records the cursor when the follow-up arrives; if any entry with `role: "user"` (in any version) appears during the wait, the follow-up is answered "busy" with `next: "end"` and nothing is sent (Grok review B1: a desktop exchange during the wait must not slip below the new baseline unnoticed). `followupIdleMs` stays 0 (today's immediate "busy") until the turn-tail data gives a value. **The wait is a scheduling allowance, not evidence of ownership:** an answered reply proves only that one delivery; the remaining busy activity may be anything (a desktop message, a routine). During the wait the per-bot in-flight guard is held, and the deadline and disconnect abort apply. After it, the baseline is a full sync to the end, and idle is checked again on that sync; still busy → "still busy", as today. Entries that arrive after the baseline are judged by §4.2 as usual (late output → O3 refusal). The baseline never moves after sending. Nothing from the previous turn's tail is ever spoken.
- This changes the immediate-busy policy of D13 / DECISIONS item 17 for follow-ups inside a run only. It needs Felix's OK (Q18-3).
- **Built:** `AskRequest.waitIdleMs`, set by the conversation service only for a follow-up whose previous turn in the run was answered, from `settings.followupIdleMs` in `config.json` (default 0, capped at 10 s). With 0 the behavior is today's immediate "busy".
- **`followupIdleMs`** comes from the turn-tail diagnostic (built): after an answer, the gateway polls the session with GETs (≤ 30 s, one observer per session, stopped by the next request for that session and at shutdown; it never moves the persisted cursor or touches tokens) and logs `idle_after_ms`, or `timeout` when idle was not observed, plus counts of other user entries and deliveries seen meanwhile. It measures the *session*, not our turn; runs with other activity are read separately. The lab (§19) can't measure this, because it has no bot.

### 18.4 Envelope
A conversation turn uses the same short hint as a one-shot question (§5.4), without "end with a statement" (the user can answer right away) and, with strict echo, with "If the user wants to end the conversation, start with [hb:<id>] [end], then say a short goodbye." (§18.2). Until DECISIONS item 35 it also named the turn number, said the user could reply right away and that the room heard only the bot's first message; that last line was not exact after v9.7 (the spoken delivery is the first *tagged* one), and none of it was load-bearing. The ProtocolFilter strips the fixed sentences and the request's echo and end instructions if a bot quotes them back.

### 18.5 Risks
- **Room speech is picked up** (TV, other people) while Siri listens after an answer, and sent to the bot. Strict ownership protects what is *spoken*, not what is *sent*. Limits: the step cap, end on errors, end words. The setup page says plainly that conversation mode listens again after each answer.
- **A long Siri session** may be ended by Apple at a limit we don't know (U4).
- **Latency per bot turn** is about 6–10 s (today's log).

### 18.6 Questions for Felix
- **Q18-1** Conversation mode default. **Closed: on by default (Felix, 2026-10-26; DECISIONS item 36).** New per-bot Shortcuts keep listening after each answer (the Make form, `homebot shortcut build`; `--no-conversation` turns it off). Existing Shortcuts keep their kind; "All my bots" always loops.
- **Q18-2** The end words in §18.2: add or remove any?
- **Q18-3** OK to wait up to `followupIdleMs` (expected a few seconds; set from the turn-tail data) for idle on a follow-up inside a run, instead of answering "busy" at once (§18.3)?

## 19. Device experiments (need Felix and HomePod sound)

### 19.1 Method (revised after design review v8 B3, S4, S8)
- **One lab Shortcut** ("家庭实验" for the Chinese HomePod), with the §18.2 loop and **both** V1 and V2 branches; a `mode` field in each response picks the branch, so one import covers E4. Before the loop it POSTs a `start` step, and the gateway answers with the current scenario's first prompt.
- **Lab tokens are their own kind** (`lab`), like probe tokens (§7.6): only `POST /v1/lab` accepts them; `/v1/ask` refuses them before any bot code runs; they never replace or retire a voice token. `/v1/lab` exists only while the gateway runs with `start --lab`, and it never contacts a bot. Voice Shortcuts keep working during the lab, on `/v1/ask` as always. Every `/v1/lab` answer is JSON with `next`, refusals included, so the loop always ends cleanly.
- **Built (offline):** `src/core/runs.ts` (runs, reused later by conversation mode), `src/core/lab.ts` (scenarios in zh-CN and English, matching, log), `buildLabShortcut` (`src/shortcut/build.ts`), `homebot shortcut build <bot> --lab`, `homebot start --lab`, `homebot lab use <E1, E1b, E2..E7> [--delays …]`, `homebot lab report`.
- **Scenarios** are selected on the Mac (`homebot lab use E2`) and are restartable on their own, so a scenario that ends the Shortcut (E1, E1b, E6) never blocks the others. The gateway can also delay a response (simulated bot time) and return a long answer.
- **What the lab log stores (privacy):** scenario and step ids, the expected sentence id, received length, whether it was empty, a match result against the expected sentence (full / cut: its start only / partial: its end only / other / empty), timings, disconnects. **Received text is discarded** after matching. No keep-text option. Manual observations (what Siri said, whether a prompt was read in full) are noted by Felix and recorded by Claude in STATUS. "No next request" is recorded as such, never interpreted alone.
- **Order of devices:** a Mac dry run first (checks the action graph: loop, If, dictionary values, run id), then the iPhone, then HomePod time only for HomePod-dependent behavior. **Import "家庭实验" at least a day before the HomePod part**: a new name can take that long to be recognized on HomePod.

### 19.2 Scenarios (priority order; ~20 min is a timebox, not a promise)

| # | Unknown | Scenario | Recorded | Decides |
|---|---|---|---|---|
| E1, E1b | U2 silence | E1: silence on the first prompt. E1b: one answer, then silence (a separate run, since silence may stop the Shortcut) | empty text arrived? run continued? Siri's words (Felix) | how runs end (§18.2 step 2) |
| E2 | U1 pause time | A fixed sentence without a pause (control), then with a 1 s, 3 s, 6 s pause; one fresh run per Pause Time setting (Default, Longer, Longest; Felix changes it on his iPhone between runs); iPhone, then HomePod | match vs expected | README step P, need for C |
| E3 | U3 hold | The same sentence and pause while holding the HomePod top from before the prompt ends until after speaking; the iPhone side button as the control. (Apple documents hold-to-talk for the first request only.) | match | README step H |
| E4 | U6 | V1 vs V2 with a short answer, then ~250 and ~500 characters ending in a marker word that Felix says back | marker word received (objective), right voice (Felix) | V1 or V2 |
| E5 | U4 | A realistic run: 6 steps with simulated 8 s bot time and normal answers, including the last-step boundary | all steps arrived; total run time | supported run length (an observed bound) |
| E6 | "No" | Answer "不用了" / "No" | run stops? (no next step + Felix) | end words |
| E7 | U5 | One fresh run per delay: 8, 12, 16, 20, 25, 30 s, then narrow the boundary with `--delays`; repeat the boundary twice | disconnect time; answer heard on the HomePod? | request deadline (with margin). Replaces the pending "Homebot 等待测试" (mixed script, may never be recognized; revoke it). |

### 19.3 Order of work
1. Built, no device needed: the phrase rule (§16), the turn-tail diagnostic (§18.3), the R1/R2 ownership fixes.
2. Next, offline: lab mode and lab tokens, the lab Shortcut (both variants), `homebot lab use|report`; fake-BDK tests for runs (overlap, duplicate steps, expiry, last step, lab-token rejection).
3. Felix: Mac dry run (approval: signing + a Shortcut added to his Mac), then the device session.
4. After the results: the conversation loop (§18) for real Shortcuts; hold rules only if E2/E3 call for them.

### 19.4 Needs Felix
- Approve signing the lab Shortcut (Apple's signing service) and the Mac dry run.
- Pick a time for E1–E7 (HomePod speaks).
- Q16-1, Q16-2, Q18-2, Q18-3 (Q18-1 closed: on by default).

### 19.5 Research notes (2026-10-22, Grok web research; claims as labeled above)
- Siri Pause Time: support.apple.com/guide/iphone/change-siri-accessibility-settings-iphaff1d606/ios. HomePod settings: support.apple.com/guide/homepod/change-settings-apde6dc8093d/homepod.
- "No" stops a Shortcut: reddit.com/r/shortcuts/comments/o23bq7, discussions.apple.com/thread/256182261.
- Dictate Text from HomePod: discussions.apple.com/thread/254565868; reddit.com/r/shortcuts/comments/9hyww7.
- Run Shortcuts with Siri (name match): support.apple.com/guide/shortcuts/run-shortcuts-with-siri-apd07c25bb38/ios.
- HomePod languages: support.apple.com/zh-cn/108045 (HomePod software update notes).
- Loop prior art (idea only; no license, nothing copied): github.com/algal/clawpod.
- Shortcut action identifiers and keys for the loop (repeat.count, conditional, getvalueforkey, exit, setvariable): ScPL action definitions (MIT) and ShortcutsBench parameter extract (Apache-2.0); identifiers only, no code copied. Not yet checked against an Apple export: the Mac dry run does that.

## 20. Native rewrite: Homebot.app in Swift (v9 draft, 2026-10-23)

> Status: **v9.6, 2026-10-23.** Draft for Felix's review (DECISIONS item 25); §20.4–§20.6 are frozen as the rules S1 builds on (Grok review S9). S0 passed; S1 (`mac/`, `HomebotCore`) is done (§15 v9.2); S2 (gateway, activity, CLI, importer) is done (§15 v9.3); S3 (the app UI) is done (§15 v9.4); S4 (the entry Shortcut) is built and tested offline, its device test is S6 (§15 v9.5). S5 (release zip, install guide, first run) is done offline; its fresh-account install check needs Felix (§15 v9.6). The TypeScript version (§3–§19) stays in the repository as the reference and the fallback until the Swift version reaches parity (§20.9).

### 20.1 Why, and what stays the same
Felix's decisions (DECISIONS items 24, 25): users never need a terminal; Homebot is an Apple-only product; it ships as one Mac app, not a web page plus a server. Native Swift removes the bundled Node runtime and gives the app system features directly: login item, sleep assertion, menu bar, notifications, Keychain, the system's accessibility and dark mode.

**Unchanged, ported rule by rule:** the voice API contract the installed Shortcuts call (`/v1/ask`, headers, body, `text/plain` replies, §4.1), the reply ownership rules O1–O5 and strict echo (§4.2), deadlines and cancellation (§4.3), the cursor rules (§5.3), the envelope (§5.4), token states and replacement (§7.7), the Shortcut action graphs (§7.1, §18), the phrase rules and the eleven language catalogs (§16, DECISIONS 23), signing consent (§7.5, DECISIONS 24). The existing tests are the specification: each one gets a Swift counterpart (§20.8).

**Dropped:** the loopback setup web server and its JSON API (the UI talks to the core in-process, so the CSRF/host-header surface disappears), the React page and its build, the Node runtime, the QR encoder (Core Image draws QR codes), and detection of any login other than Grok Bot's own.

### 20.2 Shape
```
Homebot.app (one universal binary: arm64 + x86_64, macOS 15+)
 ├─ SwiftUI window: setup flow, Home (status + activity), bots, Shortcuts, settings
 ├─ menu bar item: running / last request / open window / quit
 ├─ Gateway (in-process): LAN listener :8787 → AskService → BdkClient
 ├─ Stores: ~/Library/Application Support/Homebot (0700 dir, 0600 files)
 └─ Contents/Helpers/homebot — CLI for agents and power users, same core
    (not MacOS/: on a case-insensitive volume MacOS/homebot is the same file as MacOS/Homebot)
```
- **Swift package `HomebotCore`** (no UI): models, stores, tokens, BDK client, ownership rules, envelope, speech, languages and catalogs, Shortcut builder, signer wrapper, activity log. Swift 6 strict concurrency; actors for the stores and the in-flight guard.
- **`HomebotGateway`**: the LAN HTTP listener. Recommendation: **Hummingbird 2 on SwiftNIO** (Apache-2.0, maintained, HTTP/1.1 parsing we don't write ourselves; this listener faces the LAN). Alternative: Network.framework plus our own minimal HTTP/1.1 parser (no dependency, but a parser is security surface). License and version are checked at adoption.
- **`HomebotApp`**: SwiftUI app target, depends on the two packages. Built as a SwiftPM executable (`HomebotUI` library + `HomebotApp`) and wrapped into `Homebot.app` by `mac/scripts/build-app.sh` (S3: no Xcode project, reproducible from the command line).
- **`homebot` CLI**: `swift-argument-parser` (Apache-2.0). Same commands as today where they still make sense (`doctor`, `bot`, `token`, `shortcut build`, plus `status` and `log`), working on the same stores under the same file locks, so an agent can run the whole setup (§20.7).
- The app is ad-hoc signed and **not notarized** (DECISIONS 24). Release = a zip on GitHub Releases plus an illustrated "Open Anyway" guide (System Settings → Privacy & Security, available for about an hour after the blocked launch; source: Apple's Mac User Guide, see `.agent-logs/no-terminal-packaging-grok.md`).

### 20.3 Running without a terminal
- **Start at login:** `SMAppService.mainApp.register()`. *Unverified* for an ad-hoc-signed, un-notarized app on macOS 15/26 (spike S0). Fallback: a per-user LaunchAgent plist written by the app, with `AssociatedBundleIdentifiers`.
- **Awake while serving:** an `IOPMAssertion` of type `PreventUserIdleSystemSleep` while the gateway runs, switchable in settings ("Keep this Mac awake for Siri"). The display may still sleep. A Mac that is already asleep does not wake for the Shortcut's request (§19.5 research; no Bonjour advertisement), so Home says so plainly.
- **Local Network privacy (macOS 15+):** accepting incoming connections does not need the permission; outgoing LAN connections and `.local` resolution do (Apple TN3179). The gateway only accepts, and Grok Bot is on the internet, so no prompt is expected. *Unverified:* that no prompt appears for the app as built (S0).
- **Window closed ≠ quit:** closing the window leaves the gateway running with the menu bar item; Quit stops it and says Siri won't reach Homebot until it is opened again.

### 20.4 Credentials (frozen for S1, 2026-10-23; amended by §20.11 S3 and the S0 result)
- **One credential at a time, two possible sources, in this order:**
  1. **The saved key:** a Cursor API key the user pasted ("Use an API key instead", or `homebot account set-key`, which reads the key from standard input, never from an argument). Stored as **one file**, `api-key` in the support directory (§20.5 rule T0: directory 0700, file 0600 from creation, atomic write), containing the key only. No Keychain (§20.11 S3).
  2. **The detected BDK login:** `~/.config/agent-serve/credentials.json` under the user's home directory, read in place and never copied, used **only when** it is a regular file (not a symlink) whose JSON has a non-empty string `apiKey` and a `backendUrl` that is `https://api.cursor.com` (scheme `https`, host exactly `api.cursor.com`, no user, port, query or fragment; an empty path or `/` only). Any other backend, a missing `backendUrl`, malformed JSON or an unreadable file means "no usable login"; the Account step says a Grok Bot login was found but is for another server or unreadable, and asks for a key. The exact `backendUrl` string the BDK writes for Cursor's production API is *unverified* (we never open that file); S6 confirms it on Felix's Mac by the Account step's answer, not by reading the file.
  3. Otherwise: no credential; the Account step explains there is no Grok Bot login on this Mac and asks for a key.
- **No environment variables** (`CURSOR_API_KEY`, `CURSOR_API_KEY_FILE`, `CURSOR_SERVICE_ACCOUNT_KEY`, `AGENT_SERVE_CONFIG_DIR`, `XDG_CONFIG_HOME`, `HOMEBOT_DETECT_CREDENTIALS`) are read by Homebot.app or its CLI. A Finder-launched app sees none of them, so honouring them in the CLI only would make the two disagree. Tests inject the home directory and files instead.
- **No other logins are detected** (DECISIONS 25). The Grok Bot desktop app's own files are not a BDK login and are not read.
- **What is shown or logged:** the source only (`saved` / `bdk-login`), and whether Grok Bot accepted the key (`unchecked` / `ok` / `rejected`). Never the key, a prefix of it, its length or its hash. Errors reading either file use fixed messages that quote no content.
- **Credential generation:** the gateway keeps an in-memory generation number that changes whenever the resolved credential changes (its source or its key, compared in memory only). The accepted state belongs to one generation: a change resets it to `unchecked`, and a check that finishes for an older generation is ignored, so a slow old check can never mark a new key `ok`. A bot turn resolves the credential once at its start and uses it for all its calls; a change during the turn takes effect from the next turn.
- **Removing the saved key** deletes the file; the detected login, if any, is used again from the next turn. No restart is needed.
- **Import from the TypeScript version (S2):** the import reads no environment variables (the new app never does) and makes no claim that access continues uninterrupted. If the old `secrets.json` holds a key it is copied once into `api-key`; otherwise the user pastes a key or uses a detected BDK login under the rules above. Either way Home shows Grok Bot's answer to the first check before the import says it is done.

### 20.5 One entry: one Siri phrase for all of a user's bots (frozen for S1, 2026-10-23; built in S4)
Felix: users should have one Shortcut, not one per bot (DECISIONS 25). The Grok review (§20.11 B6) found that a literal "Hey Siri, Homebot" breaks the phrase rules (§16). These rules replace the v9 draft and are what S1's token model is built for.

**Phrase.** The entry Shortcut is named by the §16 phrase table of its Siri language, like every Homebot Shortcut: the first unused product phrase (zh-CN "家庭助手", zh-TW "居家助理", ja "うち助手", en "House Butler" until Q16-1 is decided, …), with the same script rule, refused leading words and uniqueness check (§16.2). The Latin word "Homebot" is a phrase only where the phrase table allows it (today: English, as an alternative). The product name in the UI stays Homebot.

**Tokens (rule T1–T6; per-bot Shortcuts and the entry Shortcut use the same model).**
- **T0 — files:** the support directory is `~/Library/Application Support/Homebot` (0700; `config.json`, `state.json`, `tokens.json`, `api-key`, `Logs/`, `Shortcuts/`, `Activity/`; never inside a git work tree). The token store is `tokens.json`, written as in §11/D14: 0600 from creation, temp file + rename, every change a locked read-modify-write, readers re-read when the file changed. **The cross-process lock is a kernel lock (`flock` on a `.lock` file next to the store), released by the kernel when its holder exits or crashes; it is never broken by elapsed time** (the TypeScript lock's 10-second stale break could let a suspended writer resume after another process took the lock, and is not ported). Lock order is always config → tokens.
- **T1 — scope is an explicit bot set.** A token grants a non-empty set of at most 9 bots, `bots: [{key, sessionId}]`, chosen by the user for that Shortcut. A per-bot Shortcut is a one-bot set. "All my bots" is never stored as a wildcard: adding a bot to Homebot never widens an existing Shortcut by itself; the app offers "also answer for this bot" per entry Shortcut, which edits the set (T4).
- **Kind and mode are separate fields.** `kind` is the authorization kind and keeps the TypeScript values (`ask`, `probe`, `lab`; absent means `ask`): it decides which endpoints a token may call. `mode` is the Shortcut's shape, for display and activity only: `single` (one question), `conversation` (per-bot loop), `entry` (§20.5 entry flow), or `legacy` for every migrated token (the TypeScript records do not say which Shortcut they were made for). Replacement compares `kind`, never `mode`, so an entry Shortcut can replace per-bot Shortcuts.
- **T2 — migration.** A TypeScript token record `{bot, sessionId}` becomes `{bots: [{key: bot, sessionId}], mode: "legacy"}` with hash, id, label, state, times, `replaces`, `siriLang` and `kind` unchanged, so Shortcuts already on the phone keep working. A record **without** `sessionId` (made before M4) has no evidence of which conversation it was made for, so it is imported **retired**, unless the user explicitly chooses "keep this Shortcut for <bot>" in the import step, which binds it to that bot's current session (recorded as the user's binding, not as preserved identity). A record whose bot is gone is imported retired.
- **T3 — verify, admit and activate in one locked step.** Under the config → tokens locks, in this order: the hash check (constant time, `pending` within 7 days or `active`); the endpoint kind check; then the grant. A request that names a bot is allowed only if that bot is in the set (else 403 `forbidden`) **and** the grant's `sessionId` equals the bot's current session (else 401, as §6.3). A request that names no bot is allowed only for a one-bot set (that bot), or for the entry flow, which offers only the grants whose session is still current (none left → 401). Activation (T5) happens inside the same step, only after all checks pass. The step returns the **authorized grant `(key, sessionId)`**, and the bot turn uses exactly that session: it never looks the bot up again by key, so a remove/re-add between admission and the turn cannot redirect a question to another conversation.
- **Revocation during a turn.** A turn re-reads its grant (same key **and** same `sessionId` still in the token's set, token still usable) just before sending and again before speaking the reply. Gone before sending → nothing is sent (`not-sent:revoked`). Gone after sending → the reply is not spoken; Siri says the fixed "not configured" line (`revoked`). Better silent than wrong.
- **T4 — editing a set** (add a bot, drop a bot) changes the record in place under the config → tokens locks, never changes `state`, never activates or retires anything, and needs no new Shortcut (the set lives on the Mac, not in the file). A set never becomes empty by an edit: dropping the last bot is a revoke and says so. While a pending token replaces this one, an edit is applied to both together (adding a bot adds it to the replacement too; dropping a bot from the replacement alone is refused), so the subset condition of T6 keeps holding.
- **T5 — activation.** *(Amended in v9.8, DECISIONS item 27: such a request now only marks the token used; it becomes `active`, and the token it replaces `retired`, when one of its requests ends `answered`, §7.7. Everything below about which requests count still decides which ones mark it used.)* A pending token becomes `active`, and the token it replaces becomes `retired`, on its first authenticated request **that names or pins a bot** (v1 `/v1/ask`, where an omitted `bot` pins a one-bot set; v2 step 0 with a `bot` field; the entry flow's step that pins the chosen bot). Requests that only authenticate (the entry flow's choosing steps, any future bot-list call, wait-test and lab endpoints of another kind) never activate or retire a token. A bad body, a wrong endpoint kind, a forbidden bot or a session mismatch never activates and never retires the predecessor. At activation the subset condition is checked again on `(key, sessionId)` pairs; if it no longer holds, the new token still activates but the old one is **not** retired (nothing is silently lost; the app shows both).
- **T6 — removal and replacement.** Removing a bot from Homebot removes its grant from every token in one locked step (§6.3); a token left with no grant is retired. `replaces` (§7.7) must name a usable token of the same `kind` whose grants (compared as `(key, sessionId)` pairs) are a subset of the new token's, so a replacement never silently drops a bot; a replacement is never widened automatically. Everything else in §7.7 is unchanged. Phrase uniqueness (§16.2) is checked under the same lock, across all kinds, as today.

**The entry flow** is the §18.2 thin loop (`v: "2"`, gateway decides, step cap fixed in the Shortcut), started without a `bot` field. The gateway keeps a **choosing phase** in the run state before any bot turn:
1. **Step 0:** authenticate (T3/T5: no activation). One live grant → the run is pinned to it at once, and step 0 **always says that bot's spoken alias before the question prompt** ("拆解师。想问什么？"), so the user hears which bot will get the question even when the set has one bot (a set edit could otherwise silently change who answers the same phrase). Several → say "Which bot? 1 <name>, 2 <name> …" (the set's order, at most 9) and listen. The numbered menu spoken is **stored in the run state as a snapshot** of `(number, key, sessionId, spoken name)`.
2. **Choice step:** the utterance is matched against the **snapshot**, never the live list, so a number keeps the meaning it had when it was spoken. Normalization: NFKC, case-folded, punctuation and spaces removed. Matching, in order: an exact name or alias match, the number (a digit 1–9 or the language's number word, whole utterance only), then edit distance ≤ 1 per 4 characters with a margin of at least 2 over the second best. **Ambiguity:** a name or alias that normalizes the same as another entry's in the menu, or the same as a number word, yes/no word or end word of the language, is not matchable by name (only by number); the app warns about such names when a set is edited. The chosen snapshot entry is then revalidated (T3: same key and `sessionId` still granted and current); if that fails the menu is spoken again from the live list as a new snapshot, and this counts as a miss. **Exact name or number:** the chosen bot is spoken back as part of the next prompt ("拆解师。想问什么？"), which is the confirmation; a whole-utterance "no" word ("不对", "不是", "no", "wrong" … per language) at that prompt returns to the choice once. **Fuzzy match:** spoken back as a yes/no question ("是拆解师吗？"); only a "yes" word continues, anything else returns to the choice. An end word while choosing ends the run with the goodbye line; silence counts as a miss. No confident match → say the menu once more and listen; a second miss ends the run ("I didn't find that bot", `next: "end"`). Nothing is sent to any bot during choosing, and the utterances heard while choosing are matched and discarded before anything is queued for storage (never logged; activity keeps the chosen bot and the outcome only, A1).
3. **Pinned:** from the first question on, the run is pinned to the chosen grant — key **and** `sessionId` — for its whole life. Before every step, including a retry answered from the cache, the gateway revalidates that exact grant (T3); if it was removed or its session changed, the run ends with the "not configured" line and no cached text is returned. A later step naming another bot, or any attempt to re-choose after a bot turn, ends the run with the restart line. The per-bot in-flight guard, deadline, follow-up wait and ownership rules O1–O5 apply to every bot turn exactly as in §4 and §18.3 (O1–O5 check ownership inside the chosen conversation; choosing the right conversation is T3's job).
4. **Retries must be identical.** The run keeps, in memory only, a SHA-256 fingerprint of each step's input (the question text, or the choice utterance). A repeated step number with the same fingerprint gets the cached response; with a different fingerprint it ends the run with the restart line, so a new question is never paired with an old answer. This applies to per-bot conversation runs too (§18.2).
5. **Step cap:** choosing steps count against the Shortcut's fixed cap (10); the gateway makes sure the last step's response is always `next: "end"` (§18.2 contract), also while choosing. Rate limit: once per run start, as today.

**What changes elsewhere:**
- **§4.1 steps 3–4:** step 3 is unchanged except that activation follows T5 (the step that names or pins a bot). Step 4 reads "the requested bot must be in the token's set and its grant's session current (T3)"; a v1 request without `bot` is allowed only for a one-bot token.
- **§7.7:** "the same bot" becomes "the same kind, and the old set ⊆ the new set" (T6); "either one only works for its bound bot" becomes "for the bots in its set".
- **§18.2:** a run's state gains `phase` (`choosing` | `pinned`), the chosen bot and the choice attempts; a run started with a `bot` field is pinned at step 0 (today's behaviour). Unknown run, wrong token and out-of-order step behave as today; a retry is answered from the cache only if its input fingerprint matches (rule 4) and the pinned grant still holds (rule 3).
- **§6.3:** "remove retires every token of the bot" becomes "remove drops the bot's grant from every token and retires tokens left empty" (T6).
- **API:** there is no separate bot-list endpoint; the list is spoken in step 0. If one is ever added (for example for the app's own diagnostics), it follows T5: it never activates or retires a token.

**Why the gateway matches names instead of the Shortcut's "Choose from List":** the list would be frozen into the signed file (a new bot = a new Shortcut and up to a day of HomePod learning), and spoken list selection on HomePod is untested. **Unverified on a device (S6):** the extra spoken round trips inside Siri's limits (§19), and how well bot names survive transcription (a Latin name on a Chinese HomePod: the number and the spoken alias are the fallbacks). Until S6, the app offers the entry Shortcut next to the per-bot Shortcuts, never instead of them (§20.11), and S5 ships per-bot parity.

**S4 amendments (v9.5, 2026-10-23; built and tested offline, not on a device).**
- **Mandarin names are also matched by sound.** After the exact, number and spelling passes, a Chinese name and the utterance are compared as toneless pinyin (Apple's Mandarin-to-Latin transform, diacritics stripped) with the same edit-distance and margin rule. A sound match is always a fuzzy match: spoken back as a yes/no question, never taken as the choice ("出房" → "是厨房吗？").
- **Every name competes for the margin.** A name that only the number can choose (ambiguous, or one that reads as a number) still counts as the runner-up, so two look-alike names are never guessed; if such a name is the closest, the result is no match. An utterance that is a number means only the number (an out-of-range number is no match), and a yes, no or end word is never matched as a name.
- **The pin checks the snapshot's session first.** The step that pins the chosen bot admits exactly the snapshot's `(key, sessionId)`; a grant whose session changed is refused before anything is activated or retired.
- **Set edits reach the whole chain.** T4's "applied to both together" covers every pending replacement down a chain, not only the next one.
- **A v1 request without `bot` from a one-bot entry token** pins that bot and activates the token (T5).
- **Aliases:** at most 5 per bot (`homebot bot alias`), each must keep something after normalization.
- **Activity outcome `confirm`** (A2) is added for the yes/no step after a fuzzy match.
- **The menu is the only list call.** The Shortcut has no list call of its own; step 0 is the list. `/v1/bots` stays for diagnostics and never activates or retires anything.
- **App and CLI:** the Shortcut step offers "One bot" or "All my bots" (choose up to 9; the exchange preview shows the "which bot?" turn); the Shortcuts list offers the entry Shortcut while there is none and edits an entry Shortcut's set (T4). An entry Shortcut replaces by default only an active entry Shortcut it covers; per-bot Shortcuts stay until S6. CLI: `homebot shortcut build --entry [--bots a,b]`, `homebot token bots <id> <a,b>`, `homebot bot alias <key> [names…]`.

### 20.6 Home: status and activity (frozen for S1, 2026-10-23; built in S2/S3)
After setup the last step becomes **Home**, which is also the window's start page from then on.
- **Status, live:** gateway running (and its LAN address), the credential's source and whether Grok Bot accepted it (§20.4), Mac kept awake (§20.11 S4), last request time and outcome. Each problem has its fix next to it (open settings, make a new Shortcut, re-enter the key). Home repeats §11's warning that the LAN connection is plain HTTP for a trusted home network.

- **Anonymous analytics, asked once after setup (DECISIONS item 38).** Usage counts are off until the user turns them on (`settings.usageCounts`: absent = never asked = off). The first time Home is Ready (gateway running, key usable, a Shortcut has answered; `Flow.isSetUp`), a one-line info callout under the tiles asks "Help improve Homebot? Only anonymous counts, never your questions." with **Not now** and **Share** and an (i) link to homebot.fun/privacy. Share sets `usageCounts` on, exactly like the Settings switch, and sends the first ping; Not now writes it off. Either answer is final: the callout never returns, and Settings › This Mac stays the place to change it. Never during the setup steps or over the Siri and Install guides, never once the user set the switch either way, and never when `DO_NOT_TRACK=1` or `HOMEBOT_NO_USAGE=1` force counts off. Nothing is sent before the answer, and nothing after Not now.

**Activity records (rule A1–A7).**
- **A1 — one record per voice request** that reached the gateway on `/v1/ask` (a v1 question, or one step of a v2 run that did work: a bot turn, an end word, silence, a choice). Fields:
  - `id` (local random, 16 hex; unrelated to any wire id), `at` (start, ms since epoch), `durationMs`, and the stage timings AskService already measures (`baselineMs`, `sendMs`, `replyMs` when they exist);
  - `shortcut`: the token's **id** (12 hex, a record id, not a secret) and its label (the phrase) as they were at the time, `mode` (`single` / `conversation` / `entry` / `legacy`, §20.5), `siriLang`;
  - `bot`: key and display name at the time (none before a choice);
  - `run`: a local run number (counter per gateway start) and `step` for v2; never the wire run id;
  - `question`: the full transcribed text as received (after the length check; a question over the limit is stored cut to the limit and marked `tooLong`), after the filter below;
  - `spoken`: exactly the text the gateway returned for Siri to speak (the answer after sanitize/truncate, or the system message), after the filter below;
  - `outcome` (A2), `reason` for refusals (`O2` / `O3` / `O5`).
  - **Fields by phase:** a choosing or confirmation step (outcomes `chosen`, `no-match`, and an end word or silence while choosing) has **no `question`**; its `spoken` is Homebot's own menu or confirmation line. Text fields exist only for bot turns.
  - **Logical steps, not HTTP attempts:** a retry answered from the cache (§20.5 rule 4) adds no record.
  - **Filter before speech and storage:** the answer is cleaned of the current echo tag as today (§4.2), and then, before it is spoken or stored, every remaining Homebot protocol fragment is removed: any `[hb:…]` tag or bare `hb:` marker of Homebot's id shape, and the envelope's fixed lines. The question and the answer are also cleaned of the exact current API key and the request's token plaintext if they occur. `spoken` is always the filtered text Siri actually got. Other personal content in a question is the user's own speech and is stored as said; the app says so (A6).
- **A2 — outcome codes** are AskService's, unchanged, plus the run and gateway ones: `answered`, `refused`, `busy`, `in-flight`, `not-sent:<why>`, `no-reply:<why>`, `not-accepted`, `unspeakable`, `empty`, `too-long`, `not-configured`, `auth-failed`, `history-too-long`, `upstream`, `error`, `rate-limited`, `end-word`, `silence`, `restart`, `chosen`, `no-match`, `revoked`, `bad-token`, `forbidden`. Each UI label maps from the code (String Catalog); unknown codes show as "other".
- **A3 — before authentication** (bad token, forbidden bot, session changed, bad JSON, body too long) nothing per request is written. These are **counted**: one row per minute per (canonical endpoint, outcome code) with a count, so no question text, token id or address, and a flood of bad requests from the LAN adds at most a few rows a minute. The writer's queue is bounded (1,000 records); when full, new records are dropped and the drop is counted in the same way (`dropped`).
- **A4 — never stored:** the token plaintext or hash, the API key, the request id, the `[hb:…]` echo tag or `hb:…` marker, the envelope, `messageId`, wire run ids, one-time download ids, HTTP headers, the remote address, and the text of a **refused** reply (only what was spoken is kept; a reply Homebot would not speak is not written either). Lab and wait-test requests keep their own lab log rules (§19.1) and are not activity.
- **A5 — storage:** SQLite in WAL mode at `Activity/activity.sqlite` inside the support directory. Files 0600 (created with umask 077), `Activity/` 0700. **Only the gateway owner opens the database**: the running Homebot.app process (its activity actor writes; its UI reads through the same actor). The gateway owner holds a kernel lock (`flock` on `gateway.lock`, released when the process exits); the CLI reads and clears activity by asking the owner over a local channel restricted to the user (defined in S2), and opens the database itself only when it can take that lock (no owner running). Kept until cleared; a retention setting is a later option (Felix's decision).
- **Backup exclusion:** `Activity/` is marked excluded from backups as a directory (`URLResourceValues.isExcludedFromBackup`, which Time Machine honours) at every open, and the flag is **read back before the first text field is written**. If it cannot be set or read back, records are written without `question` and `spoken`, and Home says text history is off because the folder could not be excluded from backups. The UI claims exclusion from Time Machine only; other backup products are not claimed (unverified). S2 also checks with `tmutil isexcluded` and records the result.
- **A6 — Clear activity** (with confirmation in the app; `homebot log clear --yes` in the CLI, which asks the owner, or clears directly only when it holds the gateway lock): the activity actor stops taking records, **discards every queued record that started before the Clear**, closes its connection, deletes `activity.sqlite`, `activity.sqlite-wal`, `activity.sqlite-shm` and any `-journal`, reopens a fresh file, and only then confirms. Since no other process has the database open, nothing can keep or restore the old content. Clear never touches the JSONL diagnostic log (A7) or any other store. The app says plainly that questions are stored as spoken, that text stays on this Mac, that it is excluded from Time Machine backups made after the exclusion, and that a backup made before it is a copy Homebot can't delete.
- **A7 — the diagnostic log** (`Logs/homebot.jsonl`, 0600, rotated at 5 MB × 3) keeps today's rules (§11): ids, timings, outcomes, lengths; never question or answer text, never headers or download ids. The `logText` setting is dropped: text lives only in the activity store. The menu bar shows the last outcome and time, never text.

### 20.7 Bots: names and renames
- A bot is identified by its **session id**, never its name; renaming a bot in Grok Bot does not break Homebot or its Shortcuts.
- The API returns no current name for a session (§5.1), so Homebot can't notice a rename. The display name is editable in the app ("what Siri calls this bot"), and the single-entry matching (§20.5) uses it.
- Adding by name after a rename can create a new empty bot under the old name (get-or-create, §6.2). The add flow keeps "type it twice" and the just-created check, and adds: if a just-created bot has the same name as one already in Homebot, say so and offer to remove it from Homebot.
- **New bot:** an explicit "Create a bot" action (get-or-create with a new name), confirmed by the user.

### 20.8 UI and tests
- **UI:** SwiftUI rebuild of today's design and interactions: step rail, cards, the "Hey Siri, …" exchange preview, phrase chips, the Siri orb and the Homebot mark (Canvas / AngularGradient, same hues and timings), colour-only hover with a gliding highlight (`matchedGeometryEffect`), toasts and confirmations, light and dark. The page's rules stay: no layout shift on hover or selection, shared edges, measured before done. UI text in the eleven page languages moves to a String Catalog; spoken catalogs stay code (they follow the Siri language, not the UI language).
- **Tests:** Swift Testing. Each existing test file gets a Swift counterpart, with the in-process fake Grok Bot API ported first. The port is done when every behaviour the 212 TypeScript tests cover is covered in Swift and passes. UI flows get XCUITest smoke tests plus screenshots checked by Claude.
- **Data from the TypeScript version:** on first launch the app imports `~/.homebot` (bots, cursors, tokens, settings, signing consent; the key into the Keychain), so Shortcuts already on Felix's iPhone keep working. The old directory is left untouched.

### 20.9 Phases
| Phase | Content | Done when |
|---|---|---|
| S0 spike | Where the BDK keeps its login; minimal app: ad-hoc signed zip downloaded through a browser → Open Anyway flow; SMAppService on an un-notarized app; Keychain across two builds; listener on :8787 reachable from iPhone without a Local Network prompt; `shortcuts sign` from the app (fake input only, no Apple call without Felix) | each item recorded as checked or failed, with the fallback chosen |
| S1 core | `HomebotCore` + fake BDK + ported tests (stores, tokens, entries/ownership, envelope, speech, languages, catalogs, Shortcut builder, signer wrapper) | ported tests pass |
| S2 gateway | Hummingbird listener, AskService, downloads, conversation runs, `/v1/bots`, activity log, CLI | voice and CLI tests pass; TS gateway and Swift gateway give identical answers on the same fake transcripts |
| S3 UI | setup flow, Home, bots, Shortcuts, settings, menu bar | screenshots match today's page in all eleven languages, light and dark |
| S4 single entry | "Hey Siri, Homebot" Shortcut and name matching | offline tests; device test in S6 |
| S5 release | universal build, zip, Open Anyway guide, README with the agent prompt | a fresh macOS user account installs from the zip with clicks only |
| S6 device test | Felix: one Chinese and one English combination, end to end | Felix's report in STATUS |

Then the TypeScript version is removed (DECISIONS will record it).

### 20.10 Open points (Claude's defaults unless Felix says otherwise)
- Minimum macOS 15 (Sequoia): current SwiftUI APIs, and the Gatekeeper behaviour the guide describes. Felix's Mac runs 26.
- **Design language (amended 2026-10-23, Felix):** Felix now prefers **Liquid Glass where it fits**: on macOS 26 the window uses the system's Liquid Glass materials and controls (toolbar, sidebar or step rail, sheets, menu bar extra, buttons) wherever they look the same as or better than today's web design; content cards, the Siri orb and the Homebot mark keep their own drawing. On macOS 15 the same views fall back to the standard materials (`.regularMaterial`), checked by availability, never by hand-made imitations of glass. The page's steadiness rules (colour-only hover, shared edges, no layout shift, measured before done) still apply. S3 screenshots compare both.
- Activity retention: until cleared.

### 20.11 Grok design review of v9 (2026-10-23, `.agent-logs/design-v9-review-grok.md`) and S0 so far
Accepted unless noted; §20.2–§20.9 read with these changes.
- **Install = move to Applications (B1).** A zip opened from Downloads runs translocated (a random read-only path); a login item or LaunchAgent would record that path. The guide is: open the zip, drag Homebot to Applications, open it, Open Anyway, allow the login item. The app refuses to register itself while translocated and says why. S0 passes only if the gateway is back after logging out and in. *S0 observation:* the quarantined copy opened from Downloads ran from an `AppTranslocation` path and exited without writing anything; cause not yet known (Felix's Finder test next).
- **Gatekeeper on every update (S2).** An ad-hoc signature's identity is its code hash, so each release is a new app to Gatekeeper and the Open Anyway step repeats after updates. Releases are packed with `ditto -c -k --keepParent` (as the spike already does); the CLI binary is signed before the bundle; no `--deep`.
- **No Keychain (S3).** Without a provisioning profile the app gets the file-based keychain, whose access rule is the code hash, which changes every build. The key is one 0600 file in the support directory. Revisit only with a stable signing identity. §20.4's Keychain plan is withdrawn.
- **Awake (S4).** Besides the idle-sleep assertion, the gateway holds a `ProcessInfo` activity (idle system sleep disabled, user initiated) so App Nap never stalls it. The switch says it prevents idle sleep only; lid close, the Apple menu and low battery still sleep the Mac.
- **Local Network (S5).** The Mac app only accepts connections, so it should never appear under Local Network; the iPhone (Shortcuts) asks once, as it did in the device session. S0 checks the Mac side only. `NSLocalNetworkUsageDescription` is added anyway; the app never resolves `.local` names itself.
- **Single entry needs redesign (B6), agreed.** "Hey Siri, Homebot" breaks §16: a Mandarin HomePod does not run a Latin-script name (checked on a device), so the one phrase is the per-language entry name from §16 (e.g. "家庭助手"), not the word Homebot. Also: the bot-list call must never activate or retire a token; a token stays scoped to an explicit set of bots the user chose for that Shortcut; the chosen bot is spoken back and confirmed before the question; a conversation run is pinned to that bot. The single-entry Shortcut is offered next to the per-bot ones until Felix's device test (S6). Rewritten in §20.5 (v9.1, frozen before S1).
- **Activity privacy (S7).** The activity database is excluded from backups (and checked against Time Machine in S0, since Grok says the exclusion key may not cover it; unverified either way); Clear deletes the database with its `-wal`/`-shm` files; the menu bar shows outcome and time, never question text; the app says plainly that text stays on this Mac but a backup made before exclusion is a copy. Retention stays "until cleared" (Felix's decision); a retention setting is offered.
- **One store after import (B8).** Import stops the old gateway first, copies under its lock, refuses symlinks, copies the credential the old gateway actually used (once, into the 0600 file), then marks `~/.homebot` as moved so `homebot start` (TypeScript) refuses to run on it. No two writers.
- **Order (S9).** Token and log rules for the new features are frozen in this document before S1, so ported tests aren't rewritten later. S5 ships per-bot parity; the chooser waits for S6. Architectures: macOS 15 and 26 still run on some Intel Macs, so the build stays universal (checked: Xcode 27.1 links arm64 + x86_64, `minos 15.0`); S0 adds a Rosetta launch.
- **App Sandbox stays off** (it would block `shortcuts sign`, the listener and the stores). Home repeats §11's warning that the LAN connection is plain HTTP on a trusted home network.
- **Where the BDK keeps its login (S0, checked in `@cursor/bdk` 0.2.28 from the npm registry, read only, no code copied: its license is not open):** `credentials.json` (0600) in `$AGENT_SERVE_CONFIG_DIR`, else `$XDG_CONFIG_HOME/agent-serve`, else `~/.config/agent-serve`. The file holds `apiKey` and `backendUrl` (the backend the key was made for; keys never cross backends). The app reads `~/.config/agent-serve/credentials.json` (a Finder-launched app sees no shell variables) and uses it only when `backendUrl` is Cursor's API. The Grok Bot desktop app's own files (`~/.grokbot`) are not a BDK login and are not read.
- **Gatekeeper, observed (S0, Felix's Finder test):** a quarantined, ad-hoc signed app double-clicked in Applications shows "“HomebotSpike.app” Not Opened — Apple could not verify “HomebotSpike.app” is free of malware that may harm your Mac or compromise your privacy." with **Move to Trash** and **Done** only (no Open button). The guide starts from this dialog: click Done, then System Settings → Privacy & Security → Open Anyway.
- **S0 result (2026-10-23):** passed on Felix's Mac (macOS 26.6.2): universal build (`minos 15.0`, Rosetta launch OK); Finder install from a quarantined zip → "Not Opened" → Open Anyway → runs from `/Applications`, not translocated; `SMAppService.mainApp.register()` on the ad-hoc, un-notarized app → `enabled`, listed as allowed in Background Items; idle-sleep assertion and `ProcessInfo` activity held; LAN listener ready and answering; `shortcuts` CLI runs from the app. **Deferred to S6 (Felix):** that the app actually starts after a real log-in or restart (a test step only; users never need to log out). Still open: Keychain across two builds (moot, §20.11), Time Machine exclusion (checked when the activity store is built).
