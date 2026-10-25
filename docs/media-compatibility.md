# Browser versions and media compatibility

Audit date: 25 October 2026. Oriv 0.3.0 is a locally installed, ad-hoc-signed Release build. It is not notarized. See the [current release report](releases/0.3.0.md).

## Version policy

The application uses the public system `WKWebView`. It does not embed a separately versioned WebKit binary. Each device supplies its engine through Apple's system/browser updates. The deployment target is the oldest supported OS, not a pin on the engine used at runtime.

| Component | Verified locally |
| --- | --- |
| Oriv | 0.3.0, build 3 |
| macOS | 27.0.1, build 26A434 |
| Installed Safari | 27.0.1 |
| System WebKit framework | 22625.1.29.11.28 |
| Xcode | 27.0, build 27A266a |
| Build SDK | macOS 27.0; iPhone Simulator 27.0 |
| Minimum deployment targets | macOS 26.0; shared package iOS 26.0 |

Apple lists macOS 27.0.1 as the current macOS release. For iPhone, the current general release is 27.0.1; 27.1 is specific to iPhone Duo. See [Apple security releases](https://support.apple.com/en-us/100100). Apple's [WebKit 27.1 announcement](https://webkit.org/blog/18486/webkit-features-for-safari-27-1/) describes the same engine/web technologies as 27.0 with device-specific additions.

The latest stable toolchain listed by Apple is Xcode 27.1; 27.2 is a release candidate. Installed Xcode 27.0 and stable 27.1 both supply the macOS 27 SDK. Xcode 27.1 supplies the iOS 27.1 SDK. The newer toolchain has **not** been installed in this task. Upgrade the release build machine to the latest stable Xcode before distribution, then repeat the platform checks. See [Apple's Xcode requirements](https://developer.apple.com/xcode/system-requirements).

Keep the existing minimum OS versions while compiling with current stable SDKs. Raising the minimum to 27 would exclude users without making WebKit newer on an already updated Mac. The Intel target is compiled separately; a compile does not verify playback on Intel hardware or macOS 26.

Settings displays the actual app version, OS and loaded WebKit framework build. Do not use the website user-agent string as a version detector: WebKit intentionally retains compatibility tokens such as `AppleWebKit/605.1.15` and `Intel Mac OS X 10_15_7` on newer systems.

Oriv 0.2.0 preserves WebKit's platform identity and uses the public `applicationNameForUserAgent` setting to append `Version/<installed Safari version> Safari/605.1.15` on Mac. If Safari's version cannot be read, it uses the supported OS major version as a conservative baseline. This addresses sites incorrectly rejecting WKWebView's otherwise incomplete desktop browser identity; it does not change the engine or provide Chromium APIs/DRM. See [WebKit's WKWebView identity issue](https://bugs.webkit.org/show_bug.cgi?id=278284) and [Apple's API documentation](https://developer.apple.com/documentation/webkit/wkwebviewconfiguration/applicationnameforuseragent). The integration test checks the HTTP header, main-frame JavaScript and subframe JavaScript agree. Live YouTube chat was verified in the installed release.

The Mac view now gives SwiftUI an AppKit container instead of the WKWebView itself. The child uses frame-based sizing while windowed, leaving WebKit free to reparent and size it during fullscreen transitions. This addresses the SwiftUI sizing conflict documented in [WebKit bug 313802](https://www2.webkit.org/show_bug.cgi?id=313802). Oriv 0.3.0 passed two normal-window fullscreen entry/exit cycles with both the playing-video/chat fixture and YouTube, with Balanced filtering enabled. Installed-release evidence is linked in the [current release report](releases/0.3.0.md).

## Shared media configuration

`BrowserWebConfiguration.apply(to:)` runs before every `WKWebView` is created, including supplied popup configurations. It preserves the popup's data store, user-content controller and opener relationship.

- Enable the standard webpage Fullscreen API. [Apple documents this setting](https://developer.apple.com/documentation/webkit/wkpreferences/iselementfullscreenenabled) as disabled by default.
- Enable AirPlay. On iOS, also enable inline playback and Picture in Picture; websites still need appropriate markup, and availability depends on the OS, player and device.
- Require user action for audio playback via `mediaTypesRequiringUserActionForPlayback = .audio`. Video without audio can use WebKit's autoplay policy. Muted video with an audio track remains subject to platform visibility/autoplay rules; do not promise autoplay in hidden tabs. See [WebKit's video policies](https://webkit.org/blog/6784/new-video-policies-for-ios/).
- Throttle idle views through WebKit's public inactive scheduling policy. The SDK specifies that loading pages and pages playing media are not idle. Keep live tab views resident rather than rebuilding them on every switch.
- Retain site-specific WebKit compatibility behavior and platform codec/GPU/adaptive streaming choices. There are no private preferences, universal JavaScript player patches or forced quality levels.

These settings enable platform features; they are not a measured performance gain. Hardware decoding, HDR, codecs, power use and maximum resolution depend on the hardware, stream and player. H.264/AAC MP4 and HLS are practical baseline formats. HEVC, VP9 and AV1 need capability checks and fallback renditions; Apple documents hardware requirements for its AV1 HLS examples. See [Apple HLS examples](https://developer.apple.com/streaming/examples/) and [HTTP Live Streaming](https://developer.apple.com/streaming/).

## Reproducing media checks

Generate original local fixtures using Apple's encoders, then run the loopback server:

```sh
swift scripts/generate-media-fixtures.swift build/media-fixtures
python3 scripts/qa-server.py
```

The generator creates 12-second, 640 × 360, 30 fps H.264 and HEVC videos, plus an H.264/AAC version. Generated files remain under ignored `build/`. No media is downloaded to generate them. The server supports byte-range requests for seeking and serves two WebVTT caption cues.

Open `http://127.0.0.1:8768/media` in the app. Check playback, seeking, 2× speed, captions, fullscreen, Picture in Picture, switching away/back and the codec report. The Apple HLS source contacts Apple's sample-stream CDN only when selected. Codec reports describe this runtime's claims, not proof of actual playback or commercial-service support.

Run integration tests in an unlocked, visible desktop session with the fixture running:

```sh
xcodebuild -project PersonalBrowser.xcodeproj -scheme PersonalBrowser \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData test
```

## Earlier foundation media verification

The table below records the preceding media audit. The new 0.2.0 regression run executed 13 tests: ten passed, three skipped because the test window was occluded, and zero failed. Do not treat the earlier foreground rerun as a pass of the three current skipped tests. Installed-release interactive YouTube checks are recorded separately in the [release report](releases/0.2.0.md).

| Check | Result |
| --- | --- |
| Apple silicon Mac build and strict local signature verification | Passed |
| Intel (`x86_64`) Mac build | Passed; no Intel hardware playback test |
| Both shared modules targeting iOS 26 / arm64 simulator | Compiled with the iOS 27 SDK; no iPhone app/device test |
| Existing seven browser integration cases | Passed |
| Audio autoplay without a gesture | Rejected as expected; test passed |
| H.264/AAC and HEVC metadata; 640 × 360, 12 seconds; two caption cues | Passed in WebKit |
| Fullscreen API advertised by the configured view | Passed |
| Rendered H.264/HEVC frames, seeking/speed and media tab restoration | Both rendering tests passed in the foreground rerun; real view detachment/reattachment is exercised |
| Runtime versions in Settings | Inspected in the running app; screenshot (`qa/media/runtime-settings.png`, local QA artifact) |
| HLS playback | Apple's sample rendered in the normal window and adapted from 960 × 540 to 1920 × 1080; screenshot (`qa/media/hls-playing.png`, local QA artifact) |
| Video fullscreen enter/exit | Passed interactively, including visible video and captions; screenshot (`qa/media/video-fullscreen.png`, local QA artifact) |
| Picture in Picture on this Mac build | Failed: `NotSupportedError`, despite the document advertising the API; not claimed as supported |
| AirPlay receiver, DRM services and physical iPhone | Not verified |

The initial integration run executed **11 tests: nine passed, two skipped, zero failures**, recorded in `build/MediaFinalTests.xcresult`. After correcting test-window placement/activation, the **two previously skipped tests both passed**, recorded in `build/ForegroundMediaTests.xcresult` and `build/foreground-media-tests.log`. This is a full initial run plus a targeted rerun, not a claim of a subsequent single 11-test run. The harness now centers the test window, moves it to the active Space, waits for visibility and reports application activation state if still occluded.

The user confirmed the desktop was unlocked. That did not mean the automated browser window was actually visible to WebKit: the normal window initially reported `hidden` and zero frames. Entering a dedicated fullscreen Space made it visible, and opening the built app normally through Finder also restored visible playback in the normal window. Apple's [activation documentation](https://developer.apple.com/documentation/appkit/nsapplication/activate()) explains that a programmatic activation request is not guaranteed to succeed. This evidence points to activation/occlusion in the automation setup, not a locked desktop or failed decoder. No production visibility override was added. A visible native window whose document incorrectly remains hidden still fails the test.

Interactive verification covered H.264/AAC, HEVC, both caption cues, seeking to exactly five seconds, 2× speed, preserving the paused time/speed across tab switches, video fullscreen entry/exit and HLS playback. HEVC screenshot (`qa/media/hevc-playing.png`, local QA artifact) and HLS accessibility evidence (`qa/media/visible-playback-ax.txt`, local QA artifact) are retained. HLS had zero dropped frames in the captured sample; fullscreen transitions at 2× produced some dropped frames. These short functional checks are not sustained performance or battery benchmarks.

PiP was attempted on H.264 and HEVC with a visible document, including a normal window. The request was rejected with `NotSupportedError`. The fixture now reports document-level PiP API availability separately from the video's WebKit presentation-mode support; neither alone certifies a successful transition. The public `allowsPictureInPictureMediaPlayback` configuration property is iOS-specific in the installed SDK, and the iOS configuration remains enabled. No private macOS preference or API was introduced to bypass the limitation.

## Remaining release checks

Test actual playback on macOS 26 and 27, Intel and Apple silicon, and physical iPhones once the mobile target exists. Include H.264/AAC, HEVC, VP9/WebM, AV1 where available, HLS adaptation under slow networks, HDR, subtitles, AirPlay, PiP, headphones/audio routes, background tabs and sleep/wake. Measure frame drops, CPU/GPU usage and battery on representative hardware before making performance claims.

DRM services need separate authenticated testing. The presence of the Encrypted Media API does not guarantee Netflix, Disney+, Prime Video or other providers support this app. Provider allowlists, FairPlay integration and any necessary approvals are separate concerns; this build does not ship Widevine. Camera/microphone capture and WebRTC permissions are separate from video playback and were not expanded here.

Oriv 0.3.0 adds built-in ad blocking with Balanced as the default and a per-site exception switch. The network filters exclude media resources, but blocking a supporting script can still affect a player. Strict also blocks additional analytics and hides ad slots. See [coverage, privacy behavior and limitations](ad-blocking.md). Removing first-party or server-inserted video ads is not guaranteed.

Raw QA captures and build logs referenced here are retained locally and excluded from the public repository. Published synthetic-content screenshots are in `docs/images/`.
