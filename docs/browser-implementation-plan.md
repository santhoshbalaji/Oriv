# Oriv browser implementation plan

Reconciled review, 5 November 2026. Based on the current uncommitted implementation, an independent Claude Opus 5.5 review at high effort, and a second source, artifact and model review by the parent agent.

Oriv has a working browser foundation and implemented browser-continuity infrastructure. It does not yet meet the seamless-sync requirement or the production-installation gate. The first priority is reliable, inexpensive continuity with understandable recovery, followed by broader daily-browser capability. The production release hold remains in place.

This is an implementation plan, not a record of completed fixes. This review changed no application source, installed app, user data or cloud state. The current implementation is described in [Browser continuity](browser-continuity.md).

## Product contract

- Keep Oriv browser-first on Mac and iPhone. Preserve the T3 Code dark appearance and native platform interactions. Workspace, AI, tasks, trackers and source monitoring remain outside scope.
- After one-time opt-in, bookmarks, recent history, profile metadata, regular-tab snapshots and supported preferences update without routine manual sync. Reconnection and foreground return trigger automatic catch-up. Local browsing remains usable offline and without iCloud.
- Handoff opens a new regular tab in the matching profile. It never replaces a live tab or its edited form. Other-device tabs remain snapshots, not remote control.
- Cookies and login sessions, private tabs, form drafts, downloaded files and OS permission grants remain local. Apple Passwords/Keychain manages credentials independently. Synced site rules may ask or block; they cannot grant OS access.
- No data silently moves between iCloud accounts. Preserve stable Oriv data and provide an explicit, tested upgrade and rollback path.
- Seamless means automatic and resilient, not guaranteed instantaneous delivery. iOS background notifications are opportunistic; the app must catch up automatically after suspension, missed pushes or force-quit/relaunch. [Apple background delivery rules](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app).

## Clean design and resource efficiency requirements

The owner additionally requires a clean UI/UX and very efficient RAM, CPU and other resource use. These are acceptance criteria across all milestones, not optional polish after sync. The continuation session must extend the review in these areas before finalizing implementation slices.

For design, retain the requested T3 Code palette and native Mac/iPhone behavior while reducing visual and interaction overhead. Audit address/search hierarchy, tab/profile navigation, Library/other-device discovery, toolbar density, spacing, typography, sheets, feedback and recovery. Make privacy/origin cues and destructive scope clear. Identify duplicated affordances and unnecessary steps using actual tasks; do not remove useful controls merely to create an empty screen. Use fresh captures from the current build and distinguish subjective proposals from observed usability defects. Verify keyboard/VoiceOver, Dynamic Type, touch reach, narrow/landscape layouts and contrast before calling the result clean and accessible. Bottom-address placement remains an experiment requiring device evidence.

For efficiency, measure the complete browser process group, including WebKit content/network/GPU processes, and separate browser overhead from site workload. Use Release builds, named hardware/OS, controlled pages, warm/cold conditions and repeated measurements. Compare the current build with candidates under identical conditions; a Safari comparison is useful only with equivalent settings and workload, and does not establish engine parity.

| Dimension | Required analysis and evidence |
| --- | --- |
| RAM | Physical footprint, steady/peak usage, retained memory after tab close, multiple profiles, 1/10/30 loaded tabs, memory-pressure behavior and long-session growth. Confirm whether WebKit process sharing affects attribution. |
| CPU and wakeups | Idle versus page activity, background/minimized app, title/progress churn, timers, observation callbacks, persistence and sync. Separate main-thread stalls from total CPU time. |
| Energy and thermals | Sustained browsing, media, sync and idle runs on Mac and the physical iPhone; record power/thermal state and battery conditions. Simulator energy is not phone evidence. |
| Responsiveness and rendering | Cold/warm launch, address typing, suggestions, tab/profile switches, sheet presentation, scrolling and frame hitches. Report p50/p95 and meaningful worst cases. |
| Disk and storage | Bytes/writes per change, whole-file rewrites, history/tombstone growth, caches, logs, temporary downloads and cleanup after cancellation/relaunch. |
| Network and sync | Requests, bytes, retries, coalescing, incremental restart and offline convergence; no redundant unchanged uploads or high-frequency idle polling. |

