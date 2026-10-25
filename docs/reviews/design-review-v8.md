# Design review — v8 Part 2

Date: 2026-10-22

## Verdict

**Revise before implementation.** Part 2 preserves strict reply ownership in principle. Waiting for idle does not itself weaken §4.2, provided every follow-up uses fresh evidence and all ownership checks.

The main gaps are conversation isolation, the final answer at the loop limit, and lab privacy. The experiments cover U1–U6 by name, but several cannot support the decisions assigned to them.

This is a read-only design review against BRIEF, DECISIONS 1–19, and DESIGN §§4 and 7. No excluded files were read. No network or device calls were made.

## Blockers

**B1 — A token identifies a Shortcut, not a conversation. §18.2**

The same Shortcut can start again while an earlier invocation remains active. Both invocations share the token, and `turn == 1` resets their shared state. A late request can then join a held fragment from another invocation or use the wrong “previous turn answered” state.

Add a unique invocation ID and an ordered step number. Bind the conversation to the authenticated token and bot. Reject stale or conflicting steps. Define duplicate handling so a repeated HTTP request cannot send another bot message. The per-bot in-flight guard alone does not isolate state between requests.

**B2 — The loop drops the final answer. §18.2**

In V2, response N becomes the prompt for iteration N+1. When iteration 10 returns `next: "listen"`, the loop exits without speaking that answer. It speaks only the limit message. A held fragment can also disappear at this boundary.

Define the final-step behavior explicitly. Speak the final response exactly once, then end. Do not request another fragment when no listening step remains. Distinguish captured fragments from submitted bot questions when counting turns.

**B3 — “Test sentences only” is not a privacy control. §19.1, §11; BRIEF §3**

The microphone can capture private speech, background conversation, or a spoken secret. Recording the received text directly cannot guarantee that it contains only test sentences. A separate local file and manual deletion do not establish that guarantee.

By default, store the scenario ID, expected sentence ID, lengths, match results, timings, and observed outcome. Discard unexpected text before logging. Any temporary raw capture needs explicit consent, private file permissions, bounded retention, and exclusion from `lab report` and STATUS.

## Should-fix

**S1 — The idle wait needs a precise ownership boundary. §18.3, §4.2; DECISIONS 17**

An accepted reply proves ownership of that delivery. It does **not** prove that the session’s remaining busy activity belongs to Homebot. Desktop activity or a routine can start afterward.

Describe the wait as a bounded scheduling allowance after an accepted Homebot reply. It is not evidence of ownership. Retain the per-bot guard, deadline, and disconnect cancellation. Establish the new baseline through a complete sync and check idle again before sending. Never advance that baseline after sending to exclude inconvenient entries.

The wait changes DECISIONS 17’s immediate-busy policy. Record that change explicitly. Late output after the new baseline must still cause O3 refusal where applicable. Never speak discarded tail deliveries.

**S2 — The idle diagnostic cannot identify the previous turn’s completion. §18.3**

`idle_after_ms` measures time from an accepted reply to the next observed **session** idle state. Other activity can extend that time. A 30-second timeout is also a distinct result, not a measured duration.

Keep the observer read-only with respect to request ownership and conversation state. Define its interaction with the next request, cursor updates, token revocation, and shutdown. Use at most one observer per session. Report intervening activity and “idle not observed” separately. This also needs an explicit exception to §4.3’s request-scoped polling lifecycle.

**S3 — The hold rules misclassify normal answers and lack a complete exit contract. §§17.2–17.3, 18.2**

“Why?”, “Yes”, “Tomorrow”, “天气”, and “继续” are complete utterances below the proposed thresholds. A literal suffix check can also confuse word endings with whole words. Two holds followed by automatic submission only delays these cases.

The fallback tells the user to say “发送”, but no rule processes that command. Define command precedence, punctuation normalization, fragment joining, combined length limits, cancellation, and expiry. Silence that produces no HTTP request cannot trigger a server-side send.

A premature send is not always cheap. A bot can act on an incomplete instruction before the correction arrives. Prefer explicit continuation signals over shortness alone. Do not treat silence or exhausted holds as general permission to submit uncertain instructions.

**S4 — Lab mode needs a separate authorization boundary. §19.1 versus §7.6**

A process-wide `--lab` switch and the normal `/v1/ask` route do not specify what happens when the lab Shortcut reaches a normally started gateway. A normal voice token could then send a test sentence to a real bot.

Reuse the existing probe pattern: a distinct lab token kind, accepted only by the lab handler. Lab tokens must not replace or retire voice tokens. Normal mode must reject them before bot dispatch. In lab mode, normal voice requests need an explicit, safe response.

**S5 — Phrase validation extends beyond the approved evidence. §16.2; DECISIONS 12 and 18**

