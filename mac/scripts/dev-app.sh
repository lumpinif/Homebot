#!/bin/bash
# Runs build/Homebot.app in dev mode against the fake Grok Bot (scripts/fake-grokbot.ts): a
# temporary support folder, port 18787, a fake signer, never a real account or bot. Extra
# arguments go to the app (e.g. --dev-seed bot --dev-lang de --dev-page shortcut).
# Usage: scripts/dev-app.sh [app args…]   (build first: DEBUG=1 scripts/build-app.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
app=build/Homebot.app/Contents/MacOS/Homebot
[ -x "$app" ] || { echo "build first: DEBUG=1 scripts/build-app.sh" >&2; exit 1; }
log=$(mktemp -t homebot-fake)
node ../scripts/fake-grokbot.ts >"$log" 2>&1 &
fake=$!
trap 'kill $fake 2>/dev/null || true; rm -f "$log"' EXIT
for _ in $(seq 50); do grep -q "fake Grok Bot API" "$log" && break; sleep 0.1; done
url=$(sed -n 's/^fake Grok Bot API: \([^ ]*\).*/\1/p' "$log")
[ -n "$url" ] || { cat "$log" >&2; exit 1; }
echo "fake Grok Bot: $url"
# Through Launch Services (a new instance, waiting for it to quit), so the app gets its windows
# even when this script runs from a background shell.
open -n -W build/Homebot.app --args --dev --bdk-base-url "$url" "$@"