The first assessment is in [Clean design and resource efficiency review](design-efficiency-review.md). It used an isolated Release Mac build (M4 Pro, macOS 27.0.1, on battery), attributed all WebKit helper processes, ran component models, and captured fresh iPhone Simulator screens. Summary:

- **Measured.** Idle is efficient: 62 MB, 0.05% CPU and no writes before a page loads. Light pages cost 144 / 289 / 586 MB at 1 / 10 / 30 loaded tabs. Each loaded tab keeps a WebContent process until it is closed, while relaunch restores lazily (31 tabs → 140 MB). A single title that changes every second caused about 1 MB/min of session rewrites. A no-change continuity poll costs 397–595 ms of main-actor work at 2,354–4,001 records.
- **Source.** Enabling sync instantiates every profile's full browser stack. A terminated content process becomes an error page instead of an automatic reload. Handoff recreates its activity on each title change. Load progress invalidates the root window body.
- **Observed design defects.** Placeholders use the main text color; accent text contrast is low on sheet rows; row surfaces are inconsistent; the Other devices empty state is a dead end; Library adds a navigation level; blank tabs show disabled page controls.
- **Not yet available.** Mac captures (screen-recording permission and desktop control were unavailable), Instruments latency traces, heavy real-site workloads, memory-pressure runs and any physical-iPhone resource evidence.

Set realistic absolute and regression budgets after collecting the baseline. The review proposes initial gates for persistence churn, idle sync work, app idle cost and multi-profile overhead; confirm them on the named devices before enforcing them. Each optimization needs a before/after result and correctness checks: preserve forms, playback, calls, downloads, profile/private isolation and reliable sync. A lower memory number achieved by losing state is a failure. Prioritize event coalescing, bounded data, incremental work, resource lifetime and background scheduling before decorative animation or complex caching.

## Review findings and reconciliation

| Area | Agreed finding and priority | Qualification or change to Opus's recommendation |
| --- | --- | --- |
| Release Handoff | **Release blocker.** Runtime defaults to the development activity type while the release configuration declares the release type. | Confirmed from source configuration. Production runtime failure was not exercised. Resolve configuration centrally and test every build configuration. |
| Sync growth and cost | **Release blocker.** Per-visit UUIDs and permanent closed-tab/history tombstones grow with lifetime use. Capture and persistence run on the main actor. | Move this ahead of production and push delivery. Reusing URL identities alone does not bound unique-page history or deletion metadata. The proposed nine-month failure date is an extrapolation, not a measured lifespan. |
| Automatic delivery | **Release blocker for seamless continuity.** No push integration, background completion guarantee or reconnect policy; change-token/cache state is process-local. | “Nothing syncs outside the foreground” is too absolute: a scheduled task can still run after focus changes. Durable local records/journal already exist; only incremental transport progress is lost at relaunch. Last-edit failure frequency on the phone is unmeasured. |
| Cold-start Handoff | **High.** Incoming activities are discarded while account verification is false; any sync error clears that flag. | Queue validated activities and separate transient transport failure from account identity. Keep opt-in, private-page exclusion and account-change protection. Do not simply remove all account gates or silently expire a user action. Cold-start loss is source-inferred, not physically reproduced. |
| Recovery | **High.** Account mismatch, reset, unsupported format and capacity failures lack a usable recovery path; status is buried in Settings. | A local library can include content imported from the previous account. “Use this account” must not blindly upload that library into another account. Reset, account switch and device removal have different consequences. |
| Concurrent preferences | **High correctness issue.** Entire site-rule and blocker-exception maps resolve as single values, losing independent concurrent edits. | Ordinary scalar settings already have separate records. Use per-origin/per-field conflict handling where needed, not a universal settings rewrite. |
| Mixed app versions | **High.** One unsupported record prevents the complete batch from syncing. | Tolerate declared optional extensions without altering them. Unknown deletion/security semantics must still stop the affected operation. Unconditionally replaying arbitrary opaque future records is not a safe compatibility policy. |
| Upgrade identity | **High verification gap.** A signing change may affect access to existing data even when the bundle ID is retained. | Keeping the ID is an intentional preservation strategy, not itself a defect. Test the upgrade before considering a new ID. The container's historical `.dev` suffix does not make its Production database a development database. |
| UI scope and accessibility | **Required fixes.** Settings imply device-local preferences; deletion dialogs omit synced effects. Normal accent text fails the chosen contrast target on some surfaces. | Retain the palette, add semantic text colors, and distinguish synced site rules from local OS grants. Current rendering still needs fresh acceptance. |
| CI and platform claims | **Required evidence work.** Release configuration, device lifecycle and full compatibility remain uncovered. | The workflow runs shared/Mac checks and an iPhone simulator **build**, not iPhone tests. iPad family support is declared without acceptance; iPhone release lacks the default-browser entitlement. |

