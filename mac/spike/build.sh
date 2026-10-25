#!/bin/sh
# Builds the S0 spike as a universal, ad-hoc signed app and zips it like a release would.
#   ./build.sh <build-number>   -> build/HomebotSpike.app and build/HomebotSpike-<n>.zip
set -eu
cd "$(dirname "$0")"
n="${1:-1}"
swift build -c release --arch arm64 --arch x86_64
bin="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/HomebotSpike"
app="build/HomebotSpike.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/HomebotSpike"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>win.cloudman.homebot.spike</string>
  <key>CFBundleName</key><string>HomebotSpike</string>
  <key>CFBundleExecutable</key><string>HomebotSpike</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.$n</string>
  <key>CFBundleVersion</key><string>$n</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Homebot answers Siri requests from your iPhone and HomePod on this network.</string>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none "$app"
(cd build && rm -f "HomebotSpike-$n.zip" && ditto -c -k --keepParent HomebotSpike.app "HomebotSpike-$n.zip")
echo "built $app (build $n): $(lipo -archs "$app/Contents/MacOS/HomebotSpike")"
