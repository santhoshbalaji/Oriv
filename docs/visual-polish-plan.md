# Visual polish plan after visual pass 1

Prepared 5 November 2026. This plan follows visual pass 1, which was implemented in the working tree but not committed, and its three-model council review. It includes the Astra 6 xhigh review of the first draft. It refines WP4, WP5 and WP10 of the [design and efficiency plan](design-efficiency-plan.md). Milestone order, the sync and privacy gates and the production release hold still belong to the [implementation plan](browser-implementation-plan.md).

## Where we are

Visual pass 1 council scores. Scale 1–10; the mean is across Opus 5.5 high, Astra 6 xhigh and Sol 6.1 xhigh.

| | Before | After pass 1 |
| --- | ---: | ---: |
| Overall | 6.0 | 7.3 |
| Mac | — | 7.0 |
| iPhone | — | 7.8 |

Criterion means after pass 1:

| Clean | Hierarchy | Consistency | Platform | Usability | Accessibility | Implementation |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 8.7 | 7.7 | 7.0 | 7.7 | 6.7 | 6.0 | 7.0 |

"Clean" is already high, so removing more will not raise the score. The remaining points are in four areas:
- accessibility
- clear states, especially privacy, security and selection
- telling similar pages apart
- evidence the council can check

Astra predicts these overall scores, ±0.3 and assuming the work is verified:
- 8.0 after Round 1 fixes
- 8.2 once the Round 1 evidence is added
- 8.5 after Round 2

The largest single gain is a clearly visible active tab in both Mac sidebar modes.

## Principles

1. **Fix findings before collecting evidence.** Evidence alone moves scores only a little.
2. **Keep the T3 palette.**
   - `#346BF1` stays for fills, focus, selection and toggles.
   - `#5B8CFF` is for accent-coloured text only.
   - Increased Contrast overrides are kept.
   - Selection is a narrow blue indicator, not a brighter fill.
3. **Share tokens and row content, not behaviour.** Mac and iPhone keep their own selection, swipe, context-menu and close-button patterns.
4. **No privacy cue is removed** unless another cue remains visible persistently.
5. **Every claim in a council packet comes from a run with a manifest.** No reused or stale images.
6. **Visual passes stay away from engine internals.** They change no sync format, persistence or engine behaviour.

## Round 1: council fixes

Work in this order. Tests and interaction checks are written alongside each step, not at the end.

### 1. Capture provenance (`scripts/capture-mac-visuals.sh`, `Apps/macOS/VisualSnapshots.swift`)

- **Fresh output.** Each run writes to a new `build/visual-runs/<timestamp>-<platform>/` directory. The script refuses an existing, non-empty output directory and never deletes one.
- **Manifest.** The harness writes `manifest.json` with:
  - the scene list
  - the build configuration
  - the OS version
  - the start and end times
  - a hash of `git diff HEAD`
  - each image's pixel size and SHA-256
- **Fail loudly.** A failed image write makes the harness exit with a non-zero status; replace the swallowed `try?`. The script checks:
  - the exit status
  - that the expected scene count matches the manifest
  - that every image was written after the run started
- **New Mac scenes:**
  - Settings Appearance and About panes
  - private start page
  - keyboard-selected suggestion
  - inactive (non-key) window variant of the main window
  - an attempt at a loaded local page. If WebKit content does not render in-process, record that as a limitation instead of faking it.
- **iPhone captures** go into the same run structure, with a manifest that records the device, the OS and the app build.

**Done when:** a deliberately broken scene makes the script fail, and two consecutive runs produce two separate, complete directories.

### 2. Privacy and security cues

- **iPhone private tabs.** The private indicator (eyeglasses) stays visible in the address bar while you edit a new private tab, not only once a URL exists. Location: `Apps/iOS/MobileBrowserView.swift`.
- **Mac private start page.**
  - The copy describes private tabs, not "this window". Check the wording against `BrowserWebConfiguration` (the non-persistent data store) before it ships.
  - Remove the duplicate banner on the private start page only. Loaded private pages keep their address-field cue.
- **"Not secure".**
  - Plain-HTTP pages show the visible text "Not secure" next to the existing `exclamationmark.shield`, on both platforms.
  - The text and glyph use a new `warning` token, a muted amber. It is used for nothing else.
  - The value is chosen with the contrast check (step 6): at least 4.5:1 on the toolbar and field surfaces, for T3, Classic and Increased Contrast.
- **Camera and microphone indicators** stay red, unchanged.

**Done when:** iPhone captures exist for a private tab while editing and for an HTTP page, the Mac private start page shows a single correct message, and the copy has been checked against the engine.

### 3. Selection, keyboard focus and targets

