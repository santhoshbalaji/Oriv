#!/bin/bash
# Headless app-hosted capture against an explicitly selected simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ORIV_IOS_SIMULATOR_ID:?Set ORIV_IOS_SIMULATOR_ID to an isolated iPhone simulator}"
: "${ORIV_IOS_DERIVED_DATA:?Set ORIV_IOS_DERIVED_DATA to an isolated build folder}"
: "${1:?Provide a new or empty capture output directory}"
mkdir -p "$1"
output=$(cd "$1" && pwd)
if [[ -n $(ls -A "$output") ]]; then
  echo "Choose a new or empty capture output directory." >&2
  exit 2
fi
export ORIV_BACKGROUND_UI=1
export TEST_RUNNER_ORIV_DESIGN_CAPTURE_DIR="$output"
xcrun simctl bootstatus "$ORIV_IOS_SIMULATOR_ID" -b
xcodebuild -project PersonalBrowser.xcodeproj -scheme OrivMobile \
  -configuration Debug -destination "platform=iOS Simulator,id=$ORIV_IOS_SIMULATOR_ID" \
  -derivedDataPath "$ORIV_IOS_DERIVED_DATA" CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO -collect-test-diagnostics never -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 360 -maximum-test-execution-time-allowance 360 \
  -only-testing:OrivMobileTests/DesignSystemCaptureTests \
  -resultBundlePath "$output/Captures.xcresult" test 2>&1 | tee "$output/native.log"
