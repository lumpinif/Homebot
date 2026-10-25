# Process / 协作流程

## Roles
- **Claude Code (Opus 5.5) — lead designer + implementer.** Owns docs/DESIGN.md and all code.
- **Codex CLI (GPT-6 Astra, medium reasoning) — reviewer.** Reads, critiques, verifies; writes reviews only (docs/reviews/). Does not rewrite the code.
- **Felix — product owner.** Since 2026-10-22 Claude works with Felix directly. 拆解师 (Felix's Grok Bot) was the proxy before that. Sets requirements and approves anything touching his devices or accounts. Design decisions are Claude's, open to Felix's review.

## Loop
1. Claude reads BRIEF.md (+ the spike references it points to) and writes **docs/DESIGN.md**: architecture, components, data flow, config/storage, security model, setup UX (README + local web page), Shortcut generation & delivery, bot listing/selection, failure modes/timeouts, test plan, milestones. Open questions for Felix go in a clear section. **Then stop for review.**
2. Codex reviews DESIGN.md → **docs/reviews/design-review-N.md** (prioritized: blockers / should-fix / nits, each with reasoning).
3. Claude revises DESIGN.md (note what changed and why), then implements in **small, verifiable commits** (each runs/tests locally).
4. At each milestone Codex reviews the diff → docs/reviews/milestone-<name>-review.md. Claude addresses it.
5. Repeat until the **end-to-end flow** works: HomePod/iPhone Siri → Shortcut → Homebot → chosen Grok Bot → plain-text answer spoken by Siri.

## Rules
- Both write a short dated entry to **docs/STATUS.md** after each step (what was done, what's next, blockers, questions for Felix).
- Never print/commit secrets. Respect BRIEF.md §3 constraints.
- Anything that needs Felix (logins, HomePod sound tests, importing Shortcuts on his phone, GitHub remote) → write it under "Needs Felix" in STATUS.md and stop that thread; don't work around it.
