# Deploying homebot.fun

One Worker, `homebot`, serves the whole host `homebot.fun`: the website (the built `site/`, as static assets) and the API.

## Rules

- **Account.** Deploy only to the account whose id is `account_id` in `wrangler.jsonc`, and its zone `homebot.fun`.
  - In the browser, check that every dashboard URL contains this account id before you act.
  - In the shell, `wrangler whoami` must list only this account.
- **No `wrangler login`.** Don't rely on any wrangler login already on the machine; it may belong to another account. Every wrangler command runs with:
  - `HOME` set to an empty temporary folder, so no existing login can be found;
  - `CLOUDFLARE_API_TOKEN` set to a token scoped to this one account (step 2);
  - `CLOUDFLARE_ACCOUNT_ID` set to the account id;
  - `WRANGLER_SEND_METRICS=false`.
- **No secrets in git, in chat or in logs.**
  - The API token lives only in a mode-0600 file in a temporary folder outside the repo.
  - `HMAC_SECRET` goes straight from a random generator into `wrangler secret put`.
  - Never print either one.

## What the Worker serves

| Path | What |
|---|---|
| everything else | The website: files from `site/dist`. A path that isn't a file gets `index.html`; the site picks its page from the `#hash`. |
| `/privacy`, `/install` | 301 to `/#privacy`, `/#install` (plain addresses for emails and links). |
| `/download/*` | Release zips from the private R2 bucket. `/download/latest?from=…` redirects to the newest zip. Counts one download per day, version, link (`from=`) and country. |
| `/api/v1/latest` | The app's daily update check. Counts checks per day only. |
| `/api/v1/ping` | Opt-in usage counts. Adds 1 to daily counters; never stores a ping. |
| `/api/v1/subscribe` | Email sign-up for product updates, with double opt-in. |
| `/confirm`, `/unsubscribe`, `/manage` | The pages the email links open. |
| Cron `0 3 * * *` | Clean-up: unconfirmed sign-ups after 7 days, throttle rows, and daily counters after about 13 months. |
| Cron `0 4 1 * *` | Last month's totals go to R2 `stats/YYYY-MM.json`, plus a line in the hash-chained `stats/ledger.txt`. |

Only the API paths run the Worker first (`assets.run_worker_first` in `wrangler.jsonc`). The site's files are served without running it.

Privacy settings that must stay as they are:
- `observability.enabled: false`: no Workers Logs and no traces. Check the dashboard after the deploy as well.
- No Logpush.
- `r2.dev` and public access stay off on the bucket.
- The code never reads `CF-Connecting-IP`. `test/privacy.test.ts` enforces this.

Limits to know about:
- The rate limit bindings count **per Cloudflare location**, not worldwide. The real backstops are elsewhere:
  - only released versions are counted;
  - every write is a small, fixed set of counter rows;
  - sign-up mail is capped per address and per day (`MAIL_DAILY_CAP`).

---

## The deploy, step by step

Write down what each step produced: ids and names, never secret values.

### 1. Plan (dashboard)
1. Open `https://dash.cloudflare.com/<account_id>/workers/plans`.
2. Upgrade the account to **Workers Paid**. Email Sending needs it.
3. Check that the zone `homebot.fun` is **Active**: `https://dash.cloudflare.com/<account_id>/homebot.fun`.
4. In **DNS › Records**, note any record already on `homebot.fun` or `www`. A Custom Domain can't be created on a hostname that already has a CNAME. If one is there, stop and report it.

### 2. Scoped API token (dashboard)
Create it at **My Profile › API Tokens › Create Token › Custom token**.

1. **Name:** `homebot-deploy-YYYYMMDD`.
2. **Account permissions**, using the names the form shows today:
   - Workers Scripts (or "Workers Admin"): Edit. Creating a new Worker needs this level.
   - D1: Edit.
   - Workers R2 Storage: Edit.
   - Account Settings: Read (for `wrangler whoami`).
3. **Zone permissions:** Workers Routes: Edit. This is what the Custom Domain needs.
4. **Account Resources:** include only this account.
5. **Zone Resources:** include only the zone `homebot.fun`.
6. **TTL:** today only, if the form offers an end date.

Copy the token straight into a file:

```bash
umask 077
T=$(mktemp -d)        # outside the repo; remember $T for this session
pbpaste > "$T/token"  # never echo it
pbcopy < /dev/null    # clear the clipboard
```

### 3. Shell for every wrangler command
Run these from `cloud/`:

```bash
export WR_HOME=$(mktemp -d)
export ACCOUNT_ID=$(sed -n 's/.*"account_id": *"\([0-9a-f]*\)".*/\1/p' wrangler.jsonc)
wr() { HOME="$WR_HOME" WRANGLER_SEND_METRICS=false CLOUDFLARE_ACCOUNT_ID="$ACCOUNT_ID" CLOUDFLARE_API_TOKEN="$(cat "$T/token")" npx wrangler "$@"; }
wr whoami   # must show only that account; if not, stop
```

### 4. D1
```bash
wr d1 create homebot                         # copy the database_id it prints
```
1. Put the `database_id` into `wrangler.jsonc`, replacing the placeholder of zeros, and commit that one line. A D1 id is not a secret.
2. Apply the migration:
   ```bash
   wr d1 migrations apply homebot --remote
   wr d1 execute homebot --remote --command "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
   ```
