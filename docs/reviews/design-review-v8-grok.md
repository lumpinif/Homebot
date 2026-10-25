# Design review — v8 Part 2 (Grok, second reviewer)

**Date:** 2026-10-22
**Scope:** DESIGN.md §16–§19 (v8 draft), against BRIEF.md, DECISIONS.md items 1–19, DESIGN §4 and §7, and the 2026-10-22 device log in STATUS. `auth/` and secrets were not opened. Public search only; a direct fetch of support.apple.com was blocked (private-relay address).

## Verdict

Revise before building. The script rule (DECISIONS item 18), trying Pause Time and hold-to-talk before any heuristic, and leaving v1 as `text/plain` are sound. As written, §18.3 weakens §4.2, the §18.2 graph drops answers, and the §19 session does not measure U1–U6. G2 and DECISIONS items 8 and 17 still hold. Echo compliance on this bot was good (STATUS: every answered request echoed the tag); that does not cover the new hole.

## Blockers

### B1. §18.3 moves foreign turns outside O2/O3

§4.2 accepts a reply only when the seq window proves nothing else could have caused it. O2/O3 see every `role=user` and every `send-message` after `maxSeq`. §18.3 waits for `idle`, then takes `maxSeq`. A desktop message that arrives and is answered during those 6 s sits before the baseline, so O2/O3 never see it. The follow-up is sent, the bot echoes a new `[hb:<id>]`, and O5 passes on a session that just served someone else. Concrete path: turn 1 is spoken while the backend is still `B` (STATUS: every poll is `B`); a desktop request finishes during the wait; the user says “tell me more”; the bot continues the desktop content with a valid tag. Under D13 and DECISIONS item 17 that follow-up is “busy” and nothing is sent.

“The wait only delays the baseline” is the weakening. The checks run on a window the wait has already cleared. Turn flags are session activity (§4.2, §5.1, item 17). STATUS says they must not affect ownership. Choosing `maxSeq` from `idle` uses them as ownership timing.

Budget: answered requests took 6.0–10.5 s, and one client dropped at 10.3 s for an unknown reason (STATUS). A silent 6 s wait sits inside Get Contents of URL before the bot is asked. Item 17 rejected waiting on a busy turn because the Siri budget is short.

`idle_after_ms` is the right measurement and needs no HomePod. It must not advance the persisted cursor and must not overlap the next `/v1/ask` sync. A cursor move through the tail deletes the same O3 evidence.

### B2. §18.2 speaks `say` only on `end`, so a listen-path answer is dropped

On `listen`, `say` is only the next Ask for Input prompt (V2). Iteration 10 with `next: listen` leaves Repeat and speaks the turn-limit line. That turn’s answer is discarded.

V2 also leaves Speak Text. Requirement 5 was met with Speak Text (STATUS). Apple’s Ask for Input page describes a dialog confirmed with OK. U6 is whether a long prompt is read aloud at all.

v1 errors are `text/plain`, including 401 (§10, D12). D12 chose plain text because non-200 handling on HomePod is unknown. A loop that receives plain text has no `next` and does not Stop. “Errors use `next: end`” covers the 200 JSON path only.

The Repeat 10 cap is baked into the Shortcut (§7.3). Holds in §17.3 consume that same cap. Gateway-side policy cannot raise it.

### B3. One lab loop does not answer U1–U6, and can retire「家庭助手」

E1 (silence) and E6 (“不用了” / “No”) are the steps most likely to stop the Shortcut. E2–E5 and E7 are later steps of that same run, so a stop skips them. A dead session at E7 looks like a URL timeout. §19.3 says E5 and E7 set `followupIdleMs`. Lab mode never contacts a bot, so they cannot. The tail is a BDK fact; `idle_after_ms` on a normal ask measures it.

U5 already has a ladder (§7.6, 5…58 s) that has not been run (“Homebot 等待测试” is still pending). E7 replaces it with one sample each at 10/15/20/30 s, inside a long session. That cannot separate the 10.3 s disconnect from a limit, and it never reaches the ~60 s figure in the brief.

E2 uses one 2 s pause and two settings. Apple does not publish Default vs Longest, so both can pass or both can fail. Pause Time is documented for iPhone/iPad Accessibility → Siri (“how long Siri waits for you to finish speaking”), not for Ask for Input and not for HomePod. Change it between fresh “Hey Siri” invocations.

U3: Apple documents hold-to-talk for the initial request — “To make a longer request, touch and hold the top of HomePod until you’re finished making your request” (HomePod guide, Set up Siri). That sentence is not about a later Ask for Input. E3 does not say which window is held, and it has no iPhone side-button control.

U4: ten short turns show that 10 turns fit. They do not show how long a session may last. U6 is one 250-character prompt, with no end-marker word and no shorter or longer bracket.

“家庭实验” is a new name, so HomePod may take minutes to a day to learn it (BRIEF, STATUS, §7.4). A 20-minute same-day HomePod pass is not a schedule.

§7.6 exists so a probe token cannot replace a voice token. §8 defaults “replaces” to the active voice Shortcut. §19 does not give the lab Shortcut that kind, and does not forbid `--replaces`. The first lab request can retire「家庭助手」.

### B4. Lab transcripts are on a path into git

G7 and §11 keep question text out of logs unless text logging is on. The device log stored lengths only. §19.1 stores utterance text and says `homebot lab report` prints a table for STATUS. STATUS is in the repo. Siri will transcribe the room, not only the scripted sentence. Path, mode (0600), size cap, retention, and delete-on-revoke are unspecified. `--lab` on `:8787` lets anyone holding the lab token write that file. The table that enters STATUS should be lengths, timings, empty-or-not, and pass/fail.

