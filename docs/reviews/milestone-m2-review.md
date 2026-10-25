# M2 offline review

Date: 2026-10-21  
Reviewer: Codex  
Scope: `744d06b..b1bc804`, `src/`, `bin/`, and `test/`.

## Verdict

**Localized corrections requested before M2 closeout. No new release-blocking defect was established.** The original M1 failure paths have code fixes. The Shortcut graph matches the spike. Remaining issues concern artifact lifecycle, replacement validation, and instructions that name the wrong Shortcut.

The requested DESIGN v2 was read from `744d06b`. The working DESIGN.md is v3, so both versions informed this review. Inputs also include BRIEF, DECISIONS, STATUS, PROCESS, both prior reviews, and the spike's `build_v3.py` source. The spike builder was not executed.

`node --test` on Node v24.14.0 reported 109 tests: **61 passed; 48 could not run their assertions because loopback listen returned `EPERM`.** The runner labels these 48 as failures. This review treats them as environment-blocked tests, not product failures. The socket-free XML test passed `plutil -lint`. Full HTTP integration remains unverified here.

Additional socket-free probes used temporary synthetic data. They confirmed S1, S2, S4, and N1 below. No real secret files were opened or printed. Existing tests read only their own synthetic credential and Shortcut fixtures. No bot/service requests, login, real signing, or device actions ran. Code and DESIGN.md were not changed.

## Blockers

None established within this offline review. This is not approval of real signing, iPhone import, HomePod speech, or fresh-account setup. Those acceptance steps remain separate.

## Should-fix

### S1. Cleanup can delete a newly built artifact from another process

**Locations:** `src/core/tokens.js:56`, `src/core/tokens.js:64`, `src/core/tokens.js:142`, `src/core/tokens.js:150`.

Token mutation releases the file lock before cleanup. Cleanup then uses that store's old `records` snapshot. Another CLI can issue a token and write its artifact during this gap. The first store treats the new artifact as unknown and deletes it, even though its token remains valid.

**Evidence:** A deterministic probe paused store A immediately before cleanup. Store B issued a token and wrote a dummy artifact. Resuming A deleted B's artifact. The same predicate removes an entire per-token Shortcut directory.

**Suggestion:** Make cleanup decisions against current token state under the same coordination boundary as mutations. Include artifact creation in the lifecycle analysis. Do not merely reload before an unlocked directory scan. Add a two-store test that pauses cleanup while another build completes and verifies that the new file survives.

### S2. The promised 24-hour artifact lifetime is not enforced

**Locations:** `src/core/tokens.js:64`, `src/core/tokens.js:92`, `src/core/tokens.js:141`, `src/cli.js:67`, `src/cli.js:203`; `test/tokens-credentials.test.js:98`.

Cleanup runs after mutations and gateway startup. Active-token verification does not run it. A gateway can serve an existing Shortcut for days while an abandoned plaintext export remains on disk. If no process runs, there is also no mechanism to remove files at 24 hours. DESIGN §7.5 and the CLI currently promise deletion at that deadline.

**Evidence:** With a controlled clock, an artifact still existed after 25 hours and a successful request authentication with another active token. The existing test calls `cleanupArtifacts()` itself, so it proves the age predicate, not automatic expiration.

**Suggestion:** Run bounded periodic cleanup while the gateway is active and cleanup on relevant CLI startup. Explain that files expire on the next run when Homebot is stopped. Test the lifecycle trigger, including startup, rather than only calling the cleanup method directly. Share the coordination rule from S1.

### S3. Probe and sanitized names do not reach the setup instructions

**Locations:** `src/shortcut/profile.js:60`, `src/shortcut/make.js:43`, `src/shortcut/make.js:51`, `src/shortcut/make.js:66`, `src/cli.js:207`; `test/shortcut-cli.test.js:153`, `test/shortcut-cli.test.js:163`.

`profile.steps()` closes over the Ask name. A probe build produces “Homebot Wait Test” but tells the user to run “Ask <bot>.” Following those steps can invoke the bot instead of measuring the wait limit. A name containing `/` or `:` also changes in the filename, but the reported name and instructions retain the original characters. Per DESIGN §7.5, the filename determines the imported name.

**Suggestion:** Resolve one effective import name before generating files and instructions. Pass the probe name to probe instructions. Either reject unsupported name characters or show the normalized name consistently. Add assertions for the complete probe instructions and a normalized custom name. The current tests check file safety and the build heading, not agreement with the steps.

### S4. Replacement IDs can silently retire another bot's Shortcut

**Locations:** `src/core/tokens.js:72`, `src/core/tokens.js:118`, `src/cli.js:199`; `test/tokens-credentials.test.js:35`.

Issuance accepts any `replaces` ID without checking that it exists or belongs to the same bot. Activation retires that record unconditionally. Selecting the wrong ID while building bot B can therefore disable bot A's working Shortcut. An unknown ID instead reports a replacement that never occurs. This requires local CLI access, so it is an integrity and usability issue, not a remote privilege escalation.

