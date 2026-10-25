# BDK transport fix-round re-review

Date: 2026-10-22  
Scope: `0560c2f..783879a`, DESIGN v7.1.

**Verdict: changes required.** The original O6 bypasses are fixed. However, a failed poll can still discard ownership evidence and permit an unsafe answer. Unknown delivery values are now safe, but arbitrary error names can still enter logs.

The checked-out HEAD is `7d3d263`. Its code and tests match `783879a`; only documentation changed afterward.

**Blocker — R1: partial-page failures discard disqualifying evidence**

Evidence: [src/core/entries.ts:48](../../src/core/entries.ts:48), [src/core/entries.ts:55](../../src/core/entries.ts:55), [src/core/ask.ts:148](../../src/core/ask.ts:148), [src/core/ask.ts:155](../../src/core/ask.ts:155).

`syncToEnd` stores fetched entries locally. If a later page fails, those entries never reach `seen`. AskService counts the error and retries from the previous cursor.

Reproduced sequence:

1. A page contains foreign input with `role: "user"`.
2. The next page fails.
3. Before retry, the foreign entry loses its role. The retry returns that version, our input, and a tagged reply.
4. AskService returns `answered`. Passing **all fetched versions** to `decideReply` correctly returns `refuse: O2`.

Equivalent probes bypassed O3 and skipped an earlier untagged candidate that should cause O5 refusal. The O2 case also reproduced through `createBdkClient`, using synthetic JSON responses and a synthetic HTTP 503, without network access.

A HomePod could therefore read an answer after Homebot already observed evidence that made ownership ambiguous. This is a pre-existing gap that the fix round leaves open.

**Required correction:** retain evidence from successful pages when a later page fails, or stop without speaking a bot reply. Add service tests for partial-page failure followed by entry updates. The current scripted helper only supplies successful pages ([test-helpers/scripted-bdk.ts:38](../../test-helpers/scripted-bdk.ts:38)).

**Should-fix — R2: arbitrary `Error.name` values still reach logs**

Evidence: [src/core/ask.ts:175](../../src/core/ask.ts:175), [src/core/ask.ts:195](../../src/core/ask.ts:195).

Both error paths copy `Error.name` without classification. Injecting an Error named `synthetic_private_error_name` placed that exact value in both `ask` and `persist-error` logs.

This is pre-existing. The probes establish a logging-boundary leak from dependency errors, **not a demonstrated path from a live BDK response body**. Use fixed categories or an explicit allowlist. Add tests for unknown error names.

**Nits:** none.

**Previous findings**

| Finding | Re-review result |
|---|---|
| B1 | Original unchecked replacement paths fixed. Speech uses only `d.text` at [ask.ts:138](../../src/core/ask.ts:138). Replacement and late-evidence tests pass at [ask-ownership.test.ts:33](../../test/ask-ownership.test.ts:33). R1 still prevents full ownership closure. |
| B2 | Fixed. Later deliveries are not collected. Same-poll and later-poll cases pass at [ask-ownership.test.ts:71](../../test/ask-ownership.test.ts:71). |
| S1 | Resolved by removal of settling. Cooperative stalled baseline/poll probes respect the total deadline. Pre-timer reload exclusion is documented at [DESIGN.md:114](../../docs/DESIGN.md:114). |
| S2 | Fixed for delivery values at [ask.ts:129](../../src/core/ask.ts:129). Regression assertions exist at [ask.test.ts:228](../../test/ask.test.ts:228). Independent socket-free probes passed. R2 is separate. |
| S3 | Requested scripted coverage added and passing, including missing, malformed, and stuck-busy flags at [ask-ownership.test.ts:84](../../test/ask-ownership.test.ts:84). Partial-failure coverage remains missing. |
| N1 | Fixed. Only validated idle produces `I`; tests pass at [ask-ownership.test.ts:96](../../test/ask-ownership.test.ts:96). |
| N2 | Original stale claims corrected in [DESIGN.md:133](../../docs/DESIGN.md:133), [DECISIONS.md:47](../../docs/DECISIONS.md:47), and [STATUS.md:413](../../docs/STATUS.md:413). |

**Checks run**

- `npm run typecheck`: both configurations passed.
- `node --test test/ask-ownership.test.ts test/entries.test.ts test/text.test.ts`: **36 passed, 0 failed**.
- `git diff --check 0560c2f..783879a`: passed.
- In-memory probes reproduced R1 for O2, O3, and O4/O5, and R2 for both error paths.
- Five unknown delivery values, including malformed values, logged only `"unknown"`. Synthetic key and response-body values did not enter logs.
- With a 35 ms budget, cooperative stalled baseline and poll probes returned deadline outcomes in 36 ms and 35 ms.
- Full HTTP suite not run because it makes loopback network calls. Its source was inspected; the reported 163-pass result was not independently confirmed.
- No network calls, excluded-path reads, or file changes.