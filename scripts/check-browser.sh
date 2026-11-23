#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export ORIV_BACKGROUND_UI="${ORIV_BACKGROUND_UI:-1}"
# xcodebuild strips TEST_RUNNER_ when forwarding variables to the test host.
export TEST_RUNNER_CI="${CI:-false}"
export TEST_RUNNER_GITHUB_ACTIONS="${GITHUB_ACTIONS:-false}"
python3 scripts/check-public-safety.py
python3 scripts/check-browser-scope.py
python3 scripts/check-password-fields.py
python3 scripts/check-background-ui.py
python3 scripts/check-contrast.py
mkdir -p build
quality_output=$(mktemp -d "$PWD/build/browser-quality.XXXXXX")
{ sw_vers; xcodebuild -version; } | tee "$quality_output/toolchain.log"
source scripts/browser-fixtures.sh
trap stop_browser_fixtures EXIT

# Compile the iPhone app without booting a simulator or requiring signing.
xcodebuild -project PersonalBrowser.xcodeproj -scheme OrivMobile \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/mobile CODE_SIGNING_ALLOWED=NO build \
  2>&1 | tee "$quality_output/mobile.log"
swift test --package-path Packages/BrowserKit 2>&1 | tee "$quality_output/shared.log"
start_browser_fixtures "$quality_output"
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
