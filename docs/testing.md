# Testing the browser

Use an isolated development profile and synthetic pages. The current source builds Oriv-Dev separately from Oriv; building does not install it. `scripts/run-mac.sh` explicitly replaces and opens the installed development app.

## Automated checks

Run `./scripts/check-browser.sh` with ports 8768 and 18768 free. It starts its own loopback fixtures, runs shared and native Mac tests, verifies the app signature and browser entitlements, and checks scope/whitespace. Results are retained under `build/browser-quality.*/`. Mac UI runs in background by default; foreground-only media/fullscreen checks skip with explicit reasons. Record skips separately.

`BrowserPerformanceTests` measures host-process elapsed time and memory for 1/10/30-tab JSON restoration using five iterations. It asserts that background restoration creates no WebKit views. These are setup microbenchmarks, not whole-app launch, page speed, total WebKit-process memory or energy evidence. Wider measurements remain required.

Tab-switch rendering, bounded transient snapshots and the recent-tab live reserve are covered by `TabSwitchRenderingTests` and BrowserKit's `TabSnapshotTests`. See [tab switching](tab-switching.md) for image budgets, privacy lifetime, frame evidence and the isolated 20-tab memory/CPU probe.

The Mac history/scroll regression first establishes a rendered source at 1200 points and verifies two stable readbacks before discarding it. WebKit can reset history scroll after acknowledging the setup command too; that must not silently turn the source into an unscrolled page. After selection, the original history, view-release and 1200-point restoration assertions remain unchanged. Its diagnostic callback records late resets and confirms the direct WebKit fixture performs no favicon document lookups.

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

## Shortcuts, icons and local suggestions

`BrowserShortcutTests` sends actual AppKit key-down events through `NSApp` while
WebKit content, the native address editor and a tab-overview-style sheet own
focus. It checks wrapping/sidebar order, both hard-reload focus paths, and unique
reload menu equivalents. `AddressCompletionTests` verifies suffix selection,
Backspace suppression and Right Arrow acceptance with the real editor.

`SiteIconAndSuggestionTests` runs on Mac and headless Simulator. The privacy
fixture on port 18768 serves a cookie-protected SVG icon, exercising WebKit-cookie
transfer, regular persistence, private erasure, lazy sleeping-tab lookup, and
cache bounds. `LocalSuggestionTests` measures eight indexed queries over 10,000
history records with an open tab; each must complete within 16 ms. Normalization
and index construction run separately on the suggestion actor. Results print
`SUGGESTION_QUERY` and `SUGGESTION_PERF` timings.

For the four background sidebar/favicon and suggestion captures, run
`ORIV_BACKGROUND_UI=1 ORIV_BATCH_VISUALS=1 ./scripts/capture-mac-visuals.sh build/batch-0.14/visuals`.
Use a fresh empty output directory for each run. These app-owned, off-screen
layout snapshots do not establish foreground Liquid Glass/compositor fidelity.

## Safari-like Mac sidebar

`SidebarGlassTests` covers metadata filtering, private-pin rejection, explicit
section drops and scoped row reorder, context-menu command dispatch, spoken
labels, rail geometry/toggle, search focus/Escape and arrow/Return navigation, including 60 lazy rows in
expanded and rail modes after the real keyboard toggle.
BrowserKit additionally round-trips pin/order persistence and the existing
continuity pin metadata allowlist. Existing Ctrl+Tab tests exercise pinned-first
order with actual native events.

`SidebarBehaviorTests` also loads the cookie-protected `rel=icon` fixture in a
live off-screen window, checks the row and rail's rendered green artwork within
ten seconds, and verifies sleeping rows read only their regular profile's disk
cache. Its 780 pt window test invokes the native key equivalent, checks that an
explicit overlay stays open after 1.5 seconds without changing the WKWebView or
JavaScript viewport width, and exercises repeat toggle, menu request, native
button click, Escape and outside-click dismissal. The direct history-scroll
fixture disables the optional completion callback to retain its icon-free
control; the compatibility test separately verifies discovery remains blocked
through restoration and resumes automatically after the destination cover clears.

For opt-in real-site favicon comparisons, set `ORIV_BACKGROUND_UI=1`,
`ORIV_GLASS_SCENE=sidebar-live` and an explicit comma-separated `ORIV_LIVE_SITES`
list of HTTPS URLs, then run `./scripts/capture-mac-visuals.sh --glass --key`
with a fresh output directory. This captures expanded, 780 pt rail and explicit
overlay states without seeding icons or manually requesting discovery. Geometry
receipts include both native and JavaScript page widths and per-tab cache status.

