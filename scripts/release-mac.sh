#!/bin/bash
# Builds the Developer ID public beta: archive, export, notarize, DMG, Sparkle signature.
#
# usage: ORIV_DEVELOPMENT_TEAM=<team> scripts/release-mac.sh [--publish]
#
# Needs, on the release Mac:
#   - a "Developer ID Application" certificate for ORIV_DEVELOPMENT_TEAM in the login keychain;
#   - a notarytool keychain profile, ORIV_NOTARY_PROFILE (default "oriv-notary"), made once with
#     `xcrun notarytool store-credentials oriv-notary --key <AuthKey.p8> --key-id <id> --issuer <issuer>`;
#   - Sparkle's EdDSA private key in the login keychain (created once with Sparkle's generate_keys).
#
# Without --publish it stops after verifying a signed, notarized, stapled DMG and writing the
# appcast item into site/appcast.xml. --publish also creates the GitHub prerelease and uploads
# the DMG. The appcast change still goes through a normal commit and PR to reach oriv.dev.
# The team ID is read from the environment and never printed or written to the repository.
set -euo pipefail
cd "$(dirname "$0")/.."

publish=0
[[ "${1:-}" == "--publish" ]] && publish=1
: "${ORIV_DEVELOPMENT_TEAM:?Set ORIV_DEVELOPMENT_TEAM to the Developer ID team}"
profile="${ORIV_NOTARY_PROFILE:-oriv-notary}"

version=$(awk '/MARKETING_VERSION:/ {print $2; exit}' project.yml)
build=$(awk -F"'" '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)
[[ -n "$version" && -n "$build" ]] || { echo "Couldn't read the version from project.yml" >&2; exit 1; }
tag="v$version"
out="build/release/$version"
derived="build/ReleaseDerivedData"
[[ ! -e "$out" ]] || { echo "$out already exists. Remove it, or bump the version." >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "Tag $tag already exists. Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION first." >&2; exit 1
fi
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first; a release must match a commit." >&2; exit 1; }
mkdir -p "$out"
log() { printf '\n== %s\n' "$*"; }

identity=$(security find-identity -v -p codesigning | awk -v team="($ORIV_DEVELOPMENT_TEAM)" '/"Developer ID Application:/ && index($0, team) {print $2; exit}')
[[ -n "$identity" ]] || { echo "No Developer ID Application certificate for this team in the keychain." >&2; exit 1; }

log "Archive $version ($build)"
xcodebuild -project PersonalBrowser.xcodeproj -scheme OrivReleaseMac -configuration ContinuityRelease \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived" -archivePath "$out/Oriv.xcarchive" \
  DEVELOPMENT_TEAM="$ORIV_DEVELOPMENT_TEAM" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO -allowProvisioningUpdates \
  archive > "$out/archive.log" 2>&1 || { tail -30 "$out/archive.log"; exit 1; }

log "Export with Developer ID"
options="$out/ExportOptions.plist"
cp Config/Distribution/MacDeveloperID.plist "$options"
plutil -replace teamID -string "$ORIV_DEVELOPMENT_TEAM" "$options"
xcodebuild -exportArchive -archivePath "$out/Oriv.xcarchive" -exportPath "$out/export" \
  -exportOptionsPlist "$options" -allowProvisioningUpdates > "$out/export.log" 2>&1 || { tail -30 "$out/export.log"; exit 1; }
rm "$options"
app="$out/export/Oriv.app"

log "Verify signature, entitlements and update feed"
codesign --verify --deep --strict "$app"
# Only -dvv lists the certificate chain. Capture first: with pipefail, grep -q
# closing the pipe early would make codesign's exit status fail the check.
signing=$(codesign -dvv "$app" 2>&1)
grep -q '^Authority=Developer ID Application' <<<"$signing" || { echo "Not signed with Developer ID." >&2; exit 1; }
grep -q 'flags=.*runtime' <<<"$signing" || { echo "Hardened runtime is off." >&2; exit 1; }
codesign -d --entitlements :- "$app" > "$out/entitlements.plist" 2>/dev/null
python3 -I - "$out/entitlements.plist" <<'PY'
import plistlib, sys
entitlements = plistlib.load(open(sys.argv[1], 'rb'))
problems = []
if entitlements.get('com.apple.security.app-sandbox') is not True: problems.append('App Sandbox is off')
if entitlements.get('com.apple.security.get-task-allow'): problems.append('get-task-allow is on (debug signing)')
if entitlements.get('com.apple.developer.icloud-container-environment') != 'Production': problems.append('iCloud is not Production')
if problems: raise SystemExit('Entitlements: ' + '; '.join(problems))
PY
[[ "$(plutil -extract SUFeedURL raw "$app/Contents/Info.plist")" == "https://oriv.dev/appcast.xml" ]] \
  || { echo "The update feed URL is missing." >&2; exit 1; }
[[ "$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")" == "$build" ]] \
  || { echo "The built CFBundleVersion doesn't match project.yml." >&2; exit 1; }
archs=$(lipo -archs "$app/Contents/MacOS/Oriv")
[[ " $archs " == *" x86_64 "* && " $archs " == *" arm64 "* ]] || { echo "The app isn't universal." >&2; exit 1; }

notarize() {
  local file="$1" result
  result=$(xcrun notarytool submit "$file" --keychain-profile "$profile" --wait --output-format json)
  if [[ "$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$result")" != "Accepted" ]]; then
    local id; id=$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$result")
    xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
    echo "Notarization was not accepted for $file." >&2; exit 1
  fi
}

log "Notarize the app"
ditto -c -k --keepParent "$app" "$out/Oriv.zip"
notarize "$out/Oriv.zip"
xcrun stapler staple "$app"
rm "$out/Oriv.zip"
spctl --assess --type execute "$app"

log "Build, sign and notarize the DMG"
stage=$(mktemp -d "$PWD/build/oriv-dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Oriv.app"
ln -s /Applications "$stage/Applications"
dmg="$out/Oriv-$version-macOS.dmg"
hdiutil create -volname "Oriv $version" -srcfolder "$stage" -format UDZO "$dmg" >/dev/null
codesign --sign "$identity" --timestamp "$dmg"
notarize "$dmg"
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature "$dmg"
shasum -a 256 "$dmg" | sed "s#  .*#  $(basename "$dmg")#" > "$dmg.sha256"

log "Sign the update for Sparkle"
signature=$("$derived/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" "$dmg")
python3 -I scripts/update-appcast.py --appcast site/appcast.xml --version "$version" --build "$build" \
  --url "https://github.com/santhoshbalaji/Oriv/releases/download/$tag/$(basename "$dmg")" \
  --notes "https://github.com/santhoshbalaji/Oriv/releases/tag/$tag" --signature "$signature"

echo
echo "Ready: $dmg"
echo "       site/appcast.xml now lists $version ($build)."
if [[ "$publish" == 1 ]]; then
  log "Publish GitHub prerelease $tag"
  notes=$(python3 -I scripts/update-appcast.py --changelog docs/releases/CHANGELOG.md --version "$version")
  git tag "$tag" && git push origin "$tag"
  gh release create "$tag" "$dmg" "$dmg.sha256" --prerelease --title "Oriv $version (public beta)" --notes "$notes"
  echo "Next: commit site/appcast.xml, set the oriv.dev download dialog to data-state=\"ready\", and merge."
else
  echo "Next: rerun with --publish, or create the $tag release by hand and upload the DMG."
fi