- **Accent split.**
  - Text controls inherit `.tint(accentText)`: macOS 27 Form picker values and plain text buttons use tint, as iOS does.
  - Fills, toggles, focus rings and selection opt in to brand `accent` / `controlFill` (`#346BF1`).
  - Accent text uses `#5B8CFF`, or `#79A5FF` in Increased Contrast.
- **Mac active tab.**
  - In both the expanded sidebar and the rail, the selected tab gets a narrow (3pt) `#346BF1` leading indicator on top of the existing selection.
  - The indicator needs at least 3:1 contrast against `#0A0A0A` and `#111111`.
- **Mac keyboard-selected suggestion.** Today it is `#1E1E1E` on `#111111`, about 1.13:1. It gets the same leading indicator.
- **Close buttons.**
  - Mac: visible on the selected, hovered and keyboard-focused row, with a 24×24 pt target.
  - iPhone tab list: a 44×44 pt target.
- **Keyboard focus on Mac.** With Full Keyboard Access on, the focus ring is visible on these controls:
  - the sidebar footer icons
  - start-page rows
  - Library rows
  - the New tab row
- **Target audit.** Every iPhone toolbar and row control is at least 44 pt; every Mac control is at least 24 pt.

**Done when:** captures exist of both sidebar modes, the keyboard-selected suggestion and keyboard focus. The contrast check covers the indicator.

### 4. Telling similar pages apart

- **Testable helper.** Move the secondary-line logic out of `Theme.swift` into a pure, testable helper. Rules:
  - Show the host when the title differs from it.
  - Add the path when two visible rows would otherwise read the same.
  - Add the query when the paths also collide.
  - Add the port when it is non-default.
- **Where it applies:**
  - Mac and iPhone suggestions
  - the start page's Bookmarks and Recent
  - Library Bookmarks and History
- **"Switch to tab"** becomes a trailing badge. The host stays visible.
- **Full URL access.** VoiceOver can reach the full URL as the row's value. The Mac keeps its hover help.
- **Tests:**
  - identical titles with different paths
  - the same path with different queries
  - the same host on different ports
  - an empty title
  - a title equal to the host
  - AddressAction search and go wording

**Done when:** the tests pass and a fixture capture shows two same-titled rows that can be told apart.

### 5. Large text sizes

- **iPhone layout at large sizes.**
  - Titles use one line at standard sizes and two lines at accessibility sizes (`dynamicTypeSize.isAccessibilitySize`).
  - Rows grow in height, and trailing controls stay reachable.
  - iOS text uses text styles, not fixed point sizes.
- **iPhone checks** at AX5 on the narrowest available Simulator, covering:
  - home
  - suggestions with the keyboard up
  - the tab list
  - Library
  - Settings
  - the page menu
- **Mac** has no Dynamic Type. Check the sidebar with long titles at its minimum width instead.

**Done when:** AX5 captures show no clipped primary text and no unreachable control.

### 6. Labels, casing and contrast check

- **Casing**, following Apple's guidelines:
  - Title Case for buttons and menu items ("New Tab", "Add Bookmark", "Reopen Closed Tab").
  - Sentence case for explanations and footers.
  - Applied to both apps from one string inventory.
- **iPhone Settings and zoom.**
  - The bare "Personal" row is labelled as the profile (VoiceOver: "Profile, Personal").
  - The zoom value reads "Page zoom, 100 percent".
- **Continuity settings.** Remove the duplicated "Device name" label in `Apps/Shared/ContinuityViews.swift` by hiding the redundant field label or prompt.
- **Mac address placeholder** uses `fieldText`, not `text`.
- **Contrast check.** Add `scripts/check-contrast.py`, from WP4. It checks every text and indicator token against every surface it appears on, in T3, Classic and Increased Contrast, and fails below the threshold. Add it to `check-browser.sh`.

**Done when:** the contrast check passes and the agent-device accessibility tree shows the new labels.

### 7. Evidence packet

Produce a fresh, manifested run for each platform.

**iPhone (Simulator):**
- A page that loads successfully (HTTP 200) from the local fixture server.
- The same fixture over plain HTTP, which shows "Not secure".
- A private tab while editing.
- AX5 text size.
- Increased Contrast.
- Light and System themes.
- The agent-device accessibility tree for each main screen.
- Activating the main controls by their accessibility label, to show that each label leads to the right action.

**Mac (in-process harness):**
- active and inactive windows
- keyboard focus
- every Settings pane
- the private start page
- the selected suggestion
- the selected tab in both sidebar modes

**Not possible here.** A real VoiceOver walk-through cannot run in the iOS Simulator or without Mac permissions. The packet says so, and the walk-through goes to the owner's physical-device session.

