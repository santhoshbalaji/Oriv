> Continuity update (4 November 2026): optional browser-only iCloud/Handoff code and dedicated signing configurations now exist. The earlier browser-only checks below describe the local Debug baseline. See [current continuity implementation and acceptance](browser-continuity.md).

# Browser quality and coverage

## 0.14.0 (21)

Mac tab selection now retains its native web-view host and presents a destination-only page snapshot while a discarded tab restores. Snapshots stay in an 8 MiB memory cache per session, including private pages, and never enter session or continuity records. Ordinary idle reclamation keeps the three most recently used Mac tabs live; pressure can reclaim older eligible views. Restored history scroll is checked across two settling samples before the cover releases, with bounded reapplication when WebKit resets the acknowledged position.

Control-Tab and Control-Shift-Tab cycle Mac tabs through the same selection path as sidebar and Switch to Tab suggestions. Command-Shift-R reloads from origin. Site-owned favicons appear across Mac and iPhone, with separate profile caches and memory-only private icons. Discovery waits for a painted document, completed restoration and dismissal of its destination cover; delayed SVG work revalidates document eligibility. Local address suggestions rank open tabs, bookmarks and history, with native inline completion and no remote keystroke requests.

Regression coverage combines the stable host, keyboard and suggestion selection, private snapshot/icon erasure, cookie isolation, lazy background tabs and restore-time discovery gating. Offscreen Mac captures and headless Simulator tests do not establish foreground compositing, actual system fullscreen, physical-iPhone frame pacing or energy use. See [tab switching](tab-switching.md), [keyboard shortcuts](keyboard-shortcuts.md) and [testing](testing.md) for behavior and acceptance boundaries.

## 0.13.1 (20)

The Mac Browser Actions (ellipsis) button now opens a native grouped pull-down menu. The full 36 × 32 pt glass label is the hit target, and the titlebar accessory forwards its strip to the content view, so edge and padding clicks no longer miss. Regression coverage clicks 18 edge and padding points at two widths and repeats activation with page focus; the opened menu was checked on screen in light, dark, private and narrow windows.

## 0.13.0 (19)

This version combines the 0.12.5 All Tabs button morph with external private-window presentation, incremental continuity reconciliation and ordered session saves, lighter top-bar colour observation, and safe Mac tab reclamation/process recovery. Silent CloudKit zone pushes request immediate reconciliation after continuity opt-in; polling remains the fallback, and slows only after verified delivery evidence. See [continuity](browser-continuity.md) and [architecture](architecture.md) for behavior and limits.

Automated regression coverage includes push-health fallback, background fetch deadlines, persistence ordering, discard exclusions, history/scroll restoration, private-page paint gating and private-window presentation. Signing/profile acceptance and real-device APNs delivery are separate gates; test or build success alone does not establish either.

## Current scope, 4 November 2026

