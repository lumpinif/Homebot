#!/bin/sh
# Builds a release of Homebot.app (DESIGN §20.9 S5): the universal app from scripts/build-app.sh,
# ad-hoc signed inside out (the CLI first, then the bundle; never --deep), packed with
# `ditto -c -k --keepParent`, then checked from the zip as a user would get it.
#   scripts/release.sh   -> build/Homebot-<version>.zip and build/Homebot-<version>.txt
# The version is mac/VERSION, the build number the commit count of HEAD. A tree with changes
# under mac/ is refused (ALLOW_DIRTY=1 builds anyway and says so in the manifest). File times in
# the zip are set to the commit's time, so the same commit and toolchain give the same zip when
# the compiler output is the same (the manifest records the hashes to compare).
# Publishes nothing: GitHub releases are made by hand.
set -eu
cd "$(dirname "$0")/.."
version="$(tr -d ' \n' < VERSION)"
case "$version" in '' | *[!0-9.]*) echo "VERSION must look like 1.2.3, not '$version'" >&2; exit 1 ;; esac
commit="$(git rev-parse HEAD)"
number="$(git rev-list --count HEAD)"
dirty=no
if [ -n "$(git status --porcelain -- .)" ]; then
  [ "${ALLOW_DIRTY:-0}" = 1 ] || { echo "uncommitted changes under mac/; commit first (or ALLOW_DIRTY=1)" >&2; exit 1; }
  dirty=yes
fi

out=build/release
rm -rf "$out"
OUT="$out" scripts/build-app.sh "$version" "$number"
app="$out/Homebot.app"

# Same times for every file: the commit's, so a rebuild of this commit packs the same bytes.
stamp="$(date -r "$(git log -1 --format=%ct)" +%Y%m%d%H%M.%S)"
find "$app" -exec touch -h -t "$stamp" {} +

fail() { echo "release check failed: $*" >&2; exit 1; }
for bin in MacOS/Homebot Helpers/homebot; do
  archs="$(lipo -archs "$app/Contents/$bin")"
  [ "$archs" = "x86_64 arm64" ] || fail "$bin is '$archs', not universal"
  for a in x86_64 arm64; do
    minos="$(vtool -arch "$a" -show-build "$app/Contents/$bin" | awk '/minos/ { print $2; exit }')"
    [ "$minos" = 15.0 ] || fail "$bin ($a) has minos $minos"
  done
done
codesign --verify --strict --verbose=2 "$app/Contents/Helpers/homebot" 2>"$out/verify-cli.txt" || { cat "$out/verify-cli.txt" >&2; fail "CLI signature"; }
codesign --verify --deep --strict --verbose=2 "$app" 2>"$out/verify-app.txt" || { cat "$out/verify-app.txt" >&2; fail "app signature"; }
codesign -dvvv "$app" 2>"$out/sign-info.txt"
grep -q '^Signature=adhoc' "$out/sign-info.txt" || fail "the app is not ad-hoc signed"
# Gatekeeper's verdict: an ad-hoc, un-notarized app is expected to be rejected here; users get
# past it with Open Anyway (docs/INSTALL.md).
spctl --assess --type execute --verbose=4 "$app" >"$out/spctl.txt" 2>&1 || true

zip="build/Homebot-$version.zip"
rm -f "$zip"
# No extended attributes or resource forks: what a Mac adds locally (provenance and the like)
# stays out of the download; the signatures live in the bundle's files.
ditto -c -k --keepParent --norsrc --noextattr "$app" "$zip"

# Check the zip as a user gets it: unpacked into an empty folder, the signature still holds.
check="$(mktemp -d)"
ditto -x -k "$zip" "$check"
codesign --verify --deep --strict "$check/Homebot.app" 2>"$out/verify-unzipped.txt" || { cat "$out/verify-unzipped.txt" >&2; rm -rf "$check"; fail "the unpacked app's signature"; }
rm -rf "$check"

sha="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
manifest="build/Homebot-$version.txt"
{
  echo "Homebot $version (build $number)"
  echo "commit: $commit$( [ "$dirty" = yes ] && echo ' (with uncommitted changes)')"
  echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ) on macOS $(sw_vers -productVersion), $(xcrun swift --version 2>/dev/null | head -1)"
  echo "zip: $(basename "$zip"), $(stat -f %z "$zip") bytes"
  echo "sha256: $sha"
  echo "app binary sha256: $(shasum -a 256 "$app/Contents/MacOS/Homebot" | cut -d' ' -f1)"
  echo "cli binary sha256: $(shasum -a 256 "$app/Contents/Helpers/homebot" | cut -d' ' -f1)"
  echo "architectures: x86_64 arm64 (app and CLI), minos 15.0"
  echo "signature: ad-hoc, not notarized; signed inside out without --deep"
  grep -E '^(Identifier|Format|CDHash)=' "$out/sign-info.txt"
  echo "codesign --verify --deep --strict (app, CLI, unpacked zip): OK"
  echo "spctl --assess --type execute:"
  sed 's/^/  /' "$out/spctl.txt"
} >"$manifest"
cat "$manifest"
