# Testing the browser

Use an isolated development profile and synthetic pages. The current source builds Oriv-Dev separately from Oriv; building does not install it. `scripts/run-mac.sh` explicitly replaces and opens the installed development app.

## Automated checks

Run `./scripts/check-browser.sh` with port 8768 free. It starts its own loopback fixtures, runs shared and native Mac tests, verifies the app signature and browser entitlements, and checks scope/whitespace. Results are retained under `build/browser-quality.*/`. Keep the desktop visible for media tests; record skips separately.

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
