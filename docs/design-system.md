# Oriv browser design system

Oriv is a privacy-first native browser for Mac and iPhone. The active interface covers browsing, tabs, bookmarks, history, downloads, profiles and browser settings. Workspace, tasks, trackers, AI and source monitoring are outside the current product scope.

## Appearance and typography

The shared palette and tokens live in `Apps/Shared/Theme.swift` and are compiled into both apps. **System** is the default and uses the Graphite palette. Light and Dark set Graphite explicitly. Black keeps its dark canvas. The choice belongs to the current profile. When the user turns on Sync on their devices, appearance syncs for that same profile across Mac and iPhone. The continuity allowlist includes `appearance`, keyed as `preference.<profile UUID>.appearance`; different profiles retain independent choices. With Sync off, the choice stays local. Website logins, cookies and passwords remain on the device inside the profile and are never synced. See [Appearance](appearance.md) for the exact palette and website-color behavior.

Use semantic theme roles for colors. Main text belongs in address fields and secondary text is used for hints and supporting text. Increase Contrast strengthens secondary text and boundaries. Native controls inherit the platform accent. Selection includes a checkmark or a 3 pt leading marker whose system-accent hue is preserved when lightness needs adjustment for contrast. Purple glasses and explicit labels identify private browsing independently of the connection-security icon.

Use system text styles for iPhone controls and content so Dynamic Type can reflow. Toolbar glyphs retain compact, labeled targets while text grows. At accessibility text sizes the appearance picker becomes one column and hides decorative previews. Mac controls use native text fields, menu commands and familiar keyboard shortcuts. Use system sans-serif throughout. The Mac profile name uses 17 pt semibold and sheet titles use 15 pt semibold. Sidebar section headings use 11 pt semibold secondary ink, and counts use 11 pt regular. The active sidebar row uses 13 pt medium.

## Shared metrics and content

Use the shared tokens in `Theme.swift` for new UI. Document local platform geometry with `// oriv:raw-metric <reason>`.

| Family | Values and mapping |
| --- | --- |
| `OrivSpacing` | `xxs` 2, `xs` 4, `small` 8, `medium` 12, `large` 16, `larger` 20, `xl` 24, `xxl` 32 pt |
| `OrivRadius` | `badge` 6, `control` 8, `tile` 10, `panel` 12, `card` 14, `thumbnail` 18 pt, and `capsule` |
| `OrivType` on Mac | `windowTitle` 17 semibold, `title` 15 semibold, `headline` 13 semibold, `body` 13, `bodyEmphasized` 13 medium, `detail` 12, `caption` 11, `sectionLabel` 11 semibold, `badge` 10 medium |
| `OrivType` on iPhone | System Dynamic Type styles from title 3 through caption 2 |
| Layout and targets | `OrivLayout` supplies row, control and content dimensions. `OrivTarget` defines Mac minimum, toolbar and rail targets and iPhone touch and bar targets |
| Icons and motion | `OrivIcon` sizes SF Symbols. `OrivMotion` supplies quick and standard fades, a navigation spring and a reduced-motion cross-fade |
| Elevation | `OrivElevation` supplies flat, overlay and drawer recipes |

Use `textTertiary` on `canvas`, `surface`, or `surfaceRaised`. Use `danger` for
errors, recording and destructive buttons, `success` for confirmations, and
`private` on `privateWash` for private status. `onAccent(for:)` calculates ink
for an app-owned accent fill. Existing renamed roles forward to the v2 tokens.

`PageRowContent` shares the site favicon (with local monogram fallback), title, disambiguated address and optional “Already open” badge or selection checkmark. Mac keeps compact inline rows (title only in its tab sidebar); iPhone stacks the address and moves the accessory underneath at accessibility text sizes. Titles may use two lines at accessibility sizes; addresses always use one line with middle truncation so host, port and path tokens never split across lines. Pass each visible list’s `URLDisplay.Context`. Full URLs remain available as accessibility custom content named “Address”; Mac callers keep hover help. Buttons, List/Form selection, close targets, swipe actions and context menus belong to the platform container. Keep the existing 24 pt Mac and 44 pt iPhone minimum control targets.

