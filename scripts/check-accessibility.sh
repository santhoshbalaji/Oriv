#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${ORIV_A11Y_AUDIT:-0}" != 1 ]]; then
  echo "Skipped. Set ORIV_A11Y_AUDIT=1 only after the owner approves foreground UI testing."
  exit 0
fi
case "${1:-}" in
  mac) scheme=OrivAccessibilityMac; destination=platform=macOS ;;
  iphone)
    : "${ORIV_IOS_SIMULATOR_ID:?Select an isolated iPhone simulator}"
    scheme=OrivAccessibilityMobile
    destination="platform=iOS Simulator,id=$ORIV_IOS_SIMULATOR_ID"
    ;;
  *) echo "Usage: ORIV_A11Y_AUDIT=1 $0 mac|iphone" >&2; exit 2 ;;
esac
mkdir -p build
output=$(mktemp -d "$PWD/build/accessibility.XXXXXX")
export TEST_RUNNER_ORIV_A11Y_AUDIT=1
xcodebuild -project PersonalBrowser.xcodeproj -scheme "$scheme" -configuration Debug   -destination "$destination" -derivedDataPath "$output/DerivedData"   -parallel-testing-enabled NO -resultBundlePath "$output/Accessibility.xcresult"   test 2>&1 | tee "$output/audit.log"
