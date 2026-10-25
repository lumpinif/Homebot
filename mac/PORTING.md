# Porting map: TypeScript tests → Swift (S1, S2)

Phase S1 of DESIGN §20.9 ports the core modules into `HomebotCore`; S2 adds the gateway
(`HomebotGateway`) and the `homebot` command (`HomebotCLI`). This file maps every one of
the 212 TypeScript tests (`test/*.test.ts`) to the Swift test that covers the same behaviour, or
says where it goes instead: **S2** (gateway: HTTP listener, AskService, activity, CLI import),
**S3** (app UI, setup flows, CLI commands), or **dropped** with the reason.

Swift tests are named `File.swift › Suite › test`. Run them with `swift test` in `mac/`.

## Parity checks that cover many TypeScript cases at once

`GoldenTests.swift` compares the Swift output with the TypeScript output for the same inputs,
written by `scripts/swift-golden.ts` into `Tests/HomebotCoreTests/Fixtures/`:

- seven Shortcut files (ask en/zh/escaping, probe, lab, conversation zh/ja), **byte for byte**;
- every spoken message in all eleven catalogs, every envelope variant, END_WORDS, PROBE_TEXT
  (Russian plurals included), `maxSpokenChars`;
- phrase rows and setup steps for every Siri language × three bots × every iPhone language, 35
  hostile or edge-case phrases, the taken and keep cases (over 500 profiles);
- `sanitize` / `truncate` / `speakable` on tricky input, `labelKey`, `safeFileName`, the
  language table.

The catalogs themselves are generated from the TypeScript source by `scripts/swift-catalogs.ts`
(`Catalogs.generated.swift`). Regenerate both after changing a catalog while TypeScript is the
reference:

```
node scripts/swift-catalogs.ts mac/Sources/HomebotCore/Catalogs.generated.swift
node scripts/swift-golden.ts mac/Tests/HomebotCoreTests/Fixtures
```

## test/entries.test.ts (23)

| TypeScript test | Swift |
|---|---|
| syncToEnd walks past the first 200-entry page | EntriesTests › syncToEnd › walks past the first 200-entry page |
| syncToEnd handles exactly 200 entries and an empty session | › handles exactly 200 entries and an empty session |
| syncToEnd keeps the cursor on an empty page … warm cursor | › keeps the cursor on an empty page … |
| syncToEnd tracks max creation seq … re-updated | › tracks max creation seq … |
| syncToEnd fails clearly when the history exceeds the page cap | › fails clearly … page cap |
| accepts the first echoed reply … strips the tag | DecideTests › accepts the first echoed reply … |
| waits until our entry and a text reply exist | › waits until … |
| O2: desktop message between the idle check and our send | › O2: refuses when a desktop message lands between … |
| O2: desktop message after ours, before the reply | › O2: refuses when a desktop message lands after ours … |
| O2: a foreign user entry refuses before our own entry | › O2: a foreign user entry refuses … |
| O2: unknown kinds with role user | › O2: unknown kinds with role user … |
| O3: bot output between the baseline and our message | › O3: refuses bot output … |
| O5: strict refuses untagged; non-strict accepts | › O5: strict mode refuses … |
| O5: a tag buried deep does not count | › O5: an echo tag buried deep … |
| O5: another request's tag does not count | › O5: another request's tag … |
| ignores re-updated old entries at or below the baseline | › ignores re-updated old entries … |
| answer text comes from the latest non-empty version | › answer text comes from the latest non-empty version |
| BDK review B1: untagged re-update refused | › BDK review B1 … |
| BDK review B2: only the first proved delivery | › BDK review B2 … |
| B4: textless re-update never erases O3 evidence | › B4: a textless re-update … (O3) |
| B4: foreign output already textless is still foreign | › B4: foreign output already textless … |
| B4: a re-update dropping role:user never erases O2 | › B4: a re-update that drops role:user … |
| compares seqs numerically | › compares seqs numerically, not as strings |

Added: `syncToEnd › hands each page's entries over as soon as it arrives` (BDK re-review R1, was
only covered through AskService) and `DecideTests › seqs beyond 64 bits compare exactly`.

## test/home.test.ts (6)