Source anchors: `BrowserContinuity.swift:36,69,95,147,187,226`; `BrowserContinuityRecords.swift:121,139,182,204,246`; `ContinuityCloudTransport.swift:35,44,76,108`; `ContinuityPreferences.swift:11`; `ContinuityViews.swift:20,47,117`; `Theme.swift:33`; `MobileSettingsView.swift:74,137`; `project.yml`; `.github/workflows/browser-quality.yml`.

The component review also identified an empty-result gap: `OtherDeviceTabsView` can show device headings without a “No matching tabs” state when search filters out every tab. Opening a remote tab from a different profile changes the active profile; it should provide a brief notice and a clear way back, without an unnecessary confirmation on every open.

## Evidence and limits

- Opus ran **31 shared package tests successfully** in an isolated scratch build. This does not test the real CloudKit transport or constitute current native/device acceptance.
- The parent independently reproduced **100 visits to one URL producing 101 records, 99 tombstones and one visible history item**. A separate model check reproduced lost independent edits in the map-valued preference envelope, and rejection of a version-2 record.
- The parent repeated capture on Opus's synthetic 4,001-record replica: **96.1 ms median over seven Release samples** for an unchanged capture. This substantiates component cost; it is not an Instruments measurement of a real page load or the iPhone. The production call path runs this work on the main actor.
- Independent color calculations confirm accent `#346BF1` on field `#1E1E1E` is **3.588:1**. A proposed text accent `#5B8CFF` reaches **5.271:1** on that field. Apply the [WCAG contrast calculation](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html) as a design target; token math alone is not native accessibility certification.
- Source configuration declares Production CloudKit and the release Handoff type, with no push entitlements. The release iPhone default-browser entitlement is absent. The browser-scope guard passes.
- Existing screenshots support the broad dark visual direction but predate some UI changes. No fresh live visual or physical-device acceptance was performed in this review.

Local evidence: `build/browser-review-20261105/opus-review.md`, `core-tests.log`, `parent-probe.log`, `parent-static-verification.json` and the probe sources. These are ignored review artifacts. The findings and implementation gates are retained here so the plan does not depend on retaining a build directory.

## Execution order

| Milestone | Deliverable | Dependencies | Completion gate |
| --- | --- | --- | --- |
| 0 | Handoff correctness, truthful copy and readable controls | None | Configuration checks, cold-start state tests and updated UI acceptance |
| 1 | Bounded, efficient, compatible sync model | 0 may proceed alongside it | Growth, conflict, erasure, migration and responsiveness checks |
| 2 | Automatic continuity delivery | Stable model and persistence contract from 1 | Two-device foreground/background/reconnect matrix |
| 3 | Understandable status, recovery and device management | Model/recovery contract from 1; real delivery from 2 | Fault-injection and accessible recovery acceptance |
| 4 | Signed production continuity pilot | 0–3 plus core privacy/accessibility/upgrade checks | Production-schema, physical-device and safe-upgrade gates |
| 5 | Complete the daily-browser backlog | Measurements can start now; changes follow continuity priority | Capability-specific evidence and secure maintenance |

