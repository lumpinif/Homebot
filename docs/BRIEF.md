# Homebot — Product Brief / 产品简报

> Written by 拆解师 (Felix's Grok Bot) on behalf of the product owner, Felix Lyu, 2026-10-21.
> This is the "what & why" plus the hard evidence we gathered in a 3-day spike. The "how" is yours to design (see PROCESS.md).

## 1. 用户和目标 / User & goal

**Who**: Felix — and later, people like him: they own HomePods/iPhone and have one or more personal **Grok Bots** (Cursor's Grok Bot product, https://cursor.com/docs/grok-bot , programmable via BDK https://cursor.com/docs/bdk). Many future users are **not technical**.

**Goal**: Use **Siri on HomePod (and iPhone) as a completely natural middleman** to talk to **any of the user's own Grok Bots**. You say "嘿 Siri，问拆解师 …", the bot answers, and the answer is spoken back on the HomePod you talked to.

**Product requirements (owner's words, condensed):**
1. **Publishable open-source product.** A stranger finds it on GitHub, follows the README, and it works. No hand-holding from us.
2. **Beginner-friendly local web page** that configures *both* the gateway and the Siri Shortcut (generate/deliver the Shortcut, no manual plist editing, no copy-pasting tokens if avoidable).
3. **Basic settings** incl. language (Chinese / English at least).
4. The config page **lists all of the user's Grok Bots** so they can pick which one(s) to talk to.
5. **First deliver ONE complete end-to-end flow** (HomePod voice → bot → spoken answer on the same HomePod). Don't over-engineer bot switching / maintenance yet.
6. Nice-to-have (design for, don't necessarily build now):
   - The called Grok Bot can **see it is being called via Homebot** (e.g. a clear marker/metadata), and can adapt (short spoken answers).
   - Homebot **exposes an API** so that later the user can, by voice, switch bot or do basic ops ("切换到 HomePod bot", "停止", …).
7. Later (do NOT build now): a **cloud gateway mode** (paid) for users without an always-on machine at home.

Primary platform for v1: **macOS on the user's LAN** (Felix's Mac). Keep cross-platform in mind (Linux/Pi) but don't let it slow v1.

## 2. Evidence from the spike (measured, not guessed)

Spike code (reference only, retired): `~/homepod-spike/` — see `~/homepod-spike/ARCHIVED.md`. Most useful files:
- `~/homepod-spike/gateway/gateway.mjs` — final spike gateway (Node, no deps): sync + async modes, BDK send/poll, `/delay` probe.
- `~/homepod-spike/gateway/shortcut/v3/build_v3.py` — builds Shortcut plists (Ask for Input → Get Contents of URL → Speak Text) then `shortcuts sign`.
- `~/homepod-spike/gateway/log.jsonl` — real per-request timing logs.
- `~/homepod-spike/owntone/`, `~/homepod-spike/airplay/` — AirPlay output experiments.
Do not copy secrets from there (token.txt, *.shortcut embed a token).

### 2.1 BDK / Grok Bot HTTP API (what actually worked)
- Base: `https://api.cursor.com/v0/grokbot/sessions`. Headers: `Authorization: Bearer <key>`, `x-cursor-client-type: agent-serve`.
- **Session ids are numeric** (e.g. 软件拆解师 = 14752726, HomePod bot = 14926534). The agent UUID shown elsewhere (e.g. `da83afad-…`) returned **400** on these endpoints.
- `POST /v0/grokbot/sessions {"name": "<exact bot name>"}` = **get-or-create by name** → returns the numeric id, but **a typo creates a new bot**. We only called it with Felix's approval. Whether BDK can *list* a user's bots (needed for requirement 4) is **unverified — investigate** (docs: https://cursor.com/docs/bdk , CLI `bdk --help`; Grok Bot agents extension tools exist: list/ask/check/interrupt).
- `GET /sessions/:id/entries?afterUpdatedSeq=N` → `{entries, latestUpdatedSeq, turn:{idle,inFlight,queued}}`. Entry fields seen: `seq, updatedSeq, kind, role?, text?, createdAtMs`.
  - User entry: `kind:"message", role:"user"`. Bot reply: `kind:"send-message"` (no role). Attachment sends appear as `send-message` with **no text**.
  - **Old entries can be re-updated** (come back with a new `updatedSeq`, sometimes no text). Filter by creation `seq`, not `updatedSeq`.
  - **Pagination: max 200 entries per page.** `afterUpdatedSeq=-1` returns the *first* 200, and `latestUpdatedSeq` is that page's end, NOT the real latest. Our gateway took that as the baseline → it read back a pile of older bot messages to Felix over the HomePod (bug hit 2026-10-21; fixed by paging to the end and only accepting the first text `send-message` whose `seq` > our own user entry's `seq`).
  - `entries` has no `messageId` field; we matched our user entry by exact text.
- `POST /sessions/:id/messages {messageId, text}` → `delivery: accepted_temporal`; resending the same `messageId` → `duplicate` (idempotent). `POST /sessions/:id/interrupt` exists.
- If the bot is mid-turn (`turn.idle=false`), our message queues behind it; we answered "正在忙" instead.
- The bot also talks to Felix in other channels (desktop chat) in the same session — replies to HomePod must be isolated from those.
- Creds on Felix's Mac: a bundled Grok Bot tool's BDK login (`AGENT_SERVE_CONFIG_DIR` points at it). The tool also bundles its own node. Credential resolution per BDK docs: `--api-key`, `CURSOR_API_KEY`, `CURSOR_API_KEY_FILE`, `CURSOR_SERVICE_ACCOUNT_KEY`, then stored `bdk login`. **Never run `bdk login` without Felix.**
- **Latency (measured):** sync answer to a one-line question returned in **6.6 s / 7.8 s / 8.2 s** end-to-end (gateway receive → text back). Breakdown example: entries baseline ~0.9 s (2.8 s when paging 2 pages), message sent ~1.6–2.3 s, first reply ~6.6–7.8 s. Async path to audio playing via OwnTone: ~13.1–13.7 s.

### 2.2 Siri / HomePod / Shortcuts
- HomePod runs a user's Shortcut via **Personal Requests**: the Shortcut actually executes **on the iPhone**. Requires Recognize My Voice + Personal Requests on that HomePod + Siri in iCloud + Find My location = this iPhone. (Apple: https://support.apple.com/en-us/108397)
- **A Shortcut cannot know which HomePod triggered it** ("Get Device Details" returns the iPhone). No network-side signal found either.
- **Recognition lag:** a newly imported or renamed Shortcut is recognized by **iPhone Siri immediately**, but by **HomePod only after minutes … up to ~a day** (observed: "问拆解师" worked on HomePod, "书房拆解师" imported a day later was still "not found"). Symptom when not recognized: Siri says it found web results / "ask on iPhone".
- Names starting with question/verb words (问…, 呼叫…) may be parsed as a question/call — choose distinctive names; "运行 <name>" helps. (Partly unverified.)
- **Working main path (Felix's choice):** Shortcut = **Ask for Input (Text)** → **Get Contents of URL** (POST JSON, header token) → **Speak Text** of the response (**language zh-CN, Wait Until Finished**). Siri speaks the answer **on the HomePod that heard you**, in Siri's voice. Apple owns input and output device → no room detection needed. This is the v1 path.
- Gateway returns **plain text** (`text/plain; charset=utf-8`) so the Shortcut can speak it directly.
- Timeouts: "Get Contents of URL" reportedly fails at **~60 s** (user reports, not Apple docs). **How long Siri/HomePod waits is unmeasured** (we built `GET /delay?s=next` + a "等待测试" Shortcut but haven't run the test). Spike used a 20 s budget then fell back to "还在想…" + async playback.
- Shortcut privacy: needs **Allow Running When Locked**, and a **first manual run on iPhone** to approve network access to the gateway host (HomePod can't show that prompt). Not settable in the file (unverified).
- **Signing:** iOS only imports signed Shortcuts. `shortcuts sign --mode anyone|people-who-know-me` on macOS works but uses Apple's service: we saw repeated **HTTP 502/503/504** for minutes; `people-who-know-me` sometimes succeeded when `anyone` failed. Linux has no official signer (0xilis/shortcut-sign needs dumped Apple ID keys; HubSign is a third-party upload — not OK when the file embeds a token). Alternative: an iCloud-link template with Import Questions (cross-platform, but user types values).
- Our generated Shortcuts **embed the gateway token** in the plist → treat .shortcut files as secrets.
- Plist we generate: `WFWorkflowActions` with `is.workflow.actions.ask` (`WFAskActionPrompt`, `WFInputType:"Text"`), `is.workflow.actions.downloadurl` (`WFHTTPMethod`, `WFHTTPHeaders`/`WFJSONValues` as `WFDictionaryFieldValue`, `WFHTTPBodyType:"JSON"`), `is.workflow.actions.speaktext` (`WFText` = action-output token, `WFSpeakTextLanguage:"zh-CN"`, `WFSpeakTextWait:true`). See build_v3.py.

### 2.3 Output alternatives (secondary / optional now)
- **pyatv** (RAOP) to one HomePod: works. Pushing to several in parallel: audible **drift (~877 ms measured)**; pyatv has no grouping.
- **OwnTone 29.3** (built from source, GPL-2.0 sidecar, JSON API :3689): true synced multi-room AirPlay 2 (stereo pair L+R in sync), but **~2.3 s buffer** before sound, **interrupts the user's AirPlay music and does not resume it**, PTP needs ports 319/320 (falls back to NTP). Useful later for broadcasts / long answers; **not needed for v1**.

### 2.4 Language
- Felix's iPhone **system language English**, **Siri Chinese**, **HomePod Siri Chinese**. Speak Text must set its language explicitly (zh-CN) or it may read Chinese with an English voice.

### 2.5 Prior art
- **clawpod** (https://github.com/algal/clawpod, blog https://alexisgallagher.com/posts/2026/clawpod-homepod/): same idea for OpenClaw — Shortcut (Ask for Input → POST → Speak, looped for multi-turn, `end_conversation` flag) + FastAPI server shelling out to a CLI. **No license → do not copy code**; ideas are fine. Their notes agree: Siri invocation of the Shortcut is the flakiest part; 60 s server timeout; no filler/fallback.

## 3. Constraints / 红线
- **Never print, log or commit secrets** (BDK keys, gateway tokens, signed .shortcut files). Keep them out of git (see .gitignore).
- **Do not run `bdk login`** or create Grok Bots without Felix. Be careful: `POST /sessions {name}` can create a bot.
- **Do not send messages on Felix's behalf** to anyone (email/Slack/etc.). Messages to his own bots for testing are OK but keep them few and clearly marked as tests.
- **Do not change Felix's Home app / HomePod / Siri settings.** Do not import Shortcuts into his phone yourselves.
- **Any test that makes a HomePod play sound must be announced first** — ask 拆解师 (who asks Felix). Speaking via Siri happens on his side anyway.
- Ports 8787 (old spike) and 3689 (OwnTone) are free now; nothing autostarts. Don't install launchd agents without asking.
- **Keep it simple**: few dependencies, existing tools, small verifiable steps. The product must be maintainable by a small open-source project.
- No GitHub remote yet — Felix will decide org/visibility.
