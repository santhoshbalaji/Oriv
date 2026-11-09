# Clean design and efficiency execution plan

Prepared 5 November 2026 from the [design and efficiency review](design-efficiency-review.md). It sits inside the [consolidated implementation plan](browser-implementation-plan.md), which still owns milestone order, the sync/privacy gates and the production release hold. Finding IDs (E1–E9, D1–D13) refer to the review. Sizes are relative (S: under a day, M: a few days, L: a week or more of focused work). No calendar dates are given until slices are sized against real progress.

## Principles

1. **Measure before and after.** Every resource change ships with a reproducible before/after run on the same hardware, OS, power state and workload. A lower number achieved by losing a form, media, call, download, private isolation or sync data counts as a failure.
2. **Remove work before tuning it.** Order of preference: avoid the work (no write when nothing changed), coalesce it, bound it, move it off the main thread. Caching comes last.
3. **Calm, not empty.** Keep the T3 Code dark backgrounds, the brand accent fill and native controls. Remove duplicated or dead-end paths; keep useful controls. Design opinions need owner sign-off before they ship.
4. **No sync-format change outside milestone 1.** The work packages in milestone 0 change local behavior only and stay compatible with installed development data.
5. **Each work package is one reviewable unit** with its own tests, captures and measurement record.

## Work packages

### WP0 Measurement harness · S · first

Makes the review's measurements repeatable and part of the repository, so later packages can prove their effect.

- Add `scripts/perf/`: the responsibility-attributed process sampler (`orivprobe.swift`, `window.py`), the light, ticker and animation fixtures, a heavier fixture (large DOM, images, timers), and `measure-mac.sh`. The script builds Release under the throwaway `local.personalbrowser.perfprobe` identity, serves fixtures on loopback, opens 1/10/30 tabs via URL routing, and writes JSON under `build/perf/`. It refuses to run against `local.personalbrowser.mac` or the development bundle IDs.
- Add a SwiftPM benchmark executable (`Packages/BrowserKit/Benchmarks/ContinuityBench`). It generates its own synthetic replicas instead of reading `build/`, and reports capture, idle-cycle, merge and persist medians. Report in CI, but don't fail on timing until variance is known.
- Add deterministic counting tests: an injected session store that counts saves, so write behavior is asserted without timing.
- Document Instruments runs (`xcrun xctrace record` with Time Profiler, SwiftUI, Allocations and Energy Log) in `docs/testing.md`.

**Done when:** a fresh run reproduces the review baseline within ±10% under the same conditions, and the benchmark and counting tests run in `scripts/check-browser.sh`.

### WP1 Session persistence without churn (E1) · M · milestone 0

Files: `BrowserTab.swift`, `BrowserSession.swift`, `SessionFileStore.swift`, Mac and iPhone controllers.

- Separate persisted tab state (URL, title, pin) from UI-only state (progress, loading, back/forward, security, capture). `refresh()` notifies persistence only when the tab's `record` actually changed.
- Two save classes:
  - Structural changes (tab added, closed, selected, moved or pinned; URL change; bookmarks; history) keep the 350 ms debounce, with a maximum delay of 2 s so a stream of changes cannot postpone the save indefinitely.
  - Title-only changes coalesce to at most one save per 60 s.
  - Background, profile switch and terminate flush immediately (these paths already call `saveNow`).
- Skip the write when the encoded snapshot equals the last durable one.
- Encode compactly instead of pretty-printing. Rotate the backup at most once per launch, and only from a primary that decodes. Never decode the old file on every save.
- Move encoding and writing to an ordered writer actor that keeps only the latest pending snapshot.
- Keep synchronous, throwing writes for `applyContinuity` and termination: an incoming sync change must stay durable before it is acknowledged.
- Fire `onContinuityChange` only after a real write.