3. Check that it lists 8 tables plus `d1_migrations`:
   - `active_daily`
   - `active_version_os`
   - `downloads_country_daily`
   - `downloads_daily`
   - `mail_daily`
   - `signup_throttle`
   - `subscribers`
   - `update_checks_daily`

### 5. R2 and the release zip
1. Rebuild the zip from current `main`. The tree must be clean:
   ```bash
   (cd ../mac && scripts/release.sh)   # -> mac/build/Homebot-0.1.0.zip and mac/build/Homebot-0.1.0.txt (sha256)
   ```
2. Write `latest.json` in `$T`, with the sha256 from the `.txt` manifest:
   ```json
   {"version":"0.1.0","sha256":"<sha256 from the manifest>"}
   ```
3. Create the bucket and upload. The zip goes first, then `latest.json`:
   ```bash
   wr r2 bucket create homebot-releases
   wr r2 object put homebot-releases/releases/Homebot-0.1.0.zip --file ../mac/build/Homebot-0.1.0.zip --content-type application/zip --remote
   wr r2 object put homebot-releases/releases/latest.json --file "$T/latest.json" --content-type application/json --remote
   ```
4. In the dashboard (**R2 › homebot-releases › Settings**), check that **Public Development URL** is disabled and that there is no Custom Domain.

### 6. Email (dashboard)
1. **Email Routing** (Compute › Email Service › Email Routing):
   - Select **Onboard Domain** and choose `homebot.fun`. Accept the MX, SPF and DKIM records.
   - Destination address: the maintainer's inbox. Click the verification mail Cloudflare sends there.
   - Rules:
     - `privacy@homebot.fun` → that inbox;
     - `hello@homebot.fun` → that inbox.
2. **Email Sending** (Compute › Email Service › Email Sending):
   - Select **Onboard Domain** and choose `homebot.fun`. It adds the `cf-bounce` MX, SPF, DKIM and the `_dmarc` record.
   - Wait until the domain shows as verified.
   - The sender is `hello@homebot.fun` (`MAIL_FROM`).
3. Send no test mail except the one sign-up in step 9, to the maintainer's own address.

### 7. Secret, build and deploy
```bash
openssl rand -base64 48 | tr -d '\n' | wr secret put HMAC_SECRET   # never printed; never change it later
npm ci
npm run check            # builds site/, then wrangler deploy --dry-run
wr deploy                # uploads the Worker and site/dist, adds the Custom Domain homebot.fun and the two crons
```
1. If `wr secret put` refuses because the Worker doesn't exist yet, run `wr deploy` first, then the secret command, then `wr deploy` again.
2. Never change `HMAC_SECRET` later: changing it breaks every confirm, unsubscribe and manage link already sent.

### 8. After the deploy (dashboard)
1. **Workers & Pages › homebot › Settings**:
   - **Observability:** Workers Logs **off**, Traces **off**.
   - **Domains & Routes:** `homebot.fun` is a Custom Domain; `workers.dev` and Preview URLs are off.
   - **Trigger events:** two crons, `0 3 * * *` and `0 4 1 * *`.
2. Optional, a `www` redirect:
   - In **DNS**, add a proxied `AAAA` record: `www` → `100::`.
   - In **Rules › Redirect Rules**, use the template "Redirect from WWW to root" (`https://www.homebot.fun/*` → `https://homebot.fun/${1}`, 301).

### 9. Checks
These are read-only, except the one test sign-up.
1. `curl -sI https://homebot.fun/` returns `200` with `text/html`.
2. `curl -sI https://homebot.fun/privacy` returns `301`, `location: /#privacy`.
3. `curl -sI https://homebot.fun/llms.txt` returns `200` with `text/plain`.
4. `curl -sI "https://homebot.fun/download/latest?from=home"` returns `302`, `location: …/download/Homebot-0.1.0.zip?from=home`.
5. Download the zip once and compare its SHA-256 with the manifest.
6. `curl -s https://homebot.fun/api/v1/latest` returns the JSON with version `0.1.0`.
7. `curl -s -X POST https://homebot.fun/api/v1/ping -d '{}' -o /dev/null -w '%{http_code}'` returns `204`.
8. Check the counts in D1: `wr d1 execute homebot --remote --command "SELECT * FROM downloads_daily"` shows `n = 1` for `home`, and `active_daily` is empty.
9. The site in a browser: the home page, `#install` and `#privacy` all open, and "Download for Mac" points at `/download/latest?from=home`.
10. Email, end to end, with the maintainer's own address:
    1. Subscribe with `POST /api/v1/subscribe {"email":"…","lang":"en","source":"site"}`. It returns `202`.
    2. In that inbox, open "Confirm your Homebot emails" and press **Confirm**. The page says "You're subscribed".
    3. Open the manage link. The page shows the address and an Unsubscribe button.
    4. Press it. The page says "You're unsubscribed".
    5. In D1, `SELECT COUNT(*) FROM subscribers` returns 0.
    6. Send one mail to `privacy@homebot.fun` and check that it arrives in that inbox.

### 10. Close the token
1. In **API Tokens**, delete `homebot-deploy-…`. A later deploy creates a new one the same way.
2. Delete the temporary folders:
   ```bash
   rm -rf "$T" "$WR_HOME"
   ```
3. Report that the token was revoked.

## Every release afterwards
1. Build with `mac/scripts/release.sh`.
2. Upload `releases/Homebot-<new>.zip`.
3. Then overwrite `releases/latest.json`.
4. Old zips stay, so old links keep working.
5. A site change needs only `npm run check`, then `wr deploy` (with a fresh scoped token).
