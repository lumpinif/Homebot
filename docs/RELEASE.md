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
- [ ] **Download URL / GitHub Release**: README and INSTALL download through `https://homebot.fun/download/latest?from=github` (the agent prompt uses `from=agent`), with `https://github.com/lumpinif/Homebot/releases` as the fallback. No release exists yet. Upload the zip and paste the notes below, with the SHA-256 from the `.txt`.
- [ ] **Repository visibility**: `lumpinif/Homebot` is **private** (checked with `gh repo view`), so the Releases link and the agent prompt's repository link don't work for anyone else. Make it public, or host the zip elsewhere and change the links.
- [ ] **Website hosting**: the site on branch `claude/website-2fd2d7` (`site/`, with the agent guide `site/public/install.md`) is not merged or hosted. Choose where it lives and its domain.
- [ ] **"Open Anyway" picture** for `docs/INSTALL*.md` (the only missing picture).
- [ ] **Siri orb**: our own drawing, but meant to evoke Siri (STATUS S11 risk). Keep it for a public release?

## Release notes (draft)

> **Homebot 0.1.0** — first release of the native Mac app.
>
> Ask your Grok Bot with Siri on HomePod and iPhone. Homebot runs on your Mac at home and makes the Siri Shortcut for you. Setup is clicking, no Terminal.
>
> - Four setup steps: Account, Bot, Shortcut, Install.
> - Install on **This Mac** (same Apple Account and iCloud Sync on; iCloud brings it to your iPhone) or send it to your **iPhone** by AirDrop or QR code. One answer finishes setup.
> - English phrases "Grok Bot", "My Grok Bot", "Our Grok Bot"; eleven Siri languages, each Shortcut keeps its own. Homebot asks your bot to answer in the language you ask in.
> - Phrase rules are advice; tapping a Shortcut always works.
> - Optional conversation mode: Siri keeps listening after each answer.
> - "Why didn't Siri speak?" help, an app icon that follows Light and Dark, a calmer Shortcuts list.
>
> **Status:** release candidate. Tested offline (over 500 automated tests); not yet confirmed answering a real Siri request on a device. Languages other than English and Chinese are drafts.
>
> **First open:** Homebot isn't notarized. macOS says "Homebot.app" Not Opened: click Done, then System Settings › Privacy & Security › Open Anyway. [Guide with pictures](https://github.com/lumpinif/Homebot/blob/main/docs/INSTALL.md).
>
> Requires macOS 15 or later (Apple silicon or Intel). SHA-256: from `Homebot-0.1.0.txt` of the commit you release (each commit changes the build number and the hash).