Tests (counting store):
- Progress/loading churn produces 0 saves.
- 60 title ticks in 60 s produce at most 1 save.
- A URL change produces 1 save within 2 s.
- An identical snapshot produces no write.
- A corrupt primary never overwrites the backup.
- Terminate writes the latest state.
- A failed asynchronous write surfaces the existing persistence notice and pauses saving.

**Done when:** the ticker fixture's app disk writes fall from about 960 KB/min to at most one coalesced session write per minute, the 30-tab idle run stays at 0 writes, and relaunch restores the last title and tab set.

### WP2 Automatic recovery from content-process termination (E5) · S–M · milestone 0

Files: `BrowserTab.swift`, plus the error presentation in `BrowserWindow.swift` and `MobileBrowserView.swift`.

- Record termination as state (`contentProcessTerminated`, time). Record the HTTP method of the last committed main-frame navigation from `decidePolicyFor`.
- Visible tab: reload once immediately. Background tab: reload once when it is selected.
- Do not auto-reload these; show a clear message with a Reload button instead:
  - tabs with edited fields;
  - POST results;
  - a second termination within 30 s of an automatic reload.
- Clear the state on successful commit.

Tests: unit tests drive the delegate callback directly (no private WebKit calls in the product). They cover the visible, background, edited, POST and loop-guard paths. Owner check on the physical iPhone: open many heavy tabs, background the app, return to old tabs.

**Done when:** a terminated background tab returns to its page without an error screen, and an edited or POST tab never reloads silently.

### WP3 Handoff correctness and efficiency (milestone 0 + E6) · S

Files: `BrowserContinuity.swift`, `ContinuityViews.swift`, `BrowserProfiles.swift`, `MobileProfiles.swift`.

- Already planned in milestone 0: read the activity type from the bundle's `NSUserActivityTypes` and disable Handoff when it is absent. Queue one validated cold-start activity until the profile registry is ready. Separate account identity from transient sync health.
- Added: when only the title changes, update the current `NSUserActivity` in place (`title`, `needsSave`). Recreate it only when the URL, profile or eligibility changes.

**Done when:** the metadata-consistency test passes for every configuration, the ticker fixture causes no activity re-creation, and warm and cold Handoff pass in both directions 5/5 on the physical pair (owner session).

### WP4 Text and surface tokens (D1, D2, D3, optional D8) · S · milestone 0

Files: `Theme.swift`, the 7 accent-as-text sites, the 2 address fields, and the 19 list and form containers.

- Change the T3 secondary text from `#818181` to `#A3A3A3` (6.61:1 on field, 7.49:1 on surface). Use it for placeholders too, so an empty field no longer looks filled. The owner chooses between `#A3A3A3` and `#999999` (5.85:1 on field) as the closer match to T3 Code.
- Add `accentText` `#5B8CFF` for links and accent-coloured labels. Keep `#346BF1` for fills, the focus ring and selection. The Increased Contrast values stay `#79A5FF` and `#B8B8B8`.
- Add one `rowBackground` role (the T3 surface), applied through a single `orivListStyle()` modifier to every List and Form. That replaces 15 scattered `listRowBackground` calls and fixes the four screens that render the lighter default fill.
- Optional, owner decision (D8): neutral toolbar glyphs, with accent reserved for state.
- Add `scripts/check-contrast.py`. It computes every text token against every T3 surface it can appear on and fails below 4.5:1. Add it to `check-browser.sh`.

**Done when:** the contrast check passes, fresh Simulator captures show consistent rows and readable placeholders, and VoiceOver plus Increased Contrast are checked on the changed screens.

### WP5 Truthful copy and dead ends (D4, D7, D11 defects, D12, scope copy) · S–M · milestone 0

- **Other devices.** Give each state its own message and action:
  - Unavailable in this build: explain why, with no action.
  - Off: "Set up Mac & iPhone", opening Continuity settings (iPhone: a navigation push inside Library; Mac: `openSettings` on the Continuity tab).
  - Waiting for the first sync.
  - No other devices.
  - A search with no matching tabs.
