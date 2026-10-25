# M4 offline review

Date: 2026-10-21  
Reviewer: Codex  
Scope: `1e98288..0a77422`, plus the current `src/`, `bin/`, and `test/`.

## Verdict

**Changes required before M4 approval.** Concurrent setup actions can leave an old Shortcut authorized for a different bot. They can also attach the wrong conversation cursor to a bot. The setup page has sound browser security controls, but these controls do not protect against conflicting actions from legitimate setup tabs.

The original M2 corrections remain in the code. The latest owner decisions are not fully applied. Beginner setup still stops at an unexplained session ID, and several messages promise more than the implementation proves.

Reviewed current DESIGN (v4 changelog, with a stale v3.1 header), DESIGN v2 at `4042cb0`, BRIEF, DECISIONS, STATUS, PROCESS, and the design/M2 reviews. Compared the Shortcut graph with `~/homepod-spike/gateway/shortcut/v3/build_v3.py` as source only. The spike builder was not executed.

## Blockers

### B1. A build during bot removal can authorize an old Shortcut for a new bot

**Locations:** `src/server/setup.js:217`, `src/server/setup.js:222`, `src/server/setup.js:242`, `src/server/setup.js:272`; `src/core/tokens.js:120`.

Removal lists the bot's tokens once, revokes those records, then deletes the cursor and bot. A concurrent build can issue another token after that list was taken. Removal returns success but leaves this new token usable. A later bot can reuse the same key. The old token then authorizes that new conversation.

**Confirmed offline:** Pause removal at `state.removeCursor`, after its token loop. Build a Shortcut for the still-configured bot. Finish removal, then add a different session with the same display name. Verification of the captured synthetic token succeeds, and its bot key now resolves to the new session. No artifact content or real credential was read.

**Suggestion:** Give bot removal and token issuance one coordinated lifecycle boundary. Prevent issuance after removal starts, including builds that already captured the bot object. Revalidate identity before issuance. Preserve the rule across CLI and setup writers, not only through disabled buttons. Add a deterministic overlapping build/remove/re-add test that requires the old token to fail. The existing sequential removal test at `test/setup.test.js:185` cannot expose this case.

## Should-fix

### S1. A rejected concurrent add can overwrite another bot's cursor

**Locations:** `src/server/setup.js:198`, `src/server/setup.js:201`, `src/server/setup.js:207`, `src/server/setup.js:212`; `src/core/store.js:118`.

Two adds can pass the initial identity check before either cold sync finishes. The later completion writes its cursor before `putBot` checks identity again. If that check rejects the add, the other bot keeps the wrong cursor. Because cursor writes only move forward, subsequent reads can skip the new conversation until its sequence catches up.

**Confirmed offline:** Pause session 111's sync for key `same`. Add session 222 under that key with cursor 10. Resume session 111 with cursor 900. Its request returns 500, but session 222 now has cursor 900.

**Suggestion:** Commit bot identity and its cursor through the same setup operation. Check identity again before any cursor mutation, under coordination that prevents another add/remove from intervening. Also reject delayed cursor writes from a removed identity. Test overlapping adds with the same derived key and verify that the rejected operation changes neither config nor cursor. Reuse the lifecycle owner required by B1.

### S2. The wait-test option can disable a working voice Shortcut

**Locations:** `src/setup-ui/app.js:109`, `src/setup-ui/app.js:253`, `src/setup-ui/app.js:257`; `src/server/setup.js:263`, `src/server/setup.js:274`; `src/server/voice.js:91`.

The form selects the active token as the replacement by default. Selecting the wait-test option leaves that choice intact. The probe endpoint verifies and activates its token, which retires the working voice token. A user who only measures Siri's wait limit can therefore break normal questions.

**Confirmed offline:** Build a probe with an active voice token as `replaces`, then authenticate the probe token. The old token fails verification. The existing probe tests do not use a replacement.

**Suggestion:** Make probes independent of voice replacements in both the form and API. Reject a probe build that specifies a voice replacement. Hide or disable probe creation unless the wait endpoint is enabled, or explain the required `start --probe-wait` command. Its preview must describe a timed response, not an Ask for Input action. Test that using the probe leaves the voice token usable.

### S3. Apply the recorded owner decisions to the setup flow and instructions

