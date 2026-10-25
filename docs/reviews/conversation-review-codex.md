# Conversation mode review (Codex)

Date: 2026-10-22 (reviewer: Codex). Scope: e8d42d0..fb085fe.

**Blocker**

- **Foreign input can disappear below the baseline.** [ask.ts:135](../../src/core/ask.ts:135) advances the cursor before user-entry tracking starts at line 150. Scenario: a desktop message arrives during the initial multi-page sync, the session remains busy, then becomes idle. The follow-up sends instead of refusing. Reproduced: `answered`, one send. This violates §18.3’s arrival-cursor safeguard. Track user evidence from the initial sync. Currently dormant with `followupIdleMs: 0`.

**Should-fix**

- **Some v2 failures return plain text.** [voice.ts:115](../../src/server/voice.ts:115) and line 124 execute outside the v2 catch. If token verification or config refresh throws, the outer handler returns `500 text/plain`. Reproduced both cases. The loop cannot extract `say` or `next`. Extend version-aware error handling across these operations.

- **Exceptions leave runs active.** [conversation.ts:104](../../src/core/conversation.ts:104) reaches `finish()` only when `ask()` resolves. Scenario: state refresh throws on step 2. HTTP returns `next: "end"`, but step 3 still sends to the bot. Reproduced. Store a terminal response and finish the run when a step throws.

- **Rate limiting overrides cached retries.** [voice.ts:130](../../src/server/voice.ts:130) checks the limit before resolving retries. With the default limit, step 0 plus nine questions exhausts the allowance. Retrying step 9 returns a rate-limit refusal instead of its cached answer. Reproduced. The refusal also leaves the run active. Preserve retry responses and persist terminal refusals.

- **The idle-wait limit is not enforced after sleep or fetch.** [ask.ts:145](../../src/core/ask.ts:145) checks time only before polling. Reproduced: a 5 ms allowance with an 80 ms poll interval sent at 83 ms. Slow fetches can extend this further. Bound the polling work and check expiry before sending. The overall request deadline still works.

**Nit**

- **Cached retries skip bot binding.** [conversation.ts:84](../../src/core/conversation.ts:84) returns the cached response before checking `botKey`. Repeating a completed step with another bot returns the original answer. Reproduced directly against the service. HTTP token authorization currently blocks this route, so this is a service-contract gap. Check both bindings before returning cached data.

No additional source-level defect found in the loop Shortcut or setup-ui changes. Device execution remains unverified.

Validation: 32 selected tests and type checks passed. In-memory probes confirmed the findings and verified guard release and deadline cancellation. Socket-based HTTP testing was blocked by sandbox permissions. No files changed; excluded paths were not read.
