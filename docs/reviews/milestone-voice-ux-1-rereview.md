# Milestone re-review — voice UX phase 1 fix round

Date: 2026-10-22 (reviewer: Codex)

**Changes required.** Reviewed `4387619..6831374`. B1 is fixed. S2 and S3 remain incomplete: replacements can change a valid phrase, and disabled lab mode lacks the speech-and-stop response.

| Finding | Status | Evidence |
|---|---|---|
| **B1 — incomplete-poll acceptance** | **Fixed** | Acceptance requires `complete`; failed polls retain evidence but disable acceptance. [ask.ts:157](../../src/core/ask.ts:157), [ask.ts:169](../../src/core/ask.ts:169). The new regression test passed. |
| **S1 — phrase uniqueness** | **Fixed** | Every Shortcut kind checks its effective name with `uniqueLabel: true`. The check runs after reloading records under the lock. [make.ts:82](../../src/shortcut/make.ts:82), [tokens.ts:97](../../src/core/tokens.ts:97), [tokens.ts:134](../../src/core/tokens.ts:134). |
| **S2 — replacement phrase** | **Not fixed** | Preview now includes `replaces`, but preservation rejects **all** warnings, including non-blocking advice. Reproduced: explicit “Call Butler” is allowed, yet replacing it selects “House Butler.” Check blocking problems only. [app.ts:252](../../src/setup-ui/app.ts:252), [profile.ts:145](../../src/shortcut/profile.ts:145). |
| **S3 — lab failure responses** | **Not fixed** | Enabled-mode malformed JSON, oversized bodies, and handler failures now return `say` and `next: "end"`. However, restarting without `--lab` returns `404 {"error":"not found"}`. An installed lab Shortcut still lacks its spoken explanation. [voice.ts:70](../../src/server/voice.ts:70), [voice.ts:134](../../src/server/voice.ts:134). |
| **S4 — ended/pending runs** | **Fixed** | Checks and `take()` reject pending or ended runs. Final-step retries retain their response. The cap comes from the initial request. [runs.ts:72](../../src/core/runs.ts:72), [runs.ts:84](../../src/core/runs.ts:84), [lab.ts:295](../../src/core/lab.ts:295). |
| **S5 — independent silence tests** | **Fixed** | E1 and E1b have separate scenario paths. [lab.ts:168](../../src/core/lab.ts:168). |
| **S6 — arbitrary run text in logs** | **Fixed** | Run IDs require the hexadecimal format. Invalid values log the fixed category `invalid`. [runs.ts:35](../../src/core/runs.ts:35), [lab.ts:267](../../src/core/lab.ts:267). |
| **S7 — incomplete speech marked full** | **Fixed** | `full` requires the whole normalized sentence. The reported truncated example now returns `partial`. [lab.ts:59](../../src/core/lab.ts:59). |
| **Nit — E5 turn count** | **Fixed** | Five delayed answers plus the delayed final answer give six turns. [lab.ts:186](../../src/core/lab.ts:186). |
| **Nit — matching Siri languages** | **Fixed** | Both localized instructions include the condition. [profile.ts:96](../../src/shortcut/profile.ts:96), [profile.ts:103](../../src/shortcut/profile.ts:103). |
| **Nit — whitespace** | **Fixed** | `git diff --check 4387619..HEAD` passed. Corrected locations: `README.md:40`, `docs/DESIGN.md:551`, and the EOF after `docs/reviews/design-review-v8.md:114`. |

**Validation:** 49 focused tests passed. In-memory probes confirmed the two remaining gaps and final-response retry behavior. TCP listening was blocked by sandbox `EPERM`; filesystem-writing concurrency tests and device behavior were not rerun. No files changed. No excluded paths read.