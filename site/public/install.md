# Install Homebot: a guide for an AI agent

You are helping a person install Homebot on their Mac. They may never have heard of it and may not be technical. Guide them one step at a time, in their language, in short friendly messages. After each step, wait until they say it worked before you go on.

**What Homebot is.** A free Mac app. The person asks Siri on their HomePod or iPhone, Homebot passes the question to their own Grok Bot, and Siri reads the answer aloud. Setup happens by clicking in Homebot's window. No Terminal.

**What they need.**

- A Mac with macOS 15 or later that stays on and awake at home, on the same Wi-Fi as their iPhone.
- An iPhone with Siri on. A HomePod is optional.
- A Grok Bot they already use (Cursor's Grok Bot).

## Rules for you

- **Never ask for, read, type, store or repeat their Cursor API key.** They paste it into Homebot's window themselves. If they paste it to you by mistake, tell them to revoke that key in their Cursor dashboard themselves, make a new one and paste the new one into Homebot.
- **Never change macOS security or privacy settings.** They click "Open Anyway" themselves.
- **Don't click "Sign with Apple and make" for them.** It sends the Shortcut file, which carries its token, to Apple. Explain it, and let them click.
- Don't open port 8787 to the internet or change their router.
- Steps marked **YOU (the person)** are for the person. Tell them exactly what to click, then wait.
- If you can run commands on their Mac, you may run the read-only checks in "Checks". Otherwise just guide.

## Steps

### 1. Download

Download https://homebot.fun/download/latest?from=agent (the newest `Homebot-<version>.zip`). If that link doesn't work, take the newest zip from https://github.com/lumpinif/Homebot/releases instead. Open the zip and drag **Homebot** into **Applications**.

If neither has a Homebot zip yet, stop and tell them the first release isn't out yet.

You may do this step for them if you can. Ask before you replace an older copy.

### 2. First open: YOU (the person)

Homebot isn't notarized by Apple, so macOS blocks it the first time.

1. Open **Homebot** from Applications. macOS says **"Homebot.app" Not Opened**. Click **Done**.
2. Open **System Settings › Privacy & Security**, scroll down, and click **Open Anyway**. Enter the Mac password if asked.
3. Homebot opens. macOS asks again after every update.

Picture guide: https://github.com/lumpinif/Homebot/blob/main/docs/INSTALL.md

### 3. Account: YOU (the person)

If Grok Bot is already signed in on this Mac, Homebot uses that login, so skip ahead.

Otherwise, the person opens their Cursor dashboard, makes an API key, copies it and pastes it into Homebot's **Account** step, then clicks **Save**. (The exact dashboard menu names, and whether a brand-new account's key can use Grok Bot, are not checked yet.) Homebot keeps the key in a private file on this Mac and never shows it again. The Home page says whether Grok Bot accepted it.

### 4. Bot: YOU (the person)

In the **Bot** step they type their bot's **exact name** twice and click **Add**. Grok Bot can't list bots, so they add them one by one. A typo would make Grok Bot create a new, empty bot. Homebot notices and doesn't add it.

### 5. Shortcut: YOU (the person)

In the **Shortcut** step:

- Pick a bot, or **All my bots**: one phrase, and Siri asks which bot (not yet tried on a HomePod).
- Pick the language their **HomePod's Siri** speaks (Home app › HomePod › Settings › Language).
- Check the phrase Siri will listen for. The default is "Grok Bot" in every Siri language.
- iPhones and Macs only add signed Shortcuts. **Sign with Apple and make** sends the Shortcut file, which carries its token, to Apple's signing service. They click it themselves, only if they agree.

### 6. Install: YOU (the person)

The **Install** step asks whether their iPhone uses the same Apple Account as this Mac.

- **Yes (This Mac):** click **Add to Shortcuts** and confirm in the Shortcuts window, then **Ask it once on this Mac**. iCloud brings the Shortcut to the iPhone if Shortcuts sync in iCloud is on.
- **No (iPhone):** scan the QR code with the iPhone camera (it works once, for 10 minutes, on the same Wi-Fi), or AirDrop the file. Tap **Add Shortcut**.

### 7. Ask once, then talk: YOU (the person)

1. **Ask it once.** On this Mac (This Mac path), or on the iPhone: open the Shortcuts app and **tap the new Shortcut once**. Allow it to connect to the Mac (and to the local network, if asked). Ask a question. When the answer comes back, setup is done.
2. Then try the voice: **"Hey Siri, Grok Bot"** (or their phrase). Try the iPhone first. A new phrase can take from a few minutes up to a day to work on HomePod.
3. On Homebot's Home page, turn on **Open at login** and leave **Keep this Mac awake for Siri** on.

For HomePod: in the Home app turn on **Recognize My Voice** and **Personal Content** (called **Personal Requests** before iOS 26) for their user. Siri must be on in iCloud on the iPhone.

## Checks (only if you can run commands on the Mac)

These only read. With Homebot open:

```sh
HB=/Applications/Homebot.app/Contents/Helpers/homebot
"$HB" status
"$HB" doctor
```

Tell them the result in plain words. Don't paste question or answer text anywhere else.

## If something goes wrong

| What happens | What to tell them |
|---|---|
| "Homebot.app" Not Opened, no Open button | Expected the first time. Click Done, then System Settings › Privacy & Security › Open Anyway. |
| Siri doesn't recognize the phrase | Tap the Shortcut in the Shortcuts app; that always works. HomePod can take up to a day to learn a new phrase. |
| "Couldn't connect" or a long silence | First check that Homebot is running and the Mac is awake; Homebot's Home page shows both. If the Mac's `.local` name doesn't work on their network, see the troubleshooting link below. |
| The iPhone shows the answer but doesn't read it | Settings › Siri › Responses › Prefer Spoken. |

More help: https://github.com/lumpinif/Homebot#troubleshooting