`BrowserEmptyState` shows one explanatory message and an optional native action. Use it for empty home, saved-page lists, downloads, website data, other-device states and searches with no matches. The message wraps at accessibility sizes; do not add a decorative icon, separate heading or second explanatory paragraph. Both platforms use `PageErrorState` with the attempted host, a diagnostic, and **Try Again**.

The four `OrivMaterial` roles are `navigation` for the Mac sidebar, `control` for
interactive system glass, `overlay` for a solid floating surface with a border and
shadow, and `sheet` for native presentation. Page content, settings, and libraries
use solid or native grouped surfaces.

Liquid Glass belongs to the navigation layer, the Mac sidebar, iPhone bars and floating controls. Use system foreground styles where controls sit on glass. Keep start pages, settings and libraries on solid or native grouped surfaces. The appearance modifier disables SwiftUI transaction animations under Reduce Motion. Glass controls use solid accessibility backings under Reduce Transparency or Increase Contrast. Native sheets and menus inherit the system material preferences. Site monograms use BrowserCore’s small `SiteMonogram` suffix hint, never for security, storage or sync decisions.

## Navigation

Mac: a native toolbar with one address/search field, a vertical tab sidebar, and a browser content area. The start-page search affordance focuses that same field. Suggestions are available from any page. Bookmarks, history and downloads open from the sidebar; Settings is labeled explicitly.

The Mac header’s **Browser Actions** ellipsis opens a native SwiftUI pull-down `Menu`. Its 36 × 32 pt target uses the shared toolbar button style. The menu inherits system material, selection, dismissal, keyboard navigation and accessibility. Group Bookmark (with its current state), Copy Link / Copy Original Link and Find first, followed by a zoom section (Zoom In, Zoom Out, Actual Size with the current percentage; a palette hid the reset label in practice), tab actions (including active downloads), and Sync / reading / privacy / Password AutoFill Help. Keep page-dependent and private-tab disabled states. Password help opens a popover from its menu action. Do not reintroduce a full-window tap-catcher or a custom menu panel. The native menu inherits the platform’s accessibility material preferences. Off-screen captures verify toolbar layout only; a menu tracking window must not be opened under the background-only policy.

On iPhone, the bottom browser controls contain Back, Forward when available,
the address capsule, and Show All Tabs. The capsule keeps Page Menu and Reload
alongside the address in regular and private browsing. Page Menu groups link
actions, page tools, site actions and Settings. Open Library from Tab actions
in the grid. Library links to Bookmarks, History, Other devices and Downloads.

The iPhone tab grid uses a native **Tabs / Private** segmented control and a
separate profile chip. The chip shows the active profile name and symbol in
its profile tint. At accessibility text sizes it moves into the top toolbar.
New Tab follows the selected segment. Done returns to a tab in that mode or
opens a blank tab when the mode is empty. The grid retains swipe-to-close and
the browser address capsule retains swipe-up to open the grid.

The resting address shows the host, or **Search** on a blank tab. The editor
exposes the full URL with native selection and a clear button. Its keyboard
layout guide anchors the editor and sets the available height for suggestions.
Suggestions grow upward from the field as a solid panel. The highest-ranked
result is closest to the field. VoiceOver traversal follows rank within each
group, and Up Arrow selects from nearest to farthest. Results scroll when they
reach the top safe area. Private tabs keep a glasses cue and a private-wash
top band.

Site settings shows the exact origin, connection state, protections and
permissions. Reload Page applies changes. Reset This Site restores default
protections and permissions after confirmation. Forget This Site separately
removes browsing data. Appearance uses a border and checkmark to indicate the
selected choice, with one column at accessibility text sizes.

## Shared behavior

