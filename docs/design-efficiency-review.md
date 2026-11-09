# Clean design and resource efficiency review

5 November 2026, Claude Opus 5.5 (high effort), on the current uncommitted worktree. This extends the [reconciled implementation plan](browser-implementation-plan.md) and the completed independent review. It does not repeat that review's sync, privacy or release findings. No application source, installed app, user data or cloud state was changed. The stable Oriv apps, the development apps and the physical iPhone were not touched.

## Evidence labels

| Label | Meaning |
| --- | --- |
| **Measured** | Run during this review on the current source, with the conditions below. |
| **Observed** | Seen in a fresh capture of the current build on the iPhone Simulator. |
| **Source** | Confirmed by reading current code; not executed. |
| **Opinion** | A design judgement. It is not a defect and should be validated with the owner or real use. |

## How the evidence was produced

- **Mac.** A Release build of the current source, built under the throwaway identity `local.personalbrowser.perfprobe` (`Oriv-Perf-Probe`, ad-hoc signed, no iCloud container, so continuity was unavailable). It ran in its own new sandbox container and was launched in the background without taking focus. Pages came only from a loopback fixture server. Hardware: Apple M4 Pro, 24 GB, macOS 27.0.1 (26A434), Xcode 27.0. The Mac was **on battery at 38%**. That can lower the CPU and energy figures, so treat them as a baseline for this condition only.
- **Attribution.** A small tool groups every process macOS records as *responsible* to the app pid. That covers the app plus its WebKit WebContent, GPU and Networking processes and its audio and platform helpers. For each process it reads `proc_pid_rusage`: physical footprint, lifetime peak, CPU time, wakeups and disk bytes written. It needs no root access.
- **Component timings.** A separate release-mode probe links the real `BrowserCore`. It reuses the 4,001-record and 2,354-record synthetic replicas from the earlier review and replays the sequence of operations in `BrowserContinuity.syncNow`. Each figure is the median of 7 runs.
- **iPhone.** A Debug build of `OrivMobile` on the iPhone Simulator (iOS 27.0), driven through the T3 device tools. The Simulator supplies visual and interaction evidence only. Its memory, CPU and energy figures are not phone evidence.
- **Not available.** No Mac UI capture: the window-capture attempt was refused because screen-recording permission is absent, and no desktop-control tool was available. No Instruments traces, no physical-iPhone measurements, no heavy real-site workloads and no memory-pressure runs.

Raw outputs, tool sources and fixtures are in `build/design-efficiency-20261105/` (ignored by Git). The isolated container `Library/Containers/local.personalbrowser.perfprobe` relative to the local home directory holds only synthetic fixture session data and can be deleted.

## Measured resource baseline

Each row is a 30–60 s window taken after a settle period. The fixture page is light: about 40 paragraphs, no network subresources.

| Condition | Processes | Total footprint | WebContent | App process | CPU (all processes) | Disk written by app |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Launch, start page, idle | 3 | 62 MB | none | 45 MB | 0.05% | 0 |
| 1 loaded tab, idle | 9 | 144 MB | 1 × 30 MB | 53 MB | 0.02% | 0 |
| 10 loaded tabs, idle | 18 | 289 MB | 10 = 164 MB | 62 MB | 0.20% | 0 |
| 30 loaded tabs, idle | 38 | 586 MB | 30 = 428 MB | 92 MB | 0.44% | 0 |
| 31 tabs, one tab's title changes every second | 39 | 610 MB | 31 | — | 1.18% (app 0.45%) | **960 KB/min** (1.67 MB/min logical) |
| Relaunch with the same 31 tabs restored | 8 | 140 MB | 1 | 74 MB | 0.65%* | 480 KB/30 s* |

\*The restored, selected tab is the ticking-title page, so its churn continues.

Interpretation:

- **Idle is good.** Before a page loads there is no WebKit process, CPU is near zero, and there are no writes or wakeups. At 30 idle tabs there were about 29 interrupt wakeups/s (WebContent 18, GPU 5.7, app 5.1). WebKit's `inactiveSchedulingPolicy = .throttle` is set.
- **Each loaded tab keeps its own WebContent process until the tab is closed or the app quits.** Between 10 and 30 light tabs the cost was about 13 MB per tab, and the app process grew by about 1.6 MB per loaded tab. Lazy restore works: the same tabs after relaunch use one content process and 140 MB instead of 586 MB. There is no reclamation while the app keeps running. Real sites cost far more per tab, so heavy-page numbers are still needed.
- **Title churn becomes disk churn.** The ticking title alone moved the app from 0 to about 1 MB/min of physical writes. That matches a full rewrite of `session.json` plus its backup about once a second. The test session was only 13 KB. Write volume scales with session size: a full 500-entry history means a much larger file, and the resulting write rate is an **estimate, not measured**. With sync on, each of those saves also runs the continuity capture and persistence described below.

## Measured continuity cost at idle (component model)

These figures replay the work one foreground poll performs when **nothing changed remotely**. Network time is excluded. Release build, M4 Pro, median of 7 runs.

| Step in `syncNow` | 2,354 records | 4,001 records |
| --- | ---: | ---: |
| Capture before fetch | 65 ms | 96 ms |
| Five full replica writes per cycle | 94 ms | 147 ms |
| Fetch decodes the entire server cache | 18 ms | 28 ms |
| Capture again, then merge every record | 137 ms | 198 ms |
| Apply step scans (bookmarks, history, preferences) | 65 ms | 94 ms |
| Push decodes every server record again to compare | 18 ms | 28 ms |
| **Total per idle cycle** | **397 ms** | **595 ms** |

The app runs this on the main actor every 30 s while foregrounded, which averages about 1.3–2% of one core. If those steps run back to back without yielding, the result is a 0.4–0.6 s main-thread stall each cycle on this M4 Pro (inferred from the component total). Phone performance is unmeasured and requires a separate device baseline. Cost scales with **total records, including tombstones**, not with live data: both replicas hold the same 500 history pages, 200 bookmarks and 10 tabs.

A hypothesis tested and refuted: assigning an identical value to an `@Observable` property does **not** notify observers with this toolchain. The unconditional property writes in `BrowserTab.refresh()` are therefore not a re-render cost.

## Efficiency findings, ranked

| # | Finding | Evidence | Change |
| --- | --- | --- | --- |
| E1 | **Session write amplification.** Every KVO change re-arms the save timer: title, URL, loading, progress, back/forward, security or capture state. Each save pretty-prints the whole snapshot, then reads and fully decodes the previous file, then atomically writes the backup and the new file. Progress, loading and security state are not even persisted. | Measured (above). `BrowserTab.swift:111-120,207-220`, `BrowserSession.swift:271-293`, `SessionFileStore.swift:47-63` | Write only when the persisted snapshot changes. Coalesce title-only updates (maximum one per tab per 60 s, plus a flush on background or close). Use compact encoding. Rotate the backup at most once per launch or interval, not on every save. Encode and write off the main actor with an ordered writer. |
| E2 | **Continuity idle cycle is proportional to lifetime records.** It repeats capture, makes five whole-replica writes and two whole-cache decodes, and runs a full merge on the main actor every 30 s. | Measured component model | Track dirty keys during capture and push only those. Fetch returns only changes; skip merge/apply when there are none. Persist once per cycle, off main. The record-identity bound (milestone 1) caps N. CKSyncEngine removes the poll (milestone 2). |
| E3 | **Enabling sync loads every profile's full browser stack.** `prepareSources` → `obtain` creates a controller for every available profile: session, restored tab objects, website data store, blocker and downloads. They are kept for the process lifetime, which defeats lazy profile loading on both platforms. | Source: `BrowserContinuity.swift:99-126`, `BrowserProfiles.swift:94-101`, `MobileProfiles.swift:35-39` | Capture and apply via a lightweight per-profile store adapter that reads and writes the persisted snapshot and preferences without constructing WebKit objects. Measure app footprint and launch time with one versus five profiles before and after. |
| E4 | **No in-session reclamation of background tabs.** | Measured: 428 MB in 30 WebContent processes during the session, versus one process after relaunch | Discard the web view of a background tab after an idle period, and sooner under memory pressure. Exclude audible or playing media, camera/microphone, edited fields, downloads, recently used and pinned-active tabs. Restore with `interactionState`, which also fixes the back/forward loss in restored tabs. Gate on E5. |
| E5 | **A terminated content process becomes an error page.** iOS reclaims background WebContent under memory pressure; returning to that tab then shows "This tab's website process stopped" instead of reloading. | Source: `BrowserTab.swift:244-247`, `activate()` only loads when `!hasLoaded` | Reload automatically once when a terminated tab is selected, or immediately when it is visible. Do not reload POST results or tabs with edited fields; guard against crash loops. Explain when recovery is not possible. |
| E6 | **Handoff republishes on every title change.** `ContinuityPage` equality includes the title, so each tick invalidates and recreates the `NSUserActivity`. | Source: `ContinuityViews.swift:104-129` | Update the current activity's title and URL in place. Recreate it only when the URL, profile or eligibility changes. |
| E7 | **Root-level SwiftUI invalidation on load progress.** `BrowserWindow` and `MobileBrowserView` read `tab.progress` in the root body, so every progress callback re-evaluates the toolbar, notices and sheet modifiers. Each KVO callback also spawns its own task. | Source. Cost unmeasured | Move the progress bar into a leaf view and coalesce KVO into one main-actor hop per run-loop turn. Confirm with SwiftUI update counts in Instruments. This is lower priority than E1–E5. |
| E8 | **iPhone address editing removes the page from the view hierarchy.** The web view is detached while the suggestions screen is shown, which may cause visibility-change side effects such as media pausing or a scroll or layout reset. | Source: `MobileBrowserView.swift:30-35`. Effect not reproduced | Show suggestions as an overlay above the page. Verify with a playing video and a scrolled long page. |
| E9 | **Other-device views rescan the whole replica.** Every render does multiple full scans for each device and profile. The root Handoff modifier observes the entire replica struct. | Source: `ContinuityViews.swift:52-93`, `BrowserContinuityRecords.swift:233-246` | Maintain per-device/profile indexes when records change, and expose narrow observable status values. Fold this into milestone 1's indexing work. |