Design and efficiency work is assigned to these milestones by dependency, not deferred to the end. Finding IDs refer to the [design and efficiency review](design-efficiency-review.md).

| Milestone | Added design and efficiency scope | Gate |
| --- | --- | --- |
| 0 | E1 write-if-changed persistence, title coalescing, compact off-main writes. E5 automatic recovery from content-process termination. E6 in-place Handoff updates. D1–D4 text/row tokens and a working Other devices empty state. D7 hide blank-tab controls, D12 explicit suggestion action, D11 Settings hit target and suggestion width. | Ticking-title fixture: no write per tick, at most one coalesced title write per minute. A killed background tab reloads once, never for edited-field or POST pages. Token contrast at least 4.5:1 on every T3 surface. Fresh captures and VoiceOver labels for changed screens. |
| 1 | E2 dirty-key capture/push, a single off-main persist per cycle, no apply when nothing changed. E3 profile adapters that do not construct WebKit stacks. E9 indexed device/profile views. | Checked-in idle-cycle and capture benchmarks. No-change cycle under 5 ms main-thread on the M4 Pro. Five-profile launch footprint within 10% of one profile. |
| 2 | Remove 30 s polling with CKSyncEngine. | An idle hour shows no periodic sync work, writes or request bursts. |
| 3 | D5 segmented Library, start-page continuation row, Mac Other devices command. D10 Tabs sheet profile switcher. | Fewer steps to reach a remote tab: start page one tap, Library two. VoiceOver and largest text checks. |
| 5 | E4 safe reclamation with `interactionState`. E7 leaf progress views. E8 overlay suggestions. D6, D8, D9, D13 polish after Mac captures and owner review. Bottom-address experiment. | Heavy-page 1/10/30-tab and memory-pressure runs show recovery without losing forms, media, calls or downloads; latency p50/p95 does not regress. |

The step-by-step work packages, owner decisions and done criteria are in the [design and efficiency execution plan](design-efficiency-plan.md).

Measurement protocol for every resource change: Release build; named hardware/OS and power state; the loopback fixtures plus a recorded real-site set; app-attributed process group via responsibility; at least five before/after windows; report median and spread. Add Instruments (Time Profiler, SwiftUI, Allocations, Energy) for latency and invalidation, and run physical-iPhone checks with the owner. The Simulator remains visual evidence only.

Start the default-browser entitlement request and collect performance/privacy baselines early because they need lead time. Add CI checks with each milestone, not only at the end. Do not postpone a discovered privacy or data-loss defect behind a feature milestone.

### Milestone 0 Correctness and UI scope

Read the Handoff type from explicit build metadata and ensure it belongs to `NSUserActivityTypes`. Remove the accidental development default from production construction. Keep one bounded, validated pending Handoff request during launch; deduplicate delivery and bind it to the correct account/generation. A genuine account change invalidates it. Separate verified identity from transient CloudKit health so an unrelated transport error does not discard a valid continuation.

Update Handoff availability controls, appearance/settings wording, and clearing-data confirmations. Explain that synced history/site-rule changes propagate while cookies/cache/OS grants stay local. Introduce a readable accent-text role while retaining the requested dark backgrounds and button fill. Repair outdated scope statements in design/appearance docs.

Acceptance:

- Automated development/release metadata-to-runtime consistency checks for both apps.
- Incoming Handoff before readiness opens exactly one tab after validation, or reports a clear actionable failure. No private URL, invalid URL, stale-account or duplicate activity is opened.
- Warm and cold Handoff, both directions, five trials per condition on the physical pair. Transient cloud failures are distinguished from account mismatch. Pausing sync retains the current consent boundary until independently controlled Handoff is explicitly designed.
- Clearing dialogs describe effects on other devices before confirmation. Enabled/disabled Handoff controls reflect availability.
- Normal-size text meets the chosen 4.5:1 contrast target on its actual composited background; keyboard focus and disabled states remain distinguishable. Verify actual SwiftUI rendering and VoiceOver values.

