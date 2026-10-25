# BDK transport review

Date: 2026-10-21 (Asia/Taipei). Reviewer: Codex.
Scope: `cc7078f..e43063d` (HEAD), DECISIONS item 17, DESIGN v7, STATUS, and `.agent-logs/prompt-bdk1.txt`.

**Verdict: changes required.** O6 can speak text that did not pass ownership checks. A user could hear output from a separate bot task. The total request abort remains in place, but `settleMs` is not a hard cap. No code or DESIGN changes were made during this review.

## Blockers

### B1 — An accepted reply can change without a new ownership check

References: `src/core/ask.ts:148`, `src/core/ask.ts:120`, `src/core/entries.ts:130`, `src/core/entries.ts:140`.

After the first acceptance, `decideReply` never runs again. However, `answer()` reads the latest text from all collected versions. A later version of the first reply can remove the echo and replace the text. That replacement is spoken without O5. An in-memory AskService probe accepted tagged `OWNED`, then received an untagged replacement of the same seq. It returned `answered` with the replacement.

The same bypass hides new disqualifying evidence before `userSeq`. For example, an entry between the baseline and our input can later acquire `role:user`. `turnReplies` ignores that seq, so O2 no longer causes refusal. O3 evidence can be missed in the same way.

**Suggestion:** keep one ownership decision over all observed versions until response time. Recheck any text version selected for speech. Preserve the O6 exception for a later foreign input only when the earlier spoken prefix remains proved. Add service tests for replacement text and late O2/O3 evidence after initial acceptance. Do not merely check the first reply twice while leaving later versions unchecked.

### B2 — Session activity flags do not prove that later deliveries belong to this request

References: `src/core/ask.ts:159`, `src/core/ask.ts:172`, `src/core/entries.ts:139`, `docs/DESIGN.md:133`, `docs/STATUS.md:413`.

O6 takes every subsequent text delivery without an echo or a turn identifier. The supplied schema contains session activity flags, not a delivery-to-turn link. Polling can miss an idle interval between separate turns. With missing or stuck-busy flags, collection continues until the cap and has even less boundary evidence.

A scripted service probe returned our tagged reply with idle flags, then an untagged delivery from a separate synthetic task before the two empty idle polls. Homebot spoke both. No foreign user entry was needed. This differs from the old residual risk: the unrelated delivery does not need to echo our request tag.

`syncToEnd` also returns the final empty page's turn state, but the caller treats a sync containing any entries as non-empty. Thus even a sampled empty idle page at the end of that sync does not close collection.

**Suggestion:** until the API supplies a reliable ownership link, require the request echo for each spoken delivery, or retain the first proved reply only. Activity flags can control waiting but cannot establish ownership. Test separate routine output, missing flags, and a stuck-busy backend. Correct the claims that incorrect turn assumptions can only reduce parts or increase latency.

## Should-fix

### S1 — Enforce the settle deadline during sleep and fetch

References: `src/core/ask.ts:161`, `src/core/ask.ts:163`, `src/core/ask.ts:165`, `test/ask.test.ts:266`.

The cap is checked only before sleep and paging. Those operations use the total request signal, not the remaining settle budget. A probe with `settleMs=30` and a 180 ms poll delay returned about 188 ms after acceptance. With defaults, a slow fetch can consume much more than the promised three seconds.

The total abort still bounds cooperative fetches and sleep. A separate 60 ms budget probe returned the accepted reply at about 62 ms. This is a settle-cap defect, not evidence that settling resets the total deadline.

**Suggestion:** bound sleep and fetch by the earlier of the total deadline and the settle deadline. Add elapsed-time assertions with reasonable scheduler tolerance, including a stalled fetch. Current tests assert `settle` labels, not elapsed limits. The pre-existing config/state refresh before the timer is also outside the total budget (`ask.ts:80`, `ask.ts:106`). Do not describe the budget as covering that work.

### S2 — Do not log arbitrary delivery strings

Reference: `src/core/ask.ts:144`.

The regex limits length and characters, not sensitivity. A synthetic `delivery: "synthetic_private_value"` was logged verbatim. An unexpected backend value can contain content or a secret composed of permitted characters.

**Suggestion:** log a fixed category for unknown values, or a small explicit allowlist of documented statuses. Test a sensitive-looking lowercase value as well as punctuation and oversized values. Existing `logText` is an explicit opt-in and defaults off. The new turn trace and numeric fields do not themselves contain content.

### S3 — Extend the tests beyond the fake's assumed turn lifecycle

References: `test-helpers/fake-bdk.ts:97`, `test-helpers/fake-bdk.ts:163`, `test/ask.test.ts:257`, `test/ask.test.ts:266`.

The fake's busy-until-final-delivery behavior is clearly marked as unverified. Its page tail and empty-page cursor behavior match the supplied GET evidence. However, it always emits a turn object, and the new tests do not cover missing or malformed fields, separate turns, or updates after acceptance. Those omissions hide B1/B2.

In service probes, missing flags returned the accepted text at the cap. Malformed flags also reached the cap, but the trace incorrectly reported `I`. Neither result proves that additional text is owned. The never-busy test has only one delivery, so it does not establish safe handling of delayed extra output.

**Suggestion:** add a small scripted page-response seam for the failure cases above. Use it without a listening socket. Keep the HTTP fake for transport tests. Existing accepted, duplicate, missing, and unknown delivery paths are covered in the test source. The fake intentionally stores the message even for an unknown delivery value, which is a useful uncertain-delivery scenario, not evidence of real rejection behavior.

## Nits

- **N1 — Make the trace distinguish idle from unknown.** `src/core/ask.ts:170` labels any present, non-busy object `I`, including `{}` or malformed fields. Use `I` only for validated idle state and `?` otherwise. This matters because the next live check relies on these logs.
- **N2 — Remove stale and overstated documentation.** `docs/DESIGN.md:356` still says Homebot returns on the first owned reply. `docs/STATUS.md:413` says incorrect assumptions cost at most about one second, while missing flags can consume the settle budget or more. Update these statements after the ownership and timing fixes. DESIGN remained unchanged in this review.

## Validation and source provenance

- `npm run typecheck`: passed for both configs.
- `npm test`: 160 discovered, 81 passed, 78 blocked by loopback `listen EPERM`, one Swift QR check skipped because the sandbox blocked its compiler cache. All 78 reported failures had that listen error. They are environment blocks, not established product failures. Full-suite success is not independently confirmed here.
- Additional offline, in-memory AskService probes reproduced B1, B2, S1 and S2. They also exercised absent/malformed turn fields and the total deadline. These probes used synthetic data and no sockets. Temporary script: `/tmp/homebot-bdk-review-probes.mjs`. Test log: `/tmp/homebot-bdk-review-tests.log`.
- Paging implementation is unchanged. The existing pure paging tests passed. No new page-tail regression was found. HTTP pagination acceptance remains blocked by the sandbox.
- The diff adds no vendored source, dependency, or copied-looking third-party text. Its implementation follows existing Homebot patterns and the supplied official-client behavior. The unlicensed repository was not available as a local comparison source and was not fetched. This is a bounded provenance check, not proof of independent authorship.
- The change is small. The main complexity is two ownership paths: `decideReply` checks evidence, while `turnReplies` can select new text without those checks. Consolidate that responsibility before adding more settling state.
- No bot/service requests, login, signing, device actions, or secret-file reads were performed.
