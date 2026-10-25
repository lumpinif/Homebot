# Design review 1

Date: 2026-10-21  
Reviewer: Codex  
Scope: DESIGN.md draft v1 against BRIEF.md and PROCESS.md

## Verdict

**Revise before implementation approval.** The core direction is sound: one Node process, separate setup and voice listeners, and Siri-owned speech. Removing AirPlay from v1 matches the brief and the spike.

Three gaps prevent approval. The gateway can speak an unrelated private reply. Setup for a new user is not established. The milestones postpone the first complete HomePod flow until after the full setup UI.

The findings below are design findings, not observed failures in Homebot code. Safe, offline investigation can continue while the design changes.

## Evidence and limits

Read BRIEF.md, PROCESS.md, DESIGN.md, and STATUS.md. Checked these retired spike sources without executing them:

- `~/homepod-spike/ARCHIVED.md`
- `~/homepod-spike/gateway/gateway.mjs`, especially `askBot` and `handleSync`
- `~/homepod-spike/gateway/gateway.sync.mjs`, especially its older reply collection loop
- `~/homepod-spike/gateway/shortcut/v3/build_v3.py`
- Selected numeric timing fields and known status values from `gateway/log.jsonl`. Question and reply text were not printed.

The final gateway supports the design's pagination correction, numeric session IDs, idempotent send retries, and first-text reply selection. The builder supports the three-action Shortcut structure and explicit speech language. Neither source proves safe correlation across channels.

No secrets were opened. No login, account probe, bot message, signing operation, or device test ran. Public API availability, fresh-account access, and current Apple import behavior were not independently verified in this review.

## Blockers

### B1. Reply order is not reply ownership

**Location:** DESIGN §4 steps 4.5–4.7, §4.1, §12. BRIEF §2.1 requires isolation from desktop replies.

**Reasoning:** The marker identifies the user's input. It does not identify the bot's answer. An idle check also cannot prevent a desktop message arriving after that check. The first later `send-message` could contain an unrelated private answer, which Homebot then speaks to everyone nearby. The design explicitly accepts this risk, contrary to the brief.

**Suggestion:** Make reply correlation an explicit investigation and acceptance gate. Prefer a verified upstream message or turn identifier. If none exists, define a conservative refusal rule for ambiguous replies. A full request marker echoed by the bot can support such a rule, but it is not an upstream guarantee. Do not fall back to an unmarked reply. A dedicated voice bot can support an early, clearly limited trial, but it changes the “any of the user's bots” requirement and needs owner agreement.

The integration test must assert that an unrelated desktop reply is never returned. Include a desktop message arriving between the idle check and the send. A test that merely exercises interleaving is insufficient.

### B2. The new-user connection and complete bot list remain unsolved

**Location:** DESIGN G2/G5, §5.2, §6.2, §8 step 1, M0/M3. BRIEF requirements 1, 2, and 4.

**Reasoning:** Existing detected credentials prove Felix's route only. The accepted key type and a normal user's route to that key remain unknown. “KnownBots” lists configured bots, not all account bots. Pasting a numeric ID is not beginner-friendly until the product proves where users obtain it. Add-by-name can create a bot and does not provide discovery.

**Suggestion:** Give M0 concrete outcomes: a documented account connection route and verified discovery behavior, or a stated product blocker. Keep the manual-ID route as a development aid. Do not count it as meeting requirement 4. If listing is unavailable, ask the owner to approve a narrower release requirement rather than treating fallback strategies as equivalent. Remove add-by-name from the first implementation unless it is necessary and separately accepted.

Validate release setup without inherited credentials. A fresh `HOMEBOT_HOME` alone does not establish a clean start because credential auto-detection remains active. Technical investigation should answer key-format questions where possible, rather than expecting Felix to know the API contract.

### B3. The milestones delay the highest-risk user test

**Location:** DESIGN §12–13, M0–M4. BRIEF requirement 5.