### Milestone 1 Bounded and efficient sync data

First specify versioning, ownership, deletion and retention together. Keep opaque record identifiers; do not expose URL/origin hashes in unencrypted names. Reuse identity for retained history entries and maintain a bounded representation of device-owned regular-tab snapshots. Make legitimate record deletion distinct from a cloud-zone reset.

Retained user data may grow; synchronization metadata must not grow indefinitely with every past visit and tab. Define a supported offline horizon, acknowledgement/generation rules and a safe rejoin path before removing tombstones. A device outside that horizon must not re-upload deleted history or stale bookmarks when reseeded. Preserve its genuinely new offline changes separately. Identity reuse or a blanket 180-day expiry alone does not establish this guarantee.

Index clear ranges once instead of scanning all records for each history item. Capture only changed data, coalesce title-only updates and impose a maximum flush delay. Serialize persistence/merge work away from the main actor, retaining a durable transaction boundary before applying incoming changes. Split map-valued preferences by origin and, where necessary, rule field.

Define optional versus required future data. Older clients preserve optional unknown records without mutating or re-uploading them; unknown destructive semantics produce an explicit update-required state. Test migration from the already installed development format. Changes are not “free” merely because Production is unused.

Acceptance:

- Repeated-URL and unique-URL workloads, 100,000 visits, 15,000 tab creations/closures, multiple profiles and concurrent devices. Metadata stays within the documented retention bound; no lifetime-record-limit failure with a fixed retained library. Establish the numeric bound from that model rather than an arbitrary 5,000-record target.
- No erased history/bookmark resurrection after offline rejoin, compaction, reinstall, migration, out-of-order delivery or an interrupted apply. Test clock skew explicitly; time-range erase semantics must be documented rather than hidden by an arbitrary tolerance.
- Concurrent changes to different sites survive; conflicts on the same rule converge deterministically. Clear-all rules versus an offline rule edit has explicit semantics.
- Preserve v1 local data through migration and rollback fixtures; mixed-version clients cannot corrupt shared data or silently repopulate erased records.
- Proposed responsiveness target: continuity main-actor work stays below **4 ms p95 per browsing change** on a documented test iPhone; measure with Instruments. Treat this as a target to validate, not a current result. Record off-main capture/write distributions and memory separately.
- No work for unchanged payloads; title-only changes upload at most once per minute except an intentional handover flush. Local UI title updates remain immediate.

### Milestone 2 Automatic delivery