## Should-fix

### S1. §16.2 bans more than item 18, with no override

Item 18 is the script rule. Checked:「问拆解师」worked;「问 Grok Bot」and「homebot 你好」did not. `badStarts` still hard-refuses 问, plus ask/call/play/…. The pre-v8 English default was `Ask <bot>` (§7.4). Chinese has no spaces, so a prefix match refuses 问题…, 设置…, 什么…. Uniqueness is per Siri language, but both Shortcuts live on one iPhone; the same string in en-US and en-GB is the collision Siri resolves at random. Reusing a retired name ignores the learning delay.

Hard-refuse characters outside `script`. Keep `badStarts` as a warning until a device run shows that word capturing the phrase. Uniqueness is on the string, across every non-retired Shortcut.

### S2. §17.3 misses a mid-sentence pause and holds complete questions

The device failure is a pause, then an early send.「帮我看看明天」is longer than 4 Han and does not end in 的/和/因为, so it is sent.「几点了」(3 characters) and anything ending in 的, including「好的」, is held. Lengths 2, 3, 4, 4, 9, 19 match STATUS and still do not prove a cut point.

A sent fragment is spoken to the room before any “continue” turn, and that continue still has to survive B1. Punctuation is unspecified (「因为。」). The silence fallback tells the user to say 发送, and 发送 is not a control word in §18.2.

If E3 shows that hold-to-talk covers Ask for Input, do not build `complete.ts`. Otherwise join only when the next utterance is clearly a continuation, or when the previous piece is very short.

### S3. Session edges in §18

Exact end words miss「谢谢。」and “thanks a lot”.「谢谢」as an end word swallows a thank-you the bot never sees (Q18-2). Expiry is 90 s without a request, while `turn == 1` is the only restart; turn 5 after expiry is unspecified, and speech time counts because HTTP finished before Siri reads the answer. There is no idempotency key, so a repeated POST can send a second bot message or hit the in-flight guard and take `next: end`.

§18.4 says the user can reply immediately. §4.2 speaks only the first proved delivery. “Go on” can make the bot speak the rest of a turn Homebot refused to read. The envelope should say the room heard only that one delivery. §18.5 is right that ownership does not cover what is sent. Q18-1 should default off until a room-noise run.

## Nits

- The header still says v7.1. §1 mentions multi-turn; D12, D13, and the §3 diagram do not.
- §7.5 still says iPhone import and HomePod use are unverified. STATUS says requirement 5 was met with「家庭助手」.
- English probe name “Homebot Wait Test” still needs a §16.2 pass.「家庭等待测试」is Han-only and fits.
- §16.1’s other-script recognizer is a hypothesis. Keep the label.

## Suggestions

1. **Follow-up without moving the window.** Record `maxSeq` when the follow-up arrives. Poll until idle or `followupIdleMs`. Send only if every new entry is a `send-message` continuing the proved turn (no `role=user` in any version). Otherwise say busy, set `next: end`, and do not send. Move the baseline only after that check. Ship the diagnostic first; keep `followupIdleMs` at 0 until `idle_after_ms` is known.

2. **Speak with the action that already works.** Repeat; Ask; POST; if `next` is missing or the body is not a dictionary, speak a baked failure line and Stop; else Speak Text `say` and wait; if `next` is `end`, Stop. The next Ask uses a short fixed prompt (V1). Try V2 only inside E4. On loop exit, speak the last `say` when `next` was `listen`.

3. **One unknown per invocation.** The Mac dry run checks the plist; Ask for Input on Mac is a dialog. After「家庭实验」is recognized: E0, a Shortcut with no Ask for Input, question in the rest of the “Hey Siri” utterance (if that remainder arrives whole, Pause Time and the documented HomePod hold apply to the real Siri window). E1 and E6 each on a fresh run. E2: fresh invocation per setting (Default, Longer, Longest), marker word after a 1 s, 3 s, and 6 s pause, iPhone then HomePod. E3: iPhone side-button hold as the control; HomePod hold during Ask for Input, through a long pause. E4: ~80, 250, and 500 characters with a last word Felix must hear. E5: 10 short turns, plus one run with ~20 s gaps. E7: keep §7.6; repeat the boundary delay twice. `idle_after_ms` on the next real ask, with no extra bot message.

4. **Lab privacy.** A token kind that cannot replace or be replaced (copy §7.6). `--lab` refuses voice tokens, and voice mode refuses lab tokens. Lab log under `~/.homebot`, 0600, capped, deleted with the token. `lab report` prints no transcript. Felix’s notes go in STATUS; the text does not.

5. **Phrases.** zh-CN and English only until someone can test the next language (Q16-2). Q16-1 (c) is a fair English candidate; “Homebot” vs “HomePod” is untested either way. `fromBot` only when the whole name is in-script.

## Apple claims

Confirmed from Apple snippets: Siri Pause Time is an iPhone/iPad Accessibility → Siri control (Default / Longer / Longest). HomePod hold-until-finished is documented for the initial request (Set up Siri). HomePod update notes (support.apple.com/zh-cn/108045) add zh-CN, zh-TW, yue-HK, ja-JP (15.6); nl and fr-BE (15.4); en-IN and it-IT (15.3); fr-CA/FR, es-MX/ES/US, de-AT/DE (15.2). That matches §16.3. Korean is absent there (keep “confirm”). Portuguese is absent there, so it is stronger than “user reports”. The “No” cancels a Shortcut claim and the ~60 s URL timeout stay user reports; this pass did not re-read those threads. The HomePod settings guide was not opened, so “no Pause Time on HomePod” is still unchecked against that page.