**Locations:** `src/shortcut/profile.js:13`; `test/setup.test.js:150`; `test/shortcut.test.js:40`; `src/server/setup.js:194`; `src/setup-ui/strings.js:14`, `src/setup-ui/strings.js:26`, `src/setup-ui/strings.js:46`; `README.md:5`, `README.md:11`, `README.md:33`.

DECISIONS items 11–14 now specify bot `homebot`, a phrase that does not start with 问, an all-Chinese alternative, confirmed add-by-name, and a Cursor dashboard API key. Code and tests still recommend and assert “问问拆解师.” Setup still requires a numeric ID whose location is unknown. README and page copy still describe Q-KEY and signing approval as unresolved.

**Suggestion:** Use the new naming decision and prepare the Chinese alternative without claiming either works on a device. Implement the approved exact-name confirmation flow with offline fakes. Keep numeric IDs as an advanced route. Describe the dashboard-key route while retaining the fresh-account validation caveat. Distinguish signing being disabled by default from Felix's limited approval for his own install. Update obsolete current-status instructions without rewriting historical entries. No live action is needed for these corrections.

For a new user, “unverified: where to find this number” is a stopping point, not a usable setup instruction. Keep beginner completion unapproved until that path exists.

### S4. Saving a Siri language does not explain that installed Shortcuts stay unchanged

**Locations:** `src/setup-ui/app.js:217`; `src/setup-ui/strings.js:19`; `src/server/setup.js:174`; `README.md:32`. Contract: DESIGN §7.3 and design-review-1 S6.

Saving the language displays only “Saved.” The new value affects future builds. Existing token languages and embedded speech settings stay unchanged, and no replacement notice appears. A user can select Chinese and reasonably expect an existing English Shortcut to change.

**Suggestion:** State “Applies to new Shortcuts. Make and import a replacement to change an existing Shortcut.” Identify affected voice Shortcuts or provide a direct replacement action. Keep iPhone instruction language separate. Verify the complete flow with an existing Shortcut, rather than checking only a fresh build's defaults.

### S5. Account status and credential-precedence instructions are inaccurate

**Locations:** `src/setup-ui/strings.js:11`, `src/setup-ui/strings.js:12`; `src/setup-ui/app.js:72`; `src/server/setup.js:179`; `src/core/credentials.js:42`; `README.md:62`.

“Connected” means only that a key exists. Saving accepts any printable string of the allowed length without checking account access. Also, the page says an existing app's detected key takes precedence over a saved key. The resolver does the opposite. Environment keys do take precedence, so README's instruction to save a new key may not repair authentication in that case.

**Suggestion:** Show “API key saved; access not checked” until a successful check establishes access. Give separate explanations for environment and detected credentials. Explain how to replace an overriding environment key. Test display states for invalid, saved, detected, and environment keys, including a saved key that overrides detection.

### S6. Privacy copy overstates both local processing and reply protection

**Locations:** `src/setup-ui/strings.js:8`, `src/setup-ui/strings.js:28`, `src/setup-ui/strings.js:34`; `src/setup-ui/index.html:55`; `README.md:33`.

“Everything here stays on this Mac” conflicts with account API requests and optional Apple signing. “Never reads out a message that was meant for something else” exceeds the echo rule's documented limits. The strict-check checkbox can also disable that protection without the clear privacy warning required by DESIGN §4.2.

**Suggestion:** Say that settings are stored on this Mac, requests go to Grok Bot, and signing sends the Shortcut to Apple. Say Homebot refuses replies when its checks cannot confirm ownership. Keep strict checking on by default. If the opt-out remains, explain before saving that unrelated content could be spoken to the room. These are corrections to safety claims, not wording polish.

## Nits

### N1. Repair small README instructions and lifetime claims

**Locations:** `README.md:17`, `README.md:46`, `README.md:48`, `README.md:69`; `src/shortcut/profile.js:29`.

- ZIP extraction can produce a branch-suffixed directory. Tell the reader to rename it `Homebot` before using the exact `cd` command.
- Include Siri in iCloud among the HomePod prerequisites recorded in BRIEF §2.2. Keep device-specific labels unverified until M3.
- Describe 25 seconds as the gateway's reply budget, not a guaranteed spoken answer.
- Preserve the M2 lifetime qualification: cleanup runs periodically while Homebot runs, or on the next command when it was stopped. README currently restores the unconditional “24 hours” promise.

