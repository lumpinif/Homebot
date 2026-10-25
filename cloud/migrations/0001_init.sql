-- homebot.fun counters and email sign-ups.
-- Counters hold daily totals only: no IP address, no identifier, no raw ping is ever stored.

-- One row per (UTC day, version, link the download came from).
CREATE TABLE downloads_daily (
  day TEXT NOT NULL,
  version TEXT NOT NULL,
  channel TEXT NOT NULL,
  n INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, version, channel)
) WITHOUT ROWID;

-- Country from Cloudflare's request.cf.country ('ZZ' when unknown). Kept apart from version on purpose.
CREATE TABLE downloads_country_daily (
  day TEXT NOT NULL,
  country TEXT NOT NULL,
  n INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, country)
) WITHOUT ROWID;

-- The app's daily update check carries no data; only the number of checks per day is kept.
CREATE TABLE update_checks_daily (
  day TEXT PRIMARY KEY,
  n INTEGER NOT NULL DEFAULT 0
) WITHOUT ROWID;

-- Opt-in usage counts, one counter per (day, kind, dimension, value). Dimensions are never combined,
-- so a rare value can't be joined with others into a fingerprint.
--   kind: 'day' (every ping), 'week' (first ping of the ISO week), 'month' (first of the month),
--         'first' (first ping after the user turned counts on)
--   dim:  'all' (value '-'), 'app', 'build', 'os', 'arch', 'lang', 'use7d', 'country', 'cohort', 'age'
CREATE TABLE active_daily (
  day TEXT NOT NULL,
  kind TEXT NOT NULL,
  dim TEXT NOT NULL,
  value TEXT NOT NULL,
  n INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, kind, dim, value)
) WITHOUT ROWID;

-- The one fixed cross table: which macOS versions each app version runs on.
CREATE TABLE active_version_os (
  day TEXT NOT NULL,
  app TEXT NOT NULL,
  os TEXT NOT NULL,
  n INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, app, os)
) WITHOUT ROWID;

-- Email sign-ups for one list: Homebot product updates. A row is pending until confirmed_at is set;
-- pending rows are deleted after 7 days. Unsubscribing deletes the row. No IP address or user agent
-- is stored.
CREATE TABLE subscribers (
  id INTEGER PRIMARY KEY,
  pid TEXT NOT NULL UNIQUE,            -- random public id used in links (not the row id)
  email TEXT NOT NULL UNIQUE,          -- lower-cased, trimmed
  lang TEXT NOT NULL,
  source TEXT NOT NULL,                -- 'app' | 'site'
  consent_version TEXT NOT NULL,       -- id of the wording the person saw
  created_at TEXT NOT NULL,            -- ISO 8601 UTC; also starts the 48 h confirm window
  confirmed_at TEXT                    -- NULL until the confirm button is pressed
);
CREATE INDEX subscribers_pending ON subscribers (created_at) WHERE confirmed_at IS NULL;

-- Per-address mail throttle, keyed by HMAC(secret, address). Rows older than a day are deleted.
CREATE TABLE signup_throttle (
  addr_hash TEXT PRIMARY KEY,
  window_start TEXT NOT NULL,
  last_sent_at TEXT NOT NULL,
  sends INTEGER NOT NULL
) WITHOUT ROWID;

-- Sign-up mails sent per UTC day, for the global daily cap.
CREATE TABLE mail_daily (
  day TEXT PRIMARY KEY,
  n INTEGER NOT NULL DEFAULT 0
) WITHOUT ROWID;