- Local address suggestions use the active profile only. Regular tabs can suggest regular tabs, bookmarks and history; private tabs suggest only open private tabs. Results deduplicate by URL and prefer an already open tab. Nothing is sent to a search provider until submission.
- A saved link reuses an empty regular tab. Otherwise it opens a new regular tab, preserving a loaded page or private tab. An explicit Open in new tab always adds a tab.
- Both apps confirm closing a page after trusted form input. This is an edited-field signal, not a promise that the website's data is unsaved or saved.
- Removing a bookmark offers one-level Undo, restoring its metadata and position without creating duplicates. Other destructive actions state their scope and use confirmation where recovery is unavailable.
- Download feedback reports actual activity, bytes, completion or failure. Mobile downloads are temporary until saved or shared; their list is not restored across launches.
- Empty libraries and searches with no matches have distinct messages. Success messages do not use error titles.

## Native behavior and acceptance

Preserve existing WebKit instances during address editing and sheet navigation. Native scrolling, focus, sheets, menus, system permission prompts and selection behavior take precedence over decoration. Keep large content readable, avoid nested global navigation, and use explicit scope language for profile data and privacy controls.

Release acceptance still includes real-device reachability, VoiceOver and Full Keyboard Access, Increase Contrast and Reduce Transparency, landscape/narrow layouts, localization and media/camera permission flows. Local build and simulator evidence does not establish complete accessibility, HIG or web-standards conformance. Current evidence is recorded in [the UX implementation report](ux-implementation.md).

## Site identities and address results

`SiteIdentity` uses the profile/session icon environment. Keep the monogram as a
fallback and the separate glasses/text cue for private browsing. The Mac sidebar draws site artwork full bleed at 19 pt in rows, 24 pt in pins
and 22 pt in the rail. Decode-time alpha and dominant glyph luminance analysis
adds a contrasting light or dark plate only when a transparent mark would vanish
against its panel or selection. Other lists and iPhone retain their existing
icon presentation and shared cache.

Address results use shared `AddressSuggestionRow` content and native field
editors. Group up to seven local matches under Switch to Tab, Bookmarks and
History, followed by one explicit Search row. Highlight query text in title and
address; keep selection visible with the existing marker. Both platforms place suggestions on solid overlays.
The group heading says “Switch to Tab” and the row badge says “Already open.”
Inline completion selects only the host suffix; accepting it is distinct from
choosing a result. Local ranking uses prefix strength, bookmarks, visit frequency
and recency; an actor maintains normalized prefix and trigram indexes off-main.

## Mac sidebar and rail

The Mac sidebar is a single system Liquid Glass panel flush with the window edge.
The expanded panel is 256 pt wide with an 8 pt horizontal content inset. The icon
rail is 72 pt wide. The existing toggle and
⌥⌘S animate between them, respecting Reduce Motion. The address editor and page host retain their identity.