| TypeScript test | Swift |
|---|---|
| home dir and subdirs are created 0700 | StoreTests › Home and private files › home dir and subdirs are created 0700 |
| existing world-readable home dir is tightened | › an existing world-readable home dir is tightened |
| refuses HOMEBOT_HOME inside a git work tree | › refuses a home inside a git work tree (the location is a parameter now, not `HOMEBOT_HOME`: DESIGN §20.4 reads no environment variables) |
| private files are 0600 and JSON round-trips | › private files are 0600 and JSON round-trips |
| overwriting keeps 0600 and leaves no temp files | › overwriting keeps 0600 and leaves no temp files |
| startup sweep removes leftover temp files | › the startup sweep removes leftover temp files |

Added: the default location, malformed JSON never quoting content, a symlink at the target is
replaced rather than written through, and `LockTests` for the kernel lock (§20.5 T0: exclusion,
timeout, a leftover lock file never blocks, never broken by time, released when the holder
process dies).

## test/store-log.test.ts (6)

| TypeScript test | Swift |
|---|---|
| config: defaults merge, bot validation, prototype keys are not bots | StoreTests › Config, state and log stores › config: defaults merge, bot validation, reserved names are not bots |
| S3: a key never moves to another session | › S3: a key never moves to another session; a session has one key |
| cold sync has a total time cap | › cold sync has a total time cap, not just a page cap |
| state: cursors only move forward | › state: cursors only move forward; maxSeq never decreases |
| logger: 0600 file, JSON lines, rotation keeps 3 files | › logger: 0600 file, JSON lines in order, rotation keeps 3 files |
| R2: errorName logs only known error classes | › R2: errorName logs only known error classes (Swift error types: BdkError, cancellation, timeout; anything else is "other") |

Added: a settings write never drops another writer's setting; cold sync's result (cursor, max
seq, latest bot text); the logger's fire-and-forget function keeps order.

## test/lifecycle.test.ts (6)

| TypeScript test | Swift |
|---|---|
| B1: a build that captured the bot before remove + re-add issues nothing | LifecycleTests › B1: a build that captured the bot … |
| B1: removal racing a build never leaves a usable token | › B1: removal racing a build … |
| B1: tokens record the conversation; removal retires all of a bot's tokens | › B1: tokens record the conversation; removal retires every token left empty (T6: a multi-bot token is narrowed instead, see TokenTests) |
| S1: a rejected concurrent add changes nothing | › S1: a rejected concurrent add … |
| S1: a cursor tagged for another conversation is never advanced | › S1: a cursor tagged for another conversation … |
| S2: a wait-test token never works for /v1/ask | TokenTests › Tokens › S2: a wait-test token never works for /v1/ask … |

Added: T3 `admit` (session checked under the config lock, the authorized grant returned,
`stillGranted` after remove + re-add), a session mismatch never activates or retires, T4
`setBots` checks every bot under the lock.

## test/tokens-credentials.test.ts (17)

| TypeScript test | Swift |
|---|---|
| tokens: issued plaintext is never stored, only its hash | TokenTests › Tokens › issued plaintext is never stored … |
| tokens: verify accepts own bot or omitted bot … | › verify accepts its bot or an omitted bot … |
| tokens: replacement keeps the old token working … | › replacement keeps the old token working … |
| tokens: an abandoned pending token … expires | › an abandoned pending token … |
| tokens: revoke | › revoke |
| B1: two stores on one file always agree | › B1: two stores on one file … |
| B1: activation in a stale store never overwrites a newer revoke | › B1: activation in a stale store … |
| B1: concurrent mutations from two stores are all kept | › B1: concurrent mutations … |
| S1: a Shortcut's phrase is unique under the issuance lock | › S1: a Shortcut's phrase is unique … |
| S5: token artifacts are removed on use, revoke, expiry, or after 24 h | › S5: token artifacts are removed … |
| M2 S1: cleanup in a stale store never deletes a fresh artifact | › M2 S1: cleanup in a stale store … |
| M2 S1: concurrent builds and sweeps keep every live artifact | › M2 S1: concurrent builds and sweeps … |
| M2 S4: --replaces must name a usable token of the same bot | › M2 S4 / T6: replaces must name a usable token of the same kind whose set is covered (message changed with the bot-set model: "it answers for bot …") |
| credentials: resolution order and source names | CredentialTests › order: the saved key, then the BDK login, then nothing. **Changed by DESIGN §20.4:** environment variables, `secrets.json` and detection of other tools' logins are dropped by design; the sources are `saved` and `bdk-login` |
| credentials: AGENT_SERVE_CONFIG_DIR is preferred | **Dropped** (§20.4: no environment variables; the BDK login is read only at `~/.config/agent-serve/credentials.json`). CredentialTests › no environment variable is read |
| credentials: malformed secrets JSON fails with a fixed message | **Changed:** there is no `secrets.json`; the saved key is a plain file. Malformed JSON messages: StoreTests › malformed JSON fails with a fixed message; a malformed BDK login: CredentialTests › bad files are unreadable, never used |
| i18n: every language has every message | GoldenTests › spoken messages: all eleven catalogs, every message (the Swift catalog is a struct, so a missing message cannot compile) |

