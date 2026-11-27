#!/bin/bash
# Archives the iPhone app (OrivReleaseMobile, ContinuityRelease) and uploads it to
# App Store Connect for TestFlight.
#
# usage: ORIV_DEVELOPMENT_TEAM=<team> ORIV_ASC_ISSUER_ID=<issuer> scripts/release-iphone.sh
#
# Needs, on the release Mac:
#   - the app record for com.santhoshbalaji.oriv.ios in App Store Connect;
#   - an App Store Connect API key at $HOME/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
#     (ORIV_ASC_KEY_ID picks one when there are several).
# Each upload needs a CURRENT_PROJECT_VERSION higher than any build already uploaded.
# The team, key and issuer are read from the environment and never printed.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${ORIV_DEVELOPMENT_TEAM:?Set ORIV_DEVELOPMENT_TEAM to the team}"
: "${ORIV_ASC_ISSUER_ID:?Set ORIV_ASC_ISSUER_ID to the App Store Connect issuer ID}"
keys="$HOME/.appstoreconnect/private_keys"
if [[ -z "${ORIV_ASC_KEY_ID:-}" ]]; then
  candidates=("$keys"/AuthKey_*.p8)
  [[ ${#candidates[@]} -eq 1 && -f "${candidates[0]}" ]] || { echo "Set ORIV_ASC_KEY_ID; found ${#candidates[@]} keys." >&2; exit 1; }
  ORIV_ASC_KEY_ID=$(basename "${candidates[0]}" .p8); ORIV_ASC_KEY_ID=${ORIV_ASC_KEY_ID#AuthKey_}
fi
key="$keys/AuthKey_$ORIV_ASC_KEY_ID.p8"
[[ -f "$key" ]] || { echo "No API key file for that key ID." >&2; exit 1; }

version=$(awk '/MARKETING_VERSION:/ {print $2; exit}' project.yml)
build=$(awk -F"'" '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)
out="build/release-iphone/$version-$build"
[[ ! -e "$out" ]] || { echo "$out already exists. Remove it, or bump CURRENT_PROJECT_VERSION." >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first; an upload must match a commit." >&2; exit 1; }
mkdir -p "$out"
auth=(-allowProvisioningUpdates -authenticationKeyPath "$key" -authenticationKeyID "$ORIV_ASC_KEY_ID"
      -authenticationKeyIssuerID "$ORIV_ASC_ISSUER_ID")
log() { printf '\n== %s\n' "$*"; }

log "Archive iPhone $version ($build)"
xcodebuild -project PersonalBrowser.xcodeproj -scheme OrivReleaseMobile -configuration ContinuityRelease \
  -destination 'generic/platform=iOS' -derivedDataPath build/iPhoneReleaseDerivedData \
  -archivePath "$out/Oriv.xcarchive" DEVELOPMENT_TEAM="$ORIV_DEVELOPMENT_TEAM" "${auth[@]}" \
  archive > "$out/archive.log" 2>&1 || { tail -30 "$out/archive.log"; exit 1; }

log "Check the archive"
app=$(ls -d "$out"/Oriv.xcarchive/Products/Applications/*.app)
info="$app/Info.plist"
[[ "$(plutil -extract CFBundleIdentifier raw "$info")" == "com.santhoshbalaji.oriv.ios" ]] || { echo "Unexpected bundle ID." >&2; exit 1; }
[[ "$(plutil -extract CFBundleVersion raw "$info")" == "$build" ]] || { echo "Built version doesn't match project.yml." >&2; exit 1; }
[[ "$(plutil -extract UIDeviceFamily json -o - "$info")" == "[1]" ]] || { echo "The app isn't iPhone-only." >&2; exit 1; }
[[ -f "$app/PrivacyInfo.xcprivacy" ]] || { echo "The privacy manifest is missing." >&2; exit 1; }
for forbidden in NSPhotoLibraryUsageDescription NSLocationAlwaysUsageDescription NSLocationAlwaysAndWhenInUseUsageDescription \
                 NSHomeKitUsageDescription NSBluetoothAlwaysUsageDescription NSHealthShareUsageDescription NSHealthUpdateUsageDescription; do
  if plutil -extract "$forbidden" raw "$info" >/dev/null 2>&1; then
    echo "$forbidden is set; Apple rejects it in default-browser apps." >&2; exit 1
  fi
done

log "Upload to App Store Connect"
options="$out/ExportOptions.plist"
cat > "$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
  <key>iCloudContainerEnvironment</key><string>Production</string>
</dict>
</plist>
PLIST
plutil -insert teamID -string "$ORIV_DEVELOPMENT_TEAM" "$options"
xcodebuild -exportArchive -archivePath "$out/Oriv.xcarchive" -exportPath "$out/upload" \
  -exportOptionsPlist "$options" "${auth[@]}" > "$out/upload.log" 2>&1 || { tail -30 "$out/upload.log"; exit 1; }
rm "$options"
grep -q "Upload succeeded\|EXPORT SUCCEEDED" "$out/upload.log" || { tail -30 "$out/upload.log"; exit 1; }

echo
echo "Uploaded iPhone $version ($build). App Store Connect processes it in about 15 minutes, then it appears in TestFlight."
