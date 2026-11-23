# Tab switching and reclamation

Tab selection must not expose an unpainted WKWebView. Each native web host installs a destination-only cover before attaching the view. It uses the tab's last downsampled page image, or an opaque background with a loading label when no image exists. Images are placeholders, not interactive documents. No pixels from the outgoing tab cross a privacy or profile boundary. The Mac representable updates one host across web-tab selections instead of replacing its SwiftUI identity.

Mac selection also respects WebKit's fullscreen ownership: it requests presentation closure and waits for WebKit to restore its placeholder before replacing the child. Rapid selection keeps the latest pending target; a late update cannot recreate the same closed tab's view. The ownership state machine has a synthetic regression test, while actual system fullscreen still requires foreground acceptance.

A main-frame First Contentful Paint message in an isolated content world is matched to the committed document's `performance.timeOrigin`. Delayed messages from another document cannot release the cover. Empty documents and formats without Paint Timing can also become ready on navigation completion. After attachment, a small public `takeSnapshot(afterScreenUpdates: true)` request provides a rendering barrier; only then does the cover fade over 100 ms (immediately with Reduce Motion). A transient barrier error retries up to three times, with no idle polling or forced reveal. Closed/replaced views cannot finish a stale handoff. Restored tabs also wait for scroll restoration. This is a public-API approximation: WebKit has no public first-composited-frame callback for WKWebView.

Scroll restoration reads back the viewport across two 50 ms settling checks. WebKit can acknowledge a scroll command at navigation completion and subsequently replace it with its history scroll position. Oriv reapplies the saved point up to three times, then accepts a legitimate clamp if the document is smaller. These checks run only during restoration and cancel on navigation/stop/close. The cover remains until they finish. Input passes to an already usable live document while the visual cover finishes its handoff; an unpainted or restoring document remains protected.

Favicon discovery is optional document work. It cannot access an unpainted, loading or restoring view, or a view whose destination cover remains visible. The cover's weak presentation marker clears when the handoff finishes, is replaced or is dismantled. Icon rows observe eligibility and retry after readiness without waking discarded tabs. Asynchronous icon work checks eligibility again before SVG rasterization, so a delayed download cannot execute JavaScript during a later handoff.

## Image lifetime and budget

Each browser session has an 8 MiB LRU cache. A snapshot is limited to 640 pixels on its longest edge and stored as JPEG at quality 0.65. Its budget charge includes the JPEG and entry metadata. Only visible covers decode images, and each decoded image has a separate limit of 640 × 640 × 4 bytes. Uniform unpainted images are rejected. Background capture uses updated pixels because navigation completion may precede drawing, but the asynchronous callback never delays selection. There is at most one capture in flight per session, with a 750 ms acceptance deadline. Navigation, close and pressure invalidate late results.

The existing iPhone All Tabs transition cache has a separate 24 MiB decoded budget. The combined retained-image allowance is therefore at most 32 MiB per mobile controller/session, excluding transient capture/encoding buffers and WebKit's own surfaces. Both caches purge on memory warning. This change preserves the existing grid transition path.

All images, including regular tabs, stay in memory: they are absent from session files, backups and continuity records. Closing a tab removes its image immediately, including any decoded cover. Session shutdown clears the cache. Memory pressure clears compressed and decoded images and invalidates pending captures. No snapshot is written to disk by the product. Test attachments contain synthetic fixtures only.

## Live tab policy

Detached Mac views use WebKit's `.suspend` scheduling policy. WebKit exempts playing media, media capture and active page loads. Oriv lets views with downloads, display-capture requests, or fullscreen and picture-in-picture presentations keep running under WebKit's throttle policy. Closing a view unregisters its observers and adapters, drops the tab's snapshot and rule-installation entry, and lets pending favicon downloads finish without retaining the view. [WebKit scheduling documentation](https://developer.apple.com/documentation/webkit/wkpreferences/inactiveschedulingpolicy-swift.property)

The active Mac session keeps its three most recently used instantiated tabs for fast switching. The idle pass considers other views after ten minutes. If more than eight views are live, it can trim the oldest eligible pages to eight after one minute. A memory-pressure warning or critical event can override the recent-live reserve, but still protects views used in the last minute. The active profile's selected tab remains resident. An inactive profile keeps its controller and logical selection. Its last selected view is eligible after five minutes, or after one minute under pressure, and its other tabs follow the same idle thresholds without a recent-live reserve.

Pinned tabs retain their live state. Private tabs also keep their live views because ephemeral site state and in-page work may be unrecoverable after a reload. Regular loading pages, pages with detected edits, unsafe or unknown requests, and media, capture or download activity remain resident. The edit tracker detects trusted input and change events. It cannot detect every site-managed draft. iPhone uses the same guarded discard and restore path with its eight-live-tab policy and its existing WebKit throttle setting. Its pressure path can trim to one and clears the shared image cache.

Restored background tabs remain lazy, and an image is never a reason to instantiate them. WebKit interaction state preserves navigation history and scroll on the replacement view. A discarded page will reload, so site-specific transient state may be lost despite those safeguards.

## Validation

`TabSnapshotTests` covers the decoded budget, LRU image eviction, bounded dimensions, blank-image rejection, transient private storage, invalidation and capture deadline. `TabSwitchRenderingTests` exercises live, discarded, launch-restored, private and heavy local pages; retains raw WebKit frames and native cover images as XCTest attachments; checks cover release without polling it; verifies decoded private images are dropped; and tests the Mac live reserve with real WKWebViews and a stable SwiftUI host.

Run `./scripts/check-browser.sh` and the iPhone gate. See [the off-screen tab-memory benchmark](testing.md#off-screen-tab-memory-benchmark) for the fixture, policy controls and recorded metrics.

Offscreen Mac snapshots and app-owned Simulator captures do not certify WindowServer compositing, physical-device frame pacing, foreground media, system fullscreen or energy usage. Retain those acceptance boundaries when reporting results.