### N2. The open page does not refresh after a phone request

**Locations:** `src/setup-ui/app.js:117`, `src/setup-ui/app.js:275`; `test/setup.test.js:180`.

The token list fetches state on page load and local mutations. It does not refresh when the phone first uses the Shortcut. The test explicitly fetches `/api/state`, so it proves the server state, not an automatic page update. Add a refresh action or refresh on focus while setup is open. Verify the visible transition without another settings change.

### N3. Add a positive control to the QR decoder check

**Locations:** `test/qr.test.js:11`, `test/qr.test.js:26`; `scripts/qr-verify.swift:11`.

The availability check proves only that Swift exists. In this sandbox the initial run could not write its module cache. With temporary cache paths, the decoder ran but returned `<none>` for every symbol. A separate Apple-generated QR control also returned no features, with both default and software contexts. Thus this result does not establish an encoder defect.

Use a known-good decoder control to distinguish an unavailable decoding environment from a bad Homebot symbol. Retain a required decode check in a supported environment. Do not silently count an unavailable decoder as successful validation.

## Verification and retained fixes

`node --test` on Node v24.14.0 reported **137 tests: 71 passed, 66 runner failures**. Of those failures, **65 stopped at loopback listen with `EPERM`**. They are environment-blocked, not product failures. The remaining test was the QR decoder environment issue described in N3. Its focused rerun passed the four pure QR tests but did not establish decoding success.

Three additional socket-free probes used temporary synthetic stores and invoked the actual setup request handler. They confirmed B1, S1, and S2. These probes do not replace HTTP or browser tests. No browser smoke ran in this review. STATUS's earlier smoke is historical evidence and explicitly leaves hostile-name and revoke-dialog checks incomplete.

| Area | Assessment |
| --- | --- |
| M2 S1/S2: cleanup | Cleanup reloads under the token lock. CLI startup and the running-gateway timer remain. Pure stale-store/concurrent-sweep tests passed. Timer/CLI integration was blocked by loopback. README needs N1. |
| M2 S3/S4: names and replacement | One effective sanitized name reaches instructions. Unknown/cross-bot replacements are rejected under the lock. Pure token tests passed. S2 is a new probe-versus-voice distinction. |
| M2 S5/N1: modes and failed builds | Fixed umask-077 launcher remains, with fake-signer permission tests passing. URL validation precedes issuance. Later build stages share revoke/delete cleanup. Integration tests were environment-blocked. |
| M2 N2: test claims | Token-to-HTTP and separate-store descriptions are narrower. The ordered-write test now asserts multiple writes and no overlap. It covers AskService writes, not concurrent setup mutations. |
| Paging and ownership | Pure tests passed for 200-entry paging, empty-page cursors, creation versus update sequences, O2/O3 evidence retention, strict echo, and first owned reply. No change to these rules was found in M4. |
| Deadlines and idempotent send | One abort budget, stable retry message ID, no interrupt cleanup, and off-response-path persistence remain. Fake-HTTP tests target the relevant behavior but could not execute here. Live API behavior was not rechecked. |
| Shortcut plist | Action identifiers, dictionary wrappers, text/output tokens, UUID links, explicit speech language, and wait flag match the spike. Pure graph tests and socket-free XML lint passed. Signing/import/Siri remain separate acceptance steps. |
| Browser security | Exact loopback Host plus port, per-launch API secret, POST Origin check, JSON-only writes, body cap, CSP, no-store, and text-only DOM rendering are present. No bypass was established. HTTP defense tests were blocked. The static forbidden-sink test is useful but is not browser XSS proof. |
| Secrets and logs | Inspected responses expose credential source and safe token metadata, not keys or token hashes. Download URLs are deliberately bearer secrets. Default logs contain metadata. Private writes and signer permissions remain. B1 is an authorization lifecycle defect despite those protections. |
| Simplicity | Plain ESM and small shared modules fit the project. Fix lifecycle ownership in existing stores/setup operations. Avoid separate per-route patches or a general workflow framework. The custom QR encoder adds maintenance work, so retain independent decode evidence. |

No real secret files were opened or printed. Existing tests used their own synthetic credential/Shortcut fixtures. No bot/service calls, login, real signing, device actions, or external messages ran. Only this review and the appended STATUS entry were changed in the repository. Code and DESIGN.md remain unchanged.