## Design findings, ranked

The T3 Code dark palette, native controls, sheets and the current information architecture are kept. Items marked Opinion are proposals to validate, not defects.

| # | Finding | Evidence | Change |
| --- | --- | --- | --- |
| D1 | **Placeholders look like content.** "Search or enter address" uses the main text color (`#F5F5F5`), so an empty field reads as filled. | Observed (`1-home.png`). Source on Mac: `AddressField.swift:38-40` | Add a `placeholder/secondaryText` role of `#A3A3A3`: 6.61:1 on field, 7.49:1 on surface. The current secondary `#818181` is 4.28:1 on field, a fail. |
| D2 | **Accent used as text fails contrast** on surfaces and on the elevated sheet rows. | Calculated: `#346BF1` is 4.06:1 on `#111111`, 3.59:1 on `#1E1E1E`, and about 3.00:1 on the approximately `#2C2C2E` row fill. Observed in the sheets | Keep `#346BF1` for fills, the focus ring and selection. Add `accentText` `#5B8CFF` (5.97 surface, 5.27 field). It still falls short on `#2C2C2E` (4.41), so D3 is a prerequisite. |
| D3 | **Inconsistent row surfaces.** Settings rows use the T3 surface. The Continuity row, Tabs, Library and Other devices use the lighter default grouped fill. | Observed (`4-tabs.png`, `5-library.png`, `8-settings.png`) | Define one semantic row background role and apply it to every list and form. |
| D4 | **Dead-end empty state.** Other devices says to turn on sync in Settings but offers no action. In builds where sync is unavailable, it asks for something impossible. | Observed (`6-other-devices-empty.png`) | Add a primary "Set up Mac & iPhone" action. Use separate copy for unavailable, off, waiting-for-first-sync and no-other-device states. |
| D5 | **Library is an extra hop.** It is a menu of four rows, and Other devices sits three levels deep. On the Mac, Other devices has no menu command. | Observed. Source: `BrowserCommands.swift` | Open Library directly into a segmented Bookmarks / History / Other devices / Downloads view that remembers its last segment. When sync is on, add a compact "From your Mac/iPhone" row on the start page. Add a Mac View-menu item. |
| D6 | **The start page spends its first screen on identity.** The app name, profile and serif headline fill about a third of the screen. Once history exists there is no search affordance. Rows repeat the host as title and subtitle, and VoiceOver reads "127.0.0.1, 127.0.0.1". | Observed (`1-home.png`) and accessibility snapshot | Lead with continuation and recent items. Drop the subtitle when it equals the title. Show the profile as a quiet chip only when more than one profile exists. Keep one headline (Opinion). |
| D7 | **Disabled controls on a blank tab.** Site info and reload are shown disabled, and the disabled site button still announces "Connection information. Site settings". | Observed | Hide page-only controls until a page exists. |
| D8 | **The bottom toolbar is entirely accent blue.** | Observed | Use primary text for glyphs. Reserve accent for state, such as active downloads or selected (Opinion; calmer, and consistent with D2). |
| D9 | **The page menu has ten flat items,** including three separate zoom rows. | Observed (`7-page-menu.png`) | Order by frequency: Bookmark (showing its state), Share, Find. Put zoom in one inline control group, then tab actions, then Settings. |
| D10 | **Tabs sheet chrome.** "Profile: Personal" is a non-interactive row styled like a field, and every row has an accent close glyph. | Observed (`4-tabs.png`) | Make the profile a switcher, or plain header text. Use the secondary color for close glyphs and keep swipe-to-close. |
| D11 | **Mac duplication and small defects.** New tab appears in three menus or rows plus ⌘T, and New private tab in four places. History and Downloads appear in both the sidebar footer and the toolbar menu. The start page composer duplicates the toolbar field. Defects: the sidebar footer's "Settings" text is not part of the gear button, so only the icon is clickable; the suggestion popover is capped at 600 pt and is narrower than wide address fields. | Source: `BrowserSidebar.swift:55-61,75,113-126`, `BrowserWindow.swift:58,123-131`, `StartPage.swift:52-61` | Keep one primary path per action plus its menu command and shortcut. Make the footer a single labeled Settings button. Size suggestions to the field. Fresh Mac captures are required before any layout change. |
| D12 | **The address suggestion action does not say what will happen.** | Observed (`2-address-editing.png`) | Label it with the result: "Go to example.com/…" or "Search DuckDuckGo for …". |
| D13 | **Settings density.** Explanations are rendered as separate rows inside one long form. | Observed (`8-settings.png`) | Move explanations to section footers and group the privacy controls. The scope-copy corrections remain in milestone 0. |

