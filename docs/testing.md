# Testing the browser

Use an isolated development profile and synthetic pages. The current source builds Oriv-Dev separately from Oriv; building does not install it. `scripts/run-mac.sh` explicitly replaces and opens the installed development app.

## Automated checks

Run `./scripts/check-browser.sh` with ports 8768 and 18768 free. It starts its own loopback fixtures, runs shared and native Mac tests, verifies the app signature and browser entitlements, and checks scope/whitespace. Results are retained under `build/browser-quality.*/`. Mac UI runs in background by default; foreground-only media/fullscreen checks skip with explicit reasons. Record skips separately.

`BrowserPerformanceTests` measures host-process elapsed time and memory for 1/10/30-tab JSON restoration using five iterations. It asserts that background restoration creates no WebKit views. These are setup microbenchmarks, not whole-app launch, page speed, total WebKit-process memory or energy evidence. Wider measurements remain required.

Build iPhone with the `OrivMobile` scheme and an iOS Simulator destination. Its native WebKit tests use the same server on port 8768. The service-worker check explicitly skips when the platform capability is unavailable. Use `OrivBrowserMobile` only with the necessary managed browser grant and provisioning for device acceptance.

## Manual browser acceptance

1. Launch into search. Confirm there is no Workspace, chat, dashboard or tracker navigation. Optional Mac & iPhone continuity is accessible through Settings; other-device tabs are in Library.
2. Create an isolated profile. Verify separate tabs, bookmarks, history, website logins and permissions. Switch back and confirm form/page state survives; archive/restore only the test profile.
3. Bookmark a synthetic page with Command-D, reopen it from Bookmarks, export/import HTML, and delete it. Repeat after relaunch. Private tabs cannot create persistent bookmarks.
4. Open `http://127.0.0.1:8768/quality`. Exercise navigation, find, zoom, reader text, PDF/webarchive export, HTTP authentication, uploads, downloads, pause/resume and edited-field protection.
5. Inspect per-origin permissions, private exceptions, data removal and protection modes. Use disposable website data when testing deletion. Actual OS permission grants/default-browser changes are separate user-controlled checks.
6. Exercise visible video/audio/fullscreen, conferencing, keyboard-only navigation, VoiceOver, large text and narrow layouts on supported devices.
7. With a synthetic pre-upgrade database, verify active saved links appear as bookmarks, archived/trashed links stay excluded, other records remain intact and deleted bookmarks do not return on later launches. Keep a backup before any real upgrade.

No live account, shopping purchase, submitted form, cloud operation or external message is part of the automated checks. Current local builds are not a distribution or standards-conformance certification.

## Background Mac UI testing

The native Mac test scheme and `scripts/capture-mac-visuals.sh` default to `ORIV_BACKGROUND_UI=1`. The shared `BackgroundUIMode` installs accessory activation policy before SwiftUI shows a window and suppresses the normal launch window. Test/capture windows use its `Window` subclass, which places them 20,000 points beyond the union of all display frames and overrides frame constraints and placement so AppKit cannot pull them on-screen. They are layer-backed and ordered at the back; key-window tests may call `makeKey()` without activating the application. `--key` requests key-window behaviour; the legacy `--active` flag does not grant foreground permission.

Captures continuously audit `NSWorkspace.shared.frontmostApplication`, activation notifications, and every test-app window frame against every screen. Move/resize/update notifications and a 50 ms timer check placement. SwiftUI's own hidden measurement windows are moved before ordering and counted separately as `hiddenAuxiliaryRelocations`; any visible overlap fails the run and is immediately ordered out. Native Mac test teardown checks the cumulative audit too. Manifests must report accessory policy, positive frame/frontmost sample counts, and zero display/frontmost/activation violations after placement. Geometry checks use coordinates relative to the window. No window is moved onto a display or an active Space to repair rendering.

Background runs skip compositor and Liquid Glass captures before requesting WindowServer pixels. The PNG bridge is reserved for separately approved foreground runs and attempts only the isolated process's validated window IDs. Separately labelled `WKWebView.takeSnapshot` page images and opaque `cacheDisplay` candidates permit off-screen fallback review. A page snapshot does not verify Liquid Glass, and a cache candidate must be visually inspected before accepting non-glass chrome. Never silently replace glass evidence with a 2D render.