**Reasoning:** HomePod speech is first required at M4, after directory strategies, stores, token management, and the full wizard. An iPhone success at M2 does not prove HomePod invocation or speech. M0 also requires a generated wait-probe Shortcut before the builder milestone exists.

**Suggestion:** Reorder the work around one narrow complete flow:

1. Bound the API and reply-isolation investigation. Record unresolved release requirements.
2. Implement one configured bot, safe reply handling, a bounded request, and one signed Shortcut. Provide minimal import instructions and an AirDrop path.
3. Have Felix test iPhone and HomePod input and speech. Measure the wait budget in this same device session.
4. Complete account discovery, the setup page, QR delivery, and new-user README validation.

Keep device acceptance explicitly blocked when Felix is unavailable. Continue independent offline work without labeling the end-to-end flow complete. No device action is authorized by this review.

## Should-fix

### S1. Timeout handling adds persistent answers without a usable recovery path

**Location:** DESIGN D4, §4 steps 4.3 and 5, §9.2, §10, M5.

**Reasoning:** v1 continues work for 240 seconds and stores answers for a feature deferred to v2. “Ask again later” can cause another send, while the original job still blocks the bot. The response timer also does not define whether baseline work may finish and send a new message after the user already receives a timeout. This matters for bots that perform actions.

**Suggestion:** Remove persistent late answers from v1. Define one deadline covering baseline, send, retries, and polling. Stop unsent work when the deadline expires or the client disconnects. If a send may already have succeeded, do not imply cancellation or recommend an automatic repeat. Tell the user that the reply was not received in time and to check the bot conversation. Specify lock release and cleanup. Test timeout before send, uncertain send delivery, disconnect, and restart. Do not interrupt a shared bot session merely to clean up a voice request.

### S2. Rebuilding can disable a working Shortcut before its replacement exists

**Location:** DESIGN §7.3–7.4, especially line 201.

**Reasoning:** Re-making a Shortcut revokes its previous token. The design also records frequent signing failures and delayed HomePod recognition. A user can lose a working Shortcut while trying to repair or rename it.

**Suggestion:** Keep the existing token valid while building and importing the replacement. Offer explicit revocation after the new Shortcut works, or retire the old token after the replacement's first authenticated request. Expire abandoned candidate tokens and files. Test signing failure and an import that never completes.

### S3. Per-Shortcut tokens need a defined authorization scope

**Location:** DESIGN D9, §4 steps 3–4.1, §11.

**Reasoning:** The request supplies the bot key, but the design only checks whether the token is valid. A copied token may therefore address every configured bot, despite being issued for one Shortcut. HTTP interception also exposes questions and answers, not only tokens. A one-time download does not protect later requests.

**Suggestion:** Bind each token to its permitted bot and check that binding on every request. Define explicit behavior for a generic Shortcut that omits the bot. Explain the trusted-network requirement and the consequences of a copied Shortcut. Do not imply that `0.0.0.0` restricts access to a home LAN. Document no port forwarding or public proxy exposure. Test cross-bot rejection. This does not require adding a certificate system to v1.

### S4. Secret handling needs rules for temporary files and untrusted UI content

**Location:** DESIGN D11, §7.3, §8, §11–12.

**Reasoning:** Mode 0600 on final files does not cover intermediate files, parent directories, or crash recovery. `HOMEBOT_HOME` can also point inside a repository, so “git status can never show a secret” is too strong. Bot names and reply previews reach a privileged setup page. Host and Origin checks do not prevent script injection from that content.

**Suggestion:** Require private state directories and restrictive permissions from file creation, including unsigned files and atomic-write temporaries. Delete expired artifacts at startup as well as during normal operation. Treat download URLs as bearer secrets and exclude them from logs and caches. Render bot names, replies, and errors as text, not HTML. Use generated internal filenames and argument-array process calls for signing and Finder actions. Test hostile names, secret-free errors, and cleanup after restart. Document the override-path risk.

