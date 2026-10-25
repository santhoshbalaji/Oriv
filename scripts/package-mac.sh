#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Builds both supported Mac architectures. The default is a local ad-hoc release;
# Developer ID distribution requires an appropriate identity and notarization.
output="$PWD/build/releases"
derived="$PWD/build/ReleaseDerivedData"
mkdir -p "$output"
xcodebuild -project PersonalBrowser.xcodeproj -scheme PersonalBrowser \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build

app="$derived/Build/Products/Release/Oriv.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
stage=$(mktemp -d "$PWD/build/oriv-package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Oriv.app"
identity="${ORIV_SIGNING_IDENTITY:--}"
if [[ "$identity" == '-' ]]; then
  codesign --force --sign - --options runtime --timestamp=none \
    --entitlements Apps/macOS/PersonalBrowser.entitlements "$stage/Oriv.app"
  signing_note='This personal Release build is ad-hoc signed and is not notarized. It is intended for local use. A Developer ID certificate and Apple notarization are needed for normal public distribution.'
else
  codesign --force --sign "$identity" --options runtime --timestamp \
    --entitlements Apps/macOS/PersonalBrowser.entitlements "$stage/Oriv.app"
  signing_note='This app has been signed with the configured identity. Signing alone does not establish notarization. See the release verification report for notarization status.'
fi
codesign --verify --deep --strict --verbose=2 "$stage/Oriv.app"
architectures=$(lipo -archs "$stage/Oriv.app/Contents/MacOS/Oriv")
[[ " $architectures " == *' arm64 '* && " $architectures " == *' x86_64 '* ]]
ln -s /Applications "$stage/Applications"
cat > "$stage/Read Me.txt" <<EOF
Oriv $version

Requires macOS 26 or newer. Supports Apple silicon and Intel Macs.
Drag Oriv into Applications, then open it from Applications.

$signing_note

The existing Personal Browser bundle identifier and session location are retained
so your saved tabs, bookmarks and WebKit website data remain available.

WebKit updates arrive through macOS and Safari updates. Provider-specific DRM,
AirPlay receiver support and iPhone use require separate verification.
EOF
dmg="$output/Oriv-$version-macOS.dmg"
hdiutil create -volname "Oriv $version" -srcfolder "$stage" -ov -format UDZO "$dmg"
hdiutil verify "$dmg"
shasum -a 256 "$dmg" > "$dmg.sha256"
echo "Release disk image: $dmg"