Added for §20.5: `BotSetTests` (T1 limits, multi-bot verify, session mismatch, T5 activation only
when a bot is named or pinned, T5 subset re-check at activation, T4 mirroring into a pending
replacement, T6 narrowing, `grants`, kind vs mode), `MigrationTests` (T2), and for §20.4:
`CredentialTests` (0600 key file, the exact `backendUrl` rule with 12 cases, bad and symlinked
logins, credential generation).

## test/text.test.ts (7)

All seven are in ShortcutTests › Envelope and speech, with the same names (request ids;
envelope marker/question/echo; test mode/English/no echo/custom and disabled style; sanitize;
truncate; code points; speakable). The golden speech cases add eleven more inputs.

## test/shortcut.test.ts (15)

| TypeScript test | Swift |
|---|---|
| plist: types, escaping, empty containers, rejects what it can't encode | ShortcutTests › Shortcut files › plist: … (an unsupported value such as `null` or `1.5` can't be expressed in `PlistValue` at all) |
| profile: English is the default | › profile: English is the default … |
| profile: Felix's setup — iPhone English, Siri Chinese | › profile: Felix's setup … |
| profile: one script per Siri language; bad first words; phrases in use | › profile: one script per Siri language … |
| takenPhrases | › takenPhrases … |
| every Siri language: … | › every Siri language … |
| profile: custom name, validation | › profile: custom name, validation |
| profile: every iPhone language has the five steps | › profile: every iPhone language has the five steps … |
| ask Shortcut: three actions wired by UUID … | › ask Shortcut: … |
| probe Shortcut: GET /v1/probe-wait | › probe Shortcut: … |
| generated Shortcut XML passes plutil -lint | › generated Shortcut XML passes plutil -lint (ask, probe, lab, conversation) |
| signer: retries with backoff and alternates modes | › signer: retries with backoff … |
| S5: the signer's output is 0600 … (fake signer) | › S5: the signer's output is 0600 … (fake signer) |
| signer: gives up with a clear error | › signer: gives up with a clear error |
| replacement: the old phrase is kept unless a blocking rule refuses it | › replacement: the old phrase is kept … |

## test/conversation.test.ts (15)

| TypeScript test | Swift |
|---|---|
| the first prompt is the Shortcut's question; answers keep listening | ConversationTests › the first prompt … |
| a refusal, error or timeout ends the run | › a refusal, error or timeout ends the run … |
| end words and silence end the run | › end words and silence end the run … (4 cases) and › only the whole utterance is an end word |
| the last step's answer ends the run | › the last step's answer ends the run … |
| retries are answered once; foreign runs and other bots restart | › retries are answered once … |
| a step that throws ends the run | › a step that throws ends the run … |
| a retry for another bot is not answered from the cache | › a retry for another bot … |
| follow-up wait: the previous turn's tail goes below the new baseline | AskOwnershipTests › follow-up wait: the previous turn's tail … |
| follow-up wait: a user entry during the wait answers busy | AskOwnershipTests › follow-up wait: a user entry during the wait … |
| follow-up wait: a user entry in the first sync counts too | AskOwnershipTests › follow-up wait: a user entry in the first sync … |
| follow-up wait: no wait or a turn that stays busy answers busy | AskOwnershipTests › follow-up wait: no wait (0) or a turn that stays busy … |
| envelope: a conversation turn tells the bot the turn | › envelope: a conversation turn … (and every language in GoldenTests) |
| conversation over HTTP: JSON for every v2 answer | VoiceTests › conversation over HTTP: JSON for every v2 answer … |
| conversation over HTTP: only a run's start counts toward the rate limit | VoiceTests › conversation over HTTP: only a run's start counts … |
| conversation Shortcut: the loop posts to /v1/ask | › conversation Shortcut … |