Already planned and still valid: Large Content Viewer for the compact iPhone toolbar, Reduce Motion handling, truthful sync scope wording, the remote-tab profile-switch notice, and the empty Other devices search result.

## Proposed budgets

These budgets are derived from the measurements above. They must be confirmed with Instruments and physical-iPhone baselines before they become release gates. Unmeasured dimensions do not get invented numbers.

| Area | Proposed gate | Current |
| --- | --- | --- |
| Persistence churn | 0 session writes caused by progress or loading. At most 1 persisted title update per tab per 60 s. 0 bytes/min of app writes with static idle pages. | About 1 MB/min physical with one ticking title |
| Sync at idle | No per-cycle work proportional to total records when nothing changed. Target: under 5 ms main-thread time per no-change cycle on the M4 Pro, and no 30 s polling after milestone 2. | 397–595 ms per 30 s cycle (component model) |
| Main-thread work per browsing change | Under 4 ms p95 on a documented test iPhone (existing target) | Not measured on phone |
| App process idle | Under 0.1% CPU and under 60 MB with the start page; no idle wakeup regression | 0.03% CPU, 45 MB |
| App growth per loaded tab | Track; investigate if above 2 MB per tab | About 1.6 MB per tab (light page) |
| Reclamation | After the idle threshold, background tabs that pass the safety rules release their content process. The memory recovered is reported for a heavy-page workload. | No reclamation; 30 light tabs hold 428 MB |
| Multiple profiles with sync on | App footprint and launch time with 5 profiles within 10% of 1 profile | Not measured; source shows all profiles load |

Still required, with protocols in the plan: heavy real-site workloads at 1/10/30 tabs; memory pressure and long-session soak; launch, tab-switch and typing latency p50/p95 with Instruments; physical-iPhone energy, thermal and background behavior; network request counts once sync work starts.
