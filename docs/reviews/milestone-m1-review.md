# M1 core gateway review

Date: 2026-10-21  
Reviewer: Codex  
Scope: `7341c28..7ea6600`, `src/`, `bin/`, and `test/`. DESIGN v2, BRIEF, DECISIONS, STATUS, PROCESS, and design-review-1 were read.

## Verdict

**Changes required before M1 approval.** Paging and idempotent retries follow the spike evidence. The modules are small and have clear responsibilities. However, token revocation does not reach the running gateway. Error paths can stop the gateway or expose credential text. Reply ownership can lose evidence that requires refusal.

`node --test` on Node v24.14.0 reported **43 passed, 22 failed**. All 22 failures occurred at loopback `listen`, with sandbox error `EPERM`. This is an environment limit, not evidence that those test assertions failed. The reported count also includes `test/fake-bdk.js`, which contains no test assertions. Full integration success remains unverified in this review.

Additional socket-free probes used injected dependencies and synthetic temporary data. They reproduced the findings marked below. No real secret files were opened or printed. No bot/service calls, login, signing, or device tests ran. The existing credential tests created and read only their own dummy fixtures. Code and DESIGN.md remain unchanged.

## Blockers

### B1. CLI revocation does not revoke access in the running gateway

**Locations:** `src/cli.js:44`, `src/cli.js:58`, `src/cli.js:138`, `src/core/tokens.js:26`, `src/core/tokens.js:53`, `test/server-cli.test.js:173`.

Each CLI invocation loads a separate token store. The gateway keeps its original store for its entire lifetime. `token revoke` changes the file but leaves the gateway's record active. A copied Shortcut therefore keeps working after the CLI reports “Revoked.” Tokens issued after startup are also unknown to that gateway. A later activation can save the gateway's stale snapshot over newer CLI changes.

**Evidence:** Two stores loaded the same synthetic active token. One revoked it. The other still returned `ok: true` from `verify`.

**Fix:** Give token mutations one authoritative owner. For this milestone, either coordinate reloads and writes safely, or prohibit offline mutations while the gateway runs and provide an explicit restart workflow. Reload alone does not prevent stale writes. Test a running gateway plus a separate CLI invocation: issue, use, revoke, retry, activate another token, and restart. The current CLI test checks a new listing, not HTTP rejection by an existing gateway.

### B2. A disconnected upload can terminate the gateway before authentication

**Locations:** `src/server/voice.js:34`, `src/server/voice.js:42`, `src/server/voice.js:61`, `src/server/voice.js:69`, `test/server-cli.test.js:119`.

The async HTTP listener has no outer error handler. An interrupted request body rejects its async iterator. The HTTP event emitter does not handle the returned rejected promise. With Node's default unhandled-rejection behavior, this can terminate the process. Token persistence failures also escape this boundary.

The disconnect listener is installed only after token verification. A disconnect during pending-token activation can occur before that listener exists. The subsequent ask then receives a signal that was never aborted.

**Evidence:** Calling the actual listener with an iterator that throws during upload rejected the listener promise. This probe used no socket. The existing disconnect test acts during the BDK baseline, after authentication and body consumption.

**Fix:** Catch failures across the complete request lifecycle. Install disconnect handling before the first await and check the destroyed/aborted state before invoking AskService. Return a safe response only while the connection remains usable. Test interrupted uploads in a child process, disconnect during delayed token activation, and a failed token write. Confirm process survival and zero BDK sends.

### B3. Invalid credential JSON can print credential contents

**Locations:** `src/core/fsutil.js:44`, `src/core/credentials.js:48`, `src/cli.js:146`, `src/cli.js:155`.

The Homebot credential path lets `JSON.parse` errors escape. The CLI prints the error's message verbatim. Node can include part of the invalid JSON in that message. A missing quote around a key value can therefore put credential text in terminal output. Normal valid-credential tests do not cover this path.

**Evidence:** `resolveCredential` received a synthetic malformed file at an injected path. Its exception message contained the dummy value. No real credential file was used.

**Fix:** Convert credential read/parse failures to a fixed, source-specific message before they reach the CLI. Do not include input snippets or raw parser messages. Test malformed synthetic credential JSON through CLI error output. Assert that no part of the dummy key appears.