The development app now contains browser features only. Workspace, AI, Workspace cloud sync, application/diet tracking, reminders, source monitoring and the Share extension have been removed from the UI, package targets and runtime initialization. Historical saved data is preserved through the read-only compatibility path described in [architecture](architecture.md#upgrade-and-data-preservation).

Mac starts with search, local bookmarks and recent history. iPhone has Browse, Bookmarks and Settings. Browser profiles, downloads, site permissions, protection controls and page tools remain. Local browsing requires no provider account. The previously blocked Workspace iCloud provisioning is no longer part of this build or its browser acceptance.

## Verified locally

- Shared Swift package suite: **21 tests passed**, including two historical bookmark-store formats and old session-destination migration.
- Full native Mac browser suite: **44 executed, 41 passed, three foreground-media skips, zero failures**. Evidence: `build/browser-only-acceptance.log`, `build/browser-quality.z0oqDU/BrowserTests.xcresult`.
- Additional upgrade tests: **three passed**, covering read-only bookmark import, deletion surviving relaunch, private bookmark exclusion and notification cleanup namespaces. Evidence: `build/browser-only-migration.log`.
- iPhone WebKit suite: **four executed, three passed, one service-worker capability skip, zero failures**. Evidence: `build/browser-only-mobile-tests.log`, `build/BrowserOnlyMobileTests.xcresult`.
- Both Mac and iPhone Simulator application builds succeeded. Mac strict signature/required-entitlement verification passed. Removed cloud, Calendar, app-group and inbound OAuth listener entitlements are absent.
- Interactive Mac check used the built app with ephemeral testing state: the search-first home, native loopback page navigation, Command-D bookmark creation, the independent Bookmarks library and browser-only Settings were verified. Existing installed apps were not replaced.
- `scripts/check-browser-scope.py` prevents retired package targets, service clients, URL schemes and entitlements from re-entering the browser build. This static check is part of `scripts/check-browser.sh`; it is not a network audit.

Tests for removed products were removed with those products. The smaller suite is not evidence of a browser regression or a newly passing equivalent of those old tests. iPhone visual/physical-device acceptance is separate from its successful WebKit tests.

## Performance baseline

`BrowserPerformanceTests` records elapsed time and host-process memory for constructing/restoring 1, 10 and 30 tabs, using five iterations and assertions that no background WebKit view is instantiated. Measurements are attached to the native xcresult/log. The first run establishes local setup observations only: it includes JSON persistence on shutdown, does not isolate cold app launch, and excludes WebKit subprocess memory, loaded-page workloads and energy. Host memory deltas are noisy and are not a product memory budget. No before/after speedup is claimed.

Browser startup no longer constructs an assistant, opens a writable productivity store, starts a source-monitor timer or resumes cloud controllers. iPhone opens additional profile controllers only when selected. Legacy bookmark reading runs asynchronously once. These are structural changes; real-world performance benefits still need measurement.

## Remaining browser priorities

The browser milestone has four acceptance areas:

1. **Privacy and security:** verify private/profile isolation across cookies, storage, permissions, history, restored sessions and downloads; audit app-initiated network requests with optional features unused; verify tracking protection and per-site exceptions, permission denial/revocation, website-data deletion and normal TLS handling. Account sign-in and cloud services must not be required for browsing. Distinguish website traffic and platform services from Oriv-initiated requests; do not promise network anonymity or zero network activity.
2. **Measured performance:** establish repeatable cold/warm startup, tab switching, controlled page-loading, idle CPU, memory and energy measurements on specified hardware/OS builds. Include WebKit subprocesses and 1/10/30-tab workloads. Record baseline and candidate distributions before setting budgets or claiming improvements. Profile browser startup dependencies on optional modules, restored-tab allocation and background work. Resource reclamation must preserve forms, active playback, calls and downloads.
3. **Web compatibility:** maintain a capability and behavior matrix for each supported OS/WebKit build. Expand beyond the current four WebKit tests using applicable Web Platform Tests and real user journeys: authentication/passkeys, uploads/downloads, media/fullscreen/PiP, conferencing, offline/service-worker behavior, navigation/popups and storage/security policy. Record passed, failed, skipped and unavailable separately. Current implemented standards means shipped, supported behavior; experimental APIs and capabilities unavailable to WKWebView are not automatically enabled or claimed.
4. **Daily use and maintenance:** verify keyboard/accessibility behavior, session and crash recovery, tab/window ownership, default-browser routing, supported-device coverage and secure distribution/update practices. Signing, Apple entitlements, remote CI and public release each require their own evidence.

Execution order: audit browser network/privacy behavior and establish whole-app performance baselines; fix observed isolation/resource issues; expand standards and real-site acceptance; complete distribution gates. Future Workspace planning remains outside this milestone.

Specific open browser work includes independent windows/tab moves, wider authenticated-site and passkey acceptance, visible media/DRM/conferencing, accessible keyboard and VoiceOver flows, physical-device permissions, signed default-browser capability, remote CI, Developer ID/notarization and a secure update channel. Existing downloads remain session-scoped. Full application restart restores URL metadata rather than website form values or full back/forward stacks; in-session reclamation preserves WebKit interaction state in RAM.

## Tab reclamation and process recovery, 16 November 2026

Mac now reclaims eligible background GET views after ten idle minutes and earlier on memory-pressure warning/critical events, with a sixty-second recent-use guard. A single tolerant timer and pressure source belong to each regular session and stop on shutdown. Pinned/selected/private tabs, media (including paused/suspended playback), capture, edited fields, active/resumable downloads, loading and terminated pages remain protected. macOS conservatively protects a document after any `getDisplayMedia` request, including pending or denied requests, because public WebKit exposes no display-capture state property. This page-world hook preserves the original call and reads no stream contents; it is not a tamper-proof OS capture monitor. Private tabs are not persisted to enable reclamation.

The shared discard path rechecks activity, identity, navigation revision and recent use after asynchronous WebKit replies; an eight-second timeout leaves an uncertain page resident. Selection restores `interactionState`, native back/forward entries and scroll in the original website store. Mac adapters unregister on discard and recreate without accumulating context-menu scripts. Closed-tab lifetime tests track tabs, web views, adapters, controllers and sessions; a real SwiftUI browser-window test checks detachment and restoration.

Process recovery already had a shared GET-only automatic reload and thirty-second loop guard. It now rejects stale-view termination callbacks and explains the unsafe-request/edited-field fallback. Unit tests exercise selection-delayed recovery, crash loops, unsafe requests, every discard exclusion, late IPC replies and injected pressure. Mac integration exercises real WebKit history/scroll restoration and the application adapters. Physical-iPhone and visible media/capture acceptance remain separate from the unsigned Simulator build.

Local validation passed on the final source: 125 BrowserKit tests; 151 Mac tests executed, 141 passed and ten explicitly skipped, with no failures. All twelve new shared and six new native cases passed. Native runs recorded zero activation/frontmost/display audit violations and all 156 tracked lifetime objects released. The generic iOS Simulator application built unsigned without launching a Simulator. Logs and xcresults are under `build/tab-memory/` and `build/browser-quality.Bq82kY/`.

The development-only `scripts/tab-memory.py` probe compares throttling, suspension and throttling plus discard at 1/10/20 local timer pages. Run with `ORIV_BACKGROUND_UI=1` and a new `--label`; use `--product` to exercise the product reclaimer with test-only aging. It builds an isolated app under ignored `build/tab-memory/`, enforces prohibited activation, uses the offscreen window placement/audits, and records each responsible process's physical footprint and CPU time. The safety audit itself adds a fixed CPU floor. Offscreen/occluded windows affect WebKit visibility; this is a BrowserKit probe rather than a repeat of the production/Safari benchmark. See `build/tab-memory/REPORT.md` for measurements and validation. Ten minutes is a conservative starting threshold, not an experimentally optimized deadline. `.throttle` remains because suspension's background-networking compatibility is unverified.

The completed fixture measured 132.7/292.8/465.5 MB at 1/10/20 loaded tabs before, versus 135.8/140.4/143.2 MB with eligible tabs aged and reclaimed by the final product policy. The final loaded control was 136.0/293.1/469.3 MB. At twenty tabs, reclamation reduced fixture memory by 69.2% and WebContent CPU from 2.405% to 0.124%; total CPU includes the audit/helpers and remains sensitive to host load. Fresh loaded-tab cost remains. Closing to one tab did not reproduce the production benchmark's approximately 70 MB residual; all closed views and 156 native lifetime objects released. These observations do not certify visible production, capture or physical-iPhone performance.

Primary references: [Web Platform Tests](https://web-platform-tests.org/) provides the cross-browser compatibility suite; [WebKit tracking prevention](https://webkit.org/tracking-prevention/) describes engine behavior that must be checked against the embedded runtime; [Apple's browser requirements](https://developer.apple.com/documentation/xcode/preparing-your-app-to-be-the-default-browser) describe managed browser capabilities, including iPhone service workers. Using WebKit alone does not prove all Safari browser features or their acceptance in Oriv.
