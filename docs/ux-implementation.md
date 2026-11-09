# Browser UX implementation — 4 November 2026

This is local development work on `t3/implementation-goal-review`. It implements the actionable browser UX review while preserving the T3 Code appearance. It is not a released build, a physical-iPhone result or a claim of complete browser-standards/accessibility conformance.

## Implemented

- Shared local address suggestions with privacy/profile separation and URL deduplication. Mac suggestions work on every page with arrow-key selection and Return; the start page focuses the same native address field. iPhone uses a native full-URL editor with selection, clear and Cancel.
- Persistent private-mode text and icon, separate from encrypted/not-secure connection state. iPhone keeps the private label visible while editing an address.
- Shared saved-link behavior: reuse an empty regular tab; otherwise open a new regular tab. An explicit new-tab action always creates one.
- iPhone edited-form close confirmation on both the visible close button and swipe action. Keep tab preserves the page. The app reports that it cannot know whether the site saved the edits.
- iPhone's Browse/Bookmarks/Settings tab bar replaced by one browser toolbar. Library groups bookmarks, history and downloads; tabs are searchable, grouped by privacy, counted and visibly selected. Settings is a sheet scoped to the current profile.
- iPhone per-site blocker exceptions, camera/microphone Ask/Block, popup controls, capture stopping, website-data removal and granular history/cache/cookies/permission clearing with explicit scope and confirmations.
- Profile creation, rename, archive and restore on iPhone; profile names and device-local preference scope in the UI. Archive preserves regular data and warns that private edits are lost.
- One-level bookmark-removal Undo on both apps, preserving record metadata/order and preventing duplicate restoration. Success notices are separate from error alerts. No-match and empty Library states differ.
- Download activity indicators and real mobile progress/bytes, cancellation and completion feedback. Mobile files are temporary until saved/shared; the list is not restored and resumable mobile downloads are not implemented.
- Large-text iPhone appearance picker uses one column and hides decorative previews. The resting address retains a readable host; the editor height scales with text. Native toolbar icons keep usable fixed targets.
- Stronger Mac selected-tab indication, readable field placeholders/metadata, explicit Settings label, distinct profile colors and darker filled-button tint under Increased Contrast.
- Current design documents rewritten for the browser-only product scope.

## Verification

| Check | Result |
| --- | --- |
| Shared package `swift test` | 21 tests passed |
| Targeted Mac native tests | 17 passed: BrowserExperienceTests (4), private-suggestion regression (1), BrowserQualityIntegrationTests (12) |
| iPhone Simulator native tests | BrowserExperienceTests: 4 passed |
| Final Mac Debug and iPhone Simulator Debug builds | Passed after layout/focus corrections |
| Mac signature, browser-scope guard, whitespace checks | Passed |
| Original checkout and installed Mac builds | Original source baseline 144/144 unchanged; installed release/dev binary hashes unchanged |

The four new shared-engine tests run inside both native hosts. They cover suggestion isolation/deduplication, bookmark Undo persistence and duplicate handling, saved-link tab policy, and edited-field close policy/reset. The edited-field unit test posts the internal signal; live simulator typing separately verified the trusted-input path and Keep tab preservation.

Live Mac checks used a separate derived build with `BROWSER_TESTING=1`: initial/new-tab focus, Command-L selection, local suggestions on blank and loaded pages, keyboard and mouse suggestion selection, cancellation, bookmark removal/Undo and independent private/security indicators. Live iPhone checks used the dev Simulator app: address navigation, edited-form close/Keep tab, tab groups/counts, temporary download completion, Library and Settings navigation, private-mode cues, new-tab focus, sheet dismissal without unwanted keyboard focus, and the maximum accessibility text size. Simulator text size was restored afterward.

Local logs, result bundles and screenshots are under `build/ux-implementation/` (ignored by Git). The app was updated in the simulator only. The Mac installation, original checkout, personal browser data and remote repository were not changed.

## Remaining acceptance

Physical-iPhone ergonomics and landscape/narrow-device layouts; VoiceOver and Full Keyboard Access; a comprehensive Increase Contrast/Reduce Transparency audit; real camera/microphone, system AutoFill/passkey and sharing flows. Profile archive/restore and data-clearing UI require broader acceptance beyond their shared engine tests. Bottom-address placement and scroll-collapsing chrome remain unimplemented experiments. No sync or removed productivity features were reintroduced.