- **Blank tab.** Hide site information and reload instead of disabling them, on both platforms.
- **Suggestion action.** Resolve the typed text with `AddressResolver` and label the row "Go to host/path" or "Search DuckDuckGo for “…”".
- **Mac defects.** Make the sidebar footer one labeled Settings button. Size the suggestion popover to the address field's width.
- **History and start-page rows.** Omit the subtitle when it repeats the title, which also fixes the duplicated VoiceOver label.
- **Scope copy (milestone 0).**
  - Appearance, profile and preference wording says what syncs.
  - Clearing and reset dialogs state their effect on other devices.
  - The Handoff toggle is disabled when unavailable.
  - Correct `design-system.md`, `appearance.md` and `design-direction.md`.

**Done when:** each empty state is captured and has a working action, the strings are reviewed against actual sync scope, and the native UI tests cover the new action routing.

### WP6 Efficient continuity work (E2, E3, E9) · L · milestone 1

This builds on the milestone 1 model specification (bounded identity, retention, versioning).

- **Dirty tracking.** `put` records changed keys in a persisted dirty set. Push sends only dirty keys plus conflicts, and clears them on server acknowledgement. Remove the decode-everything comparison in `push`.
- **Changes-only fetch.** Fetch returns only changed records. Skip merge and apply when there are none.
- **Profile-level dirty flags.** Only profiles whose durable snapshot changed are captured. Clear ranges are indexed once per capture.
- **One persist per cycle.** Encoding and writing happen off the main actor, keeping the transaction order before incoming changes are applied.
- **Profile adapters (E3).** A `ProfileDataSource` reads and writes an unloaded profile's session file and preference suite without constructing `BrowserSession` or WebKit objects. It hands off to the live controller when that profile loads, so the two never write concurrently.
- **Indexed views (E9).** Keep per-device/profile tab indexes current on merge. Expose narrow observable status values instead of the whole replica struct.

**Done when:** the benchmarks show a no-change cycle under 5 ms of main-thread time on the M4 Pro (from 397–595 ms) and capture/persist distributions are recorded. App footprint and launch with five profiles stay within 10% of one profile. All existing continuity tests pass, plus the migration fixture from the installed development format.

### WP7 Remove polling (E2 completion) · L · milestone 2

As specified in the consolidated plan: CKSyncEngine with persisted state, push entitlements and background completion. Efficiency gate: an idle hour with both apps open shows no periodic sync work, writes or request bursts. Measured with the WP0 sampler plus request logging.

### WP8 Navigation that reaches continuity quickly (D5, D10) · M · milestone 3

- **Library.** Opens directly to segmented Bookmarks / History / Other devices / Downloads and remembers the last segment. The current iPhone menu screen is removed.
- **Start page.** When sync is on, a compact "From your Mac/iPhone" row shows the other device's three most recent tabs.
- **Mac.** A View-menu command and shortcut for Other devices.
- **Tabs sheet.** The profile row becomes a real profile switcher, or plain header text. Close glyphs use the secondary color; swipe-to-close remains.
- **Remote tab in another profile.** Shows a brief profile-switch notice with a way back (already planned).

**Done when:** a remote tab is reachable in one tap from the start page and two from Library. The changed flows pass VoiceOver, the largest text size, landscape and the smallest iPhone.

### WP9 Memory reclamation and rendering cost (E4, E7, E8) · L · milestone 5

- **Policy (`TabResourcePolicy` in `BrowserEngine`).** A background tab becomes eligible after an idle threshold, starting at 10 min on Mac and 5 min on iPhone; the final values are set from measurement. Memory pressure lowers the threshold: `DispatchSource.makeMemoryPressureSource` on Mac, the memory-warning notification on iPhone. Never eligible:
  - the selected tab;
  - tabs playing media (checked with `requestMediaPlaybackState`);
  - tabs using camera or microphone;
  - tabs with edited fields or an active download;
  - tabs used within the threshold.
