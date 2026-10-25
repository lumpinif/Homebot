# Homebot

Talk to your Grok Bots through Siri on HomePod and iPhone. Say "Hey Siri, Grok Bot", in any Siri language. Siri asks what you'd like to know, Homebot passes your question to your bot, and Siri reads the answer aloud.

Homebot is a Mac app. It runs on a Mac at home, on the same Wi-Fi as your iPhone, and answers the Siri Shortcut it makes for you. Setup is clicking in its window: no Terminal.

> **Status: first release (0.1.0).** Homebot.app (the native Mac app in `mac/`) answers real Siri requests on the maintainer's iPhone and Mac, in English and Chinese, and passes over 500 automated tests. The earlier TypeScript version also worked on a Chinese HomePod ("家庭助手"). Languages other than English and Chinese are drafts. Steps not yet checked on a device are marked *(unverified)*. Details: [docs/STATUS.md](docs/STATUS.md).

## What you need

- A **Mac** with **macOS 15 (Sequoia) or later**, Apple silicon or Intel, that stays on and awake at home, on the same Wi-Fi as your iPhone.
- An **iPhone** with Siri turned on. A **HomePod** is optional; it uses the Shortcuts on your iPhone. For HomePod, **Siri** must also be on in **iCloud** on the iPhone (Settings › your name › iCloud).
- A **Grok Bot** you already use. If Grok Bot is already signed in on this Mac, Homebot uses that login; otherwise you paste an **API key from your Cursor dashboard** *(unverified: the exact dashboard menu names, and whether a brand-new account's key can use Grok Bot)*.

## Install

[Download Homebot](https://homebot.fun/download/latest?from=github) (the newest `Homebot-<version>.zip`; if that link doesn't work, take it from [Releases](https://github.com/lumpinif/Homebot/releases)), open it, and drag **Homebot** into **Applications**.

Homebot isn't notarized by Apple (its developer has no paid Apple developer account), so the first time you open it macOS says **"Homebot.app" Not Opened**. Click **Done**, then go to **System Settings › Privacy & Security** and click **Open Anyway**. macOS asks again after every update.

**Step-by-step guide with pictures: [docs/INSTALL.md](docs/INSTALL.md)** · [简体中文](docs/INSTALL.zh-Hans.md)

## Set up (by clicking, in Homebot's window)

Four steps: **Account → Bot → Shortcut → Install.**

1. **Account.** Homebot uses a Grok Bot login it finds on this Mac. If there is none, paste a key from your Cursor dashboard and click **Save** (with a login found, **Use an API key instead** opens the same form). The key stays in a private file on this Mac and is never shown again.
2. **Bot.** Type each bot's **exact name**, twice. A typo would make Grok Bot create a new, empty bot; Homebot notices and doesn't add it.
3. **Shortcut.** Pick a bot (or **All my bots**: one phrase, Siri asks which bot *(unverified on a HomePod)*), its Siri language (the HomePod's: Home app › your HomePod › Settings › Language) and the phrase. English defaults: **"Grok Bot"**, then "My Grok Bot", "Our Grok Bot". Click **Sign with Apple and make** (iOS adds only signed Shortcuts; the line under the button says what goes to Apple). After that first time the button is just **Make Shortcut**. Optional, for one-bot Shortcuts: **Keep listening after each answer** (conversation mode).
4. **Install.** "Does your iPhone use the same Apple Account as this Mac?"
   - **Yes → This Mac.** Click **Add to Shortcuts**, then **Add Shortcut** in the window that opens. Under "Ask it once on this Mac" click **Try it**, then **Always Allow**, and type a question. With iCloud Sync for Shortcuts on, iCloud brings the Shortcut to your iPhone *(unverified)*.
   - **No → iPhone.** Scan the QR code (works once, 10 minutes, same Wi-Fi) or AirDrop the file, tap **Add Shortcut**, then tap the Shortcut once in the Shortcuts app and ask something.

**One answer finishes setup**, on the Mac or by tapping on the iPhone. Saying "Hey Siri, Grok Bot" is a bonus on top *(unverified on the native app)*. Then, in **Settings**, turn on **Open at login** and leave **Keep this Mac awake for Siri** on.

Good to know:
- **Phrases are advice.** Homebot warns when Siri may not hear a phrase (another language's letters, digits, a first word like "ask"; a Chinese phrase starting with "问" was taken as a web search). It refuses only a phrase another Homebot Shortcut uses, one iOS would rename (`/ \ :`, control characters or a leading dot), or one longer than 60 characters. Tapping a Shortcut always works.
- **Homebot asks your bot to answer in the language you ask in** *(whether bots follow it is unverified)*. Each Shortcut keeps its own Siri language; **Settings › Language for new Shortcuts** only sets the default.
- **Conversation mode** listens again after each answer, for up to 10 rounds. Saying the end word (for example "stop"), silence or any error ends it. It can pick up room speech.
- **Why didn't Siri speak?** On the iPhone set Settings › Siri › Responses to **Prefer Spoken**; with Automatic or silent mode on, the iPhone may only show the answer. The (?) next to Activity shows where.
- **HomePod:** a new phrase takes from minutes up to a day. In the Home app turn on **Recognize My Voice** and **Personal Content** (Personal Requests before iOS 26) for your user, use this iPhone as your location device in Find My, keep the iPhone and HomePod on the same Siri language, and turn on Siri in iCloud on the iPhone ([Apple's guide](https://support.apple.com/108397)).
- **Shortcuts list:** a dot shows each Shortcut's state (green working, orange needs update, a grey ring not answered yet). **Install** opens its Install page (and makes a new copy when it needs an update); **⋯** has Install on another iPhone, Change language, conversation mode and Revoke.
- **App icon:** Automatic follows Light and Dark; Glow, Black and White are in Settings.

Used the earlier, Terminal-based Homebot? The app finds its settings (`~/.homebot`) and offers to import them; nothing happens until you click **Import**. Stop the old one first. Shortcuts already on your iPhone keep working.

## What works, and what is unverified

| | |
|---|---|
| Tested on a device (TypeScript version, 2026-10-22) | A signed Shortcut "家庭助手" on an iPhone and a Chinese HomePod: Siri ran it, the bot's answer was spoken. |
| Tested offline (native app) | Setup flow, gateway, the reply rules, Shortcut files, the one-phrase "All my bots" Shortcut and the conversation loop (played back against a stand-in Grok Bot), reading the Mac's Shortcuts library, import from the earlier version, the activity log, the release zip. |
| Unverified | The native app answering a real Siri request; the This Mac install path and iCloud sync to the iPhone; conversation mode on a device; whether bots follow "answer in the question's language"; English phrases on a HomePod; the "All my bots" menu on a HomePod; HomePod Siri in the other nine languages (the phrase and message tables in all eleven languages are drafts, not reviewed by native speakers); macOS 15 (built for it, run only on macOS 26); Intel Macs (built universal, checked once under Rosetta). |

Siri languages: English, Spanish, French, German, Italian, Portuguese (Brazil), Russian, Japanese, Korean, Chinese (Mandarin, mainland) and Chinese (Mandarin, Taiwan). Apple does not list Portuguese (Brazil) and Korean as HomePod Siri languages *(unverified)*.

Homebot gives the bot about 25 seconds to reply; if it takes longer, Siri says so. Long answers are shortened for speaking; the full answer stays in Grok Bot.

## Privacy and security

- **What stays on this Mac:** settings, bots, your API key (one private file), Shortcut tokens (only their hashes), and the **activity log**: each question as Siri heard it and what Siri said back, with times and outcomes, so you can see what happened. The activity folder is left out of Time Machine backups (a backup made earlier may still hold copies); **Clear** on the Home page deletes all of it. Homebot's diagnostic log never contains question or answer text.
- **What leaves it:** your questions go to Grok Bot (Cursor's servers) and the answers come back from there. Once you click **Sign with Apple and make** (iPhones only add Shortcuts signed by Apple), each new Shortcut file, with its phrase, the address it calls (usually your Mac on your home network) and its own token, goes to Apple's signing service. Reset everything clears this consent.
- **Plain HTTP on your home network.** Your iPhone reaches the Mac on port 8787 over plain HTTP. Use Homebot only on a home network you trust and **never forward this port** or expose it to the internet: other devices on the same Wi-Fi could read questions, answers and Shortcut tokens.
- Each Shortcut has its own token for the bots you chose, and you can revoke it in the app (Shortcuts › ⋯ › Revoke); it stops working at once. Removing a bot takes it out of every Shortcut.
- Homebot is not sandboxed (signing Shortcuts and serving the network need it) and not notarized. It is ad-hoc signed; you can check the download's SHA-256 against the release notes.

## Troubleshooting

| What happens | What to do |
|---|---|
| **"Homebot.app" Not Opened**, no Open button | Expected the first time and after each update. Click Done, then System Settings › Privacy & Security › Open Anyway. [Guide](docs/INSTALL.md) |
| **Siri doesn't recognize the phrase** (on HomePod it may offer web results) | A new or renamed Shortcut can take from a few minutes up to a day before HomePod recognizes it. On iPhone it works right away, so test there first. Check that the Shortcut was made for your HomePod's Siri language, and that the phrase uses only that language's letters. Tapping the Shortcut always works. |
| **"Couldn't connect" / a long silence** | The Mac is probably asleep, or Homebot isn't running. Homebot's Home page shows both. A Mac that is already asleep doesn't wake up for Siri. If the Mac's `.local` name doesn't work on your network, make the Shortcut again with the Mac's IP address in Shortcut › Options › "Address on Wi-Fi" (for example `http://192.168.1.20:8787`). |
| **The iPhone shows the answer but doesn't read it** | Settings › Siri › Responses › **Prefer Spoken**. A muted iPhone answers silently when you start Siri with the button. |
| **This Mac path: "Delete the old … first" or a copy named "… 1"** | Siri needs the exact name. Delete the old Shortcut (or the copies) in the Shortcuts app, then click **Add to Shortcuts** again. |
| **This Mac path: not on the iPhone** | Both need the same Apple Account and iCloud Sync on: on the Mac in Shortcuts › Settings, on the iPhone in Settings › Apps › Shortcuts *(unverified)*. Or choose **Send it to your iPhone instead**. |
| **"… is busy" / "… is still answering"** | The bot is working on something else. Ask again in a moment. |
| **"… didn't reply in time"** | Your question may still have arrived. Check the Grok Bot app instead of asking again. |
| **"… can't confirm it answers this question"** | Something else happened in that conversation at the same time, so Homebot stayed silent rather than risk reading out the wrong message. |
| **"This shortcut no longer works"** | It was replaced or revoked, or its bot was removed. Make a new one. |
| **Making the Shortcut fails while signing** | Apple's signing service is sometimes down for a while. Try again later; your existing Shortcut keeps working. |

## Set up with your AI agent

An AI agent that can run commands on your Mac (for example Claude Code or Codex) can guide you. It downloads the app and checks the result; **you** do the clicks that need you. Copy this prompt into it:

````text
Please help me install and set up Homebot on this Mac. Homebot is a free Mac app that lets Siri
on my iPhone and HomePod ask my Grok Bot. Setup is clicking in Homebot's window.
Repository: https://github.com/lumpinif/Homebot.
Guide me one step at a time, in my language, in short messages. After each step marked ME,
tell me exactly what to click and wait until I say it worked.

Rules for you, the agent:
- Never ask for, read, type, store or repeat my Cursor API key or any Shortcut token. I paste the
  key into Homebot's window myself. If I paste it to you by mistake, tell me to revoke that key
  in my Cursor dashboard, make a new one and paste the new one into Homebot.
- Never change macOS security or privacy settings. I click "Open Anyway" myself.
- Don't click "Sign with Apple and make" for me, and don't create, remove or revoke bots or Shortcuts,
  or import my old setup, without asking me first.
- Don't open port 8787 to the internet or change my router.
- Homebot is a first release, checked on one person's devices. Don't promise every step works.

Steps:
1. YOU: download https://homebot.fun/download/latest?from=agent (the newest
   Homebot-<version>.zip; if that link doesn't work, take the newest zip from
   https://github.com/lumpinif/Homebot/releases), unzip it and move Homebot.app to /Applications
   (ask before replacing an older copy).
2. ME: open Homebot. macOS says "Homebot.app" Not Opened: I click Done, then System Settings ›
   Privacy & Security › Open Anyway. Picture guide: docs/INSTALL.md in the repository.
3. ME, Account: if Homebot found a Grok Bot login, skip. Otherwise I paste a key from my
   Cursor dashboard into Homebot's Account step and click Save.
4. ME, Bot: I type my bot's exact name twice and click Add.
5. ME, Shortcut: pick the bot, the Siri language (my HomePod's), the phrase (English default
   "Grok Bot"), click Sign with Apple and make (iOS adds only signed Shortcuts; it sends the
   Shortcut to Apple).
6. ME, Install: "Does your iPhone use the same Apple Account as this Mac?"
   Yes: Add to Shortcuts, then Add Shortcut in the window that opens; then Try it, Always Allow,
   type a question.
   No: scan the QR code with the iPhone or AirDrop the file, tap Add Shortcut, then tap the
   Shortcut once in the Shortcuts app and ask something.
   One answer finishes setup. Then try "Hey Siri, <phrase>" on the iPhone; HomePod can take up to
   a day to learn a new phrase.
7. ME: in Homebot's Settings, turn on Open at login and leave Keep this Mac awake for Siri on.
8. YOU, diagnostic checks with Homebot open (they change no settings; doctor refreshes
   Homebot's own sync position for each bot):
   HB=/Applications/Homebot.app/Contents/Helpers/homebot
   "$HB" status ; "$HB" doctor
   Tell me the result in plain words. Don't paste question or answer text anywhere else.
````

The tool is `Homebot.app/Contents/Helpers/homebot`; `homebot --help` lists every command. It works on the same files as the app, so the window shows the same state.

## For developers

Native app (`mac/`, Swift 6, SwiftPM, no Xcode project):

```sh
cd mac
swift test                           # every test target (core, gateway/CLI, UI); prints one summary line per target
DEBUG=1 scripts/build-app.sh         # build/Homebot.app for this Mac
scripts/dev-app.sh --dev-seed bot    # dev mode: temporary folder, fake Grok Bot, fake signer, port 18787
scripts/release.sh                   # build/Homebot-<version>.zip + manifest (version in mac/VERSION)
```

Design and decisions: [docs/DESIGN.md](docs/DESIGN.md) §20, [docs/DECISIONS.md](docs/DECISIONS.md). Porting notes: [mac/PORTING.md](mac/PORTING.md).

### TypeScript reference implementation

The earlier version (`bin/`, `src/`, `web/`, `test/`) stays in the repository as the reference the Swift port is checked against, until the native app has passed its device test. It needs Node.js 24.12+ and runs from Terminal (`node bin/homebot.ts start`, setup page on http://127.0.0.1:8788/). `npm test` runs its offline suite. It is not the way to install Homebot any more.

## License

[MIT](LICENSE). Code adapted from other projects is listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