### S5. The session-ID preview repeats the known pagination mistake

**Location:** DESIGN §6.2 strategy 3, compared with §5.1 and BRIEF §2.1.

**Reasoning:** `GET entries?afterUpdatedSeq=-1` returns the first page. The design says this call shows the last bot message. An older preview can cause the user to validate the wrong session. It also displays conversation content when identity metadata might suffice.

**Suggestion:** Prefer verified identity metadata. If a conversation preview is necessary, label it accurately and make it optional. Fetch through the existing paging owner before calling a message “latest.” Test selection against a history longer than 200 entries. Clarify that resetting the cursor cannot fix a history that always exceeds the cold-page cap.

### S6. Several success and error messages promise more than the flow proves

**Location:** DESIGN D12, §4 step 3, §7.4, §8 step 4, §10.

**Reasoning:** D12 says non-200 responses can stop the Shortcut, but §10 promises a spoken recovery message from a 401 response. Also, any `/v1/ask` caller can trigger “Your iPhone reached Homebot.” A setup test or curl call proves neither iPhone access nor successful import. Settings such as speech language, gateway address, and Siri phrase are embedded in the Shortcut, so saving them alone does not update it.

**Suggestion:** Keep 401 authentication semantics, but label its spoken behavior unverified until tested. Provide recovery instructions on the setup page. Show “Homebot received a request” unless the product can identify the tested client. Separate received, answered, and user-confirmed speech states. Mark settings that require a replacement Shortcut and guide the user through that replacement. Check QR import, `.local` access, rejected tokens, and changed settings through the real iPhone path.

### S7. The proposed timing cause conflicts with the older spike code

**Location:** DESIGN M1 exit criteria and D3. Spike `gateway.sync.mjs:88–107`.

**Reasoning:** The older loop records `first_reply_ms` and then waits for the bot to become idle. It collects multiple replies before returning. This directly explains a possible delay after the first reply. Queue delay alone occurs before `askBot` starts, so it does not explain that internal interval. The mixed log also includes a six-reply deferred result and a later one-reply result. These are not equivalent measurements.

**Suggestion:** Remove “likely the shared serial chain” as the presumed cause. Separate evidence by implementation version and stage. The later one-reply record has `first_reply_ms=6639` and `http_reply_ms=6640`. Measure gateway response time separately from Siri input and audible completion. Treat the 2- and 5-second delay records as server delivery evidence, not a measured HomePod wait limit.

## Nits

### N1. Dependency claims and serialization wording are inconsistent

**Location:** DESIGN D1, D6, D12, §3.1.

**Reasoning:** Vendored QR code is a shipped dependency, not a dev-only extra. Zero npm runtime dependencies do not remove supply-chain risk. The request is JSON, despite “plain text in.” D6 alternates between an XML writer and a binary/XML writer.

**Suggestion:** Say “no npm install required at runtime.” Record the QR source version and license. Say “JSON request, plain-text response.” Choose a minimal XML serializer and an explicit conversion step only if needed. Avoid a general plist library of the project's own.

### N2. Reduce interfaces and choices until a real consumer needs them

**Location:** DESIGN §3.1, §4 step 4.3, §6.2, Q8.

**Reasoning:** Four directory strategies precede evidence of one working discovery route. “Enqueue” and “reject while busy” describe different behavior. Asking the owner to select a QR implementation adds a decision without changing the product requirement.

**Suggestion:** Start with one directory implementation and one per-session in-flight guard. Specify immediate busy rejection rather than a queue if requests must not wait. Select a small licensed QR implementation as an engineering decision. Add more strategies only after a verified user need establishes their contract.

## Next review

Claude should revise DESIGN.md and identify which blocker each revision closes. Keep API unknowns and device acceptance visible. Approval of a revised design will not establish fresh-user setup or HomePod acceptance without their separate evidence.