Added for §20.5: › rule 4: a repeated step with a different question is not a retry;
› rule 3: a run is pinned to key and session; › rule 3: a revoked grant ends the run, also for
a cached retry. `RunStoreTests`: run ids, early steps and expiry.

## test/lab.test.ts (15)

| TypeScript test | Swift |
|---|---|
| runs: ordered steps, repeats share one response | MakeTests › Lab Shortcut and runs › runs: ordered steps … |
| runs: an ended run keeps its last response | › runs: an ended run keeps its last response … |
| lab: sentence matching | LabTests › lab: sentence matching … |
| lab E2: matches each try … | LabTests › lab E2: … |
| lab: the last step always ends the run | LabTests › lab: the last step always ends the run … |
| lab: the cap is the one sent at the start | LabTests › lab: the cap is the one sent at the start … |
| lab: a run id the gateway did not issue is never logged | LabTests › lab: a run id the gateway did not issue … |
| lab E1 / E1b | LabTests › lab E1 / E1b … |
| lab: unknown runs end with a restart hint | LabTests › lab: unknown runs end with a restart hint … |
| lab E4: V1 / V2 | LabTests › lab E4 … |
| lab E7: one delay per run | LabTests › lab E7 … |
| lab state: bad files fall back to E1 | LabTests › lab state … |
| lab over HTTP | LabTests › lab over HTTP … (a failing lab service can't happen: `LabService` doesn't throw) |
| lab Shortcut: balanced loop and conditions … | › lab Shortcut: balanced loop and conditions … |
| lab Shortcut XML passes plutil -lint | › lab Shortcut … (same test) and ShortcutTests › plutil (lab) |

Added: › runs: a repeat with different input is reported as changed.

## test/shortcut-cli.test.ts (19)

The build itself is `ShortcutMaker.make` (MakeTests); CLI wording, settings and the HTTP round
trip are in CLITests (`homebot shortcut build`, S2).

