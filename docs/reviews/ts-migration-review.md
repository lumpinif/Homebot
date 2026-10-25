# TypeScript migration review

2026-10-21 — Codex. Reviewed `a4640d2..1f453ab`, DECISIONS item 16, DESIGN v6, STATUS and README.

**Verdict:** No blocker found in the supported Shortcut flow. Two localized corrections are requested below. The port preserves the main safety rules and the dependency-free runtime. Full test success remains unverified in this sandbox.

## Blockers

None established. The loopback failures below are environment limits, not product failures.

## Should-fix

### S1 — Separate the changed array-body behavior from the type-only port

**References:** `src/server/voice.ts:84`, `src/core/fsutil.ts:17`, `docs/STATUS.md:366`.

The old listener accepted JSON arrays as objects. The new `isRecord` check rejects them. With a valid token, `POST /v1/ask` containing `[]` previously authenticated and reached the empty-question path. It now returns JSON with HTTP 400 before authentication. The old path could also activate a pending token and retire its predecessor. The new path cannot.

A socket-free comparison of both listeners confirmed the change: old = 200, one verification and one AskService call. New = 400, neither call. The probe used synthetic dependencies. Generated Shortcuts send objects, so their normal flow is unaffected.

**Suggestion:** Restore the prior handling for this behavior-preserving migration. Alternatively, explicitly record array rejection as a separate API correction and add a focused contract test. The current “otherwise identical” statement omits it. Rejection itself is reasonable, but it is not a type-only change.

### S2 — Reconcile signing status with the recorded live result

**References:** `README.md:5`, `docs/DESIGN.md:256`, `docs/STATUS.md:335`, `docs/STATUS.md:372`.

README says signing has not run and the first signing run is upcoming. DESIGN still marks XML acceptance as unverified. STATUS records three successful signing runs at 14:23 and says those Shortcuts are unaffected by this migration.

This inconsistency predates the port, but remains in the requested documentation review. A beginner cannot tell which step already works and which still needs a device check.

**Suggestion:** State that signing succeeded for Felix before the TypeScript migration, while post-migration signing, iPhone import and HomePod acceptance were not checked here. Preserve the default-off signing gate and the fresh-account caveat. Do not describe the earlier result as post-migration validation.

## Nits

### N1 — Describe Node support by release line

**References:** `docs/DECISIONS.md:33`, `docs/STATUS.md:375`, `package.json:12`.

The blanket claim that “22.18–24.11” runs without warnings is incorrect. That range includes Node 23.6 and Node 24.0–24.2. Using the Node history supplied for this review: stripping became unflagged in 23.6/22.18, warning-free in 24.3/22.18, and stable in 24.12/25.2.

**Suggestion:** Keep the selected minimum, 24.12.0. Replace the broad range with explicit release-line statements. No online documentation request was made under this review's offline restriction.

### N2 — Distinguish allowing `.ts` imports from enforcing them

**References:** `tsconfig.json:19`, `docs/DECISIONS.md:34`, `docs/STATUS.md:355`.

`allowImportingTsExtensions` permits `.ts` specifiers. It does not require them. TypeScript can resolve a relative `.js` specifier to a `.ts` source even when Node cannot load that missing `.js` file.

**Suggestion:** Describe explicit `.ts` paths as a source convention, separate from the enforced erasable-syntax and type-import rules. Current runtime imports use the correct paths. No broken import was found.

## Checks and review coverage

- **Typecheck:** `npm run typecheck` passed for both configurations on Node 24.14.0. Strict checking, indexed-access checking, exact optional properties, erasable-only syntax and verbatim module syntax are enabled.
- **Tests:** `npm test` discovered 152 tests. 79 passed. All 72 reported failures were `listen EPERM` on `127.0.0.1`. One QR decoder test skipped because Swift could not write its module cache. Thus this run does not independently confirm Claude's 152-pass result.
- **Test preservation:** All 151 prior test names remain, plus the UI drift test. Compared test bodies and assertions. No weakened assertion or dropped test was found. `must()` adds runtime assertions rather than suppressing missing values.
- **Behavior comparison:** Compared all 44 former JS/MJS files with their TS replacements, including normalized executable output. Paging, ownership evidence across entry versions, echo checks, deadline phases, disconnect handling and retry message IDs retain their logic. Token locking, replacement, session binding, credential precedence and secret-safe errors retain their intended behavior. The documented malformed-file handling changes are real runtime changes, not merely annotations.
- **Assertions:** No explicit `any`, suppression directive or non-null assertion was found. JSON assertions remain at documented trust boundaries in the BDK client, stores and page API. These do not validate runtime data. Invalid nested file/API data remains a pre-existing limitation, not a proven new migration defect. Stream assertions match requests without a text encoding. Test JSON/plist views retain runtime value assertions.
- **Setup security:** Host checks, setup-secret checks, same-origin mutation checks, body limits, CSP, static asset allowlist and text-only DOM rendering remain intact. No new secret exposure was found by comparison. A browser interaction check did not run.
- **Install/runtime:** The CLI import graph loaded from an isolated copy without `node_modules`. External runtime imports are Node built-ins, and type-only dependencies are erased. `engines`, `bin`, `start` and developer scripts target the TS layout. Generated browser JS is tracked. No current executable reference to a removed JS file was found. Historical STATUS references and external BDK filenames are not broken runtime imports. Full listener startup is blocked here by EPERM.
- **Generated UI:** The drift test passed. In a disposable copy, the check accepted clean output and rejected an edited `app.js` with exit code 1. Without developer dependencies, the test explicitly skips. It is not a user-side build requirement.
- **QR port:** Compared old and new complete symbols for 214 synthetic payload lengths, 0–213 bytes. Every result matched. This supplements the skipped decoder check, but does not prove phone scanning.

No bot/service calls, login, real credential inspection, Apple signing or device actions ran. Only this review and the appended STATUS entry change the repository. Code and DESIGN.md remain unchanged.