The expanded sidebar and icon rail use one `MacSidebarGlass` backing. **Sidebar color**
in the Mac’s per-profile Appearance settings offers Graphite, Profile color and seven
Pastel swatches. Name every swatch and mark the selected choice with a checkmark
and the selected accessibility trait. Graphite is the fallback for unset or unknown
preferences and profile-less private windows, including windows opened by external links.
The choice lives in device-local profile defaults. The active controller supplies the
backing at the existing profile switch handoff. Black keeps its near-black backing
and disables the swatches while keeping the saved choice. See [sidebar backing tokens](appearance.md#mac-sidebar-color).

**Glass opacity** applies to all profiles. Balanced uses 55% backing, High uses 80%,
and Solid uses the opaque backing. Balanced applies the appearance-specific
neutral guard detailed in [Appearance](appearance.md#mac-sidebar-color). Sidebar-only
secondary and private text use dedicated ink. Reduce Transparency and Increase Contrast
use the chosen opaque backing in both widths. Increase Contrast also uses stronger
secondary ink, a stronger panel boundary and selection outline. Rows and the footer
use neutral fills. The 3 pt marker and controls use the system accent, while purple
glasses and labels convey privacy. Page color continues behind the panel and titlebar.

The profile picker uses a primary-color stacked-tabs glyph, bold name, tab count
and chevron, followed by persistent Search tabs. Empty Pinned is hidden; a compact
pin target appears during a local tab drag. Section counts omit zero. Pinned tiles align with tab rows and occupy at most two rows of four; additional pins
appear as a labeled lazy list. Tabs and Private have independent headings and
counts. New Tab and the Library/Settings footer stay fixed while the tab
collection scrolls. The rail uses centered 42 × 36 pt icon targets, a 15 pt selection marker and no
close button. Search and New Tab form its top group; Library and Settings form
its bottom group. It retains full accessibility labels, context-menu closing and
a search button that expands the title-bearing results.

Search filters only active-profile tab metadata by title or hostname, including
pins and private tabs in a separate section. It never instantiates a webview.
⇧⌘A expands the sidebar and focuses search; Escape clears it and returns focus
to the selected tab. Matching pins become titled rows during search. A selection
outside the current filter clears it. Arrow keys navigate the grid/list, Return
activates, and Tab/Shift-Tab reach controls and close buttons. Down Arrow from
the toggle enters the selected tab; focus waits for a lazy target to mount.
Focus ownership stays with the containing window during collapse. Down Arrow from
the sidebar toggle enters the selected tab, including in the rail. Titles, hosts,
selected/pinned/private/loading/audio states are spoken; favicons are decorative.
Close remains an accessibility action and a keyboard/VoiceOver control when its
glyph is hidden. Pins close through their context menu or ⌘W.

Pin/unpin commands use the existing `TabRecord.isPinned` model and version-3
session snapshot; no migration is needed. Dragging onto Pinned pins a regular
tab, and dropping onto Tabs unpins it, appending to the destination group. Row
and tile drops reorder within the current pin/privacy section. Drags are scoped
to the controller, so another window/profile cannot move its tabs. Move Up/Down
provide keyboard alternatives. Private tabs reject pinning in both the UI and
model. Bulk close preserves pins and the other privacy group. Pinned tabs keep
the existing idle-discard exclusion alongside selected, private, edited, media,
capture, download and request-safety rules.

Optional continuity already allows `TabRecord.isPinned` in regular-tab metadata,
with profile/device ownership and pinned-first ordering. Pins therefore use that
existing path; no new payload, preference or allowlist is added. Receiving remote
tabs does not replace local tabs. Private tabs never enter session persistence
or continuity. The search query and rail focus remain local transient state.

Rows reuse `SiteIdentity`/`SiteIconStore`'s bounded shared cache. The normal,
overflow-pin and private collections use a lazy stack with stable tab IDs. Audio
indication is event-driven for HTML audio/video, including child frames; there
are no per-row timers or playback polling loops. Web Audio-only pages require a
separate future public-API strategy; pause/block still applies through WebKit.

At narrow expanded widths, Share remains available in Browser Actions and New Tab
remains in the sidebar. The address capsule keeps a 230 pt minimum and centers
on the page viewport. Active downloads also have a sidebar badge.

The sidebar uses Graphite or the equivalent Black colors. The 32 pt search field
and rows use 8 pt corners. Pinned tiles and rail selections use 10 pt corners.
The footer puts Bookmarks, History, Downloads, Other devices and Settings directly
on the sidebar glass. Each control has a minimum 24 pt target, an accessibility
label, and keyboard focus feedback. Selection uses a neutral fill and a leading accent marker. Hover
uses a quieter solid fill. The 60 pt page header retains monochrome controls and
the filled address capsule in the page-derived color band. Browser Actions retains
its 36 × 32 pt target. Suggestions float in a solid 12 pt panel with a quiet shadow.
Restored pages receive initial native web-content focus and empty tabs focus
the address editor. Keyboard navigation retains the system focus ring.

The Mac start page aligns its 640 pt content column with the address capsule
and uses a four-column tile grid at standard text sizes. The private start page
uses the shared private banner and a short explanation on the private surface.
iPhone uses three flexible columns at standard text sizes and one column at
accessibility text sizes. Both use
solid tiles and secondary section labels. Mac settings use native grouped
forms and the system window background. Library counts appear beside their
section names on the surface, with list content on the canvas. Find in Page
uses the shared search field and toolbar controls. Glass opacity applies to all
profiles.


## Copy and verification

Use US English and sentence case for labels, headings and settings. Use title case
for commands. Keep shared labels in `OrivStrings.swift`, including **Sync**,
**Other devices**, **Search or enter address**, **Site Privacy**, and **Try Again**.
Protection list versions appear in About.

`scripts/check-browser.sh` checks the per-file raw-token baseline and contrast.
Lower the baseline when a migration removes literals. The contrast gate includes
status and private roles, solid controls, and every sidebar tint and glass level
over synthetic extreme inputs.

For Mac gallery snapshots, set `ORIV_BACKGROUND_UI=1` and
`ORIV_GLASS_SCENE=design-system` and run `scripts/capture-mac-visuals.sh --glass`.
For the iPhone gallery and browser inventory, select an isolated simulator and
derived data folder with `ORIV_IOS_SIMULATOR_ID` and `ORIV_IOS_DERIVED_DATA`,
then run `scripts/capture-iphone-design.sh <output-directory>`. Both use synthetic
fixtures. Live glass compositing and VoiceOver require a foreground or device check.

## Component catalogue

Shared SwiftUI components live in `Apps/Shared/Components`. Platform controls live in `Apps/macOS/Views/Components` and `Apps/iOS/Components`.

| Component | Use |
| --- | --- |
| `orivButton` | Primary, secondary, quiet, destructive and link roles. Native bordered styles supply keyboard and accessibility behavior. Quiet actions use hover and press fills. Busy actions expose an in-progress value and are disabled. The external-private handoff uses the contrast-resolved accent fill on iPhone. |
| `ToolbarButton` | Page-adaptive ink and a shared Mac toolbar hit area. Inline address controls use the same style at the smaller target. Hover, press and active states use 7%, 12% and 16% capsule fills. The system tracks the Browser Actions menu and ShareLink. |
| `BarButton` | iPhone control glass and 48 pt bar targets, with a 44 pt variant for Forward. Glyphs grow with Dynamic Type up to the icon cap. Native history and tab menus own their primary actions and long-press behavior. |
| `PageRowContent` | Inline, stacked and title-only site rows with highlighted suggestion text, private and loading icons, and optional selected and already-open accessories. |
| `ListSelection` | List fill and leading marker, card border, and a stronger Increase Contrast outline. Appearance choices add a checkmark. Platform containers set the selected accessibility trait and own keyboard navigation and focus. |
| `SettingRow` | Native toggle, picker or action followed by optional inline helper text. This keeps each control and its explanation in one form row. Native controls retain disabled and focus behavior. |
| `SectionHeader` | Sidebar title and count, content title with optional Show All, and suggestion group label. Forms use native section headings. |
| `OrivPopover` | Native Mac popover content with a title, optional symbol and scrollable overflow at the height cap. BrowserPopover still routes Escape, Tab and responder restoration. |
| `OrivSheet` | Native presentations with a shared title, optional subtitle, content and trailing actions. Mac widths are 420, 560 and 760 pt. Busy and error lines sit above or beside the actions. Cancel is the default for destructive confirmations. Library uses the same title style in its split layout. |
| `OrivSearchField` | Mac sidebar and content fields with 32 pt chrome, magnifier, clear action and optional shortcut hint. Callers own focus and key commands. The sidebar fill becomes opaque with focus or accessibility settings. iPhone content searches use native searchable navigation. |
| `OrivBanner` | Info, success, warning and private notices with optional action and dismiss. Minimum height is 32 pt on Mac and 44 pt on iPhone. At accessibility sizes the text wraps above the actions. The external-private destination picker shares the banner label and colors. |
| `Badge` | Neutral Already open, private and count labels. Counts may use an unfilled variant. |
| `BrowserEmptyState`, `PageErrorState` | Shared empty and retry presentation. Retain the caller’s container, full attempted host and optional recovery action. |
| `Tile` | Start-page and pinned surfaces, appearance choices and sidebar swatches. Tiles share their radius and card selection treatment while the platform retains input handling. |

The debug design-system scene captures foundations, controls, rows, notices and presentations in Light, Dark and Black with standard, reduced-transparency and increased-contrast settings. The iPhone inventory includes accessibility-sized text. Offscreen captures show the fallback material on Mac. Check live menu tracking, glass compositing, keyboard traversal and VoiceOver on an authorized foreground or physical-device pass.
