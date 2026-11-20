# Oriv hosted iPhone WebKit flake

The edited-field test failed on the first draft navigation, before posting the edited-field bridge message. The first attempt of each baseline run reported the same timeout. The first main attempt logged failed RunningBoard assertions for a WebContent process that no longer existed, including a NearSuspended assertion, and the test stopped after 20.963 seconds. The main retry failed at the same line after 20.800 seconds. [Earlier failure](https://github.com/santhoshbalaji/Oriv/actions/runs/44551163264/attempts/1) · [Main attempt 1](https://github.com/santhoshbalaji/Oriv/actions/runs/44559157033/job/135683354366) · [Main attempt 2](https://github.com/santhoshbalaji/Oriv/actions/runs/44559157033/job/135692805078)

The fixture depended on the app's key window and inserted its WebView as a direct subview. A dedicated window and a document-ready wait still timed out on the HTTP draft fixture. Inline HTML also hit the 20-second limit on the hosted runner. In that run, WebContent first logged document activity about 20 seconds after the test began. RunningBoard assertion failures also appeared during passing tests. The evidence points to variable WebKit startup time on the hosted runner. The exact WebKit-side cause of the delay remains undetermined. [Window-only run](https://github.com/santhoshbalaji/Oriv/actions/runs/44562729127/job/135696119225) · [Inline fixture with a 20-second limit](https://github.com/santhoshbalaji/Oriv/actions/runs/44565465074/job/135706149485)

The edited-field fixture runs in a dedicated visible window rooted in the iOS test host's scene. The helper lays out the fixture before navigation, retains the window through the test and restores the previous key window during cleanup. The two inline documents exercise real WebKit navigations while removing the local HTTP dependency from this test. Each document waits for the existing document-ready callback for its URL and navigation revision. The first document has a 75-second startup allowance and proceeds as soon as the callback fires. A local run showed the browser title can update after that signal, so the fixture identity comes from the callback's URL and revision. The test still verifies the bridge message and edit reset.

The hosted selection review also covered history, data navigation, Web Platform, privacy, favicon and the selected UIKit integration cases. The fix reuses the host for the data-navigation entry point, Web Platform, edited-close and image-context fixtures. The history cases use their existing window attachment and keep their original assertions. The hosted selection and app source remain at the build 35 baseline.

## Verification

On `413675f`, three runs of `scripts/check-iphone.sh` on fresh local iPhone 17 simulators running iOS 26.5 with Xcode 27.0 each recorded 81 passes, three skips and zero failures. The edited-field test passed in 7.644, 6.320 and 8.972 seconds.

Three dispatches of the unmodified workflow verified `413675f` on `macos-26`, Xcode 26.6 and an iPhone 17 simulator running iOS 26.5. The edited-field test passed in all three jobs. All three Mac jobs passed. Each hosted iPhone job was red on a different existing test.

| Run | Edited-field test | iPhone job |
| --- | --- | --- |
| [A](https://github.com/santhoshbalaji/Oriv/actions/runs/44569542473/job/135721104223) | Pass, 25.705 s | Failed in the existing favicon restoration test |
| [B](https://github.com/santhoshbalaji/Oriv/actions/runs/44569542493/job/135721271838) | Pass, 32.689 s | Failed in the existing scoped cosmetics and frame exception test |
| [C](https://github.com/santhoshbalaji/Oriv/actions/runs/44569541699/job/135720785149) | Pass, 25.718 s | Failed in the existing HTTP error history test |

The temporary refs were deleted after verification. Remote `main` was still at `ac30efa`. Local simulator work ran headlessly with `ORIV_BACKGROUND_UI=1`.

## Stabilization

The hosted iPhone step sets `ORIV_CI_TIMEOUT_SCALE=3`. The test host scales positive WebKit deadlines from a minimum baseline of 20 seconds while using the normal deadlines outside that step. Condition waits return as soon as they succeed and log `ORIV_SLOW_WEB_WAIT` when a check passes beyond its unscaled allowance. The scale applies only to deadlines. The hosted selection and XCTest's per-test execution limits are the same.

The affected iPhone navigation fixtures use a visible window in the simulator's XCTest host. The favicon test detaches the original view before discarding it, mounts the restored view and checks that icon discovery resumes after the cover is removed. The privacy test waits for a fresh top-level navigation and the child-frame messages it needs for its existing assertions. The history test waits for the final redirect and the HTTP error document, then compares the actual visit paths. The loopback server sends an explicit content length for the 404 response.

The prior privacy and history failures were assertion failures. The failure logs show missing frame reports in one run and an extra history visit in another. The updated tests retain the frame and history assertions. The fix uses per-view deadlines and readiness signals because the earlier delays appeared at different points in the suite. Each test runs once on the existing runner class.

On a fresh local iPhone 17 simulator with iOS 26.5 and Xcode 27.0, the default deadline scale produced 81 passes, three skips and zero failures on `68b6660`. The XCTest suite took 63 seconds. An earlier scaled local run used the newest installed iOS 27.0 runtime. The affected WebKit tests passed there, with the draft readiness check taking 23.4 seconds. The save-debounce test failed on that run.

The same save-debounce test failed in the first hosted batch. Its background store and main-actor notification complete separately. The test now awaits the notification, checks one attempt and one write, then verifies the saved URL. A timestamp on the first write attempt preserves the original 150 ms lower bound even when the test scheduler stalls. The edited-field draft keeps its prior 75-second allowance on unscaled runs. [First-batch save-debounce failure](https://github.com/santhoshbalaji/Oriv/actions/runs/44658414036/job/136030283547)

### First hosted batch

Four iPhone jobs and all five Mac jobs passed on `68b6660`. All four previously identified WebKit cases passed in every run. Job durations use GitHub's job start and completion timestamps. XCTest durations cover the selected iPhone suite.

| Run | iPhone job | Mac job | iPhone XCTest |
| --- | --- | --- | --- |
| A | [Pass · 11m 04s](https://github.com/santhoshbalaji/Oriv/actions/runs/44658409703/job/136030269010) | [Pass · 10m 55s](https://github.com/santhoshbalaji/Oriv/actions/runs/44658409703/job/136030269393) | 94.0 s |
| B | [Pass · 11m 07s](https://github.com/santhoshbalaji/Oriv/actions/runs/44658414907/job/136030286343) | [Pass · 11m 07s](https://github.com/santhoshbalaji/Oriv/actions/runs/44658414907/job/136030286609) | 113.9 s |
| C | [Pass · 14m 39s](https://github.com/santhoshbalaji/Oriv/actions/runs/44658414626/job/136030285380) | [Pass · 10m 42s](https://github.com/santhoshbalaji/Oriv/actions/runs/44658414626/job/136030285397) | 161.8 s |
| D | [Pass · 10m 19s](https://github.com/santhoshbalaji/Oriv/actions/runs/44658413606/job/136030281163) | [Pass · 11m 03s](https://github.com/santhoshbalaji/Oriv/actions/runs/44658413606/job/136030281604) | 97.0 s |
| E | [Fail · 11m 07s](https://github.com/santhoshbalaji/Oriv/actions/runs/44658414036/job/136030283547) | [Pass · 10m 38s](https://github.com/santhoshbalaji/Oriv/actions/runs/44658414036/job/136030283200) | 107.1 s |

In runs C and E, the draft readiness wait in `testEditedFieldSignalRequiresConfirmationUntilNextDocument` exceeded 20 seconds and passed after 30.23 and 24.68 seconds respectively. The other waits finished within their unscaled limits.

On `e700b55`, a second fresh local iOS 26.5 simulator run at the default deadline scale passed 81 tests, skipped three and reported zero failures. The selected suite took 51.9 seconds and the save-debounce test passed in 0.43 seconds.

### Final hosted verification

Five separate workflow dispatches ran `e700b55` on `macos-26`, Xcode 26.6 and an iPhone 17 simulator running iOS 26.5. Every iPhone job recorded 81 passes, three skips and zero failures. The logs show each of the 84 selected tests starting once per run. All five Mac jobs passed. The Mac job definition is byte-identical to `0380bb5`.

| Run | iPhone job | Mac job | iPhone XCTest | Waits beyond unscaled limit |
| --- | --- | --- | --- | --- |
| A | [Pass · 13m 37s](https://github.com/santhoshbalaji/Oriv/actions/runs/44661279475/job/136039849942) | [Pass · 11m 30s](https://github.com/santhoshbalaji/Oriv/actions/runs/44661279475/job/136039849743) | 126.3 s | Draft readiness, 26.32 s |
| B | [Pass · 12m 15s](https://github.com/santhoshbalaji/Oriv/actions/runs/44661285054/job/136039867231) | [Pass · 11m 16s](https://github.com/santhoshbalaji/Oriv/actions/runs/44661285054/job/136039866647) | 114.4 s | Draft readiness, 26.20 s |
| C | [Pass · 8m 48s](https://github.com/santhoshbalaji/Oriv/actions/runs/44661283124/job/136039859341) | [Pass · 10m 51s](https://github.com/santhoshbalaji/Oriv/actions/runs/44661283124/job/136039859973) | 80.6 s | None |
| D | [Pass · 11m 01s](https://github.com/santhoshbalaji/Oriv/actions/runs/44661281884/job/136039855882) | [Pass · 8m 38s](https://github.com/santhoshbalaji/Oriv/actions/runs/44661281884/job/136039855319) | 99.6 s | Draft readiness, 22.62 s |
| E | [Pass · 13m 01s](https://github.com/santhoshbalaji/Oriv/actions/runs/44661282031/job/136039855377) | [Pass · 11m 03s](https://github.com/santhoshbalaji/Oriv/actions/runs/44661282031/job/136039855179) | 122.2 s | Draft readiness, 21.63 s. Debounced save notification, 0.94 s. |

The logged waits came from `BrowserExperienceTests.testEditedFieldSignalRequiresConfirmationUntilNextDocument` and `BrowserEngineeringTests.testRealURLChangeSavesWithinDebounceAndNotifiesOnce`. Their unscaled log thresholds on hosted CI were 20 s and 0.9 s respectively. The three skips in each run were native GPC on OS 26, the opt-in live-site spot check, and service workers without Apple's managed browser entitlement.

The temporary `ci/iphone-stabilization-*` branches from both batches were deleted. Remote `main` remained at `ac30efa`, Oriv 0.17.1 build 35.