### B4. A re-update can erase foreign-output evidence and permit speech

**Locations:** `src/core/entries.js:63`, `src/core/entries.js:76`, `src/core/ask.js:100`, `test/entries.test.js:129`.

`decideReply` replaces each observed entry with its last version. BRIEF §2.1 explicitly reports re-updates without text. If an earlier foreign output loses its text, O3 no longer sees it. This can happen within one complete polling sync, before AskService evaluates the entries.

**Evidence:** Baseline 100, foreign text output 101, our input 102, tagged reply 103, then a textless re-update of 101 returns `accept`. DESIGN §4.2 requires refusal because foreign output occurred between the baseline and our input. The echo requirement does not override O3.

**Fix:** Preserve evidence relevant to ownership across updates. Once observed, disqualifying foreign output must remain disqualifying for that request. Keep this separate from selecting the current answer text. Test this exact sequence, including versions split across pages in one sync. Assert refusal and absence of private reply text. The current “latest version wins” test covers only empty-to-text updates and encodes an incomplete rule.

## Should-fix

### S1. Decode the request body once, after collecting bytes

**Location:** `src/server/voice.js:40–49`.

`raw += chunk` decodes each Buffer separately. A multi-byte UTF-8 character can cross chunk boundaries. The result contains replacement characters, even when the complete request is valid JSON. A Chinese question can reach the bot with altered text.

**Evidence:** The actual listener received two synthetic chunks split inside `中`. AskService received different text from the original `中文`.

**Fix:** Count bytes as now, then decode `Buffer.concat(chunks)` once, or use a streaming decoder. Test split Chinese characters and emoji. This is a transport contract test, not a copy snapshot.

### S2. The response deadline excludes persistence, and cold sync has no total time cap

**Locations:** `src/core/ask.js:127–131`, `src/core/bots.js:12`, `src/cli.js:111`, `src/core/bdk.js:27`.

AskService clears its timer and then awaits the state write before returning to HTTP. A slow write can delay the spoken timeout beyond the promised hard deadline. The logged `total_ms` was already recorded, so it hides that delay. A stuck write can prevent a response entirely.

**Evidence:** A 20 ms request budget plus a synthetic 200 ms state write returned after 222 ms. The guard was released, but the HTTP caller still waited.

Cold setup has a page cap and per-call timeout, but no overall timeout. Five hundred slow successful calls can occupy setup for many minutes. DESIGN §5.3 requires both caps.

**Fix:** Keep cursor persistence outside the response's critical path, with ordered writes and visible safe failure reporting. Preserve forward-only state. Add a total abort deadline to cold sync. Test response time with delayed persistence and setup with many slow pages.

### S3. Bot keys do not provide stable session ownership

**Locations:** `src/cli.js:108–113`, `src/core/store.js:62`, `src/core/store.js:87`, `src/core/ask.js:60–62`.

`bot add-id` can replace an existing key with a different session. StateStore refuses a lower cursor, so the new session can inherit the previous session's cursor and `maxSeq`. New replies may remain below that baseline and never qualify. Existing tokens also silently gain access to the replacement session.

Different keys can also reference the same session. The in-flight guard uses the key, so two requests can enter the same shared session concurrently.

**Evidence:** Setting one key to cursor 1000, then applying a new session's cursor 10, retained 1000. Source inspection confirms that add-id does not reject this remapping or duplicate session IDs.

**Fix:** For M1, reject key remapping and duplicate session IDs. If remapping becomes necessary, explicitly reset session-bound state and retire or reconfirm existing token grants. Test both cases. Avoid adding an alias abstraction without a current need.

### S4. Apply the owner's English default

**Locations:** `src/cli.js:104`, `src/core/i18n.js:46`, `src/core/envelope.js:27`, `test/tokens-credentials.test.js:99`.

DECISIONS item 3 sets English as the product default. Add-id still defaults to Chinese. Missing language and unauthenticated errors also fall back to Chinese. The existing fallback assertion enforces the old choice.

