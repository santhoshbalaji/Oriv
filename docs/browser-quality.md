> Continuity update (4 November 2026): optional browser-only iCloud/Handoff code and dedicated signing configurations now exist. The earlier browser-only checks below describe the local Debug baseline. See [current continuity implementation and acceptance](browser-continuity.md).

# Browser quality and coverage

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

Specific open browser work includes safe memory-pressure tab reclamation, independent windows/tab moves, wider authenticated-site and passkey acceptance, visible media/DRM/conferencing, accessible keyboard and VoiceOver flows, physical-device permissions, signed default-browser capability, remote CI, Developer ID/notarization and a secure update channel. Existing downloads remain session-scoped; restore does not preserve website form values or full back/forward stacks.

Primary references: [Web Platform Tests](https://web-platform-tests.org/) provides the cross-browser compatibility suite; [WebKit tracking prevention](https://webkit.org/tracking-prevention/) describes engine behavior that must be checked against the embedded runtime; [Apple's browser requirements](https://developer.apple.com/documentation/xcode/preparing-your-app-to-be-the-default-browser) describe managed browser capabilities, including iPhone service workers. Using WebKit alone does not prove all Safari browser features or their acceptance in Oriv.
