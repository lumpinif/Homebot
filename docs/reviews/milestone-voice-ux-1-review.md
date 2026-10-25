# Milestone review — voice UX phase 1 (phrases, lab, ownership fix)

Date: 2026-10-22 (reviewer: Codex)

Scope: `f3f87f2^..4387619`, against DESIGN Part 2, §§16–19, v8.1.

**Verdict: changes required.** R1 preserves fetched evidence, but introduces acceptance before a failed pagination attempt completes. A HomePod could therefore speak a reply before Homebot checks evidence that requires refusal. R2 is fixed. The tail diagnostic remains separate from ownership decisions. Phrase handling and lab failure paths need corrections.

**Blocker**

**B1 — R1 can accept a reply from an incomplete poll.**
Evidence: [ask.ts:151](../../src/core/ask.ts:151), [ask.ts:165](../../src/core/ask.ts:165), [entries.ts:60](../../src/core/entries.ts:60).

`onEntries` adds each page to `seen`. If a later page fails, the catch resumes the decision loop immediately. That loop can accept the partial result.

Reproduced without sockets:

1. Page one contains our input and a tagged reply.
2. Page two fails.
3. The remaining pages contain foreign user input.
4. Homebot returns `answered` with two pages unread.

This violates the O2 check retained by §18.3. Keep partial evidence, but require a completed sync before acceptance. A partial result can justify refusal. The existing [regression test:149](../../test/ask-ownership.test.ts:149) places the candidate **after** recovery, so it misses this case.

**Should-fix**

**S1 — Phrase uniqueness does not cover all builds or concurrent issuance.**
Evidence: [make.ts:78](../../src/shortcut/make.ts:78), [setup.ts:348](../../src/server/setup.ts:348), [tokens.ts:120](../../src/core/tokens.ts:120).

Lab and probe builds skip blocking phrase checks and use fixed names. A synthetic build reached token issuance while `Homebot Lab` was already taken. Voice builds also check a snapshot before the locked token write. Setup does not reload tokens at this check.

Two builds can therefore create the same phrase, contrary to §16.2. A test Shortcut can also collide with a voice Shortcut. Check the effective name for every kind within the issuance lock.

**S2 — Replacement preview and build can use different phrases.**
Evidence: [app.ts:244](../../src/setup-ui/app.ts:244), [app.ts:398](../../src/setup-ui/app.ts:398), [profile.ts:139](../../src/shortcut/profile.ts:139).

Preview omits `replaces`, while build includes it. With an existing `House Butler`, preview selects `Homebot`, but the replacement build selects `House Butler`. Entering the old phrase also produces a false “in use” preview.

A custom replacement phrase is not preserved by default. Pass replacement identity to preview, refresh on selection changes, and retain the old phrase when valid for the selected language.

**S3 — `/v1/lab` does not always return the required speech-and-stop response.**
Evidence: [voice.ts:88](../../src/server/voice.ts:88), [voice.ts:100](../../src/server/voice.ts:100), [voice.ts:134](../../src/server/voice.ts:134), [voice.ts:202](../../src/server/voice.ts:202).

Socket-free handler checks returned:

- Malformed JSON: `400 {"error":"bad json"}`, without `say` or `next`.
- Oversized body: plain-text `413`.
- Handler failure: plain-text `500`.

The Shortcut expects dictionary fields. These paths can produce a parsing failure or silence instead of the designed spoken explanation. Use the lab response shape for all lab refusals and failures, as §19.1 requires.

**S4 — Run state permits steps after termination and while prior work is pending.**
Evidence: [runs.ts:57](../../src/core/runs.ts:57), [runs.ts:66](../../src/core/runs.ts:66), [lab.ts:272](../../src/core/lab.ts:272).

The store has no terminal state and advances the step before its response completes. In-memory checks showed:

- A step returned `next: "end"` at `last: 1`. Step two with `last: 10` reopened it with `"listen"`.
- Step two was classified as `"next"` while step one remained pending.

The generated Shortcut is sequential, so ordinary use avoids these cases. However, the shared run contract is incomplete. Bind the cap to the run, retain terminal responses for retries, and reject later work after termination or before completion.

**S5 — E1 cannot independently test silence after an answer.**
Evidence: [lab.ts:156](../../src/core/lab.ts:156).

Every E1 run first asks for silence. If Siri stops the Shortcut on silence, the second condition is unreachable. Restarting repeats the first condition. §19.2 explicitly requires a separate run for silence after an answer. Provide independently selectable E1 conditions.

**S6 — Lab logs accept arbitrary text through the run field.**
Evidence: [voice.ts:146](../../src/server/voice.ts:146), [lab.ts:254](../../src/core/lab.ts:254).

The speech `text` field is not logged. However, an unknown client-supplied run is logged after truncation. A synthetic `run: "SECRET_FROM_REQUEST"` produced `run: "SECRET"`.

This is a logging-boundary leak, not a demonstrated microphone-text leak. Validate run IDs and log a fixed category for invalid values.

**S7 — Sentence matching can label incomplete speech as full.**
Evidence: [lab.ts:51](../../src/core/lab.ts:51).

The matcher uses only the first three normalized characters of the expected beginning, plus the ending. `tom buy some groceries` returned `"full"` for the complete park-and-groceries sentence.

This can make the pause experiment appear successful despite missing speech. Compare the complete normalized sentence, or report an explicitly partial match.

**Nits**

- E5 implements ten delayed turns at [lab.ts:172](../../src/core/lab.ts:172). [DESIGN.md:643](../../docs/DESIGN.md:643) specifies six. Align the experiment and its instructions.
- [profile.ts:95](../../src/shortcut/profile.ts:95) recommends iPhone testing without the same-Siri-language condition. Add that condition to both localized setup instructions.
- `git diff --check` reports whitespace issues in `README.md:40`, `docs/DESIGN.md:541`, and `docs/reviews/design-review-v8.md:115`.

**Other review conclusions**

- **R2:** fixed through the error-name allowlist, including ask, persistence, and tail error paths.
- **Tail diagnostic:** no ownership, guard, or persisted-cursor mutation found. It uses separate state, GET requests, cancellation, and fixed metadata logs. Production configuration caps it at 30 seconds. Activity counts count observed versions, not necessarily distinct messages.
- **Token isolation:** actual `TokenStore.verify` passed all nine ask/probe/lab combinations. Only matching kinds succeeded. Replacement checks also reject different kinds before issuance.
- **Phrase rules:** script restrictions, digit rejection, blocking leading `问`, advisory leading words, and cross-language comparison are implemented. The HomePod language label matches §16.2.
- **Plist:** syntax passed. Repeat grouping and dictionary references match available Apple samples. Those samples do not establish the conditional, variable, or exit behavior. Mac execution and HomePod speech remain unverified.
- Real conversation mode and continuation holds remain future work under §19.3, not missing phase-one features.

**Checks run**

- Reviewed all 11 commits and relevant implementation, tests, UI sources, and DESIGN sections.
- `npm run typecheck`: passed both configurations.
- Socket-free ownership, entries, and text tests: **44 passed**.
- Selected run, matcher, phrase, and lab graph tests: **8 passed**.
- `npm test`: attempted; sandbox `EPERM` blocked temporary-file creation and local listeners. Full-suite success is not confirmed.
- Independent in-memory probes reproduced B1 and the noted phrase, response, run, logging, and matching issues.
- Generated lab plist: `plutil -lint` passed through stdin. Compared local Apple `.wflow` samples.
- No external network access, signing, device execution, excluded-path reads, or file changes.
