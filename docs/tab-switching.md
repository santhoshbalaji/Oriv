# Tab switching and reclamation

Tab selection must not expose an unpainted WKWebView. Each native web host installs a destination-only cover before attaching the view. It uses the tab's last downsampled page image, or an opaque background with a loading label when no image exists. Images are placeholders, not interactive documents. No pixels from the outgoing tab cross a privacy or profile boundary. The Mac representable updates one host across web-tab selections instead of replacing its SwiftUI identity.

Mac selection also respects WebKit's fullscreen ownership: it requests presentation closure and waits for WebKit to restore its placeholder before replacing the child. Rapid selection keeps the latest pending target; a late update cannot recreate the same closed tab's view. The ownership state machine has a synthetic regression test, while actual system fullscreen still requires foreground acceptance.

A main-frame First Contentful Paint message in an isolated content world is matched to the committed document's `performance.timeOrigin`. Delayed messages from another document cannot release the cover. Empty documents and formats without Paint Timing can also become ready on navigation completion. After attachment, a small public `takeSnapshot(afterScreenUpdates: true)` request provides a rendering barrier; only then does the cover fade over 100 ms (immediately with Reduce Motion). A transient barrier error retries up to three times, with no idle polling or forced reveal. Closed/replaced views cannot finish a stale handoff. Restored tabs also wait for scroll restoration. This is a public-API approximation: WebKit has no public first-composited-frame callback for WKWebView.

Scroll restoration reads back the viewport across two 50 ms settling checks. WebKit can acknowledge a scroll command at navigation completion and subsequently replace it with its history scroll position. Oriv reapplies the saved point up to three times, then accepts a legitimate clamp if the document is smaller. These checks run only during restoration and cancel on navigation/stop/close. The cover remains until they finish. Input passes to an already usable live document while the visual cover finishes its handoff; an unpainted or restoring document remains protected.

Favicon discovery is optional document work. It cannot access an unpainted, loading or restoring view, or a view whose destination cover remains visible. The cover's weak presentation marker clears when the handoff finishes, is replaced or is dismantled. Icon rows observe eligibility and retry after readiness without waking discarded tabs. Asynchronous icon work checks eligibility again before SVG rasterization, so a delayed download cannot execute JavaScript during a later handoff.

## Image lifetime and budget

Each browser session has an 8 MiB LRU cache. A snapshot is limited to 640 pixels on its longest edge and stored as JPEG at quality 0.65. Its budget charge includes compressed bytes **plus width × height × 4**, bounding potential decoded storage rather than just file size. Only visible covers decode images. Uniform unpainted images are rejected. Background capture uses updated pixels because navigation completion may precede drawing, but the asynchronous callback never delays selection. There is at most one capture in flight per session, with a 750 ms acceptance deadline. Navigation, close and pressure invalidate late results.

The existing iPhone All Tabs transition cache has a separate 24 MiB decoded budget. The combined retained-image allowance is therefore at most 32 MiB per mobile controller/session, excluding transient capture/encoding buffers and WebKit's own surfaces. Both caches purge on memory warning. This change preserves the existing grid transition path.

All images, including regular tabs, stay in memory: they are absent from session files, backups and continuity records. Closing a tab removes its image immediately, including any decoded cover. Session shutdown clears the cache. Memory pressure clears compressed and decoded images and invalidates pending captures. No snapshot is written to disk by the product. Test attachments contain synthetic fixtures only.

## Live tab policy

Normal Mac idle reclamation preserves the three most recently used instantiated tabs, even after ten minutes. Older eligible tabs are reclaimed first. The reserve is recomputed after asynchronous eligibility checks. Memory pressure can override the three-tab reserve while retaining the existing one-minute recent-use guard and all selected/pinned/private, edited-field, unsafe-request, media/capture and download exclusions. iPhone retains its existing eight-live-tab trim policy; its pressure path can trim to one and also purges the shared image cache. These are conservative targets: protected pages may keep more views alive.

WebKit's inactive scheduling remains `.throttle`. No speculative hover or keyboard-intent network loads are added. Restored background tabs remain lazy, and an image is never a reason to instantiate them. Public WebKit interaction state restores history/scroll; it is not a retained live document or a substitute for BFCache.

## Validation

`TabSnapshotTests` covers the decoded budget, LRU image eviction, bounded dimensions, blank-image rejection, transient private storage, invalidation and capture deadline. `TabSwitchRenderingTests` exercises live, discarded, launch-restored, private and heavy local pages; retains raw WebKit frames and native cover images as XCTest attachments; checks cover release without polling it; verifies decoded private images are dropped; and tests the Mac live reserve with real WKWebViews and a stable SwiftUI host.

Run `./scripts/check-browser.sh` and the `OrivMobile` Simulator test scheme with the loopback fixtures available. `scripts/tab-memory.py --product --label <label> --policies throttle discard pressure` measures the isolated probe's responsible-process tree. The `pressure` case injects the product policy only; it does not create system-wide pressure. `--reuse-app` permits exact saved-probe comparisons and `--focus-twenty` concentrates CPU sampling at 20 tabs. Reports belong in ignored `build/tab-switch/`.

Offscreen Mac snapshots and app-owned Simulator captures do not certify WindowServer compositing, physical-device frame pacing, foreground media, system fullscreen or energy usage. Retain those acceptance boundaries when reporting results.