**Fix:** Use English for new bots and unknown/missing language. Preserve explicitly configured Chinese. Test omitted `--lang`, unknown language fallback, and explicit Chinese configuration. Keep the later iPhone-system and Siri-language settings distinct.

### S5. Remove abandoned plaintext token artifacts

**Locations:** `src/cli.js:128–131`, `src/core/tokens.js:85–91`, `src/core/home.js:47–52`.

CLI issue writes the raw token to a `.token` file. The file remains after activation, revocation, and pending expiry. Startup only removes `.homebot-tmp` files. This conflicts with DESIGN §11's hash-only token storage, with plaintext retained only in the Shortcut. It also makes abandoned exports accumulate indefinitely.

**Fix:** Treat the M1 export as a temporary secret artifact with an explicit lifetime. Remove it after consumption, revocation, or expiry, and sweep expired artifacts at startup. Keep mode 0600. Test cleanup using synthetic values and a controlled clock. Do not claim hash-only storage while these exports remain.

### S6. Retry transient baseline reads within the same deadline

**Locations:** `src/core/ask.js:76`, `src/core/ask.js:119`, `test/ask.test.js:171`.

A baseline network error or 503 returns immediately. Only polling GET errors retry. DESIGN §10 says GETs retry while time remains. A brief baseline failure therefore rejects a question even when most of its budget remains unused.

**Fix:** Retry retryable baseline failures with bounded delay and the existing abort signal. Do not retry authentication or invalid-request errors. Add a baseline-503-then-success case. Keep it separate from the existing transient-poll test.

## Nits

### N1. Tighten test names and security claims

**Locations:** `test/server-cli.test.js:173`, `src/core/home.js:3`, `src/core/envelope.js:3`.

The token-file test's name promises private modes, but it never calls `stat`. The home comment says secrets can never appear in git, despite the explicit override. The envelope comment says an echoed marker proves ownership, while DESIGN correctly describes its limits.

**Suggestion:** Add the direct mode assertion. State the narrower guarantees in comments. The existing 0600 helper tests and 0700 directory tests are useful, but they do not prove every export or failure path.

## Closure of design-review-1

| Prior finding | M1 assessment |
| --- | --- |
| B1: reply ownership | Normal O1–O5 cases are implemented. B4 above leaves the privacy condition incomplete. Live echo behavior remains unverified. |
| B2: new-user connection and discovery | Correctly remains an M0/release question. No add-by-name creation exists. DECISIONS approves the added-bot fallback, not a proven fresh-account credential route. |
| B3: milestone order | Addressed in v2. M2/M3 precede the full setup UI. No HomePod acceptance is claimed here. |
| S1: deadlines and late answers | No late-answer store or interrupt cleanup. Same-ID send retries and phase-specific timeout messages are present. B2 and S2 above remain. |
| S2: token replacement | Pending/active/retired works within one store. B1 above prevents reliable operation across CLI and gateway lifetimes. Signing-failure coverage belongs to M2. |
| S3: token scope | Cross-key rejection exists and has focused assertions. B1 and S3 above leave revocation and session identity gaps. |
| S4: secret handling | Private creation modes, random temporary names, and startup temp cleanup exist. B3 and S5 above remain. Setup HTML and signing are not implemented yet. |
| S5: pagination and preview | Full paging and opt-in preview address the original 200-entry bug. Numeric creation-sequence filtering is correct for entries below the baseline. |
| S6: honest status | 401/403 remain distinct. Normal timeout messages acknowledge uncertain delivery. Actual iPhone speech and replacement UI remain later acceptance work. |
| S7: timing evidence | v2 separates spike versions. AskService returns the first accepted reply without waiting for idle. S2 above affects response timing evidence. |
| N1/N2: simplicity | Plain ESM, no runtime package install, shared paging logic, and immediate rejection are appropriate. No speculative discovery framework was added. |

The strongest existing tests assert exact spoken results and absence of private output during desktop interleaving. The uncertain-send fake also checks that only one message is stored after a retry. These are meaningful behavioral checks. They do not prove upstream API behavior, real Siri timing, concurrent persistence, or the failure paths listed above. Rerun the full suite in an environment that permits loopback listeners after the corrections.