- **Discard.** Save `interactionState`, title and URL, then release the web view. **Restore** on selection from `interactionState`, which also restores back/forward history for relaunched tabs.
- **Rendering (E7).** Move the progress bar into leaf views on both platforms and coalesce KVO callbacks to one main-actor hop.
- **Address editing (E8).** iPhone suggestions become an overlay above the page instead of replacing it. Verify with playing video and a scrolled long page.

**Done when:** heavy-fixture and recorded real-site runs at 1/10/30 tabs show the recovered memory after the threshold, with zero loss of forms, playback, calls or downloads. Tab-switch latency p50/p95 does not regress (Instruments), and memory-pressure and four-hour soak runs are recorded.

### WP10 Visual polish after Mac captures (D6, D8, D9, D11 duplicates, D13) · M · milestone 5

> Visual pass 1 (5 Nov 2026, uncommitted) implemented the UI parts of WP4, WP5 and WP10. Follow-up rounds, with council scoring after each, are in the [visual polish plan](visual-polish-plan.md).

Needs Mac captures first, then owner review of a short before/after board.

- Start page leads with continuation and recent items; identity is reduced to a quiet profile chip shown only when there are several profiles.
- The page menu is grouped by frequency, with zoom as one control group.
- Mac paths are de-duplicated to one primary path per action, plus its menu command and shortcut.
- Settings explanations move to section footers.
- The bottom-address and collapsing-chrome experiments run only on the physical iPhone, with owner trials.

## Sequence

| Step | Work | Depends on | Can run alongside |
| --- | --- | --- | --- |
| 1 | WP0 harness, rerun baseline | — | — |
| 2 | WP1 persistence, WP2 recovery, WP3 Handoff | WP0 | WP4, WP5 |
| 3 | WP4 tokens, WP5 copy and dead ends | — | Step 2 |
| 4 | Milestone 0 review: tests, captures, measurement record, owner iPhone session | Steps 2–3 | — |
| 5 | Milestone 1 model spec, then WP6 | Step 4 | WP10 Mac captures |
| 6 | WP7 polling removal (milestone 2) | WP6 | — |
| 7 | WP8 navigation (milestone 3) | WP6 status values; WP7 for real delivery | — |
| 8 | WP9 reclamation, WP10 polish | Step 4; heavy workloads from WP0 | Production pilot preparation |

A privacy or data-loss defect found at any step takes precedence over this order.

## Owner decisions needed

1. Secondary text tone: `#A3A3A3` (recommended) or `#999999`.
2. Toolbar glyphs: neutral (recommended, calmer) or keep accent blue.
3. Start-page identity: reduce to a profile chip (recommended) or keep the app name and headline.
4. Whether to commit the current dirty worktree on this branch as a local baseline before WP0. This needs your explicit go-ahead; nothing would be pushed.

## Owner participation

- **Mac captures.** Grant screen-recording permission to T3 Code, make desktop control available, or supply screenshots. Needed for WP5 Mac acceptance and before WP10.
- **Physical iPhone (one batched session after step 4).**
  - Install the development build.
  - Background-tab termination and recovery.
  - Warm and cold Handoff in both directions.
  - VoiceOver and the largest text size on changed screens.
  - A 30-minute energy/thermal browsing run with the device's battery state recorded.
- **Existing external items, unchanged:** CloudKit Console login, push provisioning and the default-browser entitlement request.

## Definition of done for each work package

- Unit and native tests pass. Skipped tests are listed separately.
- The before/after measurement record is stored under `build/perf/`, and its summary goes in the package's documentation.
- Fresh captures of every changed screen. iPhone from the Simulator; Mac once captures are available.
- Truthful documentation updates, with no claims beyond the evidence.
- No change to installed apps, stable data or cloud state, and no publication without a separate request.