Prefer `CKSyncEngine` for scheduling, pushes and transient retry handling. Initialize it promptly on launch only for opted-in accounts, persist every state update, and supply the application-specific merge, account-isolation and reset rules. It replaces transport scheduling; it does not solve data modeling or recovery. [Apple's CKSyncEngine guidance](https://developer.apple.com/videos/play/wwdc2023/10188/).

Provision remote-notification capabilities for both signed apps and iOS background mode. Use a bounded completion opportunity for outgoing edits when backgrounding; persist pending work before suspension. Request timely foreground send/fetch through the engine where needed. Remove continuous foreground polling once push/catch-up coverage passes; avoid adding a duplicate custom retry scheduler. Persist transport state with the corresponding local application checkpoint so a crash cannot advance past unapplied records.

Acceptance targets on a named, healthy test network, measured over at least 20 trials per flow:

- Active-device changes visible remotely at p50 ≤5 seconds and p95 ≤20 seconds without manual Sync now. These are product test targets, not CloudKit service guarantees.
- Save on iPhone and background within one second: delivery to the active Mac within 30 seconds in at least 19/20 trials; otherwise investigate before claiming seamless handover. Unsent work survives suspension and retries automatically.
- Suspended iPhone: record push delivery separately. On foreground return, no manual action is needed; catch-up begins immediately and meets the foreground target when service/network is available. Do not require or promise every suspended app to have prefetched the data.
- One-hour offline edits, reconnect, force-quit/relaunch, sleep/wake and network changes converge automatically with no lost edits or excess retry loops. Respect server retry timing.
- Normal relaunch uses incremental progress. An idle hour has no fixed 30-second polling and no repeated unchanged writes. Report actual requests, CPU and energy.
- Fault injection covers token expiry, partial batch failure, rate limit, quota, account changes, missing zone and encrypted-key reset. Verify fresh-account versus previously-used-store recovery separately.

### Milestone 3 Continuity UX and recovery

Use explicit states: Off, Up to date, Syncing, Waiting for connection, and Needs attention. Show pending local work and last successful sync honestly. Put actionable failures in Other devices and a quiet navigation badge; avoid modal interruptions for ordinary offline use. Distinguish local sync health from each remote device's last-seen timestamp.

Make Other devices directly accessible on Mac and easy to find from the iPhone Library; a compact start-page continuation row is appropriate. Keep it browser-focused. Add no-match/empty states, useful device names, stale-device labeling/removal and brief profile-switch feedback. Provide Large Content Viewer where compact iPhone toolbar icons need it.

Recovery actions must match the failure:

- **Account changed:** preserve/quarantine the old account's replica and stop its uploads. Rebind with an explicit clean-account or reviewed transfer choice; do not seed from an undifferentiated library that contains the previous account's imports. Merge an existing destination account rather than replacing it.
- **Cloud copy reset:** explain the reset and offer a reviewed rebuild from preserved data. Coordinate a new generation so other devices cannot resurrect the old cloud state. Local or cloud deletion is never an automatic repair step.
- **Device removal:** distinguish hiding a stale listing from disconnecting an installation. Old installs must not silently republish removed tabs; define re-enrolment behavior.
- **Unsupported/corrupt local format:** preserve original bytes and provide update/recovery guidance. Do not overwrite the store in an attempt to clear the error.

Acceptance: inject each state; confirm it is visible and actionable, VoiceOver reads the current status/timestamp, destructive scope is explicit, and no cross-account upload or erased-data resurrection occurs. Test largest text size, narrow phone, landscape, keyboard navigation, Reduce Transparency and Increased Contrast on the changed flows. Keep normal browsing available throughout.

### Milestone 4 Production continuity pilot

Keep committed team settings blank and configure the contributor's own team locally. Preserve application identifiers unless an evidenced upgrade problem requires a deliberate migration. Validate any signing transition using synthetic data in a separate test environment, then a supported backup and restoration rehearsal. Do not probe or bypass protected live containers. Preserve legacy Personal records as well as active browser data.

After the model is stable, configure the contributor's own CloudKit container and schema, build both release configurations with correct Handoff/push settings, and verify signatures, entitlements and distribution requirements. Test Development-to-Production separation and explain any intentional data seeding; never assume Development cloud data appears in Production.

Installation gate:

- Core privacy/isolation and accessibility regressions pass; no known data-loss or account-boundary defect remains.
- Production builds pass two-way bookmark/history/profile/preference/tab delivery, deletion/Undo, concurrent/offline/relaunch, account/reset recovery, private exclusion and warm/cold Handoff.
- Upgrade preserves existing profiles, bookmarks, sessions and website stores; failed-upgrade rollback is rehearsed without restoring erased cloud data.
- Release configuration consistency checks and native tests pass; skipped or unavailable device capabilities are recorded separately.
- Only then consider an explicitly authorized production installation, reporting the exact version and remaining capability limitations. Default-browser approval and broader compatibility are separate gates for a full daily-browser release.

### Milestone 5 Broader daily browser work

| Workstream | Planned work | Acceptance evidence |
| --- | --- | --- |
| Privacy and security | Audit app-originated networking with sync off/on; verify TLS failures, tracking protection/exceptions, profile/private storage, permission denial/revocation and erase behavior. | Attribute observed requests; distinguish website/platform traffic. Confirm no optional cloud work before opt-in and no private records in persistence, sync or Handoff. Do not assume a Safe Browsing service is enabled without evidence. |
| Whole-browser performance | Cold/warm launch, navigation/tab latency, idle CPU, energy and memory including WebKit subprocesses at 1/10/30 loaded tabs. | Named hardware/OS, repeatable fixtures and distributions; baseline before budgets or speedup claims. Include background sync and longer browsing sessions. |
| Resource and crash recovery | Safe background-tab reclamation, recoverable WebContent crashes and session history where platform support permits. | Protect edited forms, playback, calls and downloads. Use bounded recovery, avoid POST resubmission or reload loops; explain unrecoverable state. Do not promise website form persistence. |
| Web compatibility | OS/WebKit capability matrix, selected applicable WPT coverage and real-site auth/passkeys/AutoFill, OAuth/popups, uploads/downloads, media/fullscreen/PiP/DRM, conferencing, service workers/offline and storage/security behavior. | Record passed/failed/skipped/unavailable per OS and signed configuration. No blanket Safari parity or standards-conformance claim from WKWebView use. Establish DRM support per platform/provider. |
| Daily navigation | Independent Mac windows and tab moves with explicit per-window/profile ownership; HTTP/HTTPS and Handoff routing. | Moving a tab preserves its WebKit state; no form loss, cookie-store mixing or accidental duplicate restore. This is a larger milestone after continuity. |
| Downloads | Persist completed-download metadata and safely resumable state; durable mobile Save to Files and clear interruption/retry behavior. | Relaunch, partial files, permission loss, unavailable resume support and cancellation tested. Downloads stay outside sync; no cross-device credentials or resume blobs. |
| Default browser and devices | Request Apple's managed default-browser entitlement; verify signed iPhone routing/service workers and Mac URL routing. Explicitly decide iPad support. | Approval plus actual signed behavior, not an entitlement string alone. Restrict first release to iPhone or complete iPad layout/accessibility acceptance; current family declaration is insufficient. |
| Accessibility and ergonomics | VoiceOver, Full Keyboard Access, Dynamic Type, contrast/transparency/motion, touch targets, smallest phone and landscape. | Fresh visual/interaction evidence for all principal sheets and error states. Bottom address placement and collapsing chrome remain optional measured experiments. |
| Maintenance and distribution | Add actual iPhone native tests to CI, release metadata/entitlement checks, deterministic sync regressions, controlled benchmarks and a secure update path. | Review/commit the dirty scope in coherent units, obtain remote CI evidence, and verify signed update/rollback behavior. No secrets or personal captures in commits; publication is a separate action. |

Use [Apple's default-browser requirements](https://developer.apple.com/documentation/xcode/preparing-your-app-to-be-the-default-browser) and the [Web Platform Tests project](https://web-platform-tests.org/) as acceptance inputs. Browser behavior depends on the shipped OS/WebKit and granted capabilities; experimental or unavailable APIs are not a checklist to enable blindly.

## External dependencies and completion boundaries

CloudKit Console authentication, push provisioning, Apple's default-browser approval and physical-device interaction are external dependencies. Local implementation, fixtures, migration design and most regression tests can proceed without waiting for them. Physical checks require compatible test devices and an explicit test scope.

“Implemented,” “locally tested,” “verified on both physical devices,” “Production cloud verified,” “installed,” “remote CI passed,” and “published” must remain distinct. The next implementation slice is milestone 0 with its added efficiency and design scope, in this order:

1. Correct Handoff configuration and queue cold-start activity.
2. Persistence write-if-changed with title coalescing.
3. Automatic content-process recovery.
4. Text and row theme tokens.
5. Truthful copy and dead-end fixes.

Then the milestone 1 model/persistence specification with growth, idle-cycle and multi-profile benchmarks. Mac captures need screen-recording permission for the T3 host, available desktop control, or captures from the owner. No estimated dates are assigned until those bounded tasks are sized.
