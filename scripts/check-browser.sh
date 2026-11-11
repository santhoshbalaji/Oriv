#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export ORIV_BACKGROUND_UI="${ORIV_BACKGROUND_UI:-1}"
python3 scripts/check-public-safety.py
python3 scripts/check-browser-scope.py
python3 scripts/check-background-ui.py
python3 scripts/check-contrast.py
mkdir -p build
quality_output=$(mktemp -d "$PWD/build/browser-quality.XXXXXX")
quality_server=''
cleanup() {
  if [[ -n "$quality_server" ]]; then
    kill "$quality_server" 2>/dev/null || true
    wait "$quality_server" 2>/dev/null || true
  fi
}
trap cleanup EXIT

swift test --package-path Packages/BrowserKit 2>&1 | tee "$quality_output/shared.log"
swift scripts/generate-media-fixtures.swift build/media-fixtures > "$quality_output/media.log" 2>&1
python3 scripts/qa-server.py > "$quality_output/fixture.log" 2>&1 &
quality_server=$!
for attempt in {1..50}; do
  if ! kill -0 "$quality_server" 2>/dev/null; then cat "$quality_output/fixture.log"; exit 1; fi
  if grep -q 'Browser QA fixture at' "$quality_output/fixture.log"; then break; fi
  sleep 0.1
done
if ! grep -q 'Browser QA fixture at' "$quality_output/fixture.log"; then
  echo 'The local QA fixture did not start. Stop any existing fixture on port 8768 and retry.' >&2
  exit 1
fi
xcodebuild -project PersonalBrowser.xcodeproj -scheme PersonalBrowser \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/DevDerivedData \
  -resultBundlePath "$quality_output/BrowserTests.xcresult" test \
  2>&1 | tee "$quality_output/native.log"
codesign --verify --deep --strict build/DevDerivedData/Build/Products/Debug/Oriv-Dev.app
codesign -d --entitlements :- build/DevDerivedData/Build/Products/Debug/Oriv-Dev.app > "$quality_output/entitlements.plist" 2>/dev/null
python3 - "$quality_output/entitlements.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], 'rb') as source:
    entitlements = plistlib.load(source)
for required in ('com.apple.security.app-sandbox', 'com.apple.security.network.client',
                 'com.apple.security.files.user-selected.read-write', 'com.apple.security.print'):
    if entitlements.get(required) is not True:
        raise SystemExit(f'Missing required browser entitlement: {required}')
for key in entitlements:
    if 'icloud' in key or 'application-groups' in key or key in ('com.apple.security.network.server', 'com.apple.security.personal-information.calendars'):
        raise SystemExit(f'Retired capability remains in built app: {key}')
PY
git diff --check
printf 'Browser check artifacts: %s\n' "$quality_output"
echo 'Review skipped media tests and complete the manual release checklist before distribution.'
