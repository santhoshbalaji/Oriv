#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export ORIV_BACKGROUND_UI=1
export TEST_RUNNER_CI="${CI:-false}"
export TEST_RUNNER_GITHUB_ACTIONS="${GITHUB_ACTIONS:-false}"
# xcodebuild strips the prefix when forwarding this value to the test host.
export TEST_RUNNER_ORIV_CI_TIMEOUT_SCALE="${ORIV_CI_TIMEOUT_SCALE:-1}"

mkdir -p build
output=$(mktemp -d "$PWD/build/iphone-quality.XXXXXX")
simulator="${ORIV_IOS_SIMULATOR_ID:-}"
owns_simulator=0
source scripts/browser-fixtures.sh
cleanup() {
  stop_browser_fixtures
  if [[ "$owns_simulator" == 1 ]]; then
    xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator"
  fi
}
trap cleanup EXIT

{ sw_vers; xcodebuild -version; } | tee "$output/toolchain.log"
if [[ -z "$simulator" ]]; then
  runtime=$(xcrun simctl list -j runtimes available | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"]
            if r["isAvailable"] and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
            and int(r["version"].split(".")[0]) >= 26]
if not runtimes:
    sys.exit("No supported iOS Simulator runtime is installed")
print(max(runtimes, key=lambda r: tuple(map(int, r["version"].split("."))))["identifier"])
')
  simulator=$(xcrun simctl create 'Oriv CI iPhone' com.apple.CoreSimulator.SimDeviceType.iPhone-17 "$runtime")
  owns_simulator=1
  printf 'iPhone 17 runtime %s\n' "$runtime" | tee -a "$output/toolchain.log"
fi
xcrun simctl bootstatus "$simulator" -b 2>&1 | tee "$output/boot.log"
start_browser_fixtures "$output"

# Browser integration, model tests and functional UIKit cases that do not
# require frame-timing or gesture/rendering acceptance.
suites=(
  BrowserEngineeringTests
  BrowserExperienceTests
  ContinuityIntegrationTests
  DataNavigationTests
  PrivacyIntegrationTests
  SiteIconAndSuggestionTests
  WebPlatformTests
  MobileSuggestionTests
  TabGestureTests
  MobileGestureIntegrationTests/testNativeRefreshEndsOnFinishFailureCancelAndShortPagesBounce
  MobileGestureIntegrationTests/testRefreshInsetsRemainStableDuringSwiftUIUpdates
  MobileGestureIntegrationTests/testImageTransferUsesWebKitAndReturnsOriginalPNGBytes
  MobileGestureIntegrationTests/testGridAccessibilityMoveActionChangesOrderWithinItsSection
  MobileGestureIntegrationTests/testMovingLastExternalPrivateTabDisposesGroupAndPreservesPrivacy
  MobileGestureIntegrationTests/testNativeFindSessionPrefillsAndEndsWhenTabChanges
  MobileGestureIntegrationTests/testImageContextTrackingAndOwnedLinkMenuHasApprovedCommands
  MobileGestureIntegrationTests/testNormalEditedCloseIsImmediateAndRecoverableButPrivateAndBulkRequireConfirmation
  MobileGestureIntegrationTests/testInactiveProfileSuppressesExternalPromptAndDownload
  MobileGestureIntegrationTests/testArchivingInactiveProfileRefusesUnfinishedWorkAndReleasesController
  MobileGestureIntegrationTests/testSwitchTrimsInactiveProfileToSelectedPage
  MobileGestureIntegrationTests/testExternalPrivateInheritsPreferencesAtCreationAndCanDeleteInactiveProfile
  MobileGestureIntegrationTests/testDeleteProfileConfirmationCapture
)
if [[ "${ORIV_GRID_TIMING_ONLY:-0}" == 1 ]]; then
  suites=(GridMorphTests/testMeasureThirtyTabsWithPrivateSelection GridMorphTests/testPrivateGridOpeningMatrix)
fi
selection=()
for suite in "${suites[@]}"; do selection+=("-only-testing:OrivMobileTests/$suite"); done

xcodebuild -project PersonalBrowser.xcodeproj -scheme OrivMobile \
  -configuration Debug -destination "platform=iOS Simulator,id=$simulator" \
  -derivedDataPath "${ORIV_IOS_DERIVED_DATA:-build/iphone-quality-derived}" CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO -collect-test-diagnostics never -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 180 \
  -resultBundlePath "$output/OrivMobileTests.xcresult" "${selection[@]}" test 2>&1 | tee "$output/native.log"
printf 'iPhone test artifacts: %s\n' "$output"
