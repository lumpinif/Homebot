# Release checklist and notes

How a Homebot release is made, what was checked, and what still needs Felix. Agents build and check; they never push, tag, publish or notarize.

## Build

```sh
cd mac
scripts/release.sh   # build/Homebot-<version>.zip and build/Homebot-<version>.txt
```

Run it in a clean checkout (it refuses changes under `mac/`). The version is `mac/VERSION`; the build number is 287 plus the commit count (the public history restarted after build 287).

## Checks (done by an agent)

| Check | How | Last result (2026-10-25, commit aeaad6c) |
|---|---|---|
| Version string | `CFBundleShortVersionString` = `mac/VERSION`, build = commit count | `0.5.0` (build 208) at the time; `mac/VERSION` is now `0.1.0` (not rebuilt since) |
| Notes file | `build/Homebot-<version>.txt`: commit, SHA-256, architectures, signature | `Homebot-0.5.0.txt`: commit aeaad6c, x86_64 + arm64, minos 15.0, ad-hoc |
| Signature | `codesign --verify --deep --strict` on the app, the CLI and the unpacked zip | OK for all three |
| Gatekeeper | `spctl --assess` says rejected (expected: ad-hoc, not notarized) | rejected (expected) |
| Localizations | `CFBundleLocalizations` and `*.lproj` in Resources | 11: de, en, es, fr, it, ja, ko, pt-BR, ru, zh-Hans, zh-Hant |
| Zip contents | `unzip -l`; no `.agent-logs`, `auth/`, keys, tokens, fixtures, test data | Only the app: binary, CLI, Info.plist, signature, icons (`AppIcon.icns`, `Assets.car`, Homebot/Black/White `.icns`), `grok-bot.png`, 11 `.lproj`. About 31 MB |
| No secrets or local paths | `strings` and `grep` over every file in the zip for `api-key`, `Bearer`, `sk-`, `key_`, `/Users/` | Clean after aeaad6c. Before it, the app binary carried the build checkout's path (`#filePath` in a debug fallback, now debug only). `api-key` matches only the file name constant |
| Tests | `cd mac && swift test`; `npm test` | Swift 501 pass (123 + 90 + 288); npm 214 pass |

## Needs Felix

- [ ] **Real-device checks** from STATUS S16 (also in [ACCEPTANCE.md](ACCEPTANCE.md) §3): the This Mac path end to end and its ticks; iCloud sync to the iPhone and HomePod; replacing on the Mac path (delete first; what a same-name import does); the sync tip's settings paths; delete the probe Shortcuts "HB Install Probe 1", "2", "3".
- [x] **Version**: `0.1.0` for the first public release (Felix, 2026-10-25). `0.5.0` had been a placeholder set with the release script in Swift phase S5 (commit 0f46c70), not a decision.
- [x] **Download URL / GitHub Release**: the main download is `https://homebot.fun/download/latest?from=…`, which redirects to the zip in the R2 bucket `homebot-releases`; the same zip (same SHA-256) is attached to the GitHub Release `v0.1.0` as the fallback (Felix, 2026-10-26: release the first version).
- [x] **Repository visibility**: `lumpinif/Homebot` is public, with a fresh history (Felix, 2026-10-25).
- [x] **Website hosting**: homebot.fun, one Cloudflare Worker on Felix's personal account (`cloud/DEPLOY.md`).
- [x] **"Open Anyway" picture**: `docs/images/install/open-anyway-en.png`, captured 2026-10-26 on Felix's Mac (macOS 26) from a quarantined copy of the app; Open Anyway was not clicked.
- [x] **Siri orb**: kept. It is our own drawing and differs from Apple's (Felix, 2026-10-25).

## Release notes (v0.1.0)

> **Homebot 0.1.0**: the first release.
>
> Ask your Grok Bot with Siri on HomePod, iPhone and Mac. Homebot runs on your Mac at home and makes the Siri Shortcut for you. Setup is clicking, no Terminal.
>
> - Four setup steps: Account, Bot, Shortcut, Install. Home shows **Ready** when Siri can reach your bot.
> - Install on **This Mac** (iCloud brings it to your iPhone) or send it to an **iPhone** by AirDrop or QR code, also to an iPhone on another Apple Account.
> - Say "Hey Siri, Grok Bot". Siri keeps listening after each answer; say you're done to end.
> - Eleven Siri languages. Each Shortcut keeps its own phrase and voice, and your bot answers in that language. Make as many Shortcuts as you like.
> - Strict reply checking: Siri reads only the answer to your question, never a different one.
> - Activity shows what was asked and said, stored only on this Mac.
> - Anonymous analytics are off unless you choose Share.
>
> **First open:** Homebot isn't notarized. macOS says "Homebot.app" Not Opened: click Done, then System Settings › Privacy & Security › Open Anyway. [Guide with pictures](https://github.com/lumpinif/Homebot/blob/main/docs/INSTALL.md).
>
> Requires macOS 15 or later (Apple silicon or Intel). Download: https://homebot.fun. SHA-256: on the release page and in `Homebot-0.1.0.txt`.