System full screen, menu reveal and rendered video playback are foreground-only checks and are explicitly skipped in background mode. Sidebar full-screen layout can still be exercised by a clearly labelled geometry fixture in a normal background window; that is not a system transition test. `ORIV_FOREGROUND_UI=1` overrides the background default only after explicit orchestrator approval. Do not enable it during ordinary work. Use device tools for Simulator tests and never open the Simulator.app GUI.

The shared privacy compatibility fixtures use the same off-screen `BackgroundUIMode.Window` policy. A per-case observer checks the cumulative audit across native and shared cases; `BACKGROUND_UI_FINAL` records the final totals.

Shield geometry and real-popover presentation have separate native tests. Address/shield fit at default, minimum and intermediate widths, sidebar states, link cleaning, tracker blocking and cookie hiding continue to run on macOS 26 in background mode. Only `testPrivacyShieldOpensRealPopover` skips when all three conditions hold: macOS is below 27, background mode is enabled, and AppKit refuses the key window. Its skip message identifies the foreground-dependent routing restriction. The real-popover assertions run on macOS 27 and later, including background runs. Record this platform-specific skip separately; it does not certify foreground popover presentation on macOS 26.

Run `python3 scripts/check-background-ui.py` to catch direct Mac activation/raising calls and window construction outside the shared policy, including shared compatibility tests. Normal app usage without either UI-mode environment variable keeps its usual activation behaviour.


## Opt-in physical-device QA

`Tests/DeviceQATests` contains device XCUITest cases; `Tests/DeviceResourceTests` contains app-hosted hardware resource measurements. Both require `ORIV_DEVICE_QA=1`, reject simulator execution, and require a `.qa` bundle identity. They are deliberately excluded from the regular project and CI schemes.

Generate the local QA project under ignored `build/ios-device-qa/`, with a separate application identifier formed from the release identifier plus `.qa`, display name `Oriv QA`, development signing, empty app entitlements, and no continuity container, Handoff activity or URL-scheme registration. Keep the project specification, device selection, signing team and fixture LAN address in ignored local configuration. Verify the signed app and runner entitlements before installation. Never point these tests at the release app.

Run the ignored project's `OrivDeviceQA` UI scheme and `OrivDeviceResources` hosted scheme using `xcodebuild test` with the locally configured physical-device destination. Keep derived products separate when building UI and hosted suites: a UI-only build can remove the hosted test plug-in from the app bundle. Use `-collect-test-diagnostics never` to avoid collecting broad device diagnostics after a test infrastructure failure. Results and traces belong under `build/ios-device-qa/`.

For device fixtures, `scripts/qa-server.py --bind <Mac-LAN-address> --port <local-port>` explicitly binds that interface; its default stays loopback. The QA app may request Local Network permission. Do not use the Mac's loopback address from the phone. Only synthetic fixtures and read-only public pages are allowed; never sign in.

The QA build alone supports `ORIV_QA_REDUCE_MOTION=1` through the `ORIV_DEVICE_QA` compilation condition. This exercises Oriv's reduced-motion path without changing the system accessibility setting. A local memory-warning notification exercises only the QA process; it does not certify behavior under real system memory pressure. Display-link callbacks do not establish composited frame rate. Keep app-process footprint separate from WebKit helper-process memory, and distinguish process launches with warm caches from a reboot-cold launch.

### Release performance isolation

Use an optimized QA configuration with the diagnostic compilation condition absent. Exclude local native gesture probes as well as Swift diagnostic writers and signposts; inspect the app executable for their marker strings before accepting a measured run. Keep frame/signpost evidence in a separate diagnostic build. Retained XCTest video is evidence of recorded frames, not proof of the display refresh rate; report its actual frame rate.

For total memory, Activity Monitor can target all processes; VM Tracker requires individual process targets. Do not sum every WebKit process on the phone. The opt-in resource test records the identities of its own views' WebContent, Networking and GPU helpers, with epoch timestamps for aligning settled checkpoints. This debugging SPI lives exclusively in the device test bundle and is not included in either app target or distribution archive. Missing identity support must be reported, not replaced with an ownership assumption.

The navigation fixture compares full Oriv chrome against a bare view with the same timing-only observer and physical viewport. Report fresh-view and reused-view samples separately. Fresh views and ephemeral stores do not establish reboot-cold caches. Navigation request-to-commit and paint-message delivery are app-side intervals; JavaScript Navigation/Paint Timing values are document-relative and must not be labelled tap latency.
