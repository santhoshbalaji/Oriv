#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
app="$PWD/build/bench/derived/Build/Products/Release/Oriv-Bench.app"
mkdir -p build/bench
xcodebuild -project PersonalBrowser.xcodeproj -scheme PersonalBrowser \
  -configuration Release -destination 'platform=macOS' -derivedDataPath build/bench/derived \
  ORIV_APP_NAME=Oriv-Bench PRODUCT_BUNDLE_IDENTIFIER=local.personalbrowser.bench \
  'OTHER_SWIFT_FLAGS=$(inherited) -D ORIV_BENCH' build \
  > build/bench/build.log 2>&1 || { tail -80 build/bench/build.log >&2; exit 1; }
[[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist") == local.personalbrowser.bench ]]
codesign --verify --deep --strict "$app"
entitlements=$(codesign -d --entitlements :- "$app" 2>/dev/null)
printf '%s' "$entitlements" | python3 -c 'import plistlib, sys; sys.exit(plistlib.loads(sys.stdin.buffer.read()).get("com.apple.security.app-sandbox") is not True)'
printf '%s\n' "$app"