Run `ORIV_BACKGROUND_UI=1 ORIV_GLASS_SCENE=sidebar-b ./scripts/capture-mac-visuals.sh --glass build/sidebar-b/after`
for 18 real-window scenes: light/dark × 820/1280 pt × expanded/rail × 12/60 tabs,
plus expanded/rail external-private windows. The pages are locally generated and
tinted; favicons are generated PNGs read through the production cache. All data
is synthetic and isolated. Background output explicitly labels opaque layout
fallbacks and page snapshots; it never establishes live Liquid Glass fidelity.
Use a fresh empty output directory. Keep side-by-side comparisons under ignored
`build/sidebar-b/` and review the actual images.

The 100-tab probe scrolls the real native scroll view for 180 steps with the
same sleeping metadata records, first with solid accessibility material and
then system glass. It reports p50/p95/max main-thread native layout/display CPU,
steps over 16.67 ms, and verifies zero WebView creation. The p95 must fit a 60 Hz
CPU frame budget. Search and toggle/reorder probes also cover 12/50/100 tabs.
These are off-screen CPU measurements, not compositor FPS, GPU hitch, loaded-page
memory or total WebKit-process measurements. Live tinted-page glass, inactive
window material, VoiceOver reading/focus and real pointer drag/menu tracking
remain foreground acceptance checks. The native AX-tree test explicitly skips
when SwiftUI exposes no descendants in an off-screen accessory window; model
labels and native key-event tests continue to run.

For sidebar contrast regression evidence, run
`ORIV_BACKGROUND_UI=1 ORIV_GLASS_SCENE=sidebar-contrast ORIV_CAPTURE_TICKS=600 ./scripts/capture-mac-visuals.sh --glass build/release-0.15.0/contrast`
with a fresh output directory. It covers window light/dark appearances ×
white/black/purple pages × expanded/rail/search, plus the same 18 cases with
Reduce Transparency and Increase Contrast (54 cases). Search contains `wiki`.
The normal cases inject a known sampled colour in place of the compositor's
glass output and render the production contrast backing and controls. The
PNG suffix `synthetic-composite` and manifest distinguish this from live glass.
The sidebar is hosted separately from the header's remote glass layers; the
page is a labelled colour swatch and the header is a layout spacer.
Accessibility cases exercise the opaque material and selection outline through
local capture overrides, without changing system accessibility settings.

`scripts/check-contrast.py` reads the backing and highlight opacities from the
sidebar source, composites them over both page extremes, purple, grey, teal and orange, and
checks text at 4.5:1 and icons/indicators at 3:1, including nested fields,
selection, hover, pressed utility buttons and opaque accessibility variants.
The dedicated sidebar palette also applies inside T3 profiles. `--negative-sidebar-test` removes the backing
in the model and must catch the original fixed-foreground/glass mismatch.
The 83% direction B slate/lilac backing bounds glass luminance while retaining
the system glass edge. Selection and hover use the mock's opaque palette fills.
The filled Mac address capsule follows the page colour with a guarded 10% dark
lift / 6% light shade;
plain header glyphs use the page's explicit contrasting foreground. It avoids colour-scheme flips
during navigation or scrolling. Foreground compositor fidelity remains a
separate, explicitly authorized acceptance check.

For the focused toolbar, sidebar and start-page evidence, run
`ORIV_BACKGROUND_UI=1 ORIV_GLASS_SCENE=p2 ./scripts/capture-mac-visuals.sh --glass --key build/p2-2026-11-20/visuals`.
The fixtures include populated and cleared history, a private start page, duplicate
titles, native traffic-light geometry and a tab menu command inventory. The colour
cases use a synthetic glass input and the two opaque accessibility fallbacks in
both appearances. Native menu tracking and live glass require foreground acceptance.

## Opt-in pre-release accessibility audit

Get the owner's approval before running the foreground XCUITest audit. Run
`ORIV_A11Y_AUDIT=1 ./scripts/check-accessibility.sh mac` for the Mac start page,
expanded sidebar, rail, and Settings. Run
`ORIV_A11Y_AUDIT=1 ORIV_IOS_SIMULATOR_ID=<isolated-simulator-id> ./scripts/check-accessibility.sh iphone`
for the iPhone start page, tab grid, Library, and Settings. The runner reports
all issues from `performAccessibilityAudit` and stores its result bundle under
`build/accessibility.*/`. Both audit schemes are separate from the browser and
iPhone gates and CI. The audited app launches with disposable browser state.

For the 30-private-tab grid timing workload, run
`ORIV_GRID_TIMING_ONLY=1 ./scripts/check-iphone.sh` headlessly. The test mounts
two inline WebKit pages and records actual display-link callback delivery across
three cycles of opening the grid, closing it, and selecting a card. It reports
the maximum gap by phase and asserts a local bound. Hosted CI or a scaled WebKit
deadline records timings without asserting frame delivery.