The single-script rule follows DECISIONS 18. The broad `badStarts` ban does not follow from the recorded tests. The draft itself records that “问拆解师” worked. It also labels the recognition mechanism as likely, not established.

Keep the approved script restriction. Treat additional intent-word exclusions as recommendations until measured, while retaining Felix’s explicit no-leading-问 requirement. Specify trimming, Unicode normalization, case handling, and English word boundaries. Separate phrase character rules from prompt text, which needs punctuation.

**S6 — Uniqueness can obstruct replacement without guaranteeing Siri uniqueness. §16.2 versus §§7.5–7.7**

A replacement normally needs the existing phrase, while the old token remains active until first use. The proposed uniqueness rule rejects this valid transition unless it exempts the replaced token.

Check the normalized effective filename, not only the entered text. Define duplicate handling across English variants. Describe the result as uniqueness within Homebot’s records. Retired tokens can still have installed Shortcuts, and unrelated Shortcuts are outside those records.

**S7 — Expiry and failure behavior are incomplete. §18.2 versus §§4.3 and 7.2**

A 90-second gap includes response generation, spoken playback, and the user’s listening and thinking time. Define what happens when the next step arrives after expiry or a gateway restart. Do not silently treat it as a fresh conversation or discard a held fragment without notice.

Also define terminal handling for malformed JSON, missing fields, authentication failures, and network errors. Preserve the explicit speech language used by §7.2. V2 must demonstrate correct pronunciation because it replaces the explicitly configured Speak Text action.

The fixed repeat count also limits the claim that turn limits can change without re-import. The gateway can lower that ceiling, not raise it.

**S8 — The experiments currently overstate what they establish. §§19.1–19.3**

“No next request” cannot distinguish silence, Siri cancellation, network failure, or a stopped Shortcut. E1 or E6 may terminate the run before later experiments execute. Ten fast lab turns do not establish the lifetime of ten realistic bot exchanges.

A bot-free lab cannot determine `followupIdleMs`. E5 and E7 measure platform behavior, not bot activity. The longest successful delay is an observed bound, not a reliable timeout limit.

## Nit

**N1 — Mark superseded contracts clearly. §§7.4, 16–19**

Section 7.4 still describes names that §16 rejects. The draft also mixes listening steps, bot turns, and `Repeat Index` under “turn”. Mark the naming replacement and use distinct terms. Keep the draft status visible until device evidence supports the chosen loop.

## Suggestions

Use one lab Shortcut with selectable, independently restartable scenarios. Include both V1 and V2 branches initially if testing both requires different actions. A gateway script alone cannot change the installed action graph.

| Unknown | Better experiment | Decision supported |
|---|---|---|
| U1: Pause Time | Start with a no-pause control. Compare Default and Longest around a pause that causes truncation. Repeat near that boundary on iPhone and HomePod. Record transcript match, not character count alone. | Whether the setting improves Shortcut input on each device. |
| U2: Silence | Test silence on the first prompt, after an answer, and after a held fragment. Record Siri’s visible or audible outcome manually. Restart each terminating case independently. | Whether empty input reaches the gateway, and which termination paths require local state expiry. |
| U3: Hold | Compare held and unheld input using the same sentence and pause. Specify when contact starts and ends relative to Ask for Input. | Whether holding preserves the full utterance in the actual Shortcut path. |
| U4: Session lifetime | Run a short control, then a realistic conversation with answer playback, user pauses, and simulated bot delays. Include the final-step boundary. | A demonstrated supported duration and step count, not a universal platform maximum. |
| U5: URL wait | Test each delay in a fresh invocation. Start below the observed failures, then narrow the boundary with repeated trials. Record disconnect time and whether the answer was heard on the initiating device. | A conservative request budget with margin. |
| U6: Answer as prompt | Compare V1 and V2 with short and maximum supported answers. Check full playback, language, when listening starts, and the returned response. | Whether V2 is suitable across the supported answer range. |

Run termination and failure probes separately from sustained conversation tests. Use the iPhone to find basic action errors, then spend HomePod time on device-dependent behavior. The 20-minute estimate should be a timebox for priority questions, not a promise to resolve every unknown.

For the product, test P/H first, as proposed. Then validate a bounded conversation loop without automatic completeness guessing. Add hold behavior only if representative pause tests show a useful improvement.

Keep conversation mode opt-in during this experiment phase. Explain that it listens again after each answer and can send nearby speech. Strict reply ownership protects spoken output, not captured input.

Before device testing, use the existing fake BDK boundary to check overlapping invocations, duplicate steps, expiry, late deliveries, and foreign activity during the idle wait. Separately check final-answer playback and lab-token rejection. These checks need no live bot messages.