| TypeScript test | Swift |
|---|---|
| default build: English, Bonjour URL, private file named after the Shortcut | MakeTests › default build … (the Bonjour host name is the caller's input; the CLI's wording is S3) |
| Felix's setup: iPhone English, Siri Chinese | › Felix's setup … |
| language defaults come from settings | CLITests › default build …; language defaults come from settings |
| built Shortcut's token + request shape are accepted over HTTP; the file is deleted on first use | CLITests › built Shortcut's token + request shape … |
| without --sign nothing goes to Apple and no signing consent is recorded | CLITests › signing consent … (the app's switch is S3) |
| a refused --sign build records no signing consent | CLITests › signing consent … |
| --sign with a fake signer | › signing with a fake signer …; reveal: CLITests › signing consent … |
| signing failure: error, token revoked, files removed | › signing failure … |
| hostile or mixed-script names are refused before a token exists | › hostile or mixed-script names … (3 cases) and › a leading 问 is refused; other leading command words are advice only |
| a phrase already used by another Shortcut is refused | › a phrase already used … and CLITests › phrases … (repeated spaces in `--name` are one) |
| M2 S3: probe build instructions name the probe Shortcut | › M2 S3: the probe build is named after the probe Shortcut … |
| M2 N1: invalid input fails before a token exists | › M2 N1: … |
| M2 S4: --replaces with another bot's token is refused | › M2 S4: … |
| M2 S2: every CLI run removes artifacts older than 24 h | CLITests › M2 S2: every CLI run … |
| M2 S2: a running gateway removes artifacts once they are 24 h old | HostTests › a running gateway removes Shortcut files … |
| probe Shortcut + start --probe-wait | CLITests › probe Shortcut + start --probe-wait … |
| built file passes plutil -lint | › default build … (plutil) |
| conversation: build a looping voice Shortcut from the CLI | › conversation and lab builds … |
| lab: build the lab Shortcut … read the report | CLITests › lab: build the lab Shortcut … |

## test/ask.test.ts (24), test/ask-ownership.test.ts (15)

Every test is ported under its own name: AskTests (24 + 5 added: input validation, T3 session
check, no credential, A1 filtering, credential generations) and AskOwnershipTests (15 + the four
follow-up waits from conversation.test.ts). "R2: an unknown error name never reaches the ask log"
is › R2: an unknown error never reaches the ask log by name.

## test/voice.test.ts (6), test/server-cli.test.ts (15)

| TypeScript test | Swift |
|---|---|
| B2: an interrupted upload neither crashes the gateway nor reaches the bot | VoiceTests › B2: an interrupted upload … |
| B2: disconnect during slow token activation | VoiceTests › B2: disconnect during slow token activation … |
| B2: a failing token write returns 500 and the gateway survives | VoiceTests › B2: a failing token write … |
| probe-wait: off by default; … | VoiceTests › probe-wait: … |
| TS review S1: a body that is not a JSON object is 400 before authentication | VoiceTests › TS review S1: … |
| S1: UTF-8 characters split across chunks arrive intact | VoiceTests › S1: UTF-8 characters split across chunks … |
| end to end over HTTP: token -> /v1/ask -> owned reply as text/plain | CLITests › end to end: … and HostTests › a Shortcut-shaped question … |
| auth: 401 for bad token, 403 for another bot, nothing sent | VoiceTests › refusals: … |
| S4: a token issued without --siri-lang speaks English; bad languages are rejected | CLITests › S4: … |
| S3: add-id refuses remapping a key or reusing a session, before any network call | CLITests › add-id validates before any network call … (and StoreTests › S3) |
| transport limits: 413, 400, 404, 405, health, rate limit | VoiceTests › body limit: …; › conversation over HTTP: only a run's start counts …; ImportParityTests › parity |
| client disconnect before send: nothing is sent | VoiceTests › a client that leaves while the bot answers …; AskTests › S1: client disconnect before send … |
| CLI: add-id validates before any network call; no credentials is a clear error | CLITests › add-id validates … |
| CLI: start without credentials still runs and points the user to the setup page | CLITests › start without credentials … (it points to `homebot account set-key`: no setup page) |
| B3: malformed secrets.json never leaks its content through CLI output | **dropped** for the CLI: there is no `secrets.json` (§20.4); the importer's case: ImportParityTests › import keeps a key …; malformed JSON never shows its content |
| CLI: doctor reports readable bots without printing secrets; failed add-id leaves no bot | CLITests › doctor … |
| CLI: preview shows the true latest bot message | CLITests › preview … |
| CLI: token export file is 0600 and removed on revoke | CLITests › token export file … |
| B1: running gateway honours issue/revoke from separate CLI store instances and survives a restart | CLITests › B1: … |
| Q-ADD CLI: bot add-name needs --confirm with the exact name | CLITests › Q-ADD: … |
| bot remove retires its tokens; token issue --curl-header … | CLITests › bot remove retires its tokens … |
| a folder the Homebot app imported (MOVED) is refused by every command | stays in TypeScript (test/server-cli.test.ts): the refusal is the TypeScript CLI's |

Added in S2: HostTests (owner lock, control channel, A3 counts, entry flow and `/v1/bots` over
HTTP, a cancelled conversation step, the Grok Bot base allowlist), CLITests › log …, › account …,
› usage …, ImportParityTests (the importer and the parity run), ActivityTests (§20.6, the
`tmutil isexcluded` check) and the awake service.

Added in S4 (the entry Shortcut, DESIGN §20.5; there is no TypeScript counterpart):
EntryShortcutTests (golden `entry-en`/`entry-zh`, graph, phrase, build, replacement), EntryTests
(choosing: exact, number, fuzzy with margin, Mandarin sound-alike, never guessed), EntryFlowTests
(the built Shortcut file played offline by `HomebotTestSupport/ShortcutRunner` against the
gateway and the fake Grok Bot: 13 scenarios), HostTests › entryTokenV1, › stalePin, TokenTests ›
editMirrorsChain, › pinSession, LifecycleTests › aliases, CLITests › entryBuild, AppModelTests ›
entry Shortcut preview, make and set edit, FlowTests › entry replacement default.

## Gateway parity with the TypeScript version

`ImportParityTests › parity` imports a folder the TypeScript CLI made (`Fixtures/ts-home`), loads
the TypeScript fake's transcripts into the Swift fake, and replays 24 Shortcut-shaped requests
(v1 and v2, refusals, limits, busy, multi-part turns, English) recorded from the TypeScript
gateway (`Fixtures/gateway-golden.json`). Status, content type and body must match. Regenerate
with `node scripts/swift-gateway-golden.ts mac/Tests/HomebotGatewayTests/Fixtures`. The tokens
and the key in the fixture are test values for the fake API only.

## test/setup.test.ts (17), test/ui-build.test.ts (1)

**S3** (the web setup page is replaced by the native app). Its loopback/secret/Origin/DNS
rebinding checks and the page's string tables have no native equivalent and are **dropped** with
the web page; the flows they drive (add a bot, save a key, signing consent, replacement, QR
download links) are rebuilt in S3 and tested in `HomebotUITests/AppModelTests` against the fake
Grok Bot API: key shape and save, add by name typed twice, the just-created check and the renamed-bot
notice, add by session id, create, rename, remove, signing consent before a signed build, the
one-time link, revoke. The step logic (`progress()`) is `FlowTests`; the page catalogs moved into
the String Catalog, checked in all eleven languages by `L10nTests`. Already covered in S1: Q-ADD (BdkTests), "B1: a
token whose bot now points at another conversation is refused" (LifecycleTests › T3 admit),
"S2: wait-test builds … never retire the voice Shortcut" (TokenTests › S2), credential source
and state (CredentialTests). "downloads: single use, 10-minute expiry" is VoiceTests › downloads: … (the QR code
itself is S3).

## test/qr.test.ts (5)

**Dropped (S3):** the app draws the QR code with Core Image (`CIQRCodeGenerator`, error
correction M) instead of porting the TypeScript encoder, so the encoder's five tests have no
counterpart. `HomebotUITests/AppModelTests › QRTests` reads a drawn code back with `CIDetector`.

## Intended differences from the TypeScript version

- Credentials (§20.4): no environment variables, no `secrets.json`, no detection of other tools' logins; the
  BDK login only for `https://api.cursor.com`.
- The cross-process lock is a kernel `flock`, never broken after 10 s (§20.5 T0).
- Tokens carry a bot set and a `mode`; sessionless TypeScript tokens import retired unless the
  user binds them (T2); `admit` checks the session and activates in one locked step (T3); a
  pending replacement follows edits of its predecessor (T4); the predecessor is retired only if
  still covered (T5).
- Runs are pinned to key and session, revalidated before every step, and a retry must carry the
  same input (§20.5 rules 3–4).
- The startup sweep removes only temp files older than 10 minutes (the TypeScript sweep removed
  all of them and could break another process's write in progress); the JSONL log holds a
  cross-process lock across rotation and append.
- BDK calls and cold sync race a hard deadline (`Deadline.run`), so a transport that ignores
  cancellation still times out.
- A Shortcut build re-checks its pending token after writing and after signing; a token revoked
  meanwhile fails the build and leaves no file.
- A 2xx Grok Bot response whose body can't be decoded is a `BdkError` of kind `upstream` (the
  TypeScript client returned whatever JSON it got).
- An empty sequence number is malformed (JavaScript's `BigInt("")` is 0).
- S2 (gateway and CLI):
  - Spoken text is filtered of protocol fragments, the key and the token (A1).
  - No separate headers timeout: the 10 s idle timeout also covers gaps while a body arrives, and
    a request must arrive in full within 70 s.
  - A download link that no longer works says "Make a new one in Homebot."
  - A v1 request without `bot` on a token for several bots is 403 (TypeScript tokens had one bot).
  - A token whose bot now points at another session is invalid (401), not a separate outcome.
  - The lab service can't throw, so TypeScript's "failing lab → 500" has no Swift case.
  - The importer refuses while the old ports listen instead of stopping the old gateway itself.
  - Usage errors exit 2 (swift-argument-parser); `homebot start` has no setup page and points to
    `homebot account set-key`; there is no environment-variable configuration.
  - The TypeScript CLI refuses every command, `start` included, on a folder marked as moved.
  - The TypeScript `start` writes `gateway.pid` while it serves; the importer claims the folder
    (exclusive `MOVED`) before it checks that file, and undoes the claim on any failure.
  - A token revoked while its question waits or while the bot answers gets "not configured"
    instead of the answer (T3; TypeScript checked only at the start).
- Not ported: the setup page and the app UI (S3).