**Evidence:** A synthetic bot-B replacement referencing an active bot-A token made the bot-A token fail verification after activation.

**Suggestion:** Validate the replacement under the mutation lock before issuing the new token. Reject unknown IDs and cross-bot replacements with a fixed error. Test that rejected replacements leave the existing token usable. If cross-bot replacement is intended, make that destructive operation explicit rather than accepting it silently.

### S5. The signer does not guarantee mode 0600 from creation

**Locations:** `src/shortcut/make.js:57`, `src/shortcut/make.js:58`, `src/shortcut/sign.js:26`; `test/shortcut-cli.test.js:124`.

The external signer inherits the process umask. Homebot applies mode 0600 only after successful completion. A signer that creates a file with the normal 0644 mode can leave it that way during signing or after process termination. The private 0700 parent limits exposure, but this still misses the explicit file-mode contract in DESIGN D11 and §7.5.

The fake signer copies a 0600 input, and the test checks only the final mode. It cannot expose this gap.

**Suggestion:** Start the signer with a restrictive umask through a controlled child launcher. Preserve argument-array handling for paths. Test permissions during output creation and interruption with a fake signer that creates a fresh file under a permissive parent umask. Do not run Apple's signer for this test.

## Nits

### N1. Build failures before signing leave pending tokens

**Locations:** `src/shortcut/make.js:44`, `src/shortcut/make.js:45`, `src/shortcut/make.js:52`, `src/shortcut/make.js:56`.

The token is issued before URL validation, XML serialization, and file creation. Only signing is inside the cleanup catch. A socket-free call with `file:///invalid` failed but added a pending token. Invalid XML text or a disk write error has the same cleanup gap.

**Suggestion:** Validate non-secret inputs first. Once a token exists, use one failure boundary for the remaining build stages and revoke on failure. Test that a failed build leaves no usable new token or artifact and preserves any old token.

### N2. Narrow test claims to what the assertions prove

**Locations:** `test/shortcut-cli.test.js:99`, `test/server-cli.test.js:220`, `test/ask.test.js:268`.

The Shortcut integration test extracts a token with a regex and manually constructs the HTTP request. It does not execute or independently decode the serialized action graph. The “separate CLI process” test calls `run()` in the same process. The ordered-persistence test performs only one cursor write.

**Suggestion:** Describe these as token-to-HTTP integration, separate store instances, and slow-write isolation. Where the stronger claim matters, add an independent plist decode, a child CLI process, or two delayed writes with asserted order. Keep real Shortcut execution as M3 acceptance. Pure builder tests and `plutil -lint` are useful but do not prove iOS import or Siri behavior.

## M1 closure and design checks

| Area | Assessment |
| --- | --- |
| M1 B1: revocation | Reload plus locked read-modify-write fixes the original stale-store cases. Socket-free two-store tests pass. HTTP restart coverage is blocked here. Artifact cleanup still has S1. |
| M1 B2: interrupted upload | The outer handler catches errors, and disconnect handling precedes awaits. The new transport tests target the relevant failures, but cannot listen here. |
| M1 B3: credential JSON | Fixed parse errors no longer include JSON content. The direct synthetic malformed-JSON test passes. CLI coverage is blocked at its unrelated fake-server setup. |
| M1 B4: ownership evidence | All observed versions contribute to refusal. Textless foreign output before our input now refuses. The direct regression tests pass. |
| M1 S1–S3 | Byte collection precedes UTF-8 decode. Cursor persistence is off the response path. Cold sync has a total cap. Bot remapping and duplicate session ownership are rejected. |
| M1 S4 | English defaults are applied. Token-bound Siri language controls speech and replies. iPhone language controls setup instructions. Felix's mixed-language profile passes its pure tests. |
| M1 S5–S6 and N1 | Lifecycle cleanup exists but needs S1/S2 above. Baseline reads retry within the abort budget. Mode assertions and narrower ownership comments were added. |
| Paging and sends | Paging continues to the empty end page and tracks creation sequence separately. Send retries reuse one message ID. No late-answer store or interrupt cleanup was added. |
| M0 | Recorded P1 supports the empty-page cursor rule and observed turn shape. P2 establishes a 404 for the tested list route, not impossibility of every alternative API. The added-bot fallback follows DECISIONS. No probe was repeated. |
| Shortcut plist | Action IDs, text tokens, dictionary fields, UUID references, explicit speech language, and wait-for-speech match `build_v3.py`. Endpoint/header changes fit Homebot's API. XML validity passed. Real signing/import remain unverified. |
| Security and logs | Token hashes, bot binding, fixed credential parse errors, private unsigned writes, and default metadata-only logs are present. No inspected default log path emits a raw token or BDK key. S1/S2/S4/S5 qualify lifecycle guarantees. |
| Maintainability | Small ESM modules and shared paging are appropriate. These corrections belong in the existing token/artifact owner and name selection, not a new framework. |

Next: address the localized findings, then rerun the full offline suite where loopback is permitted. Retain the existing approval boundary for signing and M3 device tests.
