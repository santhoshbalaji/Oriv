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
