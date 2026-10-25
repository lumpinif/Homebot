#!/bin/sh
# Builds Homebot.app from the command line (DESIGN §20.2, S3): one universal binary (arm64 +
# x86_64, macOS 15+), ad-hoc signed, not notarized.
#   scripts/build-app.sh [version] [build-number]   -> build/Homebot.app (OUT=dir: dir/Homebot.app)
# The version defaults to mac/VERSION (the one place it is set; scripts/release.sh uses it too),
# the build number to the number of commits on HEAD.
# Contents: MacOS/Homebot (the app), Helpers/homebot (the CLI, same core; not in MacOS/, where it
# would be the same file as Homebot on a case-insensitive volume), the String Catalog
# compiled into <lang>.lproj, the bundle icon (App/AppIcon.icon, compiled by actool), the three
# icons of the manual choices drawn from the mark by the app itself, the Grok Bot icon.
# The CLI is signed before the bundle; no --deep (§20.11 S2). DEBUG=1 builds debug for this Mac only.
set -eu
cd "$(dirname "$0")/.."
version="${1:-$(tr -d ' \n' < VERSION)}"
number="${2:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
if [ "${DEBUG:-0}" = 1 ]; then
  set -- -c debug
else
  set -- -c release --arch arm64 --arch x86_64
fi
swift build "$@" --product HomebotApp
swift build "$@" --product homebot
bin="$(swift build "$@" --show-bin-path)"

mkdir -p "${OUT:-build}"
app="${OUT:-build}/Homebot.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$bin/HomebotApp" "$app/Contents/MacOS/Homebot"
# SwiftPM records the deployment target (15.0) as the SDK the app was built with. AppKit and
# SwiftUI read that number to choose the look: with 15.0 the window keeps the macOS 15 chrome
# (no Liquid Glass sidebar and toolbar on macOS 26). Record the SDK it was really built against,
# as Xcode does; the minimum system version stays 15.0.
sdk="$(xcrun --sdk macosx --show-sdk-version)"
xcrun vtool -set-build-version macos 15.0 "$sdk" -replace -output "$app/Contents/MacOS/Homebot" "$app/Contents/MacOS/Homebot" 2>/dev/null
# vtool drops the linker's ad-hoc signature; the icon step below runs this binary.
codesign --force --sign - --timestamp=none "$app/Contents/MacOS/Homebot"
cp "$bin/homebot" "$app/Contents/Helpers/homebot"
xcrun xcstringstool compile App/Localizable.xcstrings --output-directory "$app/Contents/Resources"
cp App/grok-bot.png "$app/Contents/Resources/grok-bot.png"

# The bundle icon: App/AppIcon.icon (Icon Composer format) compiled into Assets.car, White with a
# Black variant for the Dark icon style on macOS 26, plus AppIcon.icns (White) for macOS 15.
# Homebot.icns (Glow), Homebot-Black and Homebot-White are the choices in Settings, shown by the
# running app (AppIcon.swift).
iconplist="$(mktemp -d)"
xcrun actool "$PWD/App/AppIcon.icon" --compile "$app/Contents/Resources" --platform macosx \
  --minimum-deployment-target 15.0 --app-icon AppIcon --output-partial-info-plist "$iconplist/icon.plist" \
  --errors --warnings >/dev/null
[ -f "$app/Contents/Resources/Assets.car" ] && [ -f "$app/Contents/Resources/AppIcon.icns" ] || { echo "actool did not compile App/AppIcon.icon" >&2; exit 1; }
rm -rf "$iconplist"
icons="$(mktemp -d)"
"$app/Contents/MacOS/Homebot" --render-icon "$icons"
for set in "$icons"/*.iconset; do iconutil -c icns -o "$app/Contents/Resources/$(basename "$set" .iconset).icns" "$set"; done
rm -rf "$icons"

langs=""
for d in "$app"/Contents/Resources/*.lproj; do langs="$langs<string>$(basename "$d" .lproj)</string>"; done
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>win.cloudman.homebot</string>
  <key>CFBundleName</key><string>Homebot</string>
  <key>CFBundleDisplayName</key><string>Homebot</string>
  <key>CFBundleExecutable</key><string>Homebot</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$number</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>$langs</array>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSLocalNetworkUsageDescription</key><string>Homebot answers Siri requests from your iPhone and HomePod on this network.</string>
</dict></plist>
PLIST

codesign --force --sign - --timestamp=none "$app/Contents/Helpers/homebot"
codesign --force --sign - --timestamp=none "$app"
echo "built $app $version ($number): $(lipo -archs "$app/Contents/MacOS/Homebot")"