**When explicitly requested by the owner:** run the council with the same three models, rubric and output format. Compare against the pass-1 "after" captures and the original "before" captures.

## Round 1 status — 5 November 2026

Evidence packet updated 9 November in `build/visual-pass-2/`; no council had run at that evidence-assembly stage. The subsequent council is recorded below. It retains the final Mac runs (19 active / 18 inactive scenes) and adds 14 manifested iPhone captures from a rebuilt Simulator Debug app, 0.6.0 (6): AX5 compact `Search “docs”`, Light/System home, suggestions and Settings, plus T3 Code restoration. The pass-1 rubric is unchanged and the 25-file round patch reproduces current source.

AX5 Settings remains not verified after three ineffective menu-scroll attempts; optional AX5 History was not attempted. Increased Contrast, VoiceOver, Full Keyboard Access and historical provenance limits remain explicit in `NOT-VERIFIED.md`. New observations: Light leaves the current Settings sheet dark until reopened; the retained active Mac Passwords capture is blank. No fixes were made in this evidence phase.

Current checks pass: BrowserKit 37 tests / 8 suites, contrast 68/68, browser scope, iOS Debug build, and `git diff --check`. Simulator text size is restored to `large`, Appearance confirms T3 Code, and the device panel is closed. App source and stable data were untouched; no commits, Mac/physical-device installations or releases occurred. The production release hold stays in place.

## Round 1 council (9 Nov 2026)

The three independent reviews found improvement but did not fully accept Round 1. The supplied mean scores are 7.7 overall, 7.7 Mac and 7.9 iPhone; accessibility is 6.3. [Full council results](../build/visual-pass-2/COUNCIL-RESULTS.md) preserve the score table, verified findings and strengths.

Must-fix findings are low-contrast Mac accent text, real input contaminating active Mac captures, and Classic Light secondary-text contrast. Other requested fixes cover live iPhone theme updates, non-default ports under host titles, zoom labels, Title Case, neutral mixed-content cues and AX5 reachability. The 3 pt selection marker, HTTP-only amber warning, URL helper, private cues and harness provenance were recognized as improvements.

The owner authorized a UI/accessibility fix round only. Its fresh evidence belongs in `build/visual-runs/round1-fix-mac-inactive/`, `round1-fix-mac-active/`, and `round1-fix-iphone/`; the validation report records tested results and remaining limits. Session/history/sync/engine behavior and the production release hold remain outside this round. No new council or scoring is authorized by this fix round.

## Round 2: selective consistency

- **Tokens.**
  - A small Mac type scale.
  - Text-style mapping on iOS.
  - Spacing steps of 4, 8, 12, 16, 24 and 32.
  - Corner-radius tokens.
  - These replace scattered literal values.
- **Shared row content.** One view (site icon, title, secondary line) is shared by start page, Library, tab and suggestion rows. Each platform keeps its own container behaviour.
- **One empty-state pattern:** one line plus an optional action, used everywhere.
- **Accessibility settings.** Check Reduce Motion and Reduce Transparency, and remove any material or animation that ignores them.
- **Site icons for multi-part domains.** Handle addresses such as `bbc.co.uk` with a small list of common second-level suffixes. The full public suffix list is not bundled. This step deliberately comes last.

**When explicitly requested by the owner:** a council run, with the existing target of 8.5 overall.

## Council protocol

The council runs **only when the owner explicitly asks**. It is no longer automatic after each round. Implementation and evidence collection do not authorize a council run.

- **Packet:**
  - the brief, with the rubric unchanged so scores stay comparable
  - the patch for the round
  - before and after captures with their manifests
  - a list of what was not verified
- **Reviewers:** Opus 5.5 high, Astra 6 xhigh and Sol 6.1 xhigh, each working independently and read-only.
- **Results:**
  - Record a score table and verified consensus findings in `build/visual-pass-N/COUNCIL-RESULTS.md`.
  - Verify each must-fix in the code before acting on it.
  - Copy a short summary into this document.

## Decisions

**Settled (owner, 5 Nov 2026):**
- Casing: Title Case for buttons and menu items, sentence case for explanations.
- Muted amber is used only for "Not secure".

**Still open:** whether to commit the current dirty worktree as a local baseline. Nothing is committed without explicit approval.

## Owner participation

These need the owner's devices or permissions. They are batched with the physical-iPhone session in the design and efficiency plan:
- a VoiceOver walk-through on iPhone and Mac
- the largest text size on the physical iPhone
- Mac web-content captures

## Constraints

- No installation, publication or commit without a separate request.
- The production release hold stays in place.
- Original user data and stable app data are untouched.
- Test builds use isolated bundle identifiers and synthetic data only.
